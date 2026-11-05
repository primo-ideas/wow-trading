//! The Battle.net data the fetcher needs, behind a trait so the pipeline can
//! run against the real API or against a stub.

use std::future::Future;

use chrono::{DateTime, Utc};
use serde::Deserialize;

use crate::sales::TimeLeft;

pub mod blizzard;
pub mod stub;

/// Where a set of auctions comes from. Commodities are region-wide; everything
/// else is listed per connected realm.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AuctionSource {
    Commodities,
    ConnectedRealm(i32),
}

/// Prices are in copper. Fields the fetcher does not use (`bid`...) are not
/// decoded, to keep large snapshots cheap in memory.
#[derive(Debug, Clone, Deserialize)]
pub struct Auction {
    pub id: i64,
    pub item: AuctionItem,
    pub quantity: i64,
    pub unit_price: Option<i64>,
    pub buyout: Option<i64>,
    #[serde(default)]
    pub time_left: TimeLeft,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AuctionItem {
    pub id: i32,
    #[serde(default)]
    pub bonus_lists: Vec<i64>,
    pub pet_species_id: Option<i64>,
}

#[derive(Debug, Clone)]
pub struct Snapshot {
    /// The header as received, to be sent back verbatim as `If-Modified-Since`.
    pub last_modified: String,
    /// `last_modified`, parsed.
    pub taken_at: DateTime<Utc>,
    pub auctions: Vec<Auction>,
}

#[derive(Debug, Clone)]
pub enum Fetched {
    NotModified,
    Snapshot(Snapshot),
}

#[derive(Debug, Clone, Deserialize)]
pub struct ConnectedRealm {
    pub id: i32,
    pub realms: Vec<Realm>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Realm {
    pub name: String,
    pub slug: String,
}

/// Only `name` is required: an item missing the rest is still worth displaying.
#[derive(Debug, Clone, Deserialize)]
pub struct Item {
    pub id: i32,
    pub name: String,
    pub quality: Option<ItemQuality>,
    pub level: Option<i32>,
    pub item_class: Option<NamedRef>,
    pub item_subclass: Option<NamedRef>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ItemQuality {
    #[serde(rename = "type")]
    pub kind: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NamedRef {
    pub name: String,
}

#[derive(Debug, thiserror::Error)]
pub enum ApiError {
    /// The token endpoint refused the client credentials: retrying cannot help.
    #[error("Battle.net rejected the client credentials (HTTP {status}): {body}")]
    Auth { status: u16, body: String },
    #[error("{url} answered HTTP {status}: {body}")]
    Status {
        url: String,
        status: u16,
        body: String,
    },
    #[error("request to Battle.net failed: {0}")]
    Http(#[from] reqwest::Error),
    #[error("could not decode the response of {url}: {source}")]
    Decode {
        url: String,
        source: serde_json::Error,
    },
    #[error("{url} answered without a valid Last-Modified header")]
    MissingLastModified { url: String },
    #[error("unexpected connected realm link: {href}")]
    UnexpectedHref { href: String },
    #[error("stub failure: {0}")]
    Stub(String),
}

pub trait AuctionApi: Send + Sync {
    fn connected_realm_ids(&self) -> impl Future<Output = Result<Vec<i32>, ApiError>> + Send;

    fn connected_realm(
        &self,
        id: i32,
    ) -> impl Future<Output = Result<ConnectedRealm, ApiError>> + Send;

    fn auctions(
        &self,
        source: AuctionSource,
        if_modified_since: Option<&str>,
    ) -> impl Future<Output = Result<Fetched, ApiError>> + Send;

    /// `None` when the API does not know this item.
    fn item(&self, id: i32) -> impl Future<Output = Result<Option<Item>, ApiError>> + Send;
}

/// Body of the auction endpoints, commodities and connected realms alike.
#[derive(Deserialize)]
pub(crate) struct AuctionsEnvelope {
    #[serde(default)]
    pub auctions: Vec<Auction>,
}

pub(crate) fn parse_http_date(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc2822(value)
        .ok()
        .map(|date| date.with_timezone(&Utc))
}

pub(crate) fn format_http_date(date: DateTime<Utc>) -> String {
    date.format("%a, %d %b %Y %H:%M:%S GMT").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_and_writes_http_dates() {
        let text = "Thu, 05 Nov 2026 05:00:00 GMT";

        let date = parse_http_date(text).unwrap();

        assert_eq!(date.timestamp(), 1_793_854_800);
        assert_eq!(format_http_date(date), text);
        assert_eq!(parse_http_date("not a date"), None);
    }
}
