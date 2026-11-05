//! Runs full cycles against the stub API and a real Postgres database. Each test
//! gets its own database, created from the server in DATABASE_URL.

use chrono::{DateTime, TimeDelta, TimeZone, Utc};
use sqlx::PgPool;

use wow_market_fetcher::aggregate::{Aggregate, PricePoint, aggregate};
use wow_market_fetcher::api::stub::StubApi;
use wow_market_fetcher::api::{Auction, AuctionItem, AuctionSource};
use wow_market_fetcher::config::{RealmSelection, Region};
use wow_market_fetcher::pipeline::{CycleReport, FetchOptions, Fetcher, RegionSource};
use wow_market_fetcher::sales::{SalesPoint, TimeLeft};
use wow_market_fetcher::simulation::Simulation;
use wow_market_fetcher::store::{NewSnapshot, Store};

const LATER: &str = "Thu, 05 Nov 2026 06:00:00 GMT";
const EARLIER: &str = "Thu, 05 Nov 2026 04:00:00 GMT";
const HYJAL: AuctionSource = AuctionSource::ConnectedRealm(1390);

fn fixture_time() -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 11, 5, 5, 0, 0).unwrap()
}

fn options() -> FetchOptions {
    FetchOptions {
        concurrency: 2,
        item_batch: 100,
        // Keeps the fixtures' dates from being rolled up, whenever the tests run.
        hourly_retention_days: 365_000,
    }
}

fn fetcher(pool: PgPool, api: StubApi, realms: RealmSelection) -> Fetcher<StubApi> {
    fetcher_with(pool, api, realms, options())
}

fn fetcher_with(
    pool: PgPool,
    api: StubApi,
    realms: RealmSelection,
    options: FetchOptions,
) -> Fetcher<StubApi> {
    Fetcher::new(
        vec![RegionSource {
            api,
            region: Region::Eu,
            realms,
        }],
        Store::from_pool(pool),
        options,
    )
}

fn slugs(slugs: &[&str]) -> RealmSelection {
    RealmSelection::Slugs(slugs.iter().map(|slug| (*slug).to_owned()).collect())
}

fn api_of(fetcher: &Fetcher<StubApi>) -> &StubApi {
    &fetcher.sources()[0].api
}

fn commodity(id: i32, unit_price: i64, quantity: i64) -> Auction {
    listing(i64::from(id), id, unit_price, quantity, TimeLeft::VeryLong)
}

fn listing(id: i64, item_id: i32, unit_price: i64, quantity: i64, time_left: TimeLeft) -> Auction {
    Auction {
        id,
        item: AuctionItem {
            id: item_id,
            bonus_lists: Vec::new(),
            pet_species_id: None,
        },
        quantity,
        unit_price: Some(unit_price),
        buyout: None,
        time_left,
    }
}

async fn count(pool: &PgPool, sql: &'static str) -> i64 {
    sqlx::query_scalar(sql).fetch_one(pool).await.unwrap()
}

/// `(house name, item id, variant)` of every stored price point.
async fn stored_series(pool: &PgPool) -> Vec<(String, i32, String)> {
    sqlx::query_as(
        "SELECT h.name, p.item_id, p.variant FROM price_points p
         JOIN auction_houses h ON h.id = p.auction_house_id
         ORDER BY h.name, p.item_id, p.variant",
    )
    .fetch_all(pool)
    .await
    .unwrap()
}

#[sqlx::test]
async fn first_cycle_stores_commodities_and_selected_realms(pool: PgPool) {
    let fetcher = fetcher(pool.clone(), StubApi::with_fixtures(), slugs(&["hyjal"]));

    let report = fetcher.run_cycle().await.unwrap();

    assert_eq!(report.ingested, 2);
    assert_eq!(report.failed, 0);
    let expected: Vec<(String, i32, String)> = [
        ("Commodities", 190395, ""),
        ("Commodities", 190396, ""),
        ("Hyjal", 2589, ""),
        ("Hyjal", 82800, "pet:39"),
        ("Hyjal", 82800, "pet:40"),
        // Same bonuses listed in a different order: one series, not two.
        ("Hyjal", 200000, "bonus:1472,6652"),
        ("Hyjal", 999999, ""),
    ]
    .into_iter()
    .map(|(house, item, variant)| (house.to_owned(), item, variant.to_owned()))
    .collect();
    assert_eq!(stored_series(&pool).await, expected);
}

#[sqlx::test]
async fn stored_statistics_resist_an_outlier(pool: PgPool) {
    let fetcher = fetcher(
        pool.clone(),
        StubApi::with_fixtures(),
        RealmSelection::CommoditiesOnly,
    );

    fetcher.run_cycle().await.unwrap();

    // 200 units at 125g, 100 at 130g, and a single troll listing at 999 999g.
    let (min, median, p75, quantity, auctions, taken_at): (
        i64,
        i64,
        i64,
        i32,
        i32,
        DateTime<Utc>,
    ) = sqlx::query_as(
        "SELECT min_price, median_price, p75_price, quantity, auction_count, taken_at
         FROM price_points WHERE item_id = 190396",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(min, 1_250_000);
    assert_eq!(median, 1_250_000);
    assert_eq!(p75, 1_300_000);
    assert_eq!(quantity, 301);
    assert_eq!(auctions, 3);
    assert_eq!(taken_at, fixture_time());
}

#[sqlx::test]
async fn snapshot_log_counts_auctions_without_a_buyout(pool: PgPool) {
    let fetcher = fetcher(pool.clone(), StubApi::with_fixtures(), slugs(&["hyjal"]));

    fetcher.run_cycle().await.unwrap();

    let (auctions, unpriced): (i32, i32) = sqlx::query_as(
        "SELECT s.auction_count, s.unpriced_count FROM snapshots s
         JOIN auction_houses h ON h.id = s.auction_house_id
         WHERE h.name = 'Hyjal'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!((auctions, unpriced), (7, 1));
    assert_eq!(
        count(
            &pool,
            "SELECT COUNT(*) FROM price_points WHERE item_id = 200001"
        )
        .await,
        0
    );
}

#[sqlx::test]
async fn an_unchanged_snapshot_adds_nothing(pool: PgPool) {
    let fetcher = fetcher(
        pool.clone(),
        StubApi::with_fixtures(),
        RealmSelection::CommoditiesOnly,
    );
    fetcher.run_cycle().await.unwrap();
    let points = count(&pool, "SELECT COUNT(*) FROM price_points").await;

    let report = fetcher.run_cycle().await.unwrap();

    assert_eq!(report.ingested, 0);
    assert_eq!(report.unchanged, 1);
    assert_eq!(
        count(&pool, "SELECT COUNT(*) FROM price_points").await,
        points
    );
    // Answered by If-Modified-Since, not downloaded again and then deduplicated.
    assert_eq!(api_of(&fetcher).snapshots_served(), 1);
}

#[sqlx::test]
async fn known_connected_realms_are_not_looked_up_again(pool: PgPool) {
    let fetcher = fetcher(
        pool,
        StubApi::with_fixtures(),
        RealmSelection::CommoditiesOnly,
    );

    fetcher.run_cycle().await.unwrap();
    fetcher.run_cycle().await.unwrap();

    assert_eq!(api_of(&fetcher).realm_lookups(), 2);
}

#[sqlx::test]
async fn a_new_snapshot_extends_the_curve(pool: PgPool) {
    let fetcher = fetcher(
        pool.clone(),
        StubApi::with_fixtures(),
        RealmSelection::CommoditiesOnly,
    );
    fetcher.run_cycle().await.unwrap();

    api_of(&fetcher).publish(
        AuctionSource::Commodities,
        LATER,
        vec![commodity(190396, 1_100_000, 50)],
    );
    let report = fetcher.run_cycle().await.unwrap();

    assert_eq!(report.ingested, 1);
    let curve: Vec<(DateTime<Utc>, i64)> = sqlx::query_as(
        "SELECT taken_at, min_price FROM price_points WHERE item_id = 190396 ORDER BY taken_at",
    )
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(
        curve,
        [
            (fixture_time(), 1_250_000),
            (fixture_time() + TimeDelta::hours(1), 1_100_000)
        ]
    );
}

#[sqlx::test]
async fn a_snapshot_seen_again_under_a_lost_header_is_not_duplicated(pool: PgPool) {
    let fetcher = fetcher(
        pool.clone(),
        StubApi::with_fixtures(),
        RealmSelection::CommoditiesOnly,
    );
    fetcher.run_cycle().await.unwrap();
    let points = count(&pool, "SELECT COUNT(*) FROM price_points").await;

    // As if the database had lost track of what it last asked for.
    sqlx::query("UPDATE auction_houses SET last_modified = NULL")
        .execute(&pool)
        .await
        .unwrap();
    let report = fetcher.run_cycle().await.unwrap();

    assert_eq!(report.unchanged, 1);
    assert_eq!(
        count(&pool, "SELECT COUNT(*) FROM price_points").await,
        points
    );

    // The header is back, so the next cycle does not download it again.
    fetcher.run_cycle().await.unwrap();
    assert_eq!(api_of(&fetcher).snapshots_served(), 2);
}

#[sqlx::test]
async fn an_older_snapshot_is_ignored(pool: PgPool) {
    let fetcher = fetcher(
        pool.clone(),
        StubApi::with_fixtures(),
        RealmSelection::CommoditiesOnly,
    );
    fetcher.run_cycle().await.unwrap();

    api_of(&fetcher).publish(
        AuctionSource::Commodities,
        EARLIER,
        vec![commodity(190396, 1, 1)],
    );
    let report = fetcher.run_cycle().await.unwrap();

    assert_eq!(report.unchanged, 1);
    assert_eq!(
        count(
            &pool,
            "SELECT COUNT(*) FROM price_points WHERE min_price = 1"
        )
        .await,
        0
    );
}

#[sqlx::test]
async fn a_failing_market_does_not_stop_the_others_and_is_retried(pool: PgPool) {
    let api = StubApi::with_fixtures();
    api.set_source_failing(HYJAL, true);
    let fetcher = fetcher(pool.clone(), api, slugs(&["hyjal", "archimonde"]));

    let report = fetcher.run_cycle().await.unwrap();

    assert_eq!(report.ingested, 2);
    assert_eq!(report.failed, 1);
    assert_eq!(
        count(
            &pool,
            "SELECT COUNT(*) FROM auction_houses WHERE name = 'Hyjal' AND last_modified IS NULL"
        )
        .await,
        1
    );

    api_of(&fetcher).set_source_failing(HYJAL, false);
    let report = fetcher.run_cycle().await.unwrap();

    assert_eq!(
        (report.ingested, report.unchanged, report.failed),
        (1, 2, 0)
    );
    assert_eq!(
        count(
            &pool,
            "SELECT COUNT(*) FROM auction_houses
             WHERE name = 'Hyjal' AND last_modified IS NOT NULL"
        )
        .await,
        1
    );
}

#[sqlx::test]
async fn commodities_only_selection_ignores_realms(pool: PgPool) {
    let fetcher = fetcher(
        pool.clone(),
        StubApi::with_fixtures(),
        RealmSelection::CommoditiesOnly,
    );

    let report = fetcher.run_cycle().await.unwrap();

    assert_eq!(report.ingested, 1);
    // The realm directory is filled regardless, for the website's benefit.
    assert_eq!(count(&pool, "SELECT COUNT(*) FROM realms").await, 3);
}

#[sqlx::test]
async fn all_selection_covers_every_connected_realm(pool: PgPool) {
    let fetcher = fetcher(pool, StubApi::with_fixtures(), RealmSelection::All);

    let report = fetcher.run_cycle().await.unwrap();

    assert_eq!(report.ingested, 3);
}

#[sqlx::test]
async fn any_realm_of_a_connected_group_selects_the_group_once(pool: PgPool) {
    let fetcher = fetcher(
        pool.clone(),
        StubApi::with_fixtures(),
        slugs(&["archimonde", "naxxramas"]),
    );

    let report = fetcher.run_cycle().await.unwrap();

    assert_eq!(report.ingested, 2);
    assert_eq!(
        count(
            &pool,
            "SELECT COUNT(*) FROM auction_houses WHERE name = 'Archimonde / Naxxramas'"
        )
        .await,
        1
    );
}

#[sqlx::test]
async fn an_unknown_realm_stops_the_fetch_and_lists_the_known_ones(pool: PgPool) {
    let fetcher = fetcher(pool, StubApi::with_fixtures(), slugs(&["hyjall"]));

    let error = fetcher.run_cycle().await.unwrap_err().to_string();

    assert!(error.contains("unknown realm 'hyjall'"), "{error}");
    assert!(error.contains("archimonde, hyjal, naxxramas"), "{error}");
}

#[sqlx::test]
async fn a_realm_missing_while_lookups_fail_is_only_skipped(pool: PgPool) {
    let api = StubApi::with_fixtures();
    api.set_realm_lookups_failing(true);
    let fetcher = fetcher(pool, api, slugs(&["hyjal"]));

    let report = fetcher.run_cycle().await.unwrap();

    assert_eq!(report.ingested, 1);

    api_of(&fetcher).set_realm_lookups_failing(false);
    let report = fetcher.run_cycle().await.unwrap();

    assert_eq!((report.ingested, report.unchanged), (1, 1));
}

#[sqlx::test]
async fn regions_are_kept_apart(pool: PgPool) {
    let fetcher = Fetcher::new(
        vec![
            RegionSource {
                api: StubApi::with_fixtures(),
                region: Region::Eu,
                realms: RealmSelection::All,
            },
            RegionSource {
                api: StubApi::with_fixtures(),
                region: Region::Us,
                realms: slugs(&["hyjal"]),
            },
        ],
        Store::from_pool(pool.clone()),
        options(),
    );

    let report = fetcher.run_cycle().await.unwrap();

    assert_eq!(report.ingested, 5);
    let houses: Vec<(String, Option<i32>)> = sqlx::query_as(
        "SELECT region, connected_realm_id FROM auction_houses
         ORDER BY region, connected_realm_id NULLS FIRST",
    )
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(houses.len(), 6);
    assert_eq!(houses[0], ("eu".to_owned(), None));
    assert_eq!(houses[3], ("us".to_owned(), None));
    assert_eq!(houses[4], ("us".to_owned(), Some(1302)));
}

#[sqlx::test]
async fn rejected_credentials_abort_the_cycle(pool: PgPool) {
    let api = StubApi::with_fixtures();
    api.reject_credentials();
    let fetcher = fetcher(pool, api, RealmSelection::CommoditiesOnly);

    let error = fetcher.run_cycle().await.unwrap_err();

    assert!(
        error
            .to_string()
            .contains("rejected the client credentials")
    );
}

#[sqlx::test]
async fn a_first_snapshot_estimates_no_sales(pool: PgPool) {
    let fetcher = fetcher(
        pool.clone(),
        StubApi::with_fixtures(),
        RealmSelection::CommoditiesOnly,
    );

    fetcher.run_cycle().await.unwrap();

    assert_eq!(count(&pool, "SELECT COUNT(*) FROM sales_points").await, 0);
    assert_eq!(
        count(
            &pool,
            "SELECT COUNT(*) FROM snapshots WHERE previous_taken_at IS NULL"
        )
        .await,
        1
    );
}

#[sqlx::test]
async fn sales_are_estimated_from_one_snapshot_to_the_next(pool: PgPool) {
    let api = StubApi::with_fixtures();
    api.publish(
        AuctionSource::Commodities,
        "Thu, 05 Nov 2026 05:00:00 GMT",
        vec![
            // Bought entirely, with plenty of time left.
            listing(1, 10, 100, 5, TimeLeft::VeryLong),
            // Partly bought.
            listing(2, 11, 200, 30, TimeLeft::Long),
            // Gone, but it may just have expired.
            listing(3, 12, 300, 7, TimeLeft::Short),
            // Untouched.
            listing(4, 13, 400, 9, TimeLeft::VeryLong),
        ],
    );
    let fetcher = fetcher(pool.clone(), api, RealmSelection::CommoditiesOnly);
    fetcher.run_cycle().await.unwrap();

    api_of(&fetcher).publish(
        AuctionSource::Commodities,
        LATER,
        vec![
            listing(2, 11, 200, 12, TimeLeft::Long),
            listing(4, 13, 400, 9, TimeLeft::VeryLong),
            listing(5, 14, 500, 1, TimeLeft::VeryLong),
        ],
    );
    fetcher.run_cycle().await.unwrap();

    let sales: Vec<(i32, i32, i64, i32, DateTime<Utc>)> = sqlx::query_as(
        "SELECT item_id, sold_quantity, sold_value, sold_auctions, taken_at
         FROM sales_points ORDER BY item_id",
    )
    .fetch_all(&pool)
    .await
    .unwrap();
    let interval_end = fixture_time() + TimeDelta::hours(1);
    assert_eq!(
        sales,
        [
            (10, 5, 500, 1, interval_end),
            (11, 18, 3_600, 1, interval_end)
        ]
    );

    let previous: DateTime<Utc> = sqlx::query_scalar(
        "SELECT previous_taken_at FROM snapshots WHERE previous_taken_at IS NOT NULL",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(previous, fixture_time());
}

#[sqlx::test]
async fn a_failed_ingestion_keeps_the_interval_for_the_next_cycle(pool: PgPool) {
    let api = StubApi::with_fixtures();
    api.publish(
        AuctionSource::Commodities,
        "Thu, 05 Nov 2026 05:00:00 GMT",
        vec![listing(1, 10, 100, 5, TimeLeft::VeryLong)],
    );
    let fetcher = fetcher(pool.clone(), api, RealmSelection::CommoditiesOnly);
    fetcher.run_cycle().await.unwrap();

    api_of(&fetcher).set_source_failing(AuctionSource::Commodities, true);
    fetcher.run_cycle().await.unwrap();
    api_of(&fetcher).set_source_failing(AuctionSource::Commodities, false);
    api_of(&fetcher).publish(AuctionSource::Commodities, LATER, Vec::new());
    fetcher.run_cycle().await.unwrap();

    assert_eq!(
        count(
            &pool,
            "SELECT SUM(sold_quantity)::bigint FROM sales_points WHERE item_id = 10"
        )
        .await,
        5
    );
}

#[sqlx::test]
async fn resolves_item_metadata_and_remembers_unknown_items(pool: PgPool) {
    let fetcher = fetcher(pool.clone(), StubApi::with_fixtures(), slugs(&["hyjal"]));

    let report = fetcher.run_cycle().await.unwrap();

    assert_eq!(report.items_resolved, 6);
    let (name, quality, level, class, subclass): (String, String, i32, String, String) =
        sqlx::query_as(
            "SELECT name, quality, level, item_class, item_subclass FROM items WHERE id = 190396",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(name, "Minerai de test");
    assert_eq!(quality, "RARE");
    assert_eq!(level, 70);
    assert_eq!(class, "Artisanat");
    assert_eq!(subclass, "Métal et pierre");
    assert_eq!(
        count(
            &pool,
            "SELECT COUNT(*) FROM items
             WHERE id = 999999 AND name IS NULL AND resolved_at IS NOT NULL"
        )
        .await,
        1
    );

    let report = fetcher.run_cycle().await.unwrap();

    assert_eq!(report.items_resolved, 0);
}

#[sqlx::test]
async fn an_unknown_item_is_asked_about_again_after_a_while(pool: PgPool) {
    let fetcher = fetcher(pool.clone(), StubApi::with_fixtures(), slugs(&["hyjal"]));
    fetcher.run_cycle().await.unwrap();

    sqlx::query("UPDATE items SET resolved_at = '2000-01-01' WHERE id IN (999999, 190396)")
        .execute(&pool)
        .await
        .unwrap();
    let report = fetcher.run_cycle().await.unwrap();

    // 190396 has a name: its age does not matter.
    assert_eq!(report.items_resolved, 1);
    assert_eq!(
        count(
            &pool,
            "SELECT COUNT(*) FROM items WHERE id = 999999 AND resolved_at > '2000-01-02'"
        )
        .await,
        1
    );
}

#[sqlx::test]
async fn an_item_lookup_failure_is_retried_next_cycle(pool: PgPool) {
    let api = StubApi::with_fixtures();
    api.set_item_failing(190396, true);
    let fetcher = fetcher(pool, api, RealmSelection::CommoditiesOnly);

    let report = fetcher.run_cycle().await.unwrap();

    assert_eq!((report.items_resolved, report.items_failed), (1, 1));

    api_of(&fetcher).set_item_failing(190396, false);
    let report = fetcher.run_cycle().await.unwrap();

    assert_eq!((report.items_resolved, report.items_failed), (1, 0));
}

#[sqlx::test]
async fn item_lookups_are_capped_per_cycle(pool: PgPool) {
    let fetcher = fetcher_with(
        pool,
        StubApi::with_fixtures(),
        RealmSelection::CommoditiesOnly,
        FetchOptions {
            item_batch: 1,
            ..options()
        },
    );

    let first = fetcher.run_cycle().await.unwrap();
    let second = fetcher.run_cycle().await.unwrap();
    let third = fetcher.run_cycle().await.unwrap();

    assert_eq!(
        [
            first.items_resolved,
            second.items_resolved,
            third.items_resolved
        ],
        [1, 1, 0]
    );
}

async fn commodity_house_id(store: &Store) -> i32 {
    store.ensure_commodity_house(Region::Eu).await.unwrap();
    store.auction_houses(Region::Eu).await.unwrap()[0].id
}

fn sale(item_id: i32, quantity: i64, value: i64) -> SalesPoint {
    SalesPoint {
        item_id,
        variant: String::new(),
        sold_quantity: quantity,
        sold_value: value,
        sold_auctions: 1,
    }
}

async fn save(
    store: &Store,
    house: i32,
    taken_at: DateTime<Utc>,
    aggregate: &Aggregate,
    sales: &[SalesPoint],
) -> anyhow::Result<bool> {
    store
        .save_snapshot(&NewSnapshot {
            auction_house_id: house,
            taken_at,
            previous_taken_at: None,
            fetched_at: taken_at,
            last_modified: LATER,
            aggregate,
            sales,
            state: b"[]",
        })
        .await
}

#[sqlx::test]
async fn a_snapshot_failing_halfway_leaves_nothing_behind(pool: PgPool) {
    let store = Store::from_pool(pool.clone());
    let house = commodity_house_id(&store).await;
    let mut result = aggregate(&[commodity(1, 100, 1)]);
    // The same point twice: the insert fails on the primary key.
    result.points.push(result.points[0].clone());

    let saved = save(&store, house, fixture_time(), &result, &[]).await;

    assert!(saved.is_err());
    for query in [
        "SELECT COUNT(*) FROM snapshots",
        "SELECT COUNT(*) FROM price_points",
        "SELECT COUNT(*) FROM market_states",
        "SELECT COUNT(*) FROM auction_houses WHERE last_modified IS NOT NULL",
    ] {
        assert_eq!(count(&pool, query).await, 0, "{query}");
    }
}

#[sqlx::test]
async fn saving_the_same_snapshot_twice_changes_nothing(pool: PgPool) {
    let store = Store::from_pool(pool.clone());
    let house = commodity_house_id(&store).await;
    let result = aggregate(&[commodity(1, 100, 1)]);

    let first = save(&store, house, fixture_time(), &result, &[]).await.unwrap();
    let second = save(&store, house, fixture_time(), &result, &[]).await.unwrap();

    assert!(first);
    assert!(!second);
    assert_eq!(count(&pool, "SELECT COUNT(*) FROM price_points").await, 1);
}

#[sqlx::test]
async fn large_snapshots_are_stored_completely(pool: PgPool) {
    let store = Store::from_pool(pool.clone());
    let house = commodity_house_id(&store).await;
    // Two variants per item, so ids repeat.
    let auctions: Vec<Auction> = (0..30_000)
        .map(|index| {
            let mut auction = commodity(1 + index / 2, 100, 1);
            if index % 2 == 0 {
                auction.item.bonus_lists = vec![1];
            }
            auction
        })
        .collect();

    let inserted = save(&store, house, fixture_time(), &aggregate(&auctions), &[])
        .await
        .unwrap();

    assert!(inserted);
    assert_eq!(
        count(&pool, "SELECT COUNT(*) FROM price_points").await,
        30_000
    );
    assert_eq!(count(&pool, "SELECT COUNT(*) FROM items").await, 15_000);
}

#[sqlx::test]
async fn each_day_gets_its_own_partition(pool: PgPool) {
    let store = Store::from_pool(pool.clone());
    let house = commodity_house_id(&store).await;
    let result = aggregate(&[commodity(1, 100, 1)]);

    save(&store, house, fixture_time(), &result, &[sale(1, 1, 100)])
        .await
        .unwrap();
    save(
        &store,
        house,
        fixture_time() + TimeDelta::days(1),
        &result,
        &[],
    )
    .await
    .unwrap();

    assert_eq!(
        count(
            &pool,
            "SELECT COUNT(*) FROM price_points_20261105"
        )
        .await,
        1
    );
    assert_eq!(
        count(
            &pool,
            "SELECT COUNT(*) FROM price_points_20261106"
        )
        .await,
        1
    );
    assert_eq!(
        count(
            &pool,
            "SELECT COUNT(*) FROM sales_points_20261105"
        )
        .await,
        1
    );
}

#[sqlx::test]
async fn a_day_boundary_is_midnight_utc(pool: PgPool) {
    let store = Store::from_pool(pool.clone());
    let house = commodity_house_id(&store).await;
    let result = aggregate(&[commodity(1, 100, 1)]);
    let midnight = Utc.with_ymd_and_hms(2026, 11, 6, 0, 0, 0).unwrap();

    save(
        &store,
        house,
        midnight - TimeDelta::seconds(1),
        &result,
        &[],
    )
    .await
    .unwrap();
    save(&store, house, midnight, &result, &[]).await.unwrap();

    assert_eq!(
        count(&pool, "SELECT COUNT(*) FROM price_points_20261105").await,
        1
    );
    assert_eq!(
        count(&pool, "SELECT COUNT(*) FROM price_points_20261106").await,
        1
    );
}

fn point(item_id: i32, min: i64, median: i64, quantity: i64) -> PricePoint {
    PricePoint {
        item_id,
        variant: String::new(),
        min_price: min,
        p25_price: median,
        median_price: median,
        p75_price: median,
        mean_price: median,
        quantity,
        auction_count: 1,
    }
}

fn aggregate_of(points: Vec<PricePoint>) -> Aggregate {
    Aggregate {
        points,
        ..Aggregate::default()
    }
}

#[sqlx::test]
async fn old_days_are_rolled_up_and_recent_ones_kept(pool: PgPool) {
    let store = Store::from_pool(pool.clone());
    let house = commodity_house_id(&store).await;
    let old_day = fixture_time();
    save(
        &store,
        house,
        old_day,
        &aggregate_of(vec![point(1, 100, 200, 10)]),
        &[sale(1, 2, 400)],
    )
    .await
    .unwrap();
    save(
        &store,
        house,
        old_day + TimeDelta::hours(1),
        &aggregate_of(vec![point(1, 80, 300, 30)]),
        &[sale(1, 3, 900)],
    )
    .await
    .unwrap();
    let recent = old_day + TimeDelta::days(2);
    save(
        &store,
        house,
        recent,
        &aggregate_of(vec![point(1, 50, 60, 5)]),
        &[sale(1, 1, 60)],
    )
    .await
    .unwrap();

    let rolled_up = store.roll_up_old_partitions(1, recent).await.unwrap();

    assert_eq!(rolled_up, 1);
    let (min, median, quantity): (i64, i64, i32) = sqlx::query_as(
        "SELECT min_price, median_price, quantity FROM price_points_daily WHERE day = '2026-11-05'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!((min, median, quantity), (80, 250, 20));
    let (sold, value, auctions): (i32, i64, i32) = sqlx::query_as(
        "SELECT sold_quantity, sold_value, sold_auctions FROM sales_points_daily
         WHERE day = '2026-11-05'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!((sold, value, auctions), (5, 1_300, 2));

    assert_eq!(count(&pool, "SELECT COUNT(*) FROM price_points").await, 1);
    assert_eq!(count(&pool, "SELECT COUNT(*) FROM sales_points").await, 1);
    assert_eq!(
        count(
            &pool,
            "SELECT COUNT(*) FROM pg_class
             WHERE relname IN ('price_points_20261105', 'sales_points_20261105')"
        )
        .await,
        0
    );

    // Nothing left to do, and the snapshot log is kept.
    assert_eq!(store.roll_up_old_partitions(1, recent).await.unwrap(), 0);
    assert_eq!(count(&pool, "SELECT COUNT(*) FROM snapshots").await, 3);
}

#[sqlx::test]
async fn a_day_at_the_retention_limit_is_kept(pool: PgPool) {
    let store = Store::from_pool(pool);
    let house = commodity_house_id(&store).await;
    let result = aggregate(&[commodity(1, 100, 1)]);
    save(&store, house, fixture_time(), &result, &[])
        .await
        .unwrap();

    let same_week = fixture_time() + TimeDelta::days(7);

    assert_eq!(store.roll_up_old_partitions(7, same_week).await.unwrap(), 0);
    assert_eq!(
        store
            .roll_up_old_partitions(6, same_week)
            .await
            .unwrap(),
        1
    );
}

#[sqlx::test]
async fn a_snapshot_for_a_rolled_up_day_can_still_be_saved(pool: PgPool) {
    let store = Store::from_pool(pool);
    let house = commodity_house_id(&store).await;
    let result = aggregate(&[commodity(1, 100, 1)]);
    save(&store, house, fixture_time(), &result, &[])
        .await
        .unwrap();
    store
        .roll_up_old_partitions(1, fixture_time() + TimeDelta::days(5))
        .await
        .unwrap();

    let saved = save(
        &store,
        house,
        fixture_time() + TimeDelta::hours(1),
        &result,
        &[],
    )
    .await
    .unwrap();

    assert!(saved);
}

#[sqlx::test]
async fn a_cycle_rolls_up_what_is_past_the_retention(pool: PgPool) {
    let fetcher = fetcher_with(
        pool.clone(),
        StubApi::with_fixtures(),
        RealmSelection::CommoditiesOnly,
        FetchOptions {
            hourly_retention_days: 7,
            ..options()
        },
    );
    let old = Utc::now() - TimeDelta::days(30);
    api_of(&fetcher).publish(
        AuctionSource::Commodities,
        &old.format("%a, %d %b %Y %H:%M:%S GMT").to_string(),
        vec![commodity(1, 100, 1)],
    );

    fetcher.run_cycle().await.unwrap();

    assert_eq!(count(&pool, "SELECT COUNT(*) FROM price_points").await, 0);
    assert_eq!(
        count(&pool, "SELECT COUNT(*) FROM price_points_daily").await,
        1
    );
}

#[sqlx::test]
async fn a_simulated_week_gives_curves_and_sales(pool: PgPool) {
    let fetcher = fetcher(pool.clone(), StubApi::with_fixtures(), RealmSelection::All);
    let hours = 72;

    let simulation = Simulation::ending_at(fixture_time(), hours);
    for hour in simulation.hours() {
        Simulation::publish(api_of(&fetcher), *hour);
        let report = fetcher.run_cycle().await.unwrap();
        assert_eq!(report.failed, 0);
    }

    assert_eq!(
        count(
            &pool,
            "SELECT COUNT(*) FROM price_points WHERE item_id = 190396"
        )
        .await,
        hours
    );
    // Sales for nearly every interval of a busy item, and none for the first snapshot.
    let intervals_with_sales = count(
        &pool,
        "SELECT COUNT(*) FROM sales_points WHERE item_id = 190396",
    )
    .await;
    assert!(
        intervals_with_sales > hours * 3 / 4 && intervals_with_sales < hours,
        "{intervals_with_sales}"
    );
    // Each market has its own life.
    assert!(
        count(
            &pool,
            "SELECT COUNT(DISTINCT min_price) FROM price_points WHERE item_id = 2589
             AND taken_at = (SELECT max(taken_at) FROM price_points)"
        )
        .await
            > 1
    );
}

#[tokio::test]
async fn opening_creates_the_database_and_can_be_repeated() {
    let server = std::env::var("DATABASE_URL").expect("the tests need DATABASE_URL");
    let (base, _) = server.rsplit_once('/').unwrap();
    let name = format!("wow_market_open_test_{}", std::process::id());
    let url = format!("{base}/{name}");
    let cleanup = |url: String| async move {
        use sqlx::migrate::MigrateDatabase;
        let _ = sqlx::Postgres::drop_database(&url).await;
    };
    cleanup(url.clone()).await;

    let store = Store::open(&url, 2).await.unwrap();
    let fetcher_store = store.clone();
    let first = Fetcher::new(
        vec![RegionSource {
            api: StubApi::with_fixtures(),
            region: Region::Eu,
            realms: RealmSelection::CommoditiesOnly,
        }],
        fetcher_store,
        options(),
    )
    .run_cycle()
    .await
    .unwrap();
    store.pool().close().await;

    let store = Store::open(&url, 2).await.unwrap();
    let second = Fetcher::new(
        vec![RegionSource {
            api: StubApi::with_fixtures(),
            region: Region::Eu,
            realms: RealmSelection::CommoditiesOnly,
        }],
        store.clone(),
        options(),
    )
    .run_cycle()
    .await
    .unwrap();
    store.pool().close().await;
    cleanup(url).await;

    assert_eq!(first.ingested, 1);
    assert_eq!(
        second,
        CycleReport {
            unchanged: 1,
            ..CycleReport::default()
        }
    );
}
