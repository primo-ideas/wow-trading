use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use anyhow::{Context, bail};
use chrono::Utc;
use clap::{Parser, Subcommand};
use tracing_subscriber::EnvFilter;

use wow_market_fetcher::api::AuctionApi;
use wow_market_fetcher::api::blizzard::{BlizzardClient, Credentials, Endpoints, RetryPolicy};
use wow_market_fetcher::api::stub::StubApi;
use wow_market_fetcher::config::{Region, RealmSelection, Scope};
use wow_market_fetcher::pipeline::{FetchOptions, Fetcher, RegionSource};
use wow_market_fetcher::simulation::Simulation;
use wow_market_fetcher::store::Store;

const STUB_HISTORY_HOURS: i64 = 7 * 24;
/// Added to the database name with `--stub`: sample data must never end up in the
/// real price history.
const STUB_DATABASE_SUFFIX: &str = "_stub";

/// `once` found markets it could not ingest, as opposed to not being able to run at all.
const EXIT_PARTIAL_FAILURE: u8 = 2;

/// Fetches WoW auction house data from Battle.net into Postgres.
///
/// Reads DATABASE_URL, BLIZZARD_CLIENT_ID and BLIZZARD_CLIENT_SECRET from the
/// environment, the file given with --config, or a .env file. A variable already
/// set in the environment wins over a file.
#[derive(Parser)]
#[command(version)]
struct Cli {
    #[command(subcommand)]
    command: Command,

    /// File of KEY=VALUE lines holding the credentials
    #[arg(long, global = true)]
    config: Option<PathBuf>,

    /// What to fetch: eu, eu/hyjal, eu/commodities, or several separated by commas.
    /// Default: every realm of every region
    #[arg(long, global = true, env = "WOW_SCOPE")]
    scope: Option<Scope>,

    /// Language of item and realm names
    #[arg(long, global = true, env = "WOW_LOCALE", default_value = "fr_FR")]
    locale: String,

    /// Simultaneous API requests per region
    #[arg(
        long,
        global = true,
        env = "WOW_CONCURRENCY",
        default_value_t = 4,
        value_parser = clap::value_parser!(u16).range(1..)
    )]
    concurrency: u16,

    /// Most items to look up per cycle
    #[arg(long, global = true, env = "WOW_ITEM_BATCH", default_value_t = 5000)]
    item_batch: usize,

    /// Days of hourly detail to keep before rolling them up into daily statistics
    #[arg(
        long,
        global = true,
        env = "WOW_HOURLY_RETENTION_DAYS",
        default_value_t = 14
    )]
    hourly_retention_days: u32,

    /// Serve a simulated week of sample data instead of calling Battle.net, in a
    /// separate database. Needs no credentials
    #[arg(long, global = true)]
    stub: bool,
}

#[derive(Subcommand)]
enum Command {
    /// Run a single cycle and exit. Exit code 2 means some markets failed.
    Once,
    /// Run cycles until interrupted.
    Watch {
        /// Seconds between two cycles
        #[arg(
            long,
            env = "WOW_POLL_SECONDS",
            default_value_t = 600,
            value_parser = clap::value_parser!(u64).range(1..)
        )]
        poll_seconds: u64,
    },
}

#[tokio::main]
async fn main() -> ExitCode {
    match run().await {
        Ok(code) => code,
        Err(error) => {
            eprintln!("error: {error:#}");
            ExitCode::FAILURE
        }
    }
}

async fn run() -> anyhow::Result<ExitCode> {
    // Parsed twice: finding the file takes the command line, and the file can
    // provide what the command line defaults to.
    let config = Cli::parse().config;
    load_environment(config)?;
    let cli = Cli::parse();

    let default_filter = if cli.stub { "warn" } else { "info,sqlx=warn" };
    let filter =
        EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new(default_filter));
    tracing_subscriber::fmt().with_env_filter(filter).init();

    let url = std::env::var("DATABASE_URL")
        .context("DATABASE_URL must be set, for example by run.ps1 or in a .env file")?;
    let options = FetchOptions {
        concurrency: usize::from(cli.concurrency),
        item_batch: cli.item_batch,
        hourly_retention_days: cli.hourly_retention_days,
    };

    if cli.stub {
        // A week of curves for the whole world would only slow the demonstration down.
        let scope = cli.scope.unwrap_or_else(|| Scope::single(Region::Eu, RealmSelection::All));
        let url = with_database_suffix(&url, STUB_DATABASE_SUFFIX)?;
        let fetcher = build_fetcher(&url, &scope, options, |_| Ok(StubApi::with_fixtures())).await?;

        println!("Simulating {STUB_HISTORY_HOURS} hours of auctions...");
        for hour in Simulation::ending_at(Utc::now(), STUB_HISTORY_HOURS).hours() {
            for source in fetcher.sources() {
                Simulation::publish(&source.api, *hour);
            }
            fetcher.run_cycle().await?;
        }
        return finish(&fetcher, cli.command).await;
    }

    let Some(credentials) = Credentials::from_env() else {
        bail!(
            "BLIZZARD_CLIENT_ID and BLIZZARD_CLIENT_SECRET must be set (see .env.example), \
             or pass --stub to run on sample data"
        );
    };
    let scope = cli.scope.unwrap_or_else(Scope::everything);
    let locale = cli.locale;
    let fetcher = build_fetcher(&url, &scope, options, |region| {
        Ok(BlizzardClient::new(
            credentials.clone(),
            Endpoints::for_region(region),
            region,
            locale.clone(),
            RetryPolicy::default(),
        )?)
    })
    .await?;
    finish(&fetcher, cli.command).await
}

fn load_environment(config: Option<PathBuf>) -> anyhow::Result<()> {
    match config {
        Some(path) => {
            dotenvy::from_path(&path).with_context(|| format!("cannot read {}", path.display()))
        }
        None => match dotenvy::dotenv() {
            Err(error) if !error.not_found() => Err(error).context("cannot read .env"),
            _ => Ok(()),
        },
    }
}

async fn build_fetcher<A: AuctionApi>(
    url: &str,
    scope: &Scope,
    options: FetchOptions,
    api_for: impl Fn(Region) -> anyhow::Result<A>,
) -> anyhow::Result<Fetcher<A>> {
    let regions = scope.regions();
    // Every simultaneous request may end up writing, plus the item lookups.
    let connections = u32::try_from(options.concurrency * regions.len() + 2).unwrap_or(u32::MAX);
    let store = Store::open(url, connections).await?;

    let mut sources = Vec::with_capacity(regions.len());
    for (region, realms) in regions {
        sources.push(RegionSource {
            api: api_for(*region)?,
            region: *region,
            realms: realms.clone(),
        });
    }
    Ok(Fetcher::new(sources, store, options))
}

async fn finish<A: AuctionApi>(fetcher: &Fetcher<A>, command: Command) -> anyhow::Result<ExitCode> {
    match command {
        Command::Once => {
            let report = fetcher.run_cycle().await?;
            Ok(if report.failed > 0 {
                ExitCode::from(EXIT_PARTIAL_FAILURE)
            } else {
                ExitCode::SUCCESS
            })
        }
        Command::Watch { poll_seconds } => {
            // Safe to interrupt at any point: a snapshot is written in one
            // transaction, and an unfinished one is fetched again on restart.
            tokio::select! {
                result = fetcher.watch(Duration::from_secs(poll_seconds)) => result?,
                signal = tokio::signal::ctrl_c() => {
                    signal.context("cannot listen for Ctrl-C")?;
                    tracing::info!("interrupted, exiting");
                }
            }
            Ok(ExitCode::SUCCESS)
        }
    }
}

/// `postgres://user:secret@host:5432/name?option=1` with `name` extended by `suffix`.
fn with_database_suffix(url: &str, suffix: &str) -> anyhow::Result<String> {
    let (base, query) = match url.split_once('?') {
        Some((base, query)) => (base, Some(query)),
        None => (url, None),
    };
    let authority_end = base
        .find("://")
        .map(|scheme| scheme + 3)
        .context("DATABASE_URL is not a URL")?;
    base[authority_end..]
        .rfind('/')
        .map(|slash| authority_end + slash + 1)
        .filter(|start| *start < base.len())
        .context("DATABASE_URL does not name a database")?;

    let mut result = format!("{base}{suffix}");
    if let Some(query) = query {
        result.push('?');
        result.push_str(query);
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adds_a_suffix_to_the_database_name_only() {
        assert_eq!(
            with_database_suffix("postgres://u:p@localhost:5432/market", "_stub").unwrap(),
            "postgres://u:p@localhost:5432/market_stub"
        );
        assert_eq!(
            with_database_suffix("postgres://u:p@localhost/market?sslmode=disable", "_stub").unwrap(),
            "postgres://u:p@localhost/market_stub?sslmode=disable"
        );
    }

    #[test]
    fn refuses_a_url_without_a_database_name() {
        assert!(with_database_suffix("postgres://u:p@localhost:5432/", "_stub").is_err());
        assert!(with_database_suffix("postgres://u:p@localhost:5432", "_stub").is_err());
        assert!(with_database_suffix("market", "_stub").is_err());
    }

    #[test]
    fn the_command_line_is_consistent() {
        use clap::CommandFactory;
        Cli::command().debug_assert();
    }
}
