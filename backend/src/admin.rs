//! Operator endpoints, behind `Authorization: Bearer $ADMIN_TOKEN`:
//! the Lightning node (funding, channels), KYC overrides, and orders
//! whose provider outcome is unknown.

use std::str::FromStr;
use std::sync::Arc;

use axum::extract::{FromRequestParts, Path, State};
use axum::http::request::Parts;
use axum::routing::{get, post};
use axum::{Json, Router};
use ldk_node::bitcoin::secp256k1::PublicKey;
use ldk_node::lightning::ln::msgs::SocketAddress;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::App;
use crate::json::ApiJson;
use crate::error::{ApiError, ApiResult};
use crate::orders::{ORDER_COLUMNS, OrderRow};

pub fn routes() -> Router<Arc<App>> {
    Router::new()
        .route("/admin/node", get(node_info))
        .route("/admin/node/address", post(new_address))
        .route("/admin/node/channels", post(open_channel))
        .route("/admin/users/{username}/kyc", post(set_tier))
        .route("/admin/orders/review", get(orders_to_review))
        .route("/admin/orders/{id}/resolve", post(resolve_order))
}

pub struct Admin;

impl FromRequestParts<Arc<App>> for Admin {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, app: &Arc<App>) -> Result<Self, Self::Rejection> {
        let given = parts
            .headers
            .get(axum::http::header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.strip_prefix("Bearer "))
            .unwrap_or_default();
        let expected = app.config.admin_token.as_bytes();
        let same = given.len() == expected.len()
            && given.bytes().zip(expected).fold(0u8, |acc, (a, b)| acc | (a ^ b)) == 0;
        if same { Ok(Admin) } else { Err(ApiError::unauthorized("Admin token required.")) }
    }
}

async fn node_info(State(app): State<Arc<App>>, _: Admin) -> ApiResult<Json<Value>> {
    let node = &app.lightning.node;
    let balances = node.list_balances();
    let channels: Vec<Value> = node
        .list_channels()
        .iter()
        .map(|c| {
            json!({
                "channelId": c.channel_id.to_string(),
                "counterparty": c.counterparty_node_id.to_string(),
                "capacitySats": c.channel_value_sats,
                "outboundSats": c.outbound_capacity_msat / 1000,
                "inboundSats": c.inbound_capacity_msat / 1000,
                "ready": c.is_channel_ready,
                "usable": c.is_usable,
            })
        })
        .collect();
    Ok(Json(json!({
        "nodeId": node.node_id().to_string(),
        "listeningPort": app.config.ldk_listen_port,
        "onchainSats": balances.total_onchain_balance_sats,
        "spendableOnchainSats": balances.spendable_onchain_balance_sats,
        "lightningSats": balances.total_lightning_balance_sats,
        "channels": channels,
    })))
}

/// An on-chain address to fund the node from the Mutinynet faucet.
async fn new_address(State(app): State<Arc<App>>, _: Admin) -> ApiResult<Json<Value>> {
    let address = app.lightning.node.onchain_payment().new_address().map_err(ApiError::internal)?;
    Ok(Json(json!({ "address": address.to_string() })))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OpenChannel {
    /// `pubkey@host:port`.
    peer: String,
    amount_sats: u64,
    /// Sats given to the peer on open, so we can receive straight away.
    push_sats: Option<u64>,
}

async fn open_channel(State(app): State<Arc<App>>, _: Admin, ApiJson(body): ApiJson<OpenChannel>) -> ApiResult<Json<Value>> {
    let (pubkey, address) =
        body.peer.split_once('@').ok_or_else(|| ApiError::bad_request("peer must be pubkey@host:port"))?;
    let node_id = PublicKey::from_str(pubkey).map_err(|_| ApiError::bad_request("bad peer pubkey"))?;
    let address = SocketAddress::from_str(address).map_err(|_| ApiError::bad_request("bad peer address"))?;
    let id = app
        .lightning
        .node
        .open_channel(node_id, address, body.amount_sats, body.push_sats.map(|s| s * 1000), None)
        .map_err(|e| ApiError::bad_request(format!("Couldn't open the channel: {e}")))?;
    Ok(Json(json!({ "userChannelId": id.0.to_string() })))
}

#[derive(Deserialize)]
struct SetTier {
    tier: i32,
}

async fn set_tier(
    State(app): State<Arc<App>>,
    _: Admin,
    Path(username): Path<String>,
    ApiJson(body): ApiJson<SetTier>,
) -> ApiResult<Json<Value>> {
    let status = if body.tier > 0 { "verified" } else { "unverified" };
    let updated = sqlx::query("UPDATE users SET kyc_tier = $2, kyc_status = $3 WHERE username = $1")
        .bind(username.trim_start_matches('@').to_lowercase())
        .bind(body.tier)
        .bind(status)
        .execute(&app.db)
        .await?;
    if updated.rows_affected() == 0 {
        return Err(ApiError::not_found("No such user."));
    }
    Ok(Json(json!({ "tier": body.tier, "status": status })))
}

async fn orders_to_review(State(app): State<Arc<App>>, _: Admin) -> ApiResult<Json<Value>> {
    let rows: Vec<OrderRow> = sqlx::query_as(&format!(
        "SELECT {ORDER_COLUMNS} FROM orders WHERE needs_review ORDER BY paid_at"
    ))
    .fetch_all(&app.db)
    .await?;
    Ok(Json(Value::Array(
        rows.iter()
            .map(|r| {
                let mut json = r.to_json();
                json["provider"] = json!(r.provider);
                json
            })
            .collect(),
    )))
}

#[derive(Deserialize)]
struct Resolve {
    /// `done` after confirming delivery on the provider's dashboard, or
    /// `refundable` if it wasn't delivered.
    outcome: String,
    reference: Option<String>,
    message: Option<String>,
}

async fn resolve_order(
    State(app): State<Arc<App>>,
    _: Admin,
    Path(id): Path<String>,
    ApiJson(body): ApiJson<Resolve>,
) -> ApiResult<Json<Value>> {
    let updated = match body.outcome.as_str() {
        "done" => {
            let receipt = json!({
                "reference": body.reference.clone().unwrap_or_else(|| id.to_uppercase()),
                "message": body.message,
                "items": [],
            });
            sqlx::query("UPDATE orders SET status = 'done', needs_review = false, receipt = $2 WHERE id = $1 AND needs_review")
                .bind(&id)
                .bind(receipt)
                .execute(&app.db)
                .await?
        }
        "refundable" => sqlx::query(
            "UPDATE orders SET status = 'refundable', needs_review = false, failure_reason = $2 WHERE id = $1 AND needs_review",
        )
        .bind(&id)
        .bind(body.message.unwrap_or_else(|| "This bill couldn't be completed. Your sats can be refunded.".into()))
        .execute(&app.db)
        .await?,
        _ => return Err(ApiError::bad_request("outcome must be done or refundable")),
    };
    if updated.rows_affected() == 0 {
        return Err(ApiError::not_found("No order awaiting review with that ID."));
    }
    Ok(Json(json!({ "ok": true })))
}
