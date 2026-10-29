//! Bill links: "pay my bill" requests anyone can pay from any Lightning
//! wallet, e.g. family abroad paying a Lagos electricity bill from Strike.
//!
//! The user creates a link for one bill and shares it. Whoever opens it
//! gets the bill's details and, when they choose to pay, an invoice. That
//! invoice belongs to an ordinary order owned by the user, so tier
//! limits, holding until delivery and failing back all work as usual:
//! if the bill can't be delivered, the payer's sats go straight back.
//!
//! A link's state is worked out from its current order: open (nothing
//! paid yet, or the last attempt failed back), paying (an invoice is out
//! or a payment is held), paid (delivered), plus cancelled and expired.

use std::sync::Arc;

use axum::extract::{Path, State};
use axum::http::header;
use axum::response::{Html, IntoResponse};
use axum::routing::{get, post};
use axum::{Json, Router};
use chrono::{DateTime, Duration, Utc};
use rand::Rng;
use serde::Deserialize;
use serde_json::{Value, json};
use sqlx::FromRow;
use uuid::Uuid;

use crate::App;
use crate::auth::AuthUser;
use crate::json::ApiJson;
use crate::error::{ApiError, ApiResult};
use crate::orders::{OrderRequest, OrderRow, check_per_order_limit, describe, order_row, place_order, requote_order};

const LINK_DAYS: i64 = 7;
const PAY_PAGE: &str = include_str!("../static/pay.html");

pub fn routes() -> Router<Arc<App>> {
    Router::new()
        .route("/v1/bill-links", post(create).get(list))
        .route("/v1/bill-links/{code}", get(get_own).delete(cancel))
        .route("/v1/public/bill-links/{code}", get(get_public))
        .route("/v1/public/bill-links/{code}/invoice", post(invoice))
        .route("/v1/public/bill-links/{code}/qr.svg", get(qr))
        .route("/pay/{code}", get(pay_page))
}

#[derive(FromRow)]
struct LinkRow {
    id: String,
    user_id: Uuid,
    request: sqlx::types::Json<OrderRequest>,
    title: String,
    category: String,
    biller_name: String,
    target: String,
    amount: i64,
    note: Option<String>,
    order_id: Option<String>,
    cancelled_at: Option<DateTime<Utc>>,
    created_at: DateTime<Utc>,
    expires_at: DateTime<Utc>,
}

const LINK_COLUMNS: &str = "id, user_id, request, title, category, biller_name, target, amount, note, order_id, \
    cancelled_at, created_at, expires_at";

// ---------------------------------------------------------------------
// The requester (signed in)
// ---------------------------------------------------------------------

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreateLink {
    /// Share an order the user already created (it must still be unpaid).
    order_id: Option<String>,
    // Or describe a new bill (an OrderRequest):
    biller_id: Option<String>,
    target: Option<String>,
    option_id: Option<String>,
    plan_id: Option<String>,
    amount: Option<i64>,
    /// Shown to the payer, e.g. "Light for the house this week 🙏".
    note: Option<String>,
}

impl CreateLink {
    fn describes_a_bill(&self) -> bool {
        self.biller_id.is_some() || self.target.is_some() || self.option_id.is_some() || self.plan_id.is_some() || self.amount.is_some()
    }
}

/// Creates a link, either for an order the user already has (`orderId`)
/// or for a new bill (`billerId`, `target`, …).
///
/// - **Existing order:** it must be the user's and still unpaid (an
///   expired quote is fine: it's requoted when someone opens the link).
///   The link follows that order: if the user requotes it, the link shows
///   the new price and invoice. Sharing an order that already has a live
///   link returns that link.
/// - **New bill:** checked now (biller, target, plan, customer name,
///   per-order limit) and priced in sats only when someone opens an
///   invoice.
async fn create(State(app): State<Arc<App>>, AuthUser(user_id): AuthUser, ApiJson(body): ApiJson<CreateLink>) -> ApiResult<Json<Value>> {
    let note = body.note.clone().map(|n| n.trim().to_string()).filter(|n| !n.is_empty());
    if note.as_ref().is_some_and(|n| n.chars().count() > 140) {
        return Err(ApiError::bad_request("Keep the note under 140 characters."));
    }
    let link = match body.order_id.clone() {
        Some(order_id) => {
            if body.describes_a_bill() {
                return Err(ApiError::bad_request("Send either orderId or a new bill's details, not both."));
            }
            share_existing_order(&app, user_id, &order_id, note).await?
        }
        None => {
            let missing = || ApiError::bad_request("Send an orderId, or billerId and target for a new bill.");
            let request = OrderRequest {
                biller_id: body.biller_id.ok_or_else(missing)?,
                target: body.target.ok_or_else(missing)?,
                option_id: body.option_id,
                plan_id: body.plan_id,
                amount: body.amount,
            };
            new_bill_link(&app, user_id, request, note).await?
        }
    };
    Ok(Json(owner_json(&app, &link).await?))
}

async fn new_bill_link(app: &App, user_id: Uuid, request: OrderRequest, note: Option<String>) -> ApiResult<LinkRow> {
    let d = describe(app, &request).await?;
    // Fail early if it can never fit; the daily limit is checked when
    // it's paid, which may be another day.
    check_per_order_limit(app, user_id, d.amount).await?;
    let request = OrderRequest { target: d.target.clone(), ..request };
    insert_link(app, user_id, &request, &d.title, d.category.as_str(), &d.biller_name, &d.target, d.amount, &note, None).await
}

async fn share_existing_order(app: &App, user_id: Uuid, order_id: &str, note: Option<String>) -> ApiResult<LinkRow> {
    let order = order_row(app, user_id, order_id).await?;
    match order.status.as_str() {
        // An expired quote still reads awaitingPayment here: opening the
        // link requotes it.
        "awaitingPayment" => {}
        "paid" | "fulfilling" | "done" => return Err(ApiError::conflict("alreadyPaid", "This order has already been paid.")),
        _ => return Err(ApiError::conflict("unknown", "Only an unpaid order can be shared.")),
    }

    // One live link per order: two would hand the same invoice to two payers.
    let existing: Option<LinkRow> = sqlx::query_as(&format!(
        "SELECT {LINK_COLUMNS} FROM bill_links
         WHERE order_id = $1 AND user_id = $2 AND cancelled_at IS NULL AND expires_at > now()
         ORDER BY created_at DESC LIMIT 1"
    ))
    .bind(order_id)
    .bind(user_id)
    .fetch_optional(&app.db)
    .await?;
    if let Some(link) = existing {
        if note.is_some() && note != link.note {
            sqlx::query("UPDATE bill_links SET note = $2 WHERE id = $1").bind(&link.id).bind(&note).execute(&app.db).await?;
            return load(app, &link.id).await;
        }
        return Ok(link);
    }

    let request = OrderRequest {
        biller_id: order.biller_id.clone(),
        target: order.target.clone(),
        option_id: order.option_id.clone(),
        plan_id: order.plan_id.clone(),
        amount: order.requested_amount,
    };
    insert_link(
        app, user_id, &request, &order.title, &order.category, &order.biller_name, &order.target, order.amount, &note,
        Some(order_id),
    )
    .await
}

#[allow(clippy::too_many_arguments)]
async fn insert_link(
    app: &App,
    user_id: Uuid,
    request: &OrderRequest,
    title: &str,
    category: &str,
    biller_name: &str,
    target: &str,
    amount: i64,
    note: &Option<String>,
    order_id: Option<&str>,
) -> ApiResult<LinkRow> {
    let code = new_code();
    sqlx::query(
        "INSERT INTO bill_links (id, user_id, request, title, category, biller_name, target, amount, note, order_id, expires_at)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)",
    )
    .bind(&code)
    .bind(user_id)
    .bind(sqlx::types::Json(request))
    .bind(title)
    .bind(category)
    .bind(biller_name)
    .bind(target)
    .bind(amount)
    .bind(note)
    .bind(order_id)
    .bind(Utc::now() + Duration::days(LINK_DAYS))
    .execute(&app.db)
    .await?;
    load(app, &code).await
}

async fn list(State(app): State<Arc<App>>, AuthUser(user_id): AuthUser) -> ApiResult<Json<Value>> {
    let links: Vec<LinkRow> =
        sqlx::query_as(&format!("SELECT {LINK_COLUMNS} FROM bill_links WHERE user_id = $1 ORDER BY created_at DESC LIMIT 50"))
            .bind(user_id)
            .fetch_all(&app.db)
            .await?;
    let mut out = Vec::with_capacity(links.len());
    for link in &links {
        out.push(owner_json(&app, link).await?);
    }
    Ok(Json(Value::Array(out)))
}

async fn get_own(State(app): State<Arc<App>>, AuthUser(user_id): AuthUser, Path(code): Path<String>) -> ApiResult<Json<Value>> {
    let link = load(&app, &code).await?;
    if link.user_id != user_id {
        return Err(ApiError::not_found("Link not found."));
    }
    Ok(Json(owner_json(&app, &link).await?))
}

/// Stops a link from being paid. Not possible while a payment is held
/// or the bill is already paid.
async fn cancel(State(app): State<Arc<App>>, AuthUser(user_id): AuthUser, Path(code): Path<String>) -> ApiResult<Json<Value>> {
    let link = load(&app, &code).await?;
    if link.user_id != user_id {
        return Err(ApiError::not_found("Link not found."));
    }
    let order = current_order(&app, &link).await?;
    if let Some(order) = &order {
        if matches!(order.status.as_str(), "paid" | "fulfilling" | "done") {
            return Err(ApiError::conflict("alreadyPaid", "This bill has already been paid."));
        }
    }
    sqlx::query("UPDATE bill_links SET cancelled_at = now() WHERE id = $1 AND cancelled_at IS NULL")
        .bind(&code)
        .execute(&app.db)
        .await?;
    Ok(Json(owner_json(&app, &load(&app, &code).await?).await?))
}

// ---------------------------------------------------------------------
// The payer (public, no account)
// ---------------------------------------------------------------------

async fn get_public(State(app): State<Arc<App>>, Path(code): Path<String>) -> ApiResult<Json<Value>> {
    let link = load(&app, &code).await?;
    Ok(Json(public_json(&app, &link).await?))
}

/// Returns the link with a payable invoice: the current one if it's
/// still valid, a requote if it expired, or a fresh attempt if the last
/// one was handed back. Refused once the bill is paid, or while a
/// payment is being processed.
async fn invoice(State(app): State<Arc<App>>, Path(code): Path<String>) -> ApiResult<Json<Value>> {
    // One payer at a time per link.
    let mut tx = app.db.begin().await?;
    let link: LinkRow = sqlx::query_as(&format!("SELECT {LINK_COLUMNS} FROM bill_links WHERE id = $1 FOR UPDATE"))
        .bind(&code)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(|| ApiError::not_found("This link doesn't exist."))?;
    if link.cancelled_at.is_some() {
        return Err(ApiError::conflict("cancelled", "This bill request was cancelled."));
    }
    if link.expires_at <= Utc::now() {
        return Err(ApiError::conflict("expired", "This bill request has expired."));
    }

    let order = current_order(&app, &link).await?;
    let new_order = match order.as_ref().map(|o| (o.status.as_str(), o.expires_at <= Utc::now())) {
        None | Some(("refunded", _)) => true,
        Some(("awaitingPayment", false)) => false,
        Some(("awaitingPayment", true)) => {
            requote_order(&app, link.user_id, link.order_id.as_deref().unwrap(), None).await.map_err(for_payer)?;
            false
        }
        Some(("done", _)) => return Err(ApiError::conflict("alreadyPaid", "This bill has already been paid.")),
        Some(_) => return Err(ApiError::conflict("inProgress", "A payment for this bill is being processed.")),
    };
    if new_order {
        let id = place_order(&app, link.user_id, &link.request).await.map_err(for_payer)?;
        sqlx::query("UPDATE bill_links SET order_id = $2 WHERE id = $1").bind(&code).bind(&id).execute(&mut *tx).await?;
    }
    tx.commit().await?;
    let link = load(&app, &code).await?;
    Ok(Json(public_json(&app, &link).await?))
}

/// The current invoice as a QR code (`lightning:` URI), for the pay page.
async fn qr(State(app): State<Arc<App>>, Path(code): Path<String>) -> ApiResult<impl IntoResponse> {
    let link = load(&app, &code).await?;
    let order = current_order(&app, &link).await?.ok_or_else(|| ApiError::not_found("No invoice yet."))?;
    let qr = qrcode::QrCode::new(format!("lightning:{}", order.invoice.to_uppercase()).as_bytes())
        .map_err(ApiError::internal)?;
    let svg = qr
        .render::<qrcode::render::svg::Color>()
        .min_dimensions(260, 260)
        .dark_color(qrcode::render::svg::Color("#111113"))
        .light_color(qrcode::render::svg::Color("#ffffff"))
        .build();
    Ok(([(header::CONTENT_TYPE, "image/svg+xml"), (header::CACHE_CONTROL, "no-store")], svg))
}

async fn pay_page(Path(code): Path<String>) -> Html<String> {
    // The code is only placed in a data attribute; strip anything that
    // isn't part of a link code.
    let code: String = code.chars().filter(|c| c.is_ascii_alphanumeric()).take(32).collect();
    Html(PAY_PAGE.replace("{{CODE}}", &code))
}

/// Errors from the requester's side, worded for the payer.
fn for_payer(err: ApiError) -> ApiError {
    match err.code {
        "overLimit" => ApiError::unprocessable(
            "overLimit",
            "This bill is over the requester's limit right now. Ask them to verify their account or try tomorrow.",
        ),
        _ => err,
    }
}

// ---------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------

async fn load(app: &App, code: &str) -> ApiResult<LinkRow> {
    sqlx::query_as(&format!("SELECT {LINK_COLUMNS} FROM bill_links WHERE id = $1"))
        .bind(code)
        .fetch_optional(&app.db)
        .await?
        .ok_or_else(|| ApiError::not_found("This link doesn't exist."))
}

async fn current_order(app: &App, link: &LinkRow) -> ApiResult<Option<OrderRow>> {
    match &link.order_id {
        Some(id) => Ok(Some(order_row(app, link.user_id, id).await?)),
        None => Ok(None),
    }
}

/// open | paying | paid | cancelled | expired.
fn link_status(link: &LinkRow, order: Option<&OrderRow>) -> &'static str {
    match order.map(|o| o.status.as_str()) {
        Some("done") => "paid",
        Some("paid" | "fulfilling" | "refundable") => "paying",
        _ if link.cancelled_at.is_some() => "cancelled",
        _ if link.expires_at <= Utc::now() => "expired",
        Some("awaitingPayment") if order.is_some_and(|o| o.expires_at > Utc::now()) => "paying",
        _ => "open",
    }
}

fn url(app: &App, code: &str) -> String {
    format!("{}/pay/{code}", app.config.public_url.trim_end_matches('/'))
}

/// What the link is for. Taken from its current order when it has one, so
/// a shared order the owner requoted with new details shows them here too.
struct Details {
    title: String,
    category: String,
    biller_name: String,
    target: String,
    amount: i64,
    request: OrderRequest,
}

fn details(link: &LinkRow, order: Option<&OrderRow>) -> Details {
    match order {
        Some(o) => Details {
            title: o.title.clone(),
            category: o.category.clone(),
            biller_name: o.biller_name.clone(),
            target: o.target.clone(),
            amount: o.amount,
            request: OrderRequest {
                biller_id: o.biller_id.clone(),
                target: o.target.clone(),
                option_id: o.option_id.clone(),
                plan_id: o.plan_id.clone(),
                amount: o.requested_amount,
            },
        },
        None => Details {
            title: link.title.clone(),
            category: link.category.clone(),
            biller_name: link.biller_name.clone(),
            target: link.target.clone(),
            amount: link.amount,
            request: link.request.0.clone(),
        },
    }
}

/// The link as its owner sees it: everything, plus the full order (with
/// any token on its receipt).
async fn owner_json(app: &App, link: &LinkRow) -> ApiResult<Value> {
    let order = current_order(app, link).await?;
    let d = details(link, order.as_ref());
    Ok(json!({
        "code": link.id,
        "url": url(app, &link.id),
        "status": link_status(link, order.as_ref()),
        "title": d.title,
        "category": d.category,
        "billerName": d.biller_name,
        "target": d.target,
        "amount": d.amount,
        "currency": "NGN",
        "note": link.note,
        "request": d.request,
        "createdAt": link.created_at.to_rfc3339(),
        "expiresAt": link.expires_at.to_rfc3339(),
        "order": order.map(|o| o.to_json()),
    }))
}

/// The link as a payer sees it: no full target, no receipt items (a
/// meter token is for the requester), but enough to pay and follow it.
async fn public_json(app: &App, link: &LinkRow) -> ApiResult<Value> {
    let order = current_order(app, link).await?;
    let d = details(link, order.as_ref());
    let (requester,): (String,) =
        sqlx::query_as("SELECT display_name FROM users WHERE id = $1").bind(link.user_id).fetch_one(&app.db).await?;
    let payment = order.as_ref().map(|o| {
        let status = if o.status == "awaitingPayment" && o.expires_at <= Utc::now() { "expired" } else { o.status.as_str() };
        json!({
            "status": status,
            "sats": o.sats,
            "invoice": o.invoice,
            "expiresAt": o.expires_at.to_rfc3339(),
            "paidAt": o.paid_at.map(|t| t.to_rfc3339()),
            "message": o.receipt.as_ref().and_then(|r| r["message"].as_str()).map(|m| mask_in(m, &d.target)),
            "failureReason": o.failure_reason,
        })
    });
    Ok(json!({
        "code": link.id,
        "status": link_status(link, order.as_ref()),
        "requester": requester,
        "title": d.title,
        "category": d.category,
        "billerName": d.biller_name,
        "target": mask(&d.target),
        "amount": d.amount,
        "currency": "NGN",
        "note": link.note,
        "expiresAt": link.expires_at.to_rfc3339(),
        "payment": payment,
    }))
}

/// `0803****567`: enough to recognise, not enough to reuse.
fn mask(target: &str) -> String {
    let n = target.chars().count();
    if n <= 7 {
        return "•".repeat(n);
    }
    let head: String = target.chars().take(4).collect();
    let tail: String = target.chars().skip(n - 3).collect();
    format!("{head}{}{tail}", "•".repeat(n - 7))
}

fn mask_in(text: &str, target: &str) -> String {
    text.replace(target, &mask(target))
}

fn new_code() -> String {
    const ALPHABET: &[u8] = b"abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let mut rng = rand::thread_rng();
    (0..10).map(|_| ALPHABET[rng.gen_range(0..ALPHABET.len())] as char).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn masks_targets() {
        assert_eq!(mask("08031234567"), "0803••••567");
        assert_eq!(mask("1234567"), "•••••••");
        assert_eq!(mask_in("₦500 MTN airtime sent to 08031234567.", "08031234567"), "₦500 MTN airtime sent to 0803••••567.");
    }

    #[test]
    fn codes_are_url_safe() {
        let code = new_code();
        assert_eq!(code.len(), 10);
        assert!(code.chars().all(|c| c.is_ascii_alphanumeric()));
    }
}
