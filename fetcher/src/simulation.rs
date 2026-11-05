//! Generates a plausible market over time, so that without credentials the site
//! still has curves and sales to show. Used by `--stub` only.
//!
//! Each listing lives its whole life deterministically: it is posted at some hour,
//! then either sells at a later hour or expires after 48 hours. Asking for the same
//! hour twice gives the same auctions, so re-running extends the history cleanly.

use std::f64::consts::TAU;

use chrono::{DateTime, TimeDelta, Utc};

use crate::api::stub::StubApi;
use crate::api::{Auction, AuctionItem, AuctionSource, format_http_date};
use crate::sales::TimeLeft;

const LIFETIME_HOURS: i64 = 48;
/// Share of listings that find a buyer, in percent.
const SOLD_PERCENT: u64 = 60;
const HOURS_PER_WEEK: f64 = 168.0;
const HOURS_PER_DAY: f64 = 24.0;

struct SimulatedItem {
    id: i32,
    bonus_lists: &'static [i64],
    pet_species_id: Option<i64>,
    base_price: i64,
    listings_per_hour: u64,
    /// Above 1, listings are stacks priced per unit; otherwise they carry a buyout.
    max_stack: u64,
}

const fn commodity(id: i32, base_price: i64, listings_per_hour: u64, max_stack: u64) -> SimulatedItem {
    SimulatedItem {
        id,
        bonus_lists: &[],
        pet_species_id: None,
        base_price,
        listings_per_hour,
        max_stack,
    }
}

const COMMODITIES: [SimulatedItem; 2] = [
    commodity(190396, 1_250_000, 6, 200),
    commodity(190395, 40_000, 4, 100),
];

const REALM_ITEMS: [SimulatedItem; 5] = [
    commodity(2589, 2_000, 3, 20),
    SimulatedItem {
        id: 200000,
        bonus_lists: &[1472, 6652],
        pet_species_id: None,
        base_price: 150_000_000,
        listings_per_hour: 1,
        max_stack: 1,
    },
    SimulatedItem {
        id: 82800,
        bonus_lists: &[],
        pet_species_id: Some(39),
        base_price: 99_000_000,
        listings_per_hour: 1,
        max_stack: 1,
    },
    SimulatedItem {
        id: 82800,
        bonus_lists: &[],
        pet_species_id: Some(40),
        base_price: 1_000_000,
        listings_per_hour: 2,
        max_stack: 1,
    },
    // Not in the item fixtures: shows how the site handles an unknown item.
    commodity(999999, 500_000, 1, 1),
];

/// A week of hourly snapshots ending at the last full hour before `end`.
pub struct Simulation {
    hours: Vec<DateTime<Utc>>,
}

impl Simulation {
    pub fn ending_at(end: DateTime<Utc>, hours: i64) -> Self {
        let last = hour_number(end);
        Self {
            hours: ((last - hours + 1)..=last).map(hour_start).collect(),
        }
    }

    pub fn hours(&self) -> &[DateTime<Utc>] {
        &self.hours
    }

    /// Publishes this hour's snapshot of every market of `api`.
    pub fn publish(api: &StubApi, at: DateTime<Utc>) {
        let last_modified = format_http_date(at);
        api.publish(
            AuctionSource::Commodities,
            &last_modified,
            auctions(&COMMODITIES, 0, at),
        );
        for realm in api.connected_realm_ids_published() {
            api.publish(
                AuctionSource::ConnectedRealm(realm),
                &last_modified,
                auctions(&REALM_ITEMS, realm.unsigned_abs().into(), at),
            );
        }
    }
}

fn hour_number(at: DateTime<Utc>) -> i64 {
    at.timestamp().div_euclid(3600)
}

fn hour_start(number: i64) -> DateTime<Utc> {
    DateTime::UNIX_EPOCH + TimeDelta::hours(number)
}

fn auctions(items: &[SimulatedItem], market: u64, at: DateTime<Utc>) -> Vec<Auction> {
    let now = hour_number(at);
    let mut auctions = Vec::new();
    for item in items {
        for posted in (now - LIFETIME_HOURS + 1)..=now {
            for index in 0..item.listings_per_hour {
                if let Some(auction) = listing(item, market, posted, index, now) {
                    auctions.push(auction);
                }
            }
        }
    }
    auctions
}

/// The listing posted at hour `posted`, as seen at hour `now`, unless it is gone by then.
fn listing(
    item: &SimulatedItem,
    market: u64,
    posted: i64,
    index: u64,
    now: i64,
) -> Option<Auction> {
    let species = item.pet_species_id.unwrap_or(0).unsigned_abs();
    let seed = mix(&[
        market,
        u64::from(item.id.unsigned_abs()),
        species,
        posted.unsigned_abs(),
        index,
    ]);

    let expires = posted + LIFETIME_HOURS;
    let gone_at = if seed % 100 < SOLD_PERCENT {
        posted + 1 + ((seed >> 8) % (LIFETIME_HOURS as u64 - 1)) as i64
    } else {
        expires
    };
    if now >= gone_at {
        return None;
    }

    let minutes_left = (expires - now) * 60 - ((seed >> 16) % 60) as i64;
    let time_left = match minutes_left {
        ..30 => TimeLeft::Short,
        30..120 => TimeLeft::Medium,
        120..720 => TimeLeft::Long,
        _ => TimeLeft::VeryLong,
    };

    // Prices follow a weekly and a daily wave, plus each listing's own spread.
    let hour = posted as f64;
    let trend = 1.0
        + 0.15 * (TAU * hour / HOURS_PER_WEEK).sin()
        + 0.04 * (TAU * hour / HOURS_PER_DAY).sin();
    let spread = 0.92 + 0.16 * ((seed >> 24) % 1000) as f64 / 1000.0;
    let price = (item.base_price as f64 * trend * spread) as i64;

    let stacks = item.max_stack > 1;
    Some(Auction {
        id: (seed >> 1) as i64,
        item: AuctionItem {
            id: item.id,
            bonus_lists: item.bonus_lists.to_vec(),
            pet_species_id: item.pet_species_id,
        },
        quantity: if stacks {
            1 + ((seed >> 34) % item.max_stack) as i64
        } else {
            1
        },
        unit_price: stacks.then_some(price),
        buyout: (!stacks).then_some(price),
        time_left,
    })
}

/// A small non-cryptographic hash, to get reproducible variety without a dependency.
fn mix(values: &[u64]) -> u64 {
    let mut hash = 0x9E37_79B9_7F4A_7C15_u64;
    for value in values {
        hash ^= *value;
        hash = hash.wrapping_mul(0xBF58_476D_1CE4_E5B9);
        hash ^= hash >> 27;
        hash = hash.wrapping_mul(0x94D0_49BB_1331_11EB);
        hash ^= hash >> 31;
    }
    hash
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at_hour(hour: i64) -> DateTime<Utc> {
        hour_start(500_000 + hour)
    }

    #[test]
    fn the_same_hour_gives_the_same_auctions() {
        let ids = |auctions: Vec<Auction>| {
            auctions
                .iter()
                .map(|auction| (auction.id, auction.quantity))
                .collect::<Vec<_>>()
        };

        assert_eq!(
            ids(auctions(&REALM_ITEMS, 1, at_hour(0))),
            ids(auctions(&REALM_ITEMS, 1, at_hour(0)))
        );
    }

    #[test]
    fn markets_differ() {
        let first = auctions(&REALM_ITEMS, 1, at_hour(0));
        let second = auctions(&REALM_ITEMS, 2, at_hour(0));

        assert_ne!(first[0].id, second[0].id);
    }

    #[test]
    fn listings_keep_their_id_from_one_hour_to_the_next() {
        let first: Vec<i64> = auctions(&COMMODITIES, 0, at_hour(0))
            .iter()
            .map(|auction| auction.id)
            .collect();
        let second: Vec<i64> = auctions(&COMMODITIES, 0, at_hour(1))
            .iter()
            .map(|auction| auction.id)
            .collect();

        let kept = first.iter().filter(|id| second.contains(id)).count();
        assert!(kept > first.len() / 2, "{kept} of {}", first.len());
        assert!(kept < first.len());
    }

    #[test]
    fn every_time_band_shows_up() {
        let auctions = auctions(&COMMODITIES, 0, at_hour(0));

        for band in [
            TimeLeft::Short,
            TimeLeft::Medium,
            TimeLeft::Long,
            TimeLeft::VeryLong,
        ] {
            assert!(
                auctions.iter().any(|auction| auction.time_left == band),
                "{band:?}"
            );
        }
    }

    #[test]
    fn stacks_have_a_unit_price_and_the_rest_a_buyout() {
        for auction in auctions(&REALM_ITEMS, 1, at_hour(0)) {
            match auction.item.id {
                2589 => assert!(auction.unit_price.is_some() && auction.buyout.is_none()),
                _ => assert!(auction.buyout.is_some() && auction.unit_price.is_none()),
            }
        }
    }

    #[test]
    fn covers_the_requested_hours_ending_at_the_last_full_hour() {
        let end = hour_start(500_000) + TimeDelta::minutes(25);

        let simulation = Simulation::ending_at(end, 3);

        assert_eq!(
            simulation.hours(),
            [hour_start(499_998), hour_start(499_999), hour_start(500_000)]
        );
    }
}
