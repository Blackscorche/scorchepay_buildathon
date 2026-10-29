//! BTC/NGN for quotes, plus the configured spread.
//!
//! The price comes from CoinGecko, then CoinPaprika, then Blockchain.com:
//! the first that answers wins. It's cached for a minute. When every source
//! fails the last good price is used for up to 15 minutes, and after that
//! quotes fail rather than guess. A failing feed isn't retried more than
//! once every 15 seconds, so it isn't hammered and quotes fail fast.
//!
//! `FALLBACK_NGN_PER_BTC` is a development convenience for working offline.
//! It is not a market price, so leave it unset anywhere real money moves.

use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow, bail, ensure};
use serde_json::Value;
use tokio::sync::Mutex;

const CACHE_FOR: Duration = Duration::from_secs(60);
/// A cached price older than this isn't used for quotes, even if every
/// source is down.
const STALE_AFTER: Duration = Duration::from_secs(15 * 60);
/// After every source fails, wait this long before asking again.
const RETRY_AFTER: Duration = Duration::from_secs(15);
const SOURCE_TIMEOUT: Duration = Duration::from_secs(5);
/// NGN per BTC outside this range is a unit mix-up (say, a dollar price),
/// not the market. The market is around 1e8.
const PLAUSIBLE: std::ops::RangeInclusive<f64> = 1.0e6..=1.0e10;
const FALLBACK_LABEL: &str = "FALLBACK_NGN_PER_BTC";

#[derive(Clone, Copy, Debug)]
enum Source {
    CoinGecko,
    CoinPaprika,
    BlockchainCom,
}

const SOURCES: [Source; 3] = [Source::CoinGecko, Source::CoinPaprika, Source::BlockchainCom];

impl Source {
    fn name(self) -> &'static str {
        match self {
            Source::CoinGecko => "CoinGecko",
            Source::CoinPaprika => "CoinPaprika",
            Source::BlockchainCom => "Blockchain.com",
        }
    }

    fn url(self) -> &'static str {
        match self {
            Source::CoinGecko => "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=ngn",
            Source::CoinPaprika => "https://api.coinpaprika.com/v1/tickers/btc-bitcoin?quotes=NGN",
            Source::BlockchainCom => "https://blockchain.info/ticker",
        }
    }

    fn parse(self, json: &Value) -> Result<f64> {
        let price = match self {
            Source::CoinGecko => &json["bitcoin"]["ngn"],
            Source::CoinPaprika => &json["quotes"]["NGN"]["price"],
            Source::BlockchainCom => &json["NGN"]["last"],
        };
        price.as_f64().context("the response has no NGN price")
    }
}

#[derive(Default)]
struct State {
    /// The last good price, when it was fetched, and where from.
    price: Option<(f64, Instant, &'static str)>,
    /// When every source last failed.
    failed_at: Option<Instant>,
}

pub struct Rates {
    http: reqwest::Client,
    spread_bps: u32,
    fallback: Option<f64>,
    coingecko_key: Option<String>,
    sources: Vec<Source>,
    state: Mutex<State>,
}

impl Rates {
    pub fn new(http: reqwest::Client, spread_bps: u32, fallback: Option<f64>, coingecko_key: Option<String>) -> Self {
        Self { http, spread_bps, fallback, coingecko_key, sources: SOURCES.to_vec(), state: Mutex::new(State::default()) }
    }

    /// NGN per BTC the user pays at, spread included.
    pub async fn quote_rate(&self) -> Result<f64> {
        Ok(self.market().await?.0 / (1.0 + self.spread_bps as f64 / 10_000.0))
    }

    /// Asks for a price now and logs what came back, so a broken feed shows
    /// at startup instead of on the first order.
    pub async fn warm_up(&self) {
        match self.market().await {
            Ok((price, FALLBACK_LABEL)) => tracing::warn!(
                "no live BTC/NGN price: quoting at {FALLBACK_LABEL} (₦{price:.0}), which is not the market"
            ),
            Ok((price, source)) => tracing::info!("BTC/NGN: ₦{price:.0} per BTC (from {source})"),
            Err(err) => tracing::error!("no BTC/NGN price, so orders can't be quoted until a source answers: {err:#}"),
        }
    }

    /// The market price and where it came from.
    async fn market(&self) -> Result<(f64, &'static str)> {
        let mut state = self.state.lock().await;
        if let Some((price, at, source)) = state.price {
            if at.elapsed() < CACHE_FOR {
                return Ok((price, source));
            }
        }
        if state.failed_at.is_none_or(|at| at.elapsed() >= RETRY_AFTER) {
            match self.fetch_any().await {
                Ok((price, source)) => {
                    state.price = Some((price, Instant::now(), source));
                    state.failed_at = None;
                    return Ok((price, source));
                }
                Err(err) => {
                    tracing::warn!("no live BTC/NGN price: {err:#}");
                    state.failed_at = Some(Instant::now());
                }
            }
        }
        match (state.price, self.fallback) {
            (Some((price, at, _)), _) if at.elapsed() < STALE_AFTER => Ok((price, "an earlier price")),
            (_, Some(fallback)) => Ok((fallback, FALLBACK_LABEL)),
            _ => bail!("no BTC/NGN price: every source failed"),
        }
    }

    /// The first source that gives a plausible price. When none does, the
    /// error says why each one failed.
    async fn fetch_any(&self) -> Result<(f64, &'static str)> {
        let mut failures = Vec::new();
        for &source in &self.sources {
            match self.fetch(source).await {
                Ok(price) => return Ok((price, source.name())),
                Err(err) => failures.push(format!("{}: {err:#}", source.name())),
            }
        }
        Err(anyhow!(if failures.is_empty() { "no price sources".to_string() } else { failures.join("; ") }))
    }

    async fn fetch(&self, source: Source) -> Result<f64> {
        let mut request = self.http.get(source.url()).timeout(SOURCE_TIMEOUT);
        if let (Source::CoinGecko, Some(key)) = (source, &self.coingecko_key) {
            request = request.header("x-cg-demo-api-key", key);
        }
        let response = request.send().await.context("request failed")?;
        let status = response.status();
        let body = response.text().await.context("couldn't read the response")?;
        if !status.is_success() {
            bail!("HTTP {status}: {}", snippet(&body));
        }
        let json: Value = serde_json::from_str(&body).with_context(|| format!("not JSON: {}", snippet(&body)))?;
        let price = source.parse(&json)?;
        ensure!(PLAUSIBLE.contains(&price), "{price} NGN per BTC isn't plausible");
        Ok(price)
    }
}

/// The start of a response body on one line, for error messages.
fn snippet(body: &str) -> String {
    let one_line: String = body.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut out: String = one_line.chars().take(160).collect();
    if one_line.chars().count() > 160 {
        out.push('…');
    }
    out
}

/// Sats for `amount` naira at `rate` NGN/BTC, rounded up.
pub fn sats_for(amount: i64, rate: f64) -> i64 {
    // The small allowance stops float noise from rounding an exact
    // result up by a sat.
    (amount as f64 * 1e8 / rate - 1e-6).ceil() as i64
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn rates(fallback: Option<f64>) -> Rates {
        let mut rates = Rates::new(reqwest::Client::new(), 150, fallback, None);
        rates.sources.clear(); // no network in unit tests
        rates
    }

    #[test]
    fn converts_naira_to_sats() {
        // ₦1,000 at ₦100,000,000/BTC is 1,000 sats exactly.
        assert_eq!(sats_for(1_000, 100_000_000.0), 1_000);
        // Rounds up, so the user never underpays.
        assert_eq!(sats_for(1_000, 150_000_000.0), 667);
    }

    #[test]
    fn reads_each_sources_real_response_shape() {
        let gecko = json!({"bitcoin": {"ngn": 109975695}});
        assert_eq!(Source::CoinGecko.parse(&gecko).unwrap(), 109975695.0);
        let paprika = json!({"id": "btc-bitcoin", "quotes": {"NGN": {"price": 109936790.32282795, "volume_24h": 3.0e13}}});
        assert!((Source::CoinPaprika.parse(&paprika).unwrap() - 109936790.32).abs() < 0.01);
        let blockchain = json!({"ARS": {"last": 1.25E8}, "NGN": {"15m": 1.0993E8, "last": 1.0993E8, "symbol": "NGN"}});
        assert_eq!(Source::BlockchainCom.parse(&blockchain).unwrap(), 1.0993E8);
    }

    #[test]
    fn a_response_without_the_price_is_an_error() {
        let err = Source::CoinGecko.parse(&json!({"status": {"error_code": 403}})).unwrap_err();
        assert!(err.to_string().contains("no NGN price"));
        assert!(Source::BlockchainCom.parse(&json!({"USD": {"last": 1}})).is_err());
    }

    #[test]
    fn only_plausible_prices_pass() {
        assert!(PLAUSIBLE.contains(&110_000_000.0));
        assert!(!PLAUSIBLE.contains(&105_000.0), "a dollar price mistaken for naira");
        assert!(!PLAUSIBLE.contains(&0.0));
    }

    #[test]
    fn snippets_are_one_short_line() {
        assert_eq!(snippet("a\n  b\tc"), "a b c");
        let long = "x".repeat(500);
        assert_eq!(snippet(&long).chars().count(), 161);
    }

    #[tokio::test]
    async fn with_no_feed_and_no_history_quotes_fail() {
        assert!(rates(None).quote_rate().await.is_err());
    }

    #[tokio::test]
    async fn the_dev_fallback_is_used_only_when_nothing_else_answers() {
        let rates = rates(Some(100_000_000.0));
        let (price, source) = rates.market().await.unwrap();
        assert_eq!((price, source), (100_000_000.0, FALLBACK_LABEL));
        // The spread is added on top: users pay a little more per BTC.
        let quote = rates.quote_rate().await.unwrap();
        assert!((quote - 100_000_000.0 / 1.015).abs() < 1.0);
    }

    #[tokio::test]
    async fn a_recent_price_covers_a_dead_feed_but_an_old_one_does_not() {
        let rates = rates(None);
        rates.state.lock().await.price = Some((110_000_000.0, Instant::now() - Duration::from_secs(120), "CoinGecko"));
        assert_eq!(rates.market().await.unwrap().1, "an earlier price");

        let old = self::rates(None);
        old.state.lock().await.price = Some((110_000_000.0, Instant::now() - Duration::from_secs(20 * 60), "CoinGecko"));
        assert!(old.market().await.is_err(), "a 20-minute-old price must not be used");
    }

    #[tokio::test]
    async fn a_fresh_cached_price_is_returned_as_is() {
        let rates = rates(None);
        rates.state.lock().await.price = Some((111_000_000.0, Instant::now(), "CoinPaprika"));
        assert_eq!(rates.market().await.unwrap(), (111_000_000.0, "CoinPaprika"));
    }
}
