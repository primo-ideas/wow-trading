//! Estimates sales by comparing two consecutive snapshots of a market.
//!
//! The API does not report sales. What can be observed is an auction leaving, or
//! its quantity dropping, between two snapshots. An auction that left may have
//! simply expired, so it only counts as sold if it had too much time left for that.
//!
//! This remains an estimate. A cancelled auction looks like a sold one, which
//! inflates it; an auction sold close to its expiry, or both listed and sold
//! between two snapshots, goes unseen, which deflates it.

use std::collections::{BTreeMap, HashMap};
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::aggregate::{unit_price, variant};
use crate::api::Auction;

/// Time remaining on an auction, as the coarse bands the API reports.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum TimeLeft {
    Short,
    Medium,
    Long,
    VeryLong,
    #[default]
    #[serde(other)]
    Unknown,
}

impl TimeLeft {
    /// The least time an auction in this band can have left, or `None` if nothing
    /// is known. Bands are under 30 minutes, under 2 hours, under 12 hours and
    /// under 48 hours.
    fn minimum_remaining(self) -> Option<Duration> {
        const MINUTE: u64 = 60;
        match self {
            TimeLeft::Short => Some(Duration::ZERO),
            TimeLeft::Medium => Some(Duration::from_secs(30 * MINUTE)),
            TimeLeft::Long => Some(Duration::from_secs(120 * MINUTE)),
            TimeLeft::VeryLong => Some(Duration::from_secs(720 * MINUTE)),
            TimeLeft::Unknown => None,
        }
    }

    fn cannot_have_expired_within(self, elapsed: Duration) -> bool {
        self.minimum_remaining()
            .is_some_and(|remaining| remaining > elapsed)
    }
}

/// What must be remembered of an auction until the next snapshot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LiveAuction {
    pub id: i64,
    pub item_id: i32,
    pub variant: String,
    pub quantity: i64,
    pub unit_price: i64,
    pub time_left: TimeLeft,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SalesPoint {
    pub item_id: i32,
    pub variant: String,
    pub sold_quantity: i64,
    /// Copper.
    pub sold_value: i64,
    pub sold_auctions: i64,
}

/// Auctions with no buyout are left out: their sale price cannot be known.
pub fn live_auctions(auctions: &[Auction]) -> Vec<LiveAuction> {
    auctions
        .iter()
        .filter_map(|auction| {
            Some(LiveAuction {
                id: auction.id,
                item_id: auction.item.id,
                variant: variant(&auction.item),
                quantity: auction.quantity,
                unit_price: unit_price(auction)?,
                time_left: auction.time_left,
            })
        })
        .collect()
}

/// Compares `previous` to `current`, `elapsed` apart. Sorted by item, then variant.
pub fn estimate_sales(
    previous: &[LiveAuction],
    current: &[LiveAuction],
    elapsed: Duration,
) -> Vec<SalesPoint> {
    let current_quantities: HashMap<i64, i64> = current
        .iter()
        .map(|auction| (auction.id, auction.quantity))
        .collect();

    let mut totals: BTreeMap<(i32, &str), (i64, i128, i64)> = BTreeMap::new();
    for auction in previous {
        let sold = match current_quantities.get(&auction.id) {
            // Part of a commodity auction can be bought: it stays listed for less.
            Some(quantity) => (auction.quantity - quantity).max(0),
            None if auction.time_left.cannot_have_expired_within(elapsed) => auction.quantity,
            None => 0,
        };
        if sold > 0 {
            let total = totals
                .entry((auction.item_id, auction.variant.as_str()))
                .or_default();
            total.0 += sold;
            total.1 += i128::from(sold) * i128::from(auction.unit_price);
            total.2 += 1;
        }
    }

    totals
        .into_iter()
        .map(|((item_id, variant), (quantity, value, auctions))| SalesPoint {
            item_id,
            variant: variant.to_owned(),
            sold_quantity: quantity,
            sold_value: i64::try_from(value).unwrap_or(i64::MAX),
            sold_auctions: auctions,
        })
        .collect()
}

type EncodedAuction<'a> = (i64, i32, &'a str, i64, i64, TimeLeft);
type DecodedAuction = (i64, i32, String, i64, i64, TimeLeft);

/// Arrays rather than objects: field names would be repeated for each of up to a
/// million auctions.
pub fn encode_state(auctions: &[LiveAuction]) -> Vec<u8> {
    let rows: Vec<EncodedAuction> = auctions
        .iter()
        .map(|auction| {
            (
                auction.id,
                auction.item_id,
                auction.variant.as_str(),
                auction.quantity,
                auction.unit_price,
                auction.time_left,
            )
        })
        .collect();
    serde_json::to_vec(&rows).expect("these types always serialize")
}

pub fn decode_state(bytes: &[u8]) -> Result<Vec<LiveAuction>, serde_json::Error> {
    let rows: Vec<DecodedAuction> = serde_json::from_slice(bytes)?;
    Ok(rows
        .into_iter()
        .map(
            |(id, item_id, variant, quantity, unit_price, time_left)| LiveAuction {
                id,
                item_id,
                variant,
                quantity,
                unit_price,
                time_left,
            },
        )
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::AuctionItem;

    const ONE_HOUR: Duration = Duration::from_secs(3600);

    fn live(id: i64, item_id: i32, quantity: i64, unit_price: i64, time_left: TimeLeft) -> LiveAuction {
        LiveAuction {
            id,
            item_id,
            variant: String::new(),
            quantity,
            unit_price,
            time_left,
        }
    }

    fn totals(sales: &[SalesPoint]) -> Vec<(i32, i64, i64, i64)> {
        sales
            .iter()
            .map(|sale| {
                (
                    sale.item_id,
                    sale.sold_quantity,
                    sale.sold_value,
                    sale.sold_auctions,
                )
            })
            .collect()
    }

    #[test]
    fn an_auction_gone_with_a_lot_of_time_left_counts_as_sold() {
        let previous = [live(1, 10, 5, 100, TimeLeft::VeryLong)];

        let sales = estimate_sales(&previous, &[], ONE_HOUR);

        assert_eq!(totals(&sales), [(10, 5, 500, 1)]);
    }

    #[test]
    fn an_auction_gone_near_its_expiry_may_have_expired_and_does_not_count() {
        for band in [TimeLeft::Short, TimeLeft::Medium, TimeLeft::Unknown] {
            let previous = [live(1, 10, 5, 100, band)];

            assert!(
                estimate_sales(&previous, &[], ONE_HOUR).is_empty(),
                "{band:?}"
            );
        }
    }

    #[test]
    fn what_may_have_expired_depends_on_the_time_between_snapshots() {
        let medium = [live(1, 10, 1, 100, TimeLeft::Medium)];
        let long = [live(1, 10, 1, 100, TimeLeft::Long)];
        let very_long = [live(1, 10, 1, 100, TimeLeft::VeryLong)];
        let minutes = |count: u64| Duration::from_secs(count * 60);

        assert_eq!(estimate_sales(&medium, &[], minutes(29)).len(), 1);
        assert_eq!(estimate_sales(&medium, &[], minutes(30)).len(), 0);
        assert_eq!(estimate_sales(&long, &[], minutes(119)).len(), 1);
        assert_eq!(estimate_sales(&long, &[], minutes(120)).len(), 0);
        assert_eq!(estimate_sales(&very_long, &[], minutes(719)).len(), 1);
        assert_eq!(estimate_sales(&very_long, &[], minutes(720)).len(), 0);
    }

    #[test]
    fn a_quantity_drop_is_a_sale_whatever_the_time_left() {
        let previous = [live(1, 10, 100, 7, TimeLeft::Short)];
        let current = [live(1, 10, 60, 7, TimeLeft::Short)];

        let sales = estimate_sales(&previous, &current, ONE_HOUR);

        assert_eq!(totals(&sales), [(10, 40, 280, 1)]);
    }

    #[test]
    fn an_auction_still_listed_unchanged_or_growing_sold_nothing() {
        let previous = [
            live(1, 10, 5, 100, TimeLeft::VeryLong),
            live(2, 11, 5, 100, TimeLeft::VeryLong),
        ];
        let current = [
            live(1, 10, 5, 100, TimeLeft::VeryLong),
            live(2, 11, 9, 100, TimeLeft::VeryLong),
        ];

        assert!(estimate_sales(&previous, &current, ONE_HOUR).is_empty());
    }

    #[test]
    fn a_new_auction_sold_nothing() {
        let current = [live(1, 10, 5, 100, TimeLeft::VeryLong)];

        assert!(estimate_sales(&[], &current, ONE_HOUR).is_empty());
    }

    #[test]
    fn sales_are_totaled_per_item_and_variant() {
        let mut gear = live(3, 10, 1, 1000, TimeLeft::Long);
        gear.variant = "bonus:1".to_owned();
        let previous = [
            live(1, 10, 2, 100, TimeLeft::Long),
            live(2, 10, 3, 200, TimeLeft::VeryLong),
            gear,
        ];

        let sales = estimate_sales(&previous, &[], ONE_HOUR);

        assert_eq!(sales[0].variant, "");
        assert_eq!(
            (sales[0].sold_quantity, sales[0].sold_value, sales[0].sold_auctions),
            (5, 800, 2)
        );
        assert_eq!(sales[1].variant, "bonus:1");
        assert_eq!(sales[1].sold_value, 1000);
    }

    #[test]
    fn a_huge_value_saturates_rather_than_wraps() {
        let previous = [live(1, 10, i64::MAX, i64::MAX, TimeLeft::VeryLong)];

        let sales = estimate_sales(&previous, &[], ONE_HOUR);

        assert_eq!(sales[0].sold_value, i64::MAX);
    }

    #[test]
    fn keeps_only_auctions_with_a_price() {
        let auction = |id, unit_price, buyout| Auction {
            id,
            item: AuctionItem {
                id: 10,
                bonus_lists: vec![2, 1],
                pet_species_id: None,
            },
            quantity: 2,
            unit_price,
            buyout,
            time_left: TimeLeft::Long,
        };

        let live = live_auctions(&[
            auction(1, Some(50), None),
            auction(2, None, Some(300)),
            auction(3, None, None),
        ]);

        assert_eq!(live.len(), 2);
        assert_eq!(live[0].unit_price, 50);
        assert_eq!(live[1].unit_price, 150);
        assert_eq!(live[1].variant, "bonus:1,2");
    }

    #[test]
    fn the_state_survives_encoding() {
        let mut pet = live(2, 82800, 1, 5, TimeLeft::Unknown);
        pet.variant = "pet:39".to_owned();
        let auctions = vec![live(1, 10, 3, 100, TimeLeft::VeryLong), pet];

        let decoded = decode_state(&encode_state(&auctions)).unwrap();

        assert_eq!(decoded, auctions);
    }

    #[test]
    fn time_left_reads_the_api_values_and_tolerates_new_ones() {
        let parse = |value: &str| serde_json::from_str::<TimeLeft>(value).unwrap();

        assert_eq!(parse("\"SHORT\""), TimeLeft::Short);
        assert_eq!(parse("\"VERY_LONG\""), TimeLeft::VeryLong);
        assert_eq!(parse("\"SOMETHING_NEW\""), TimeLeft::Unknown);
    }
}
