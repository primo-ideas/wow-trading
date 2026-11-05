//! In-process stand-in for the Battle.net API. It needs no credentials and serves
//! the same JSON fixtures the HTTP client is tested against, decoded by the same types.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::{Mutex, MutexGuard};

use serde::de::DeserializeOwned;

use super::{
    ApiError, Auction, AuctionApi, AuctionSource, AuctionsEnvelope, ConnectedRealm, Fetched, Item,
    Pet, Snapshot, parse_http_date,
};

/// `Last-Modified` of the snapshots served by [`StubApi::with_fixtures`].
pub const FIXTURE_LAST_MODIFIED: &str = "Thu, 05 Nov 2026 05:00:00 GMT";

const CONNECTED_REALMS: &str = include_str!("../../fixtures/connected_realms.json");
const COMMODITIES: &str = include_str!("../../fixtures/commodities.json");
const REALM_AUCTIONS: &str = include_str!("../../fixtures/connected_realm_auctions.json");
const ITEMS: &str = include_str!("../../fixtures/items.json");
const PETS: &str = include_str!("../../fixtures/pets.json");

#[derive(Default)]
pub struct StubApi {
    state: Mutex<StubState>,
}

#[derive(Default)]
struct StubState {
    realms: BTreeMap<i32, ConnectedRealm>,
    snapshots: HashMap<AuctionSource, Snapshot>,
    items: HashMap<i32, Item>,
    pets: HashMap<i32, Pet>,
    failing_sources: HashSet<AuctionSource>,
    failing_items: HashSet<i32>,
    failing_pets: HashSet<i32>,
    failing_realm_lookups: bool,
    credentials_rejected: bool,
    snapshots_served: usize,
    realm_lookups: usize,
}

impl StubApi {
    /// Commodities and two connected realms (which share the same auctions), all
    /// published at [`FIXTURE_LAST_MODIFIED`], plus item metadata. Item 999999
    /// is on sale but unknown to the item API.
    pub fn with_fixtures() -> Self {
        let stub = Self::default();
        let commodities: AuctionsEnvelope = parse_fixture(COMMODITIES);
        stub.publish(
            AuctionSource::Commodities,
            FIXTURE_LAST_MODIFIED,
            commodities.auctions,
        );

        let realm_auctions: AuctionsEnvelope = parse_fixture(REALM_AUCTIONS);
        for realm in parse_fixture::<Vec<ConnectedRealm>>(CONNECTED_REALMS) {
            stub.publish(
                AuctionSource::ConnectedRealm(realm.id),
                FIXTURE_LAST_MODIFIED,
                realm_auctions.auctions.clone(),
            );
            stub.state().realms.insert(realm.id, realm);
        }

        for mut item in parse_fixture::<Vec<Item>>(ITEMS) {
            item.icon_url = Some(stub_icon_url(item.id));
            stub.state().items.insert(item.id, item);
        }
        for mut pet in parse_fixture::<Vec<Pet>>(PETS) {
            pet.icon_url = Some(stub_icon_url(pet.id));
            stub.state().pets.insert(pet.id, pet);
        }
        stub
    }

    /// Replaces the snapshot of a source, as Blizzard does when it publishes a new one.
    pub fn publish(&self, source: AuctionSource, last_modified: &str, auctions: Vec<Auction>) {
        let taken_at = parse_http_date(last_modified).expect("stub dates must be HTTP dates");
        self.state().snapshots.insert(
            source,
            Snapshot {
                last_modified: last_modified.to_owned(),
                taken_at,
                auctions,
            },
        );
    }

    pub fn connected_realm_ids_published(&self) -> Vec<i32> {
        self.state().realms.keys().copied().collect()
    }

    pub fn set_source_failing(&self, source: AuctionSource, failing: bool) {
        let mut state = self.state();
        if failing {
            state.failing_sources.insert(source);
        } else {
            state.failing_sources.remove(&source);
        }
    }

    pub fn set_item_failing(&self, id: i32, failing: bool) {
        let mut state = self.state();
        if failing {
            state.failing_items.insert(id);
        } else {
            state.failing_items.remove(&id);
        }
    }

    pub fn set_pet_failing(&self, species_id: i32, failing: bool) {
        let mut state = self.state();
        if failing {
            state.failing_pets.insert(species_id);
        } else {
            state.failing_pets.remove(&species_id);
        }
    }

    pub fn set_realm_lookups_failing(&self, failing: bool) {
        self.state().failing_realm_lookups = failing;
    }

    pub fn reject_credentials(&self) {
        self.state().credentials_rejected = true;
    }

    /// Full snapshots handed out, not counting "not modified" answers.
    pub fn snapshots_served(&self) -> usize {
        self.state().snapshots_served
    }

    pub fn realm_lookups(&self) -> usize {
        self.state().realm_lookups
    }

    fn state(&self) -> MutexGuard<'_, StubState> {
        self.state
            .lock()
            .expect("stub state lock is never poisoned")
    }
}

impl AuctionApi for StubApi {
    async fn connected_realm_ids(&self) -> Result<Vec<i32>, ApiError> {
        let state = self.state();
        if state.credentials_rejected {
            return Err(ApiError::Auth {
                status: 401,
                body: "stub: credentials rejected".to_owned(),
            });
        }
        Ok(state.realms.keys().copied().collect())
    }

    async fn connected_realm(&self, id: i32) -> Result<ConnectedRealm, ApiError> {
        let mut state = self.state();
        state.realm_lookups += 1;
        if state.failing_realm_lookups {
            return Err(ApiError::Stub("realm lookups are set to fail".to_owned()));
        }
        state
            .realms
            .get(&id)
            .cloned()
            .ok_or_else(|| ApiError::Stub(format!("unknown connected realm {id}")))
    }

    async fn auctions(
        &self,
        source: AuctionSource,
        if_modified_since: Option<&str>,
    ) -> Result<Fetched, ApiError> {
        let mut state = self.state();
        if state.failing_sources.contains(&source) {
            return Err(ApiError::Stub(format!("{source:?} is set to fail")));
        }
        let snapshot = state
            .snapshots
            .get(&source)
            .ok_or_else(|| ApiError::Stub(format!("nothing published for {source:?}")))?;
        if if_modified_since == Some(snapshot.last_modified.as_str()) {
            return Ok(Fetched::NotModified);
        }
        let snapshot = snapshot.clone();
        state.snapshots_served += 1;
        Ok(Fetched::Snapshot(snapshot))
    }

    async fn item(&self, id: i32) -> Result<Option<Item>, ApiError> {
        let state = self.state();
        if state.failing_items.contains(&id) {
            return Err(ApiError::Stub(format!("item {id} is set to fail")));
        }
        Ok(state.items.get(&id).cloned())
    }

    async fn pet(&self, species_id: i32) -> Result<Option<Pet>, ApiError> {
        let state = self.state();
        if state.failing_pets.contains(&species_id) {
            return Err(ApiError::Stub(format!("pet {species_id} is set to fail")));
        }
        Ok(state.pets.get(&species_id).cloned())
    }
}

/// Without credentials the site still needs images, and can only get them from the
/// real image server. These icons exist there, whichever item they end up on.
fn stub_icon_url(id: i32) -> String {
    const ICONS: [u32; 4] = [4615906, 656559, 136235, 132320];
    let icon = ICONS[id.unsigned_abs() as usize % ICONS.len()];
    format!("https://render.worldofwarcraft.com/eu/icons/56/{icon}.jpg")
}

fn parse_fixture<T: DeserializeOwned>(json: &str) -> T {
    serde_json::from_str(json).expect("fixtures are valid")
}
