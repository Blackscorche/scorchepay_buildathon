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
/// The same sanity check for the dollar and pound prices (about 1e5 now).
const PLAUSIBLE_FOREIGN: std::ops::RangeInclusive<f64> = 1.0e3..=1.0e7;
const FALLBACK_LABEL: &str = "FALLBACK_NGN_PER_BTC";

/// What one bitcoin costs: in naira (what quotes use) and, when the source
/// says, in dollars and pounds (shown to people paying from abroad).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Market {
    pub ngn: f64,
    pub usd: Option<f64>,
    pub gbp: Option<f64>,
}

impl Market {
    fn only_ngn(ngn: f64) -> Self {
        Self { ngn, usd: None, gbp: None }
    }
}

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
            Source::CoinGecko => "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=ngn,usd,gbp",
            Source::CoinPaprika => "https://api.coinpaprika.com/v1/tickers/btc-bitcoin?quotes=NGN,USD,GBP",
            Source::BlockchainCom => "https://blockchain.info/ticker",
        }
    }

    fn parse(self, json: &Value) -> Result<Market> {
        let price = |currency: &str| -> Option<f64> {
            match self {
                Source::CoinGecko => json["bitcoin"][currency.to_lowercase()].as_f64(),
                Source::CoinPaprika => json["quotes"][currency]["price"].as_f64(),
                Source::BlockchainCom => json[currency]["last"].as_f64(),
            }
        };
        let foreign = |p: Option<f64>| p.filter(|v| PLAUSIBLE_FOREIGN.contains(v));
        Ok(Market { ngn: price("NGN").context("the response has no NGN price")?, usd: foreign(price("USD")), gbp: foreign(price("GBP")) })
    }
}

#[derive(Default)]
struct State {
    /// The last good price, when it was fetched, and where from.
    price: Option<(Market, Instant, &'static str)>,
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
        Ok(self.market().await?.0.ngn / (1.0 + self.spread_bps as f64 / 10_000.0))
    }

    /// What `sats` are worth in dollars and pounds, to the cent, for people
    /// paying from abroad. None when no source gave those prices.
    pub async fn sats_in_fiat(&self, sats: i64) -> Option<(f64, f64)> {
        let (market, _) = self.market().await.ok()?;
        let worth = |per_btc: f64| (sats as f64 / 1e8 * per_btc * 100.0).round() / 100.0;
        Some((worth(market.usd?), worth(market.gbp?)))
    }

    /// Asks for a price now and logs what came back, so a broken feed shows
    /// at startup instead of on the first order.
    pub async fn warm_up(&self) {
        match self.market().await {
            Ok((market, FALLBACK_LABEL)) => tracing::warn!(
                "no live BTC/NGN price: quoting at {FALLBACK_LABEL} (₦{:.0}), which is not the market",
                market.ngn
            ),
            Ok((market, source)) => tracing::info!("BTC/NGN: ₦{:.0} per BTC (from {source})", market.ngn),
            Err(err) => tracing::error!("no BTC/NGN price, so orders can't be quoted until a source answers: {err:#}"),
        }
    }

    /// The market price and where it came from.
    async fn market(&self) -> Result<(Market, &'static str)> {
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
            (_, Some(fallback)) => Ok((Market::only_ngn(fallback), FALLBACK_LABEL)),
            _ => bail!("no BTC/NGN price: every source failed"),
        }
    }

    /// The first source that gives a plausible price. When none does, the
    /// error says why each one failed.
    async fn fetch_any(&self) -> Result<(Market, &'static str)> {
        let mut failures = Vec::new();
        for &source in &self.sources {
            match self.fetch(source).await {
                Ok(price) => return Ok((price, source.name())),
                Err(err) => failures.push(format!("{}: {err:#}", source.name())),
            }
        }
        Err(anyhow!(if failures.is_empty() { "no price sources".to_string() } else { failures.join("; ") }))
    }

    async fn fetch(&self, source: Source) -> Result<Market> {
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
        let market = source.parse(&json)?;
        ensure!(PLAUSIBLE.contains(&market.ngn), "{} NGN per BTC isn't plausible", market.ngn);
        Ok(market)
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
        let gecko = json!({"bitcoin": {"ngn": 109975695, "usd": 81500.0, "gbp": 62000.5}});
        assert_eq!(Source::CoinGecko.parse(&gecko).unwrap(), Market { ngn: 109975695.0, usd: Some(81500.0), gbp: Some(62000.5) });
        let paprika = json!({"id": "btc-bitcoin", "quotes": {"NGN": {"price": 109936790.32282795, "volume_24h": 3.0e13}, "USD": {"price": 81480.1}}});
        let m = Source::CoinPaprika.parse(&paprika).unwrap();
        assert!((m.ngn - 109936790.32).abs() < 0.01);
        assert_eq!((m.usd, m.gbp), (Some(81480.1), None), "a missing currency is None, not an error");
        let blockchain = json!({"ARS": {"last": 1.25E8}, "NGN": {"15m": 1.0993E8, "last": 1.0993E8, "symbol": "NGN"}, "USD": {"last": 81000}, "GBP": {"last": 61000}});
        assert_eq!(Source::BlockchainCom.parse(&blockchain).unwrap(), Market { ngn: 1.0993E8, usd: Some(81000.0), gbp: Some(61000.0) });
    }

    #[test]
    fn a_response_without_the_price_is_an_error() {
        let err = Source::CoinGecko.parse(&json!({"status": {"error_code": 403}})).unwrap_err();
        assert!(err.to_string().contains("no NGN price"));
        assert!(Source::BlockchainCom.parse(&json!({"USD": {"last": 1}})).is_err());
    }

    #[test]
    fn implausible_foreign_prices_are_dropped() {
        let m = Source::CoinGecko.parse(&json!({"bitcoin": {"ngn": 1.1e8, "usd": 12.0, "gbp": 62000.0}})).unwrap();
        assert_eq!((m.usd, m.gbp), (None, Some(62000.0)), "a price of 12 dollars per BTC is a unit mix-up");
    }

    #[tokio::test]
    async fn sats_are_valued_to_the_cent() {
        let rates = rates(None);
        rates.state.lock().await.price =
            Some((Market { ngn: 1.1e8, usd: Some(100_000.0), gbp: Some(80_000.0) }, Instant::now(), "CoinGecko"));
        // 462 sats at $100,000 per BTC is $0.462, which rounds to $0.46.
        assert_eq!(rates.sats_in_fiat(462).await, Some((0.46, 0.37)));
        assert_eq!(rates.sats_in_fiat(100_000_000).await, Some((100_000.0, 80_000.0)));
    }

    #[tokio::test]
    async fn no_fiat_value_without_foreign_prices() {
        let rates = rates(Some(1.1e8));
        assert_eq!(rates.sats_in_fiat(1000).await, None, "the dev fallback has no dollar price");
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
        let (market, source) = rates.market().await.unwrap();
        assert_eq!((market.ngn, source), (100_000_000.0, FALLBACK_LABEL));
        // The spread is added on top: users pay a little more per BTC.
        let quote = rates.quote_rate().await.unwrap();
        assert!((quote - 100_000_000.0 / 1.015).abs() < 1.0);
    }

    #[tokio::test]
    async fn a_recent_price_covers_a_dead_feed_but_an_old_one_does_not() {
        let rates = rates(None);
        rates.state.lock().await.price = Some((Market::only_ngn(110_000_000.0), Instant::now() - Duration::from_secs(120), "CoinGecko"));
        assert_eq!(rates.market().await.unwrap().1, "an earlier price");

        let old = self::rates(None);
        old.state.lock().await.price = Some((Market::only_ngn(110_000_000.0), Instant::now() - Duration::from_secs(20 * 60), "CoinGecko"));
        assert!(old.market().await.is_err(), "a 20-minute-old price must not be used");
    }

    #[tokio::test]
    async fn a_fresh_cached_price_is_returned_as_is() {
        let rates = rates(None);
        rates.state.lock().await.price = Some((Market::only_ngn(111_000_000.0), Instant::now(), "CoinPaprika"));
        assert_eq!(rates.market().await.unwrap(), (Market::only_ngn(111_000_000.0), "CoinPaprika"));
    }
}
