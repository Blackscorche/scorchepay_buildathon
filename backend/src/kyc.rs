//! Identity verification. Tiers only go up here: through Mono Prove's
//! webhook (or the fake provider in development), or an admin.
//!
//! Flow: the app calls `POST /kyc/verify`, opens the returned `url`
//! (Mono's hosted page), and polls `GET /me` until the status changes.

use std::sync::Arc;

use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::routing::post;
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::App;
use crate::auth::{AuthUser, random_hex};
use crate::config::KycProviderKind;
use crate::json::ApiJson;
use crate::error::{ApiError, ApiResult};

const MONO_INITIATE_URL: &str = "https://api.withmono.com/v1/prove/initiate";

/// The tier a successful verification grants.
const VERIFIED_TIER: i32 = 1;

pub fn routes() -> Router<Arc<App>> {
    Router::new().route("/kyc/verify", post(start_verification)).route("/webhooks/mono", post(mono_webhook))
}

/// Starts verification. Returns `{status, url}`: `url` is Mono's hosted
/// page to open (null for the fake provider, which approves by itself).
async fn start_verification(State(app): State<Arc<App>>, AuthUser(user_id): AuthUser) -> ApiResult<Json<Value>> {
    let (tier, display_name, contact): (i32, String, String) =
        sqlx::query_as("SELECT kyc_tier, display_name, contact FROM users WHERE id = $1")
            .bind(user_id)
            .fetch_one(&app.db)
            .await?;
    if tier >= VERIFIED_TIER {
        return Ok(Json(json!({ "status": "verified", "url": null })));
    }

    let reference = format!("kyc_{}", random_hex(12));
    let (provider, url) = match app.config.kyc_provider {
        KycProviderKind::Fake => {
            let app = app.clone();
            let reference = reference.clone();
            tokio::spawn(async move {
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                if let Err(err) = apply_result(&app, &reference, "successful").await {
                    tracing::error!("fake KYC: {err:?}");
                }
            });
            ("fake", None)
        }
        KycProviderKind::MonoProve => ("mono", Some(initiate_mono(&app, &reference, &display_name, &contact).await?)),
    };

    sqlx::query("INSERT INTO kyc_sessions (reference, user_id, provider) VALUES ($1, $2, $3)")
        .bind(&reference)
        .bind(user_id)
        .bind(provider)
        .execute(&app.db)
        .await?;
    sqlx::query("UPDATE users SET kyc_status = 'pending' WHERE id = $1 AND kyc_tier < $2")
        .bind(user_id)
        .bind(VERIFIED_TIER)
        .execute(&app.db)
        .await?;
    Ok(Json(json!({ "status": "pending", "url": url })))
}

/// Creates a Mono Prove session and returns its hosted URL.
async fn initiate_mono(app: &App, reference: &str, name: &str, contact: &str) -> ApiResult<String> {
    let key = app.config.mono_secret_key.as_deref().unwrap_or_default();
    let mut customer = json!({ "name": name });
    if contact.contains('@') {
        customer["email"] = json!(contact);
    } else {
        customer["phone"] = json!(contact);
    }
    let mut body = json!({ "reference": reference, "kyc_level": "tier_1", "customer": customer });
    if let Some(redirect) = &app.config.mono_redirect_url {
        body["redirect_url"] = json!(redirect);
    }
    let response = app
        .http
        .post(MONO_INITIATE_URL)
        .header("mono-sec-key", key)
        .header("accept", "application/json")
        .json(&body)
        .send()
        .await
        .map_err(|e| ApiError::unavailable("network", format!("Couldn't reach verification: {e}")))?;
    let status = response.status();
    let json: Value = response.json().await.unwrap_or_default();
    if !status.is_success() {
        tracing::warn!(%status, %json, "Mono Prove initiate failed");
        return Err(ApiError::unavailable("network", "Verification is unavailable right now. Try again later."));
    }
    // The hosted page's field name isn't fixed in Mono's docs; accept the
    // likely ones.
    let data = &json["data"];
    ["mono_url", "url", "link"]
        .iter()
        .find_map(|k| data[k].as_str())
        .map(str::to_string)
        .ok_or_else(|| ApiError::internal(format!("Mono Prove response had no URL: {json}")))
}

#[derive(Deserialize)]
struct MonoEvent {
    event: String,
    data: MonoEventData,
}

#[derive(Deserialize)]
struct MonoEventData {
    reference: Option<String>,
}

/// Mono's webhook. Authenticated by the `mono-webhook-secret` header,
/// which must equal the secret set in Mono's dashboard.
async fn mono_webhook(State(app): State<Arc<App>>, headers: HeaderMap, ApiJson(body): ApiJson<Value>) -> ApiResult<StatusCode> {
    let expected = app.config.mono_webhook_secret.as_deref();
    let given = headers.get("mono-webhook-secret").and_then(|v| v.to_str().ok());
    if expected.is_none() || !constant_time_eq(given.unwrap_or_default(), expected.unwrap_or_default()) {
        return Err(ApiError::unauthorized("Bad webhook secret."));
    }
    let Ok(event) = serde_json::from_value::<MonoEvent>(body) else {
        return Ok(StatusCode::OK); // Not one of ours; acknowledge so Mono stops retrying.
    };
    let Some(reference) = event.data.reference else {
        return Ok(StatusCode::OK);
    };
    let result = match event.event.as_str() {
        "mono.prove.data_verification_successful" => "successful",
        "mono.prove.data_verification_rejected" | "mono.prove.data_verification_failed" => "rejected",
        "mono.prove.data_verification_cancelled" | "mono.prove.data_verification_expired" => "cancelled",
        // initiated, awaiting_review: still pending.
        _ => return Ok(StatusCode::OK),
    };
    apply_result(&app, &reference, result).await?;
    Ok(StatusCode::OK)
}

/// Records a session's outcome and updates its user's tier and status.
/// Never lowers a tier.
async fn apply_result(app: &App, reference: &str, result: &str) -> ApiResult<()> {
    let mut tx = app.db.begin().await?;
    let session: Option<(Uuid,)> =
        sqlx::query_as("UPDATE kyc_sessions SET status = $2, updated_at = now() WHERE reference = $1 RETURNING user_id")
            .bind(reference)
            .bind(result)
            .fetch_optional(&mut *tx)
            .await?;
    let Some((user_id,)) = session else {
        tracing::warn!(reference, "KYC result for an unknown session");
        return Ok(());
    };
    match result {
        "successful" => {
            sqlx::query("UPDATE users SET kyc_tier = GREATEST(kyc_tier, $2), kyc_status = 'verified' WHERE id = $1")
                .bind(user_id)
                .bind(VERIFIED_TIER)
                .execute(&mut *tx)
                .await?;
        }
        "rejected" => {
            sqlx::query("UPDATE users SET kyc_status = 'rejected' WHERE id = $1 AND kyc_status <> 'verified'")
                .bind(user_id)
                .execute(&mut *tx)
                .await?;
        }
        _ => {
            sqlx::query("UPDATE users SET kyc_status = 'unverified' WHERE id = $1 AND kyc_status = 'pending'")
                .bind(user_id)
                .execute(&mut *tx)
                .await?;
        }
    }
    tx.commit().await?;
    tracing::info!(%user_id, reference, result, "KYC result");
    Ok(())
}

fn constant_time_eq(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}
