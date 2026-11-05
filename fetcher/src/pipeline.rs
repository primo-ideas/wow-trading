//! One fetch cycle: for each region, discover realms and ingest whichever snapshots
//! changed; then resolve the metadata of newly seen items and roll up old data.

use std::collections::HashSet;
use std::time::Duration;

use anyhow::{Context, bail};
use chrono::{TimeDelta, Utc};
use futures::future::join_all;
use futures::{StreamExt, stream};

use crate::aggregate::aggregate;
use crate::api::{ApiError, AuctionApi, Fetched};
use crate::config::{RealmSelection, Region};
use crate::sales::{encode_state, estimate_sales, live_auctions};
use crate::store::{AuctionHouse, NewSnapshot, Store};

/// How long before asking again about an item the API answered 404 for. An
/// unknown item is on sale all the same, so the answer may well change.
const UNKNOWN_ITEM_RETRY: TimeDelta = TimeDelta::days(7);

#[derive(Debug, Clone)]
pub struct FetchOptions {
    /// Simultaneous API requests per region. Must be at least 1.
    pub concurrency: usize,
    /// Most items to look up per cycle, so a first run spreads over several
    /// cycles instead of spending the API quota at once.
    pub item_batch: usize,
    /// Days of hourly detail to keep before rolling them up into daily statistics.
    pub hourly_retention_days: u32,
}

/// A region to fetch, and the API client to fetch it with.
pub struct RegionSource<A> {
    pub api: A,
    pub region: Region,
    pub realms: RealmSelection,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CycleReport {
    pub ingested: usize,
    pub unchanged: usize,
    pub failed: usize,
    pub items_resolved: usize,
    pub items_failed: usize,
}

enum IngestOutcome {
    Ingested,
    Unchanged,
}

pub struct Fetcher<A> {
    sources: Vec<RegionSource<A>>,
    store: Store,
    options: FetchOptions,
}

impl<A: AuctionApi> Fetcher<A> {
    pub fn new(sources: Vec<RegionSource<A>>, store: Store, options: FetchOptions) -> Self {
        Self {
            sources,
            store,
            options,
        }
    }

    pub fn sources(&self) -> &[RegionSource<A>] {
        &self.sources
    }

    pub fn store(&self) -> &Store {
        &self.store
    }

    /// A market that fails is logged, counted and retried at the next cycle
    /// without affecting the others. Errors returned here are the ones another
    /// cycle would not fix: rejected credentials, a realm that does not exist,
    /// and database failures.
    pub async fn run_cycle(&self) -> anyhow::Result<CycleReport> {
        let regions = join_all(self.sources.iter().map(|source| self.ingest_region(source))).await;

        let mut report = CycleReport::default();
        for region in regions {
            let region = region?;
            report.ingested += region.ingested;
            report.unchanged += region.unchanged;
            report.failed += region.failed;
        }

        self.resolve_items(&mut report).await?;
        self.store
            .roll_up_old_partitions(self.options.hourly_retention_days, Utc::now())
            .await?;

        tracing::info!(
            ingested = report.ingested,
            unchanged = report.unchanged,
            failed = report.failed,
            items_resolved = report.items_resolved,
            items_failed = report.items_failed,
            "cycle finished"
        );
        Ok(report)
    }

    /// Runs cycles forever, waiting `interval` between them. Asking often is
    /// cheap because an unchanged snapshot answers 304 with no body.
    pub async fn watch(&self, interval: Duration) -> anyhow::Result<()> {
        loop {
            self.run_cycle().await?;
            tokio::time::sleep(interval).await;
        }
    }

    async fn ingest_region(&self, source: &RegionSource<A>) -> anyhow::Result<CycleReport> {
        self.store.ensure_commodity_house(source.region).await?;
        let directory_is_complete = self.sync_connected_realms(source).await?;
        let houses = self.selected_houses(source, directory_is_complete).await?;

        let mut report = CycleReport::default();
        let mut ingestions = stream::iter(houses)
            .map(|house| async move {
                let result = self.ingest(source, &house).await;
                (house, result)
            })
            .buffer_unordered(self.options.concurrency);
        while let Some((house, result)) = ingestions.next().await {
            match result {
                Ok(IngestOutcome::Ingested) => report.ingested += 1,
                Ok(IngestOutcome::Unchanged) => report.unchanged += 1,
                Err(error) => {
                    tracing::error!(
                        region = %source.region,
                        house = %house.name,
                        error = format!("{error:#}"),
                        "ingestion failed"
                    );
                    report.failed += 1;
                }
            }
        }
        Ok(report)
    }

    /// Looks up connected realms not seen before. Known ones are not refreshed:
    /// their names practically never change. Returns whether every realm of the
    /// region is now known.
    async fn sync_connected_realms(&self, source: &RegionSource<A>) -> anyhow::Result<bool> {
        let region = source.region;
        let ids = match source.api.connected_realm_ids().await {
            Ok(ids) => ids,
            Err(error @ ApiError::Auth { .. }) => return Err(error.into()),
            Err(error) => {
                tracing::warn!(%region, %error, "cannot list connected realms, using the known ones");
                return Ok(false);
            }
        };

        let known: HashSet<i32> = self
            .store
            .known_connected_realm_ids(region)
            .await?
            .into_iter()
            .collect();
        let mut complete = true;
        let mut lookups = stream::iter(ids.into_iter().filter(|id| !known.contains(id)))
            .map(|id| async move { (id, source.api.connected_realm(id).await) })
            .buffer_unordered(self.options.concurrency);
        while let Some((id, result)) = lookups.next().await {
            match result {
                Ok(connected_realm) => {
                    self.store
                        .upsert_connected_realm(region, &connected_realm)
                        .await?;
                }
                Err(error) => {
                    tracing::warn!(%region, id, %error, "cannot look up connected realm, will retry");
                    complete = false;
                }
            }
        }
        Ok(complete)
    }

    async fn selected_houses(
        &self,
        source: &RegionSource<A>,
        directory_is_complete: bool,
    ) -> anyhow::Result<Vec<AuctionHouse>> {
        let region = source.region;
        let houses = self.store.auction_houses(region).await?;
        let is_commodities = |house: &AuctionHouse| house.connected_realm_id.is_none();

        Ok(match &source.realms {
            RealmSelection::All => houses,
            RealmSelection::CommoditiesOnly => houses.into_iter().filter(is_commodities).collect(),
            RealmSelection::Slugs(slugs) => {
                let known = self.store.realm_slugs(region).await?;
                let mut wanted = HashSet::new();
                for slug in slugs {
                    match known.iter().find(|(known_slug, _)| known_slug == slug) {
                        Some((_, house_id)) => {
                            wanted.insert(*house_id);
                        }
                        // Asked for by name: going on without it would look like success.
                        None if directory_is_complete => {
                            let names: Vec<&str> =
                                known.iter().map(|(name, _)| name.as_str()).collect();
                            bail!(
                                "unknown realm '{slug}' in region {region}. Known realms: {}",
                                names.join(", ")
                            );
                        }
                        None => tracing::warn!(%region, slug, "realm not found yet, skipping it"),
                    }
                }
                houses
                    .into_iter()
                    .filter(|house| is_commodities(house) || wanted.contains(&house.id))
                    .collect()
            }
        })
    }

    async fn ingest(
        &self,
        source: &RegionSource<A>,
        house: &AuctionHouse,
    ) -> anyhow::Result<IngestOutcome> {
        let fetched = source
            .api
            .auctions(house.source(), house.last_modified.as_deref())
            .await?;
        let snapshot = match fetched {
            Fetched::NotModified => return Ok(IngestOutcome::Unchanged),
            Fetched::Snapshot(snapshot) => snapshot,
        };

        let previous = self.store.market_state(house.id).await?;
        let previous_taken_at = previous.as_ref().map(|state| state.taken_at);
        // Already ingested, or older: not a new interval to estimate sales over.
        if previous_taken_at.is_some_and(|taken_at| snapshot.taken_at <= taken_at) {
            self.store
                .set_last_modified(house.id, &snapshot.last_modified)
                .await?;
            return Ok(IngestOutcome::Unchanged);
        }

        // Sorting and comparing a large snapshot would otherwise stall the async runtime.
        let auctions = snapshot.auctions;
        let taken_at = snapshot.taken_at;
        let (aggregate, sales, state) = tokio::task::spawn_blocking(move || {
            let aggregate = aggregate(&auctions);
            let live = live_auctions(&auctions);
            let sales = previous.map_or_else(Vec::new, |previous| {
                let elapsed = (taken_at - previous.taken_at)
                    .to_std()
                    .unwrap_or(Duration::ZERO);
                estimate_sales(&previous.auctions, &live, elapsed)
            });
            (aggregate, sales, encode_state(&live))
        })
        .await
        .context("processing a snapshot panicked")?;

        let inserted = self
            .store
            .save_snapshot(&NewSnapshot {
                auction_house_id: house.id,
                taken_at,
                previous_taken_at,
                fetched_at: Utc::now(),
                last_modified: &snapshot.last_modified,
                aggregate: &aggregate,
                sales: &sales,
                state: &state,
            })
            .await?;
        if !inserted {
            return Ok(IngestOutcome::Unchanged);
        }

        tracing::info!(
            region = %source.region,
            house = %house.name,
            %taken_at,
            auctions = aggregate.auction_count,
            points = aggregate.points.len(),
            sold_items = sales.len(),
            "snapshot ingested"
        );
        Ok(IngestOutcome::Ingested)
    }

    /// Items are the same in every region, so one client is enough.
    async fn resolve_items(&self, report: &mut CycleReport) -> anyhow::Result<()> {
        let Some(source) = self.sources.first() else {
            return Ok(());
        };
        let ids = self
            .store
            .items_to_resolve(Utc::now() - UNKNOWN_ITEM_RETRY, self.options.item_batch)
            .await?;
        let mut lookups = stream::iter(ids)
            .map(|id| async move { (id, source.api.item(id).await) })
            .buffer_unordered(self.options.concurrency);
        while let Some((id, result)) = lookups.next().await {
            match result {
                Ok(item) => {
                    if item.is_none() {
                        tracing::warn!(id, "item unknown to the item API");
                    }
                    self.store.save_item(id, item.as_ref(), Utc::now()).await?;
                    report.items_resolved += 1;
                }
                Err(error) => {
                    tracing::warn!(id, %error, "cannot look up item, will retry");
                    report.items_failed += 1;
                }
            }
        }
        Ok(())
    }
}
