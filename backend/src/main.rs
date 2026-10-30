//! ScorchePay backend: accounts and KYC, the VTU API, and a Lightning
//! node (ldk-node) that receives payments for bills. See README.md.

mod admin;
mod auth;
mod bill_links;
mod catalog;
mod config;
mod error;
mod helper;
mod assistant;
mod llm;
mod stt;
mod tts;
mod json;
mod kyc;
mod lightning;
mod orders;
mod pages;
mod photos;
mod policy;
mod providers;
mod rates;

use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use axum::Router;
use axum::routing::get;
use sqlx::PgPool;
use sqlx::postgres::PgPoolOptions;
use tokio::sync::Notify;
use tower_http::cors::CorsLayer;
use tower_http::trace::TraceLayer;
use tracing_subscriber::EnvFilter;

use crate::catalog::{Catalog, CatalogSource};
use crate::config::Config;
use crate::lightning::Lightning;
use crate::providers::Providers;
use crate::providers::smeplug::SmePlug;
use crate::rates::Rates;

/// Shared by every request and background task.
pub struct App {
    pub config: Config,
    pub db: PgPool,
    pub http: reqwest::Client,
    pub lightning: Lightning,
    pub rates: Rates,
    pub providers: Providers,
    catalog: CatalogSource,
    /// Wakes the fulfilment loop when an order is paid.
    pub wake_fulfilment: Notify,
}

impl App {
    pub async fn catalog(&self) -> Arc<Catalog> {
        self.catalog.get(self.providers.smeplug.as_ref()).await
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let _ = dotenvy::dotenv();
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info,ldk_node=warn".into()))
        .init();

    let config = Config::from_env()?;
    let db = PgPoolOptions::new()
        .max_connections(10)
        .connect(&config.database_url)
        .await
        .context("connecting to Postgres")?;
    sqlx::migrate!().run(&db).await.context("running migrations")?;

    // Some APIs refuse requests with no User-Agent (CoinGecko answers 403).
    let http = reqwest::Client::builder()
        .timeout(Duration::from_secs(30))
        .user_agent(concat!("scorchepay-backend/", env!("CARGO_PKG_VERSION")))
        .build()?;
    let lightning = Lightning::start(&config)?;
    let smeplug = config.smeplug_key.clone().map(|key| SmePlug::new(http.clone(), key));
    let app = Arc::new(App {
        rates: Rates::new(http.clone(), config.spread_bps, config.fallback_ngn_per_btc, config.coingecko_api_key.clone()),
        catalog: CatalogSource::new(&config),
        providers: Providers { smeplug },
        wake_fulfilment: Notify::new(),
        config,
        db,
        http,
        lightning,
    });

    // Check the price feed now, so a broken one shows in the log at startup.
    tokio::spawn({
        let app = app.clone();
        async move { app.rates.warm_up().await }
    });
    tokio::spawn(orders::run_events(app.clone()));
    tokio::spawn(orders::run_fulfilment(app.clone()));

    let api = Router::new().merge(auth::routes()).merge(kyc::routes()).merge(orders::routes()).merge(policy::routes()).merge(helper::routes()).merge(tts::routes()).merge(assistant::routes()).merge(stt::routes());
    let router = Router::new()
        .route("/health", get(|| async { "ok" }))
        // API docs: Swagger UI and the OpenAPI spec it reads.
        .route("/docs", get(|| async { axum::response::Html(include_str!("../static/swagger.html")) }))
        .route(
            "/openapi.yaml",
            get(|| async { ([(axum::http::header::CONTENT_TYPE, "application/yaml")], include_str!("../static/openapi.yaml")) }),
        )
        .nest("/v1", api)
        .merge(bill_links::routes())
        .merge(pages::routes())
        .merge(photos::routes())
        .merge(admin::routes())
        .layer(axum::middleware::from_fn(json::json_errors))
        .layer(tower_http::compression::CompressionLayer::new())
        .layer(CorsLayer::permissive())
        .layer(TraceLayer::new_for_http())
        .with_state(app.clone());

    let addr = format!("0.0.0.0:{}", app.config.port);
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    tracing::info!("listening on http://{addr}");
    axum::serve(listener, router).with_graceful_shutdown(shutdown()).await?;

    tracing::info!("stopping the Lightning node");
    let node = app.lightning.node.clone();
    tokio::task::spawn_blocking(move || node.stop()).await??;
    Ok(())
}

async fn shutdown() {
    let _ = tokio::signal::ctrl_c().await;
}
