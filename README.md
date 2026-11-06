# WoW Trading

Price curves and estimated sales for the World of Warcraft auction house.

- [`fetcher/`](fetcher/): collects auctions from the Battle.net API and stores statistics in Postgres (Rust).
- [`web/`](web/): the site, which reads that database and never writes to it (Rails).
- [`deploy/`](deploy/): installation on an Ubuntu server, see [its guide](deploy/README.md).

## Try it without credentials

On Windows, with [PowerShell 7.2 or later](https://github.com/PowerShell/PowerShell) and [Rust](https://rustup.rs):

```powershell
./run.ps1 -Stub
```

On first use, the script installs Postgres and Ruby in `%LOCALAPPDATA%\wow-trading`, without admin rights, without touching the `PATH` and without creating a service. It then simulates a week of auctions, starts the site on <http://127.0.0.1:3000> and opens the browser. Ctrl-C stops everything it started.

`-Stub` writes to a separate database, `wow_trading_stub`: fake data cannot mix with the real history.

## Connect Battle.net

1. Create a client on <https://develop.battle.net/access/clients>.
2. Copy `.env.example` to `.env` and fill in `BLIZZARD_CLIENT_ID` and `BLIZZARD_CLIENT_SECRET`. Git ignores this file.
3. Run the script on a small scope:

```powershell
./run.ps1 -Scope eu/commodities
```

Without `-Scope`, the script fetches every realm of every region. Without `-Stub` and without credentials, it stops with an error message: it never falls back on sample data.

## Deploy to a server

On Ubuntu 26.04, `deploy/install.sh` installs everything, with the fetcher on a systemd timer every 5 minutes. See [the deployment guide](deploy/README.md), which also explains that frequency.

## run.ps1

| Option | Purpose |
| --- | --- |
| `-Scope` | What to fetch, see [Scope](#scope) |
| `-Config` | File holding the credentials, instead of `.env` |
| `-Stub` | Simulated data, no credentials needed |
| `-Port` | Port of the site, 3000 by default |
| `-NoBrowser` | Does not open the browser |
| `-SetupOnly` | Installs what is missing, then exits |
| `-Test` | Runs the fetcher and site tests, then exits |

## Without run.ps1

The script only works on Windows. Elsewhere, with a Postgres server and Ruby already installed (these commands have not been tested outside Windows):

```sh
export DATABASE_URL=postgres://user:password@localhost:5432/wow_trading
cargo run -p wow-trading-fetcher -- --stub once

cd web
bundle install
DATABASE_URL=postgres://user:password@localhost:5432/wow_trading_stub bin/rails server
```

The fetcher creates the database if it does not exist and applies its own migrations.

## Fetcher

```sh
cargo run -p wow-trading-fetcher -- once    # one cycle, exit code 2 if a market failed
cargo run -p wow-trading-fetcher -- watch   # one cycle every 10 minutes, until Ctrl-C
```

Each option can be passed on the command line or as an environment variable, possibly in `.env`. A variable already set in the environment wins over the file.

| Option | Variable | Default | Purpose |
| --- | --- | --- | --- |
| | `DATABASE_URL` | required | Postgres server and database |
| | `BLIZZARD_CLIENT_ID`, `BLIZZARD_CLIENT_SECRET` | required without `--stub` | Battle.net credentials |
| `--scope` | `WOW_SCOPE` | everything | What to fetch |
| `--locale` | `WOW_LOCALE` | `en_US` | Language of item and realm names |
| `--concurrency` | `WOW_CONCURRENCY` | `4` | Simultaneous requests per region |
| `--item-batch` | `WOW_ITEM_BATCH` | `1000` | Most items, and pet species, to look up per cycle |
| `--hourly-retention-days` | `WOW_HOURLY_RETENTION_DAYS` | `14` | Days of hourly detail to keep |
| `--poll-seconds` (`watch`) | `WOW_POLL_SECONDS` | `600` | Wait between two cycles |
| `--config` | | `.env` | File of variables to read |
| `--stub` | | | Simulated data, in the database suffixed `_stub` |

Logging is set with `RUST_LOG`, for example `RUST_LOG=debug`.

### Scope

One or more entries separated by commas, for example `eu/hyjal,eu/archimonde,us`:

| Entry | Meaning |
| --- | --- |
| `eu` | Every realm of the region, and its commodities |
| `eu/hyjal` | This realm, and the commodities of the region |
| `eu/commodities` | Only the commodities of the region |

The regions are `us`, `eu`, `kr` and `tw`.

### What a cycle does

For each region, the fetcher:

1. discovers connected realms it does not know yet;
2. asks each followed market for its snapshot with `If-Modified-Since`, which costs next to nothing as long as nothing has changed;
3. reduces each new snapshot to one line of statistics per item, estimates sales since the previous snapshot, works out what the site will show for that market, and writes it all in a single transaction.

It then fetches the names, details and icons of newly seen items and pets, in batches and starting with what trades most, and rolls up into daily statistics the days that have left the retention period.

A failed market does not hold back the others and is retried at the next cycle. Rejected credentials, an unknown realm or a database error stop the program, as retrying would not change anything.

## Data

Prices are in copper (1 gold = 10,000) and dates in UTC.

| Table | Contents |
| --- | --- |
| `auction_houses` | A market: a connected realm, or the commodities of the region (`connected_realm_id` is `NULL`) |
| `realms` | Realms and the market each belongs to |
| `snapshots` | Log of ingested snapshots |
| `market_states` | Auctions of the latest snapshot of each market, to estimate sales at the next one. Not meant for reading |
| `price_points` | Minimum price, 1st quartile, median, 3rd quartile, mean, quantity and number of auctions, per item and per snapshot |
| `sales_points` | Quantity, value and number of auctions sold, per item, between two snapshots |
| `price_points_daily`, `sales_points_daily` | The same data, per UTC day, once out of the retention period |
| `listed_products` | What a market has for sale at the latest snapshot: the variants of a piece of gear added up, 24-hour sales, the 24-hour change, and the usual cheapest price over 3 days. Replaced at each snapshot, this is what the site's listings read |
| `items` | Name, quality, level, class and icon of items. `name` is `NULL`: not looked up yet, or unknown to the API |
| `pets` | Name and icon of pet species |

`price_points` and `sales_points` have one partition per day. Beyond the retention period, each day is replaced by one row per item in the `*_daily` tables: mean prices and quantities, lowest minimum price, sales added up. This summary is final.

Quantiles are weighted by quantity, so that a single listing at an absurd price does not move the median. Prefer the median or the quartiles to the mean for curves: the mean remains sensitive to those listings.

`variant` tells apart what shares an item id without being the same product:

| `variant` | Meaning |
| --- | --- |
| *(empty)* | Plain item |
| `pet:39` | Caged pet, by species: they all share item 82800 |
| `bonus:1472,6652` | Gear, by bonus list, which notably sets the item level |

A recent curve can be read directly; [`item_history.rb`](web/app/models/item_history.rb) adds the rolled-up days to it.

```sql
SELECT taken_at, min_price, median_price, quantity
FROM price_points
WHERE auction_house_id = $1 AND item_id = $2 AND variant = ''
ORDER BY taken_at;
```

### Estimated sales

The API does not give sales. The fetcher compares two consecutive snapshots: an auction that disappears counts as sold if it had too much time left to have simply expired, and a quantity that drops counts as a partial sale.

This remains an estimate. A cancelled auction looks like a sale, which inflates the figure. An auction sold shortly before expiring, or listed and sold between two snapshots, goes unnoticed, which reduces it.

## Site

A player picks their realm, then searches for an item. Markets never show: each page of a realm adds up the auction house it shares with its connected realms and the commodities of its region, and an item's page is on whichever of the two trades it.

- `/`: the last realm visited, or failing that the realm picker (`/realms`), which suggests realms as you type, without regard for accents. A realm can be picked once its own market, or the commodities of its region, are followed.
- `/:region/:realm`, for example `/eu/hyjal`: a search box, the biggest rises and falls over 24 hours and the most traded, then everything for sale at the latest snapshot, to sort and filter by name, id, category or quality, ignoring accents and case.
- `/:region/:realm/deals`: what sells well below its usual price, with what is left after reselling at that price. See [Deals](#deals).
- `/:region/:realm/items/:id`: price curves, estimated sales and quantity for sale, over 24 hours, 7, 30 or 90 days, or the whole history. Each chart has its data table. The page also gives the usual cheapest price, when the product sells by hour of the day and day of the week over the last two weeks, the same product on the other realms of the region, and a CSV download of the prices (`.csv`, in copper and UTC).
- `/:region/:realm/search`: searches the realm. The header of each page offers suggestions as you type, with `/` or Ctrl-K to get there.
- `/watchlist`: the products a reader follows, at their latest prices on their realm, each with a target price if they set one. Once the cheapest listing reaches it, the row and the header of every page say so. It lives in a cookie: the site has no accounts, and never writes to its database.

Hovering a product shows its card: what it is, and its prices on the realm. The products a reader opened last show under the search box of a realm's page, and in the suggestions before anything is typed; that list stays in their browser. Hovering the label of a figure says what it means. The addresses of the time the site was organised by market (`/markets/:id`, `/search`) lead to the same pages on the player's realm.

### Deals

A deal is measured on the cheapest listing, compared to the median of its cheapest price over the last 3 days. That is what a buyer actually pays, while the two other candidates mislead: asking prices can be absurd with nobody buying, and estimated sales count cancelled listings. On real data, comparing to the median listing put a 10 gold backpack first, against a median of 19,800 gold that nobody pays.

A product shows up with at least 24 snapshots of history, a margin of 20% and a profit of 1 gold after the auction house's 5% cut. Gear in several variants is left out, as a low item level is not a bargain. These thresholds have not been checked against real data yet, as no market had a day of history when they were written.

The schema belongs to the fetcher: the site has no migrations, and outside tests Postgres refuses its writes (`default_transaction_read_only`). Its tests load the fetcher's migrations, so a schema change that breaks the site makes them fail. They wipe their database and refuse to run on a database whose name does not end in `_test`.

## Volume

About 1 GB per market for 14 days of hourly detail, and 2 MB per day and per market for the daily summaries. These figures extrapolate real snapshots of `eu/commodities` (11,700 series) and `eu/hyjal` (18,300 series) to a simulated history. What grows:

- `price_points` and `sales_points`, during the retention period;
- the `*_daily` and `snapshots` tables, which are never purged.

All of it multiplies by the number of markets followed, which by default is every connected realm of the four regions. `run.ps1` warns when less than 20 GB is left on the disk.

## Known limits

- The real format of responses has only been confirmed on `eu/commodities` and `eu/hyjal`, not on the other regions.
- `deploy/install.sh` has not been run on a real Linux server yet.
- Individual auctions are only kept until the next snapshot, so the history cannot be recomputed with other statistics.
- The variants of a piece of gear show as their bonus list, which does not mean much to a player.
- Item `modifiers` are not part of `variant`.
- Neither China, which uses other servers, nor WoW Classic.
- The site has no authentication. `run.ps1` only exposes it on `127.0.0.1`; online, it is public as soon as it is given a domain. Times are shown in Paris time.
