//! Reduces the auctions of a snapshot to one row of statistics per item variant.

use std::collections::BTreeMap;

use crate::api::{Auction, AuctionItem};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PricePoint {
    pub item_id: i32,
    pub variant: String,
    pub min_price: i64,
    pub p25_price: i64,
    pub median_price: i64,
    pub p75_price: i64,
    pub mean_price: i64,
    pub quantity: i64,
    pub auction_count: i64,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Aggregate {
    /// Sorted by item id, then variant.
    pub points: Vec<PricePoint>,
    pub auction_count: i64,
    /// Auctions left out of the statistics because they have no buyout price.
    pub unpriced_count: i64,
}

struct Listing {
    unit_price: i64,
    quantity: i64,
}

pub fn aggregate(auctions: &[Auction]) -> Aggregate {
    let mut listings_by_key: BTreeMap<(i32, String), Vec<Listing>> = BTreeMap::new();
    let mut unpriced_count = 0;

    for auction in auctions {
        match unit_price(auction) {
            Some(unit_price) => listings_by_key
                .entry((auction.item.id, variant(&auction.item)))
                .or_default()
                .push(Listing {
                    unit_price,
                    quantity: auction.quantity,
                }),
            None => unpriced_count += 1,
        }
    }

    let points = listings_by_key
        .into_iter()
        .map(|((item_id, variant), listings)| summarize(item_id, variant, listings))
        .collect();

    Aggregate {
        points,
        auction_count: auctions.len() as i64,
        unpriced_count,
    }
}

/// Commodities and stacks carry a `unit_price`; other items a `buyout` for the
/// whole auction. An auction with neither can only be bid on.
pub fn unit_price(auction: &Auction) -> Option<i64> {
    if auction.quantity <= 0 {
        return None;
    }
    auction
        .unit_price
        .or_else(|| auction.buyout.map(|buyout| buyout / auction.quantity))
        .filter(|&price| price > 0)
}

/// Distinguishes listings sharing an item id that are not the same product:
/// every caged pet is item 82800, and bonus lists set a piece of gear's item level.
pub fn variant(item: &AuctionItem) -> String {
    if let Some(species) = item.pet_species_id {
        return format!("pet:{species}");
    }
    if item.bonus_lists.is_empty() {
        return String::new();
    }
    let mut bonuses = item.bonus_lists.clone();
    bonuses.sort_unstable();
    let bonuses: Vec<String> = bonuses.iter().map(i64::to_string).collect();
    format!("bonus:{}", bonuses.join(","))
}

/// `listings` must not be empty and quantities must be positive, which
/// `unit_price` guarantees.
fn summarize(item_id: i32, variant: String, mut listings: Vec<Listing>) -> PricePoint {
    listings.sort_unstable_by_key(|listing| listing.unit_price);

    let quantity: i64 = listings.iter().map(|listing| listing.quantity).sum();
    let total_value: i128 = listings
        .iter()
        .map(|listing| i128::from(listing.unit_price) * i128::from(listing.quantity))
        .sum();

    PricePoint {
        item_id,
        variant,
        min_price: listings[0].unit_price,
        p25_price: weighted_quantile(&listings, quantity, 1, 4),
        median_price: weighted_quantile(&listings, quantity, 1, 2),
        p75_price: weighted_quantile(&listings, quantity, 3, 4),
        mean_price: (total_value / i128::from(quantity)) as i64,
        quantity,
        auction_count: listings.len() as i64,
    }
}

/// Price of the unit at rank `ceil(total * numerator / denominator)` in the
/// price-sorted listings. Weighting by quantity matters: 1000 units at 5g and
/// one unit at 1000g have a median of 5g, not of the midpoint of two auctions.
fn weighted_quantile(sorted: &[Listing], total: i64, numerator: i64, denominator: i64) -> i64 {
    let rank = (total * numerator + denominator - 1) / denominator;
    let mut cumulative = 0;
    for listing in sorted {
        cumulative += listing.quantity;
        if cumulative >= rank {
            return listing.unit_price;
        }
    }
    sorted[sorted.len() - 1].unit_price
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sales::TimeLeft;

    fn item(id: i32) -> AuctionItem {
        AuctionItem {
            id,
            bonus_lists: Vec::new(),
            pet_species_id: None,
        }
    }

    fn listing(id: i32, unit_price: i64, quantity: i64) -> Auction {
        Auction {
            id: i64::from(id),
            time_left: TimeLeft::Long,
            item: item(id),
            quantity,
            unit_price: Some(unit_price),
            buyout: None,
        }
    }

    #[test]
    fn quantiles_are_weighted_by_quantity() {
        let result = aggregate(&[listing(1, 1_000, 1), listing(1, 50, 1_000)]);

        let point = &result.points[0];
        assert_eq!(point.min_price, 50);
        assert_eq!(point.median_price, 50);
        assert_eq!(point.p75_price, 50);
        assert_eq!(point.quantity, 1_001);
        assert_eq!(point.auction_count, 2);
    }

    #[test]
    fn quantiles_pick_the_expected_rank() {
        let auctions: Vec<Auction> = (1..=4).map(|price| listing(1, price * 100, 1)).collect();

        let point = &aggregate(&auctions).points[0];
        assert_eq!(point.p25_price, 100);
        assert_eq!(point.median_price, 200);
        assert_eq!(point.p75_price, 300);
        assert_eq!(point.mean_price, 250);
    }

    #[test]
    fn single_auction_gives_the_same_price_everywhere() {
        let point = &aggregate(&[listing(1, 700, 3)]).points[0];

        assert_eq!(
            (
                point.min_price,
                point.p25_price,
                point.median_price,
                point.p75_price,
                point.mean_price
            ),
            (700, 700, 700, 700, 700)
        );
    }

    #[test]
    fn mean_does_not_overflow_on_extreme_listings() {
        let point = &aggregate(&[
            listing(1, i64::MAX / 2, 1_000),
            listing(1, i64::MAX / 2, 1_000),
        ])
        .points[0];

        assert_eq!(point.mean_price, i64::MAX / 2);
    }

    #[test]
    fn buyout_is_divided_by_quantity_when_there_is_no_unit_price() {
        let auction = Auction {
            id: 1,
            time_left: TimeLeft::Long,
            item: item(1),
            quantity: 4,
            unit_price: None,
            buyout: Some(1_000),
        };

        assert_eq!(aggregate(&[auction]).points[0].min_price, 250);
    }

    #[test]
    fn auctions_without_a_usable_price_are_counted_but_not_aggregated() {
        let bid_only = Auction {
            id: 1,
            time_left: TimeLeft::Long,
            item: item(1),
            quantity: 1,
            unit_price: None,
            buyout: None,
        };
        let zero_buyout = Auction {
            id: 2,
            time_left: TimeLeft::Long,
            item: item(2),
            quantity: 1,
            unit_price: None,
            buyout: Some(0),
        };
        let zero_quantity = Auction {
            id: 3,
            time_left: TimeLeft::Long,
            item: item(3),
            quantity: 0,
            unit_price: None,
            buyout: Some(100),
        };

        let result = aggregate(&[bid_only, zero_buyout, zero_quantity]);

        assert!(result.points.is_empty());
        assert_eq!(result.auction_count, 3);
        assert_eq!(result.unpriced_count, 3);
    }

    #[test]
    fn pets_are_split_by_species_and_ignore_bonus_lists() {
        let pet = |species| AuctionItem {
            id: 82800,
            bonus_lists: vec![1],
            pet_species_id: Some(species),
        };

        assert_eq!(variant(&pet(39)), "pet:39");
        assert_ne!(variant(&pet(39)), variant(&pet(40)));
    }

    #[test]
    fn bonus_list_order_does_not_change_the_variant() {
        let gear = |bonus_lists| AuctionItem {
            id: 1,
            bonus_lists,
            pet_species_id: None,
        };

        assert_eq!(variant(&gear(vec![6652, 1472])), "bonus:1472,6652");
        assert_eq!(variant(&gear(vec![1472, 6652])), "bonus:1472,6652");
        assert_eq!(variant(&gear(Vec::new())), "");
    }

    #[test]
    fn points_are_sorted_by_item_then_variant() {
        let mut gear = listing(1, 10, 1);
        gear.item.bonus_lists = vec![5];

        let result = aggregate(&[listing(2, 10, 1), gear, listing(1, 10, 1)]);

        let keys: Vec<(i32, &str)> = result
            .points
            .iter()
            .map(|point| (point.item_id, point.variant.as_str()))
            .collect();
        assert_eq!(keys, [(1, ""), (1, "bonus:5"), (2, "")]);
    }
}
