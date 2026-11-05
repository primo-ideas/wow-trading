//! Postgres persistence. Everything SQL lives here and in the migrations.

use std::collections::HashSet;
use std::sync::Arc;

use anyhow::Context;
use chrono::{DateTime, Days, NaiveDate, Utc};
use sqlx::migrate::MigrateDatabase;
use sqlx::postgres::PgPoolOptions;
use sqlx::{AssertSqlSafe, PgPool, Postgres};
use tokio::sync::Mutex;

use crate::aggregate::{Aggregate, PricePoint};
use crate::api::{AuctionSource, ConnectedRealm, Item};
use crate::config::Region;
use crate::sales::{LiveAuction, SalesPoint, decode_state};

/// Display name of the commodity market in `auction_houses`.
const COMMODITIES_NAME: &str = "Commodities";

/// Tables holding one partition per day, in the order they must always be locked
/// to avoid deadlocks: inserting a snapshot takes the same order.
const PARTITIONED_TABLES: [&str; 2] = ["price_points", "sales_points"];
const PARTITION_DATE_FORMAT: &str = "%Y%m%d";

/// Serializes partition changes across processes. An arbitrary constant.
const PARTITION_LOCK_ID: i64 = 7_274_301;

#[derive(Debug, Clone, PartialEq, Eq, sqlx::FromRow)]
pub struct AuctionHouse {
    pub id: i32,
    pub connected_realm_id: Option<i32>,
    pub name: String,
    pub last_modified: Option<String>,
}

impl AuctionHouse {
    pub fn source(&self) -> AuctionSource {
        match self.connected_realm_id {
            Some(id) => AuctionSource::ConnectedRealm(id),
            None => AuctionSource::Commodities,
        }
    }
}

/// The latest snapshot of a market, to compare the next one to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarketState {
    pub taken_at: DateTime<Utc>,
    pub auctions: Vec<LiveAuction>,
}

#[derive(Debug, Clone)]
pub struct NewSnapshot<'a> {
    pub auction_house_id: i32,
    pub taken_at: DateTime<Utc>,
    pub previous_taken_at: Option<DateTime<Utc>>,
    pub fetched_at: DateTime<Utc>,
    pub last_modified: &'a str,
    pub aggregate: &'a Aggregate,
    pub sales: &'a [SalesPoint],
    /// See [`crate::sales::encode_state`].
    pub state: &'a [u8],
}

#[derive(Clone)]
pub struct Store {
    pool: PgPool,
    /// Days whose partitions are known to exist.
    partitions: Arc<Mutex<HashSet<NaiveDate>>>,
}

impl Store {
    /// Connects, creating the database if needed, and applies pending migrations.
    pub async fn open(url: &str, max_connections: u32) -> anyhow::Result<Self> {
        let exists = Postgres::database_exists(url)
            .await
            .context("cannot reach the database, check DATABASE_URL")?;
        if !exists {
            Postgres::create_database(url)
                .await
                .context("cannot create the database")?;
        }
        let pool = PgPoolOptions::new()
            .max_connections(max_connections)
            .connect(url)
            .await
            .context("cannot connect to the database")?;
        sqlx::migrate!("./migrations").run(&pool).await?;
        Ok(Self::from_pool(pool))
    }

    /// For a database that is already migrated.
    pub fn from_pool(pool: PgPool) -> Self {
        Self {
            pool,
            partitions: Arc::default(),
        }
    }

    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    pub async fn ensure_commodity_house(&self, region: Region) -> anyhow::Result<()> {
        sqlx::query(
            "INSERT INTO auction_houses (region, connected_realm_id, name) VALUES ($1, NULL, $2)
             ON CONFLICT (region, connected_realm_id) DO NOTHING",
        )
        .bind(region.as_str())
        .bind(COMMODITIES_NAME)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn known_connected_realm_ids(&self, region: Region) -> anyhow::Result<Vec<i32>> {
        let ids = sqlx::query_scalar(
            "SELECT connected_realm_id FROM auction_houses
             WHERE region = $1 AND connected_realm_id IS NOT NULL",
        )
        .bind(region.as_str())
        .fetch_all(&self.pool)
        .await?;
        Ok(ids)
    }

    pub async fn upsert_connected_realm(
        &self,
        region: Region,
        connected_realm: &ConnectedRealm,
    ) -> anyhow::Result<()> {
        let names: Vec<&str> = connected_realm
            .realms
            .iter()
            .map(|realm| realm.name.as_str())
            .collect();

        let mut tx = self.pool.begin().await?;
        let house_id: i32 = sqlx::query_scalar(
            "INSERT INTO auction_houses (region, connected_realm_id, name) VALUES ($1, $2, $3)
             ON CONFLICT (region, connected_realm_id)
             DO UPDATE SET name = excluded.name
             RETURNING id",
        )
        .bind(region.as_str())
        .bind(connected_realm.id)
        .bind(names.join(" / "))
        .fetch_one(&mut *tx)
        .await?;

        for realm in &connected_realm.realms {
            sqlx::query(
                "INSERT INTO realms (region, slug, name, auction_house_id) VALUES ($1, $2, $3, $4)
                 ON CONFLICT (region, slug)
                 DO UPDATE SET name = excluded.name, auction_house_id = excluded.auction_house_id",
            )
            .bind(region.as_str())
            .bind(&realm.slug)
            .bind(&realm.name)
            .bind(house_id)
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(())
    }

    pub async fn auction_houses(&self, region: Region) -> anyhow::Result<Vec<AuctionHouse>> {
        let houses = sqlx::query_as(
            "SELECT id, connected_realm_id, name, last_modified FROM auction_houses
             WHERE region = $1 ORDER BY id",
        )
        .bind(region.as_str())
        .fetch_all(&self.pool)
        .await?;
        Ok(houses)
    }

    /// `(slug, auction_house_id)` of every known realm of the region.
    pub async fn realm_slugs(&self, region: Region) -> anyhow::Result<Vec<(String, i32)>> {
        let slugs = sqlx::query_as(
            "SELECT slug, auction_house_id FROM realms WHERE region = $1 ORDER BY slug",
        )
        .bind(region.as_str())
        .fetch_all(&self.pool)
        .await?;
        Ok(slugs)
    }

    /// `None` if the state is missing, or unreadable because an older version wrote
    /// it: sales just cannot be estimated for one interval, and the next snapshot
    /// writes a fresh state.
    pub async fn market_state(&self, auction_house_id: i32) -> anyhow::Result<Option<MarketState>> {
        let row: Option<(DateTime<Utc>, Vec<u8>)> = sqlx::query_as(
            "SELECT taken_at, auctions FROM market_states WHERE auction_house_id = $1",
        )
        .bind(auction_house_id)
        .fetch_optional(&self.pool)
        .await?;
        let Some((taken_at, bytes)) = row else {
            return Ok(None);
        };

        let decoded = tokio::task::spawn_blocking(move || decode_state(&bytes))
            .await
            .context("decoding a market state panicked")?;
        match decoded {
            Ok(auctions) => Ok(Some(MarketState { taken_at, auctions })),
            Err(error) => {
                tracing::warn!(auction_house_id, %error, "unreadable market state, ignoring it");
                Ok(None)
            }
        }
    }

    pub async fn set_last_modified(
        &self,
        auction_house_id: i32,
        last_modified: &str,
    ) -> anyhow::Result<()> {
        sqlx::query("UPDATE auction_houses SET last_modified = $1 WHERE id = $2")
            .bind(last_modified)
            .bind(auction_house_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// Stores a snapshot atomically: a crash leaves either all of it or nothing,
    /// and in the latter case `last_modified` has not moved so the next cycle
    /// fetches it again. Returns `false` if this snapshot was already stored.
    pub async fn save_snapshot(&self, snapshot: &NewSnapshot<'_>) -> anyhow::Result<bool> {
        self.ensure_partitions(snapshot.taken_at.date_naive())
            .await?;
        self.register_items(&snapshot.aggregate.points).await?;

        let aggregate = snapshot.aggregate;
        let mut tx = self.pool.begin().await?;

        let inserted = sqlx::query(
            "INSERT INTO snapshots
                 (auction_house_id, taken_at, previous_taken_at, fetched_at,
                  auction_count, unpriced_count)
             VALUES ($1, $2, $3, $4, $5, $6)
             ON CONFLICT (auction_house_id, taken_at) DO NOTHING",
        )
        .bind(snapshot.auction_house_id)
        .bind(snapshot.taken_at)
        .bind(snapshot.previous_taken_at)
        .bind(snapshot.fetched_at)
        .bind(clamp(aggregate.auction_count))
        .bind(clamp(aggregate.unpriced_count))
        .execute(&mut *tx)
        .await?
        .rows_affected()
            > 0;

        if inserted {
            insert_price_points(&mut tx, snapshot).await?;
            insert_sales_points(&mut tx, snapshot).await?;
            sqlx::query(
                "INSERT INTO market_states (auction_house_id, taken_at, auctions)
                 VALUES ($1, $2, $3)
                 ON CONFLICT (auction_house_id)
                 DO UPDATE SET taken_at = excluded.taken_at, auctions = excluded.auctions",
            )
            .bind(snapshot.auction_house_id)
            .bind(snapshot.taken_at)
            .bind(snapshot.state)
            .execute(&mut *tx)
            .await?;
        }

        sqlx::query("UPDATE auction_houses SET last_modified = $1 WHERE id = $2")
            .bind(snapshot.last_modified)
            .bind(snapshot.auction_house_id)
            .execute(&mut *tx)
            .await?;

        tx.commit().await?;
        Ok(inserted)
    }

    /// Creates the partitions of a day if they are missing. Creating a partition
    /// locks the whole table, so it is not done more than once per process.
    async fn ensure_partitions(&self, day: NaiveDate) -> anyhow::Result<()> {
        let mut partitions = self.partitions.lock().await;
        if partitions.contains(&day) {
            return Ok(());
        }
        let next = day
            .checked_add_days(Days::new(1))
            .context("date out of range")?;

        let mut tx = self.pool.begin().await?;
        sqlx::query("SELECT pg_advisory_xact_lock($1)")
            .bind(PARTITION_LOCK_ID)
            .execute(&mut *tx)
            .await?;
        for table in PARTITIONED_TABLES {
            let name = partition_name(table, day);
            let sql = format!(
                "CREATE TABLE IF NOT EXISTS {name} PARTITION OF {table}
                 FOR VALUES FROM ('{day} 00:00:00+00') TO ('{next} 00:00:00+00')"
            );
            sqlx::query(AssertSqlSafe(sql)).execute(&mut *tx).await?;
        }
        tx.commit().await?;

        partitions.insert(day);
        Ok(())
    }

    /// Outside the snapshot's transaction, which can last a while: markets being
    /// ingested at the same time would wait on each other for the items they share.
    /// Points are sorted by item, which also keeps these inserts free of deadlocks.
    async fn register_items(&self, points: &[PricePoint]) -> anyhow::Result<()> {
        let mut ids: Vec<i32> = points.iter().map(|point| point.item_id).collect();
        ids.dedup();
        sqlx::query(
            "INSERT INTO items (id) SELECT id FROM UNNEST($1::int[]) AS t(id)
             ON CONFLICT (id) DO NOTHING",
        )
        .bind(ids)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Replaces the partitions of days older than `retain_days` with one row per
    /// item per day, in the `*_daily` tables. Returns how many days were rolled up.
    pub async fn roll_up_old_partitions(
        &self,
        retain_days: u32,
        now: DateTime<Utc>,
    ) -> anyhow::Result<usize> {
        let cutoff = now
            .date_naive()
            .checked_sub_days(Days::new(u64::from(retain_days)))
            .context("date out of range")?;

        let names: Vec<String> = sqlx::query_scalar(
            "SELECT child.relname::text FROM pg_inherits
             JOIN pg_class child ON child.oid = pg_inherits.inhrelid
             WHERE pg_inherits.inhparent = 'price_points'::regclass",
        )
        .fetch_all(&self.pool)
        .await?;

        let mut days: Vec<NaiveDate> = names
            .iter()
            .filter_map(|name| name.strip_prefix("price_points_"))
            .filter_map(|date| NaiveDate::parse_from_str(date, PARTITION_DATE_FORMAT).ok())
            .filter(|day| *day < cutoff)
            .collect();
        days.sort_unstable();

        for day in &days {
            self.roll_up_day(*day).await?;
            tracing::info!(%day, "rolled up into daily statistics");
        }
        Ok(days.len())
    }

    async fn roll_up_day(&self, day: NaiveDate) -> anyhow::Result<()> {
        let mut partitions = self.partitions.lock().await;
        let prices = partition_name("price_points", day);
        let sales = partition_name("sales_points", day);

        let mut tx = self.pool.begin().await?;
        sqlx::query("SELECT pg_advisory_xact_lock($1)")
            .bind(PARTITION_LOCK_ID)
            .execute(&mut *tx)
            .await?;

        let sql = format!(
            "INSERT INTO price_points_daily
                 (auction_house_id, item_id, variant, day, min_price, p25_price, median_price,
                  p75_price, mean_price, quantity, auction_count)
             SELECT auction_house_id, item_id, variant, $1::date, min(min_price),
                    round(avg(p25_price))::bigint, round(avg(median_price))::bigint,
                    round(avg(p75_price))::bigint, round(avg(mean_price))::bigint,
                    round(avg(quantity))::int, round(avg(auction_count))::int
             FROM {prices}
             GROUP BY auction_house_id, item_id, variant
             ON CONFLICT (auction_house_id, item_id, variant, day) DO NOTHING"
        );
        sqlx::query(AssertSqlSafe(sql))
            .bind(day)
            .execute(&mut *tx)
            .await?;

        let sql = format!(
            "INSERT INTO sales_points_daily
                 (auction_house_id, item_id, variant, day, sold_value, sold_quantity, sold_auctions)
             SELECT auction_house_id, item_id, variant, $1::date,
                    least(sum(sold_value), 9223372036854775807)::bigint,
                    least(sum(sold_quantity), 2147483647)::int,
                    least(sum(sold_auctions), 2147483647)::int
             FROM {sales}
             GROUP BY auction_house_id, item_id, variant
             ON CONFLICT (auction_house_id, item_id, variant, day) DO NOTHING"
        );
        sqlx::query(AssertSqlSafe(sql))
            .bind(day)
            .execute(&mut *tx)
            .await?;

        for table in [prices, sales] {
            sqlx::query(AssertSqlSafe(format!("DROP TABLE {table}")))
                .execute(&mut *tx)
                .await?;
        }
        tx.commit().await?;

        partitions.remove(&day);
        Ok(())
    }

    /// Items never looked up, plus those the API did not know as of `unknown_before`.
    pub async fn items_to_resolve(
        &self,
        unknown_before: DateTime<Utc>,
        limit: usize,
    ) -> anyhow::Result<Vec<i32>> {
        let ids = sqlx::query_scalar(
            "SELECT id FROM items
             WHERE name IS NULL AND (resolved_at IS NULL OR resolved_at < $1)
             ORDER BY id LIMIT $2",
        )
        .bind(unknown_before)
        .bind(limit as i64)
        .fetch_all(&self.pool)
        .await?;
        Ok(ids)
    }

    /// `item` is `None` when the API does not know this id: recording the answer
    /// keeps it from being asked again at every cycle.
    pub async fn save_item(
        &self,
        id: i32,
        item: Option<&Item>,
        resolved_at: DateTime<Utc>,
    ) -> anyhow::Result<()> {
        sqlx::query(
            "UPDATE items
             SET name = $1, quality = $2, level = $3, item_class = $4, item_subclass = $5,
                 resolved_at = $6
             WHERE id = $7",
        )
        .bind(item.map(|item| item.name.as_str()))
        .bind(
            item.and_then(|item| item.quality.as_ref())
                .map(|quality| quality.kind.as_str()),
        )
        .bind(item.and_then(|item| item.level))
        .bind(
            item.and_then(|item| item.item_class.as_ref())
                .map(|class| class.name.as_str()),
        )
        .bind(
            item.and_then(|item| item.item_subclass.as_ref())
                .map(|class| class.name.as_str()),
        )
        .bind(resolved_at)
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }
}

fn partition_name(table: &str, day: NaiveDate) -> String {
    format!("{table}_{}", day.format(PARTITION_DATE_FORMAT))
}

/// Quantities are stored as 32-bit integers to keep rows small.
fn clamp(value: i64) -> i32 {
    i32::try_from(value).unwrap_or(i32::MAX)
}

async fn insert_price_points(
    tx: &mut sqlx::Transaction<'_, Postgres>,
    snapshot: &NewSnapshot<'_>,
) -> anyhow::Result<()> {
    let points = &snapshot.aggregate.points;
    sqlx::query(
        "INSERT INTO price_points
             (auction_house_id, taken_at, item_id, min_price, p25_price, median_price,
              p75_price, mean_price, quantity, auction_count, variant)
         SELECT $1::int, $2::timestamptz, t.*
         FROM UNNEST($3::int[], $4::bigint[], $5::bigint[], $6::bigint[], $7::bigint[],
                     $8::bigint[], $9::int[], $10::int[], $11::text[]) AS t",
    )
    .bind(snapshot.auction_house_id)
    .bind(snapshot.taken_at)
    .bind(column(points, |point| point.item_id))
    .bind(column(points, |point| point.min_price))
    .bind(column(points, |point| point.p25_price))
    .bind(column(points, |point| point.median_price))
    .bind(column(points, |point| point.p75_price))
    .bind(column(points, |point| point.mean_price))
    .bind(column(points, |point| clamp(point.quantity)))
    .bind(column(points, |point| clamp(point.auction_count)))
    .bind(column(points, |point| point.variant.as_str()))
    .execute(&mut **tx)
    .await?;
    Ok(())
}

async fn insert_sales_points(
    tx: &mut sqlx::Transaction<'_, Postgres>,
    snapshot: &NewSnapshot<'_>,
) -> anyhow::Result<()> {
    let sales = snapshot.sales;
    sqlx::query(
        "INSERT INTO sales_points
             (auction_house_id, taken_at, item_id, sold_value, sold_quantity, sold_auctions, variant)
         SELECT $1::int, $2::timestamptz, t.*
         FROM UNNEST($3::int[], $4::bigint[], $5::int[], $6::int[], $7::text[]) AS t",
    )
    .bind(snapshot.auction_house_id)
    .bind(snapshot.taken_at)
    .bind(column(sales, |sale| sale.item_id))
    .bind(column(sales, |sale| sale.sold_value))
    .bind(column(sales, |sale| clamp(sale.sold_quantity)))
    .bind(column(sales, |sale| clamp(sale.sold_auctions)))
    .bind(column(sales, |sale| sale.variant.as_str()))
    .execute(&mut **tx)
    .await?;
    Ok(())
}

/// One column of rows, to be sent as an array: one statement instead of one per row.
fn column<'a, Row, Value>(rows: &'a [Row], value: impl Fn(&'a Row) -> Value) -> Vec<Value> {
    rows.iter().map(value).collect()
}
