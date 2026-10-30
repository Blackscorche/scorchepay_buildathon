use std::env;

use anyhow::{Context, Result, bail};

/// Which company fulfils a group of bills.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProviderKind {
    /// Built-in stand-in: succeeds after a short delay, spends nothing.
    Fake,
    /// SMEPlug (airtime and data).
    SmePlug,
    /// Not offered: the catalog lists these billers as unavailable.
    Off,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KycProviderKind {
    /// Approves tier 1 a couple of seconds after it's requested.
    Fake,
    MonoProve,
}

/// Everything read from the environment (see .env.example).
#[derive(Clone, Debug)]
pub struct Config {
    pub port: u16,
    /// Where this server is reachable from outside, for bill link URLs.
    pub public_url: String,
    pub database_url: String,
    pub jwt_secret: String,
    pub admin_token: String,

    /// Accepted for every sign-up OTP when set, and codes are logged
    /// instead of sent. For development only.
    pub otp_dev_code: Option<String>,
    /// Development only: enables POST /v1/dev/orders/{id}/simulate-payment.
    pub dev_simulate_payments: bool,
    pub live_provider_test_user: Option<uuid::Uuid>,

    pub ldk_storage_dir: String,
    pub ldk_listen_port: u16,
    /// `signet` (Mutinynet) or `regtest` (local testing).
    pub network: ldk_node::bitcoin::Network,
    pub esplora_url: String,
    /// `user:password@host:port`. When set, chain data comes from this
    /// Bitcoin Core node over RPC instead of Esplora.
    pub bitcoind_rpc: Option<String>,
    pub rgs_url: Option<String>,

    /// Fallback NGN per BTC when the price feed can't be reached.
    pub fallback_ngn_per_btc: Option<f64>,
    /// Optional CoinGecko demo API key, for higher rate limits.
    pub coingecko_api_key: Option<String>,
    /// Optional AI fallback for the bill helper (any OpenAI-compatible API).
    pub llm: Option<crate::llm::LlmConfig>,
    /// Optional natural voice for the voice assistant (OpenAI-compatible).
    pub tts: Option<crate::tts::TtsConfig>,
    /// The Whisper model that listens when a phone can't (see `stt.rs`).
    pub stt_model: String,
    /// Added to the market rate, in basis points (150 = 1.5%).
    pub spread_bps: u32,
    pub quote_secs: u32,

    pub airtime_data_provider: ProviderKind,
    pub bills_provider: ProviderKind,
    pub smeplug_key: Option<String>,
    /// Added to SMEPlug's data plan prices, in percent.
    pub data_markup_percent: u32,

    pub kyc_provider: KycProviderKind,
    pub mono_secret_key: Option<String>,
    pub mono_webhook_secret: Option<String>,
    pub mono_redirect_url: Option<String>,
}

impl Config {
    pub fn from_env() -> Result<Self> {
        let airtime_data_provider = match var_or("VTU_PROVIDER", "fake").as_str() {
            "fake" => ProviderKind::Fake,
            "smeplug" => ProviderKind::SmePlug,
            other => bail!("VTU_PROVIDER must be fake or smeplug, not {other}"),
        };
        let bills_provider = match var_or("BILLS_PROVIDER", "fake").as_str() {
            "fake" => ProviderKind::Fake,
            "off" => ProviderKind::Off,
            // N3TData plugs in here once its API is wired up.
            other => bail!("BILLS_PROVIDER must be fake or off, not {other}"),
        };
        let kyc_provider = match var_or("KYC_PROVIDER", "fake").as_str() {
            "fake" => KycProviderKind::Fake,
            "mono" => KycProviderKind::MonoProve,
            other => bail!("KYC_PROVIDER must be fake or mono, not {other}"),
        };

        let port = parse_or("PORT", 8080)?;
        let config = Self {
            port,
            public_url: var_or("PUBLIC_URL", &format!("http://localhost:{port}")),
            database_url: required("DATABASE_URL")?,
            jwt_secret: required("JWT_SECRET")?,
            admin_token: required("ADMIN_TOKEN")?,
            otp_dev_code: optional("OTP_DEV_CODE"),
            dev_simulate_payments: var_or("DEV_SIMULATE_PAYMENTS", "false") == "true",
            live_provider_test_user: optional("LIVE_PROVIDER_TEST_USER_ID").map(|v| v.parse()).transpose().context("LIVE_PROVIDER_TEST_USER_ID must be a user UUID")?,
            ldk_storage_dir: var_or("LDK_STORAGE_DIR", "./data/ldk"),
            ldk_listen_port: parse_or("LDK_LISTEN_PORT", 9735)?,
            network: match var_or("BITCOIN_NETWORK", "signet").as_str() {
                "signet" => ldk_node::bitcoin::Network::Signet,
                "regtest" => ldk_node::bitcoin::Network::Regtest,
                other => bail!("BITCOIN_NETWORK must be signet or regtest, not {other}"),
            },
            esplora_url: var_or("ESPLORA_URL", "https://mutinynet.com/api"),
            bitcoind_rpc: optional("BITCOIND_RPC"),
            rgs_url: optional("RGS_URL"),
            fallback_ngn_per_btc: optional("FALLBACK_NGN_PER_BTC")
                .map(|v| v.parse())
                .transpose()
                .context("FALLBACK_NGN_PER_BTC")?,
            coingecko_api_key: optional("COINGECKO_API_KEY"),
            stt_model: var_or("STT_MODEL", "whisper-large-v3"),
            tts: optional("TTS_BASE_URL").map(|base_url| crate::tts::TtsConfig {
                base_url,
                api_key: optional("TTS_API_KEY"),
                model: var_or("TTS_MODEL", "tts-1"),
                voice: var_or("TTS_VOICE", "en-NG-EzinneNeural"),
                // Hausa has a free voice by default; Yoruba and Igbo have none, so
                // they use the default voice until TTS_VOICE_YO / TTS_VOICE_IG say otherwise.
                voices: [("ha", "gtts:ha"), ("yo", ""), ("ig", ""), ("pcm", "")]
                    .into_iter()
                    .filter_map(|(lang, default)| {
                        let value = optional(&format!("TTS_VOICE_{}", lang.to_uppercase())).unwrap_or_else(|| default.to_string());
                        (!value.is_empty()).then(|| (lang.to_string(), value))
                    })
                    .collect(),
            }),
            llm: optional("LLM_BASE_URL").map(|base_url| crate::llm::LlmConfig {
                base_url,
                api_key: optional("LLM_API_KEY"),
                model: var_or("LLM_MODEL", "llama-3.1-8b-instant"),
            }),
            spread_bps: parse_or("SPREAD_BPS", 150)?,
            quote_secs: parse_or("QUOTE_SECS", 120)?,
            airtime_data_provider,
            bills_provider,
            smeplug_key: optional("SMEPLUG_API_KEY"),
            data_markup_percent: parse_or("DATA_MARKUP_PERCENT", 5)?,
            kyc_provider,
            mono_secret_key: optional("MONO_SECRET_KEY"),
            mono_webhook_secret: optional("MONO_WEBHOOK_SECRET"),
            mono_redirect_url: optional("MONO_REDIRECT_URL"),
        };

        if config.jwt_secret.len() < 32 {
            bail!("JWT_SECRET must be at least 32 characters");
        }
        if config.airtime_data_provider == ProviderKind::SmePlug && config.smeplug_key.is_none() {
            bail!("VTU_PROVIDER=smeplug needs SMEPLUG_API_KEY");
        }
        if config.airtime_data_provider == ProviderKind::SmePlug && config.dev_simulate_payments && config.live_provider_test_user.is_none() {
            bail!("Live SMEPlug simulation requires LIVE_PROVIDER_TEST_USER_ID; otherwise set DEV_SIMULATE_PAYMENTS=false");
        }
        if config.kyc_provider == KycProviderKind::MonoProve
            && (config.mono_secret_key.is_none() || config.mono_webhook_secret.is_none())
        {
            bail!("KYC_PROVIDER=mono needs MONO_SECRET_KEY and MONO_WEBHOOK_SECRET");
        }
        Ok(config)
    }
}

fn optional(name: &str) -> Option<String> {
    env::var(name).ok().filter(|v| !v.trim().is_empty())
}

fn required(name: &str) -> Result<String> {
    optional(name).with_context(|| format!("{name} is not set"))
}

fn var_or(name: &str, default: &str) -> String {
    optional(name).unwrap_or_else(|| default.to_string())
}

fn parse_or<T: std::str::FromStr>(name: &str, default: T) -> Result<T>
where
    T::Err: std::fmt::Display,
{
    match optional(name) {
        Some(v) => v.parse().map_err(|e| anyhow::anyhow!("{name}: {e}")),
        None => Ok(default),
    }
}
