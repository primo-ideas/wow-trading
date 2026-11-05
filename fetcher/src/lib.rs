//! Fetches World of Warcraft auction house snapshots from the Battle.net API,
//! reduces them to per-item price statistics and estimated sales, and stores
//! those for the website.

pub mod aggregate;
pub mod api;
pub mod config;
pub mod pipeline;
pub mod sales;
pub mod simulation;
pub mod store;
