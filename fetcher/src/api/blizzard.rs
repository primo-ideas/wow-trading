//! HTTP client for the Battle.net Game Data API.

use std::fmt;
use std::time::Duration;

use chrono::{DateTime, Utc};
use reqwest::header::{HeaderValue, IF_MODIFIED_SINCE, LAST_MODIFIED, RETRY_AFTER};
use reqwest::{Response, StatusCode};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use tokio::sync::Mutex;
use tokio::time::Instant;

use super::{
    ApiError, AuctionApi, AuctionSource, AuctionsEnvelope, ConnectedRealm, Fetched, Item, Media,
    Pet, Snapshot, parse_http_date,
};
use crate::config::Region;

/// A token this close to expiry is replaced rather than used.
const TOKEN_EXPIRY_MARGIN: Duration = Duration::from_secs(60);
const MAX_RETRY_DELAY: Duration = Duration::from_secs(60);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// Generous because a commodity snapshot is a very large document.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(300);
const ERROR_BODY_MAX_CHARS: usize = 300;
/// Battle.net allows 100 requests per second for a client id, across all regions.
/// With four regions at this pace, and low latency, this stays below it instead of
/// relying on retries.
const MIN_REQUEST_INTERVAL: Duration = Duration::from_millis(50);

#[derive(Clone)]
pub struct Credentials {
    client_id: String,
    client_secret: String,
}

impl Credentials {
    pub fn new(client_id: impl Into<String>, client_secret: impl Into<String>) -> Self {
        Self {
            client_id: client_id.into(),
            client_secret: client_secret.into(),
        }
    }

    /// Reads `BLIZZARD_CLIENT_ID` and `BLIZZARD_CLIENT_SECRET`. `None` if either
    /// is unset or empty.
    pub fn from_env() -> Option<Self> {
        let read = |name| {
            std::env::var(name)
                .ok()
                .filter(|value: &String| !value.is_empty())
        };
        Some(Self::new(
            read("BLIZZARD_CLIENT_ID")?,
            read("BLIZZARD_CLIENT_SECRET")?,
        ))
    }
}

impl fmt::Debug for Credentials {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Credentials")
            .field("client_id", &self.client_id)
            .field("client_secret", &"<redacted>")
            .finish()
    }
}

#[derive(Debug, Clone)]
pub struct Endpoints {
    pub api_base: String,
    pub oauth_token: String,
}

impl Endpoints {
    pub fn for_region(region: Region) -> Self {
        Self {
            api_base: format!("https://{}.api.blizzard.com", region.as_str()),
            oauth_token: "https://oauth.battle.net/token".to_owned(),
        }
    }
}

/// Applies to rate limiting (429), server errors and connection failures.
#[derive(Debug, Clone, Copy)]
pub struct RetryPolicy {
    /// Total number of tries, including the first one.
    pub max_attempts: u32,
    /// Doubled after each failed attempt. A `Retry-After` header takes precedence.
    pub base_delay: Duration,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            max_attempts: 4,
            base_delay: Duration::from_millis(500),
        }
    }
}

#[derive(Clone, Copy)]
enum Namespace {
    Dynamic,
    Static,
}

struct CachedToken {
    value: String,
    expires_at: Instant,
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    expires_in: u64,
}

pub struct BlizzardClient {
    http: reqwest::Client,
    credentials: Credentials,
    endpoints: Endpoints,
    region: Region,
    locale: String,
    retry: RetryPolicy,
    /// Held across the token request so concurrent callers share a single refresh.
    token: Mutex<Option<CachedToken>>,
    /// When the next request may leave.
    next_request: Mutex<Instant>,
}

impl BlizzardClient {
    pub fn new(
        credentials: Credentials,
        endpoints: Endpoints,
        region: Region,
        locale: impl Into<String>,
        retry: RetryPolicy,
    ) -> Result<Self, ApiError> {
        let http = reqwest::Client::builder()
            .user_agent(concat!("wow-market-fetcher/", env!("CARGO_PKG_VERSION")))
            .connect_timeout(CONNECT_TIMEOUT)
            .timeout(REQUEST_TIMEOUT)
            .build()?;
        Ok(Self {
            http,
            credentials,
            endpoints,
            region,
            locale: locale.into(),
            retry,
            token: Mutex::new(None),
            next_request: Mutex::new(Instant::now()),
        })
    }

    /// Waits for this request's turn. Each one books the next free slot, so that
    /// concurrent requests end up evenly spaced.
    async fn pace(&self) {
        let slot = {
            let mut next = self.next_request.lock().await;
            let slot = (*next).max(Instant::now());
            *next = slot + MIN_REQUEST_INTERVAL;
            slot
        };
        tokio::time::sleep_until(slot).await;
    }

    async fn access_token(&self) -> Result<String, ApiError> {
        let mut cached = self.token.lock().await;
        if let Some(token) = cached.as_ref()
            && token.expires_at > Instant::now()
        {
            return Ok(token.value.clone());
        }

        let url = &self.endpoints.oauth_token;
        let response = self
            .http
            .post(url)
            .basic_auth(
                &self.credentials.client_id,
                Some(&self.credentials.client_secret),
            )
            .form(&[("grant_type", "client_credentials")])
            .send()
            .await?;

        let status = response.status();
        if matches!(
            status,
            StatusCode::BAD_REQUEST | StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN
        ) {
            return Err(ApiError::Auth {
                status: status.as_u16(),
                body: error_body(response).await,
            });
        }
        if !status.is_success() {
            return Err(status_error(url, response).await);
        }

        let token: TokenResponse = decode(url, response).await?;
        let lifetime = Duration::from_secs(token.expires_in).saturating_sub(TOKEN_EXPIRY_MARGIN);
        *cached = Some(CachedToken {
            value: token.access_token.clone(),
            expires_at: Instant::now() + lifetime,
        });
        Ok(token.access_token)
    }

    /// Drops the cached token, unless another request already replaced it.
    async fn forget_token(&self, rejected: &str) {
        let mut cached = self.token.lock().await;
        if cached.as_ref().is_some_and(|token| token.value == rejected) {
            *cached = None;
        }
    }

    /// Sends an authenticated GET, retrying transient failures. The returned
    /// response can still be an error other than 429 or 5xx: 304 and 404 mean
    /// something to the callers.
    async fn get(
        &self,
        url: &str,
        namespace: Namespace,
        if_modified_since: Option<&str>,
    ) -> Result<Response, ApiError> {
        let namespace = match namespace {
            Namespace::Dynamic => format!("dynamic-{}", self.region.as_str()),
            Namespace::Static => format!("static-{}", self.region.as_str()),
        };
        let mut attempt = 1;
        let mut token_refreshed = false;

        loop {
            let token = self.access_token().await?;
            self.pace().await;
            let mut request = self
                .http
                .get(url)
                .bearer_auth(&token)
                .query(&[("namespace", &namespace), ("locale", &self.locale)]);
            if let Some(date) = if_modified_since {
                request = request.header(IF_MODIFIED_SINCE, date);
            }

            let requested_delay = match request.send().await {
                Ok(response)
                    if response.status() == StatusCode::UNAUTHORIZED && !token_refreshed =>
                {
                    // Revoked or expired early. Does not use up an attempt.
                    self.forget_token(&token).await;
                    token_refreshed = true;
                    continue;
                }
                Ok(response) if is_transient(response.status()) => {
                    let delay = retry_after(&response);
                    if attempt >= self.retry.max_attempts {
                        return Err(status_error(url, response).await);
                    }
                    tracing::debug!(url, status = %response.status(), attempt, "retrying");
                    delay
                }
                Ok(response) => return Ok(response),
                Err(error) => {
                    if attempt >= self.retry.max_attempts || error.is_builder() {
                        return Err(error.into());
                    }
                    tracing::debug!(url, %error, attempt, "retrying");
                    None
                }
            };

            let delay = requested_delay.unwrap_or_else(|| {
                self.retry
                    .base_delay
                    .saturating_mul(2u32.saturating_pow(attempt - 1))
            });
            tokio::time::sleep(delay.min(MAX_RETRY_DELAY)).await;
            attempt += 1;
        }
    }

    async fn get_json<T>(&self, url: &str, namespace: Namespace) -> Result<T, ApiError>
    where
        T: DeserializeOwned + Send + 'static,
    {
        let response = self.get(url, namespace, None).await?;
        if !response.status().is_success() {
            return Err(status_error(url, response).await);
        }
        decode(url, response).await
    }

    /// `None` when the API answers 404.
    async fn get_static<T>(&self, url: &str) -> Result<Option<T>, ApiError>
    where
        T: DeserializeOwned + Send + 'static,
    {
        let response = self.get(url, Namespace::Static, None).await?;
        if response.status() == StatusCode::NOT_FOUND {
            return Ok(None);
        }
        if !response.status().is_success() {
            return Err(status_error(url, response).await);
        }
        decode(url, response).await.map(Some)
    }

    /// An icon is a nicety: failing to get one must not lose the name that came
    /// with it. The lookup is simply tried again later, as the icon stays empty.
    async fn icon_url(&self, kind: &str, id: i32) -> Option<String> {
        let url = format!("{}/data/wow/media/{kind}/{id}", self.endpoints.api_base);
        match self.get_static::<Media>(&url).await {
            Ok(media) => media.and_then(Media::into_icon_url),
            Err(error) => {
                tracing::warn!(kind, id, %error, "cannot look up icon, will retry");
                None
            }
        }
    }
}

impl AuctionApi for BlizzardClient {
    async fn connected_realm_ids(&self) -> Result<Vec<i32>, ApiError> {
        #[derive(Deserialize)]
        struct Index {
            connected_realms: Vec<Link>,
        }
        #[derive(Deserialize)]
        struct Link {
            href: String,
        }

        let url = format!("{}/data/wow/connected-realm/index", self.endpoints.api_base);
        let index: Index = self.get_json(&url, Namespace::Dynamic).await?;
        index
            .connected_realms
            .iter()
            .map(|link| {
                connected_realm_id_from_href(&link.href).ok_or_else(|| ApiError::UnexpectedHref {
                    href: link.href.clone(),
                })
            })
            .collect()
    }

    async fn connected_realm(&self, id: i32) -> Result<ConnectedRealm, ApiError> {
        let url = format!("{}/data/wow/connected-realm/{id}", self.endpoints.api_base);
        self.get_json(&url, Namespace::Dynamic).await
    }

    async fn auctions(
        &self,
        source: AuctionSource,
        if_modified_since: Option<&str>,
    ) -> Result<Fetched, ApiError> {
        let base = &self.endpoints.api_base;
        let url = match source {
            AuctionSource::Commodities => format!("{base}/data/wow/auctions/commodities"),
            AuctionSource::ConnectedRealm(id) => {
                format!("{base}/data/wow/connected-realm/{id}/auctions")
            }
        };

        let response = self
            .get(&url, Namespace::Dynamic, if_modified_since)
            .await?;
        if response.status() == StatusCode::NOT_MODIFIED {
            return Ok(Fetched::NotModified);
        }
        if !response.status().is_success() {
            return Err(status_error(&url, response).await);
        }

        let header = response.headers().get(LAST_MODIFIED);
        let (last_modified, taken_at) = header
            .and_then(parse_last_modified)
            .ok_or_else(|| ApiError::MissingLastModified { url: url.clone() })?;

        let envelope: AuctionsEnvelope = decode(&url, response).await?;
        Ok(Fetched::Snapshot(Snapshot {
            last_modified,
            taken_at,
            auctions: envelope.auctions,
        }))
    }

    async fn item(&self, id: i32) -> Result<Option<Item>, ApiError> {
        let url = format!("{}/data/wow/item/{id}", self.endpoints.api_base);
        let Some(mut item) = self.get_static::<Item>(&url).await? else {
            return Ok(None);
        };
        item.icon_url = self.icon_url("item", id).await;
        Ok(Some(item))
    }

    async fn pet(&self, species_id: i32) -> Result<Option<Pet>, ApiError> {
        let url = format!("{}/data/wow/pet/{species_id}", self.endpoints.api_base);
        let Some(mut pet) = self.get_static::<Pet>(&url).await? else {
            return Ok(None);
        };
        pet.icon_url = self.icon_url("pet", species_id).await;
        Ok(Some(pet))
    }
}

fn is_transient(status: StatusCode) -> bool {
    status == StatusCode::TOO_MANY_REQUESTS || status.is_server_error()
}

fn retry_after(response: &Response) -> Option<Duration> {
    let seconds = response.headers().get(RETRY_AFTER)?.to_str().ok()?;
    seconds.trim().parse().ok().map(Duration::from_secs)
}

fn parse_last_modified(value: &HeaderValue) -> Option<(String, DateTime<Utc>)> {
    let raw = value.to_str().ok()?;
    Some((raw.to_owned(), parse_http_date(raw)?))
}

/// `https://eu.api.blizzard.com/data/wow/connected-realm/1390?namespace=dynamic-eu` gives 1390.
fn connected_realm_id_from_href(href: &str) -> Option<i32> {
    let path = href.split('?').next()?;
    path.rsplit('/').next()?.parse().ok()
}

/// Decodes on a blocking thread: snapshots are large enough to stall the runtime.
async fn decode<T>(url: &str, response: Response) -> Result<T, ApiError>
where
    T: DeserializeOwned + Send + 'static,
{
    let body = response.bytes().await?;
    tokio::task::spawn_blocking(move || serde_json::from_slice(&body))
        .await
        .expect("JSON decoding does not panic")
        .map_err(|source| ApiError::Decode {
            url: url.to_owned(),
            source,
        })
}

async fn status_error(url: &str, response: Response) -> ApiError {
    let status = response.status().as_u16();
    ApiError::Status {
        url: url.to_owned(),
        status,
        body: error_body(response).await,
    }
}

async fn error_body(response: Response) -> String {
    let body = response.text().await.unwrap_or_default();
    body.chars().take(ERROR_BODY_MAX_CHARS).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_the_connected_realm_id_from_an_href() {
        assert_eq!(
            connected_realm_id_from_href(
                "https://eu.api.blizzard.com/data/wow/connected-realm/1390?namespace=dynamic-eu"
            ),
            Some(1390)
        );
        assert_eq!(
            connected_realm_id_from_href("https://example.com/nope"),
            None
        );
    }

    #[test]
    fn debug_output_does_not_leak_the_secret() {
        let output = format!("{:?}", Credentials::new("my-id", "my-secret"));

        assert!(output.contains("my-id"));
        assert!(!output.contains("my-secret"));
    }
}
