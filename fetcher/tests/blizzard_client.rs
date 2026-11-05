//! Exercises the real HTTP client against a local stub of Battle.net.

use std::time::Duration;

use serde_json::Value;
use wiremock::matchers::{basic_auth, bearer_token, body_string, method, path, query_param};
use wiremock::{Mock, MockServer, Request, ResponseTemplate};

use wow_market_fetcher::api::blizzard::{BlizzardClient, Credentials, Endpoints, RetryPolicy};
use wow_market_fetcher::api::{ApiError, AuctionApi, AuctionSource, Fetched};
use wow_market_fetcher::config::Region;
use wow_market_fetcher::sales::TimeLeft;

const INDEX: &str = include_str!("../fixtures/connected_realm_index.json");
const CONNECTED_REALMS: &str = include_str!("../fixtures/connected_realms.json");
const COMMODITIES: &str = include_str!("../fixtures/commodities.json");
const REALM_AUCTIONS: &str = include_str!("../fixtures/connected_realm_auctions.json");
const ITEMS: &str = include_str!("../fixtures/items.json");

const LAST_MODIFIED: &str = "Thu, 05 Nov 2026 05:00:00 GMT";
const COMMODITIES_PATH: &str = "/data/wow/auctions/commodities";
const INDEX_PATH: &str = "/data/wow/connected-realm/index";

fn client(server: &MockServer) -> BlizzardClient {
    BlizzardClient::new(
        Credentials::new("my-id", "my-secret"),
        Endpoints {
            api_base: server.uri(),
            oauth_token: format!("{}/token", server.uri()),
        },
        Region::Eu,
        "fr_FR",
        RetryPolicy {
            max_attempts: 3,
            base_delay: Duration::from_millis(1),
        },
    )
    .unwrap()
}

fn token_response(token: &str, expires_in: u64) -> ResponseTemplate {
    ResponseTemplate::new(200).set_body_json(serde_json::json!({
        "access_token": token,
        "token_type": "bearer",
        "expires_in": expires_in,
    }))
}

fn json(body: &str) -> ResponseTemplate {
    ResponseTemplate::new(200).set_body_raw(body.to_owned(), "application/json")
}

fn snapshot(body: &str) -> ResponseTemplate {
    json(body).insert_header("Last-Modified", LAST_MODIFIED)
}

async fn mount_token(server: &MockServer) {
    Mock::given(method("POST"))
        .and(path("/token"))
        .respond_with(token_response("tok", 86_399))
        .mount(server)
        .await;
}

#[tokio::test]
async fn requests_a_token_with_the_client_credentials_then_reuses_it() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/token"))
        .and(basic_auth("my-id", "my-secret"))
        .and(body_string("grant_type=client_credentials"))
        .respond_with(token_response("tok", 86_399))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path(INDEX_PATH))
        .and(bearer_token("tok"))
        .and(query_param("namespace", "dynamic-eu"))
        .and(query_param("locale", "fr_FR"))
        .respond_with(json(INDEX))
        .expect(2)
        .mount(&server)
        .await;
    let client = client(&server);

    let ids = client.connected_realm_ids().await.unwrap();
    client.connected_realm_ids().await.unwrap();

    assert_eq!(ids, [1390, 1302]);
}

#[tokio::test]
async fn requests_a_new_token_once_the_previous_one_expired() {
    let server = MockServer::start().await;
    // Shorter than the safety margin, so it counts as expired right away.
    Mock::given(method("POST"))
        .and(path("/token"))
        .respond_with(token_response("tok", 1))
        .expect(2)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path(INDEX_PATH))
        .respond_with(json(INDEX))
        .mount(&server)
        .await;
    let client = client(&server);

    client.connected_realm_ids().await.unwrap();
    client.connected_realm_ids().await.unwrap();
}

#[tokio::test]
async fn replaces_a_token_the_api_rejects_and_retries() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/token"))
        .respond_with(token_response("revoked", 86_399))
        .up_to_n_times(1)
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/token"))
        .respond_with(token_response("fresh", 86_399))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path(INDEX_PATH))
        .and(bearer_token("revoked"))
        .respond_with(ResponseTemplate::new(401))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path(INDEX_PATH))
        .and(bearer_token("fresh"))
        .respond_with(json(INDEX))
        .expect(1)
        .mount(&server)
        .await;

    client(&server).connected_realm_ids().await.unwrap();
}

#[tokio::test]
async fn gives_up_when_a_fresh_token_is_rejected_too() {
    let server = MockServer::start().await;
    mount_token(&server).await;
    Mock::given(method("GET"))
        .and(path(INDEX_PATH))
        .respond_with(ResponseTemplate::new(401))
        .expect(2)
        .mount(&server)
        .await;

    let error = client(&server).connected_realm_ids().await.unwrap_err();

    assert!(
        matches!(error, ApiError::Status { status: 401, .. }),
        "{error:?}"
    );
}

#[tokio::test]
async fn reports_rejected_credentials_as_an_auth_error() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/token"))
        .respond_with(ResponseTemplate::new(401).set_body_string("invalid_client"))
        .mount(&server)
        .await;

    let error = client(&server).connected_realm_ids().await.unwrap_err();

    match &error {
        ApiError::Auth { status, body } => {
            assert_eq!(*status, 401);
            assert_eq!(body, "invalid_client");
        }
        other => panic!("expected an auth error, got {other:?}"),
    }
    assert!(!error.to_string().contains("my-secret"));
}

#[tokio::test]
async fn fetches_commodities_and_asks_for_compressed_responses() {
    let server = MockServer::start().await;
    mount_token(&server).await;
    Mock::given(method("GET"))
        .and(path(COMMODITIES_PATH))
        .and(query_param("namespace", "dynamic-eu"))
        .and(|request: &Request| {
            request
                .headers
                .get("accept-encoding")
                .and_then(|value| value.to_str().ok())
                .is_some_and(|value| value.contains("gzip"))
        })
        .respond_with(snapshot(COMMODITIES))
        .expect(1)
        .mount(&server)
        .await;

    let fetched = client(&server)
        .auctions(AuctionSource::Commodities, None)
        .await
        .unwrap();

    let Fetched::Snapshot(snapshot) = fetched else {
        panic!("expected a snapshot");
    };
    assert_eq!(snapshot.last_modified, LAST_MODIFIED);
    assert_eq!(snapshot.taken_at.timestamp(), 1_793_854_800);
    assert_eq!(snapshot.auctions[0].id, 1);
    assert_eq!(snapshot.auctions[0].time_left, TimeLeft::Short);
    assert_eq!(snapshot.auctions.len(), 4);
    assert_eq!(snapshot.auctions[0].item.id, 190396);
    assert_eq!(snapshot.auctions[0].unit_price, Some(1_250_000));
    assert_eq!(snapshot.auctions[0].quantity, 200);
}

#[tokio::test]
async fn fetches_realm_auctions_with_every_price_shape() {
    let server = MockServer::start().await;
    mount_token(&server).await;
    Mock::given(method("GET"))
        .and(path("/data/wow/connected-realm/1390/auctions"))
        .respond_with(snapshot(REALM_AUCTIONS))
        .mount(&server)
        .await;

    let fetched = client(&server)
        .auctions(AuctionSource::ConnectedRealm(1390), None)
        .await
        .unwrap();

    let Fetched::Snapshot(snapshot) = fetched else {
        panic!("expected a snapshot");
    };
    let auctions = &snapshot.auctions;
    assert_eq!(auctions.len(), 7);
    assert_eq!(auctions[0].buyout, Some(150_000_000));
    assert_eq!(auctions[0].item.bonus_lists, [6652, 1472]);
    assert_eq!((auctions[2].buyout, auctions[2].unit_price), (None, None));
    assert_eq!(auctions[3].unit_price, Some(2000));
    assert_eq!(auctions[4].item.pet_species_id, Some(39));
}

#[tokio::test]
async fn sends_if_modified_since_verbatim_and_understands_not_modified() {
    let server = MockServer::start().await;
    mount_token(&server).await;
    Mock::given(method("GET"))
        .and(path(COMMODITIES_PATH))
        .and(|request: &Request| {
            request
                .headers
                .get("if-modified-since")
                .and_then(|value| value.to_str().ok())
                == Some(LAST_MODIFIED)
        })
        .respond_with(ResponseTemplate::new(304))
        .expect(1)
        .mount(&server)
        .await;

    let fetched = client(&server)
        .auctions(AuctionSource::Commodities, Some(LAST_MODIFIED))
        .await
        .unwrap();

    assert!(matches!(fetched, Fetched::NotModified));
}

#[tokio::test]
async fn refuses_a_snapshot_without_last_modified() {
    let server = MockServer::start().await;
    mount_token(&server).await;
    Mock::given(method("GET"))
        .and(path(COMMODITIES_PATH))
        .respond_with(json(COMMODITIES))
        .mount(&server)
        .await;

    let error = client(&server)
        .auctions(AuctionSource::Commodities, None)
        .await
        .unwrap_err();

    assert!(
        matches!(error, ApiError::MissingLastModified { .. }),
        "{error:?}"
    );
}

#[tokio::test]
async fn retries_rate_limits_and_server_errors() {
    let server = MockServer::start().await;
    mount_token(&server).await;
    Mock::given(method("GET"))
        .and(path(COMMODITIES_PATH))
        .respond_with(ResponseTemplate::new(429).insert_header("Retry-After", "0"))
        .up_to_n_times(1)
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path(COMMODITIES_PATH))
        .respond_with(ResponseTemplate::new(503))
        .up_to_n_times(1)
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path(COMMODITIES_PATH))
        .respond_with(snapshot(COMMODITIES))
        .expect(1)
        .mount(&server)
        .await;

    let fetched = client(&server)
        .auctions(AuctionSource::Commodities, None)
        .await
        .unwrap();

    assert!(matches!(fetched, Fetched::Snapshot(_)));
}

#[tokio::test]
async fn gives_up_after_the_configured_number_of_attempts() {
    let server = MockServer::start().await;
    mount_token(&server).await;
    Mock::given(method("GET"))
        .and(path(COMMODITIES_PATH))
        .respond_with(ResponseTemplate::new(503).set_body_string("down"))
        .expect(3)
        .mount(&server)
        .await;

    let error = client(&server)
        .auctions(AuctionSource::Commodities, None)
        .await
        .unwrap_err();

    match error {
        ApiError::Status { status, body, .. } => {
            assert_eq!(status, 503);
            assert_eq!(body, "down");
        }
        other => panic!("expected a status error, got {other:?}"),
    }
}

#[tokio::test]
async fn does_not_retry_client_errors() {
    let server = MockServer::start().await;
    mount_token(&server).await;
    Mock::given(method("GET"))
        .and(path(COMMODITIES_PATH))
        .respond_with(ResponseTemplate::new(403))
        .expect(1)
        .mount(&server)
        .await;

    let error = client(&server)
        .auctions(AuctionSource::Commodities, None)
        .await
        .unwrap_err();

    assert!(
        matches!(error, ApiError::Status { status: 403, .. }),
        "{error:?}"
    );
}

#[tokio::test]
async fn reports_invalid_json_as_a_decode_error() {
    let server = MockServer::start().await;
    mount_token(&server).await;
    Mock::given(method("GET"))
        .and(path(COMMODITIES_PATH))
        .respond_with(snapshot("{ not json"))
        .mount(&server)
        .await;

    let error = client(&server)
        .auctions(AuctionSource::Commodities, None)
        .await
        .unwrap_err();

    assert!(matches!(error, ApiError::Decode { .. }), "{error:?}");
}

#[tokio::test]
async fn reads_a_connected_realm() {
    let server = MockServer::start().await;
    mount_token(&server).await;
    let realms: Vec<Value> = serde_json::from_str(CONNECTED_REALMS).unwrap();
    Mock::given(method("GET"))
        .and(path("/data/wow/connected-realm/1302"))
        .respond_with(ResponseTemplate::new(200).set_body_json(&realms[1]))
        .mount(&server)
        .await;

    let realm = client(&server).connected_realm(1302).await.unwrap();

    assert_eq!(realm.id, 1302);
    let slugs: Vec<&str> = realm
        .realms
        .iter()
        .map(|realm| realm.slug.as_str())
        .collect();
    assert_eq!(slugs, ["archimonde", "naxxramas"]);
}

#[tokio::test]
async fn reads_an_item_from_the_static_namespace() {
    let server = MockServer::start().await;
    mount_token(&server).await;
    let items: Vec<Value> = serde_json::from_str(ITEMS).unwrap();
    Mock::given(method("GET"))
        .and(path("/data/wow/item/190396"))
        .and(query_param("namespace", "static-eu"))
        .and(query_param("locale", "fr_FR"))
        .respond_with(ResponseTemplate::new(200).set_body_json(&items[0]))
        .expect(1)
        .mount(&server)
        .await;

    let item = client(&server).item(190396).await.unwrap().unwrap();

    assert_eq!(item.name, "Minerai de test");
    assert_eq!(item.quality.unwrap().kind, "RARE");
    assert_eq!(item.level, Some(70));
    assert_eq!(item.item_class.unwrap().name, "Artisanat");
}

#[tokio::test]
async fn an_unknown_item_is_none_rather_than_an_error() {
    let server = MockServer::start().await;
    mount_token(&server).await;
    Mock::given(method("GET"))
        .and(path("/data/wow/item/999999"))
        .respond_with(ResponseTemplate::new(404))
        .expect(1)
        .mount(&server)
        .await;

    assert!(client(&server).item(999999).await.unwrap().is_none());
}
