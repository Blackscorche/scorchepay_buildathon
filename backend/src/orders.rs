//! The VTU API (docs/VTU.md): catalog, limits, customer checks, orders,
//! requotes and refunds, plus the background work that moves orders on:
//! holding payments, fulfilling paid orders, and settling refunds.
//!
//! Payments are held until the bill is delivered: a delivered bill takes
//! the payment, a failed one hands it straight back to the payer's
//! wallet (the order reads refunded). There's no refund to ask for.
//!
//! States: awaitingPayment → paid (payment held) → fulfilling → done, or
//! → refunded (payment failed back). An awaitingPayment order past its
//! expiry reads as expired; a requote puts it back to awaitingPayment
//! with a new invoice. refundable is left for orders a reviewer finds
//! undelivered after the payment was taken; the user then pastes an
//! invoice and the node pays it.

use std::sync::Arc;
use std::time::Duration as StdDuration;

use axum::extract::{Path, Query, State};
use axum::routing::{get, post};
use axum::{Json, Router};
use chrono::{DateTime, Duration, FixedOffset, Utc};
use ldk_node::Event;
use ldk_node::lightning_types::payment::PaymentHash;
use rand::Rng;
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sqlx::{FromRow, Postgres, Transaction};
use uuid::Uuid;

use crate::App;
use crate::auth::AuthUser;
use crate::catalog::{Biller, Category, Pricing};
use crate::config::ProviderKind;
use crate::json::{ApiJson, OptionalApiJson};
use crate::error::{ApiError, ApiResult, naira, sats};
use crate::providers::{CustomerLookup, Fulfilment, Purchase};
use crate::rates::sats_for;

pub fn routes() -> Router<Arc<App>> {
    Router::new()
        .route("/vtu/catalog", get(catalog))
        .route("/vtu/limits", get(limits))
        .route("/vtu/customers/validate", post(validate_customer))
        .route("/vtu/orders", post(create_order).get(list_orders))
        .route("/vtu/orders/{id}", get(get_order))
        .route("/vtu/orders/{id}/quote", post(requote))
        .route("/vtu/orders/{id}/refund", post(request_refund))
        .route("/dev/orders/{id}/simulate-payment", post(simulate_payment))
}

// ---------------------------------------------------------------------
// Catalog and limits
// ---------------------------------------------------------------------

#[derive(Deserialize)]
struct CatalogQuery {
    country: Option<String>,
}

async fn catalog(State(app): State<Arc<App>>, Query(q): Query<CatalogQuery>) -> ApiResult<Json<Value>> {
    if q.country.as_deref().is_some_and(|c| c != "NG") {
        return Err(ApiError::not_found("ScorchePay isn't available there yet."));
    }
    let catalog = app.catalog().await;
    Ok(Json(serde_json::to_value(&*catalog).map_err(ApiError::internal)?))
}

/// Caps per KYC tier, in naira.
fn tier_caps(tier: i32) -> (i64, i64) {
    if tier >= 1 { (200_000, 1_000_000) } else { (10_000, 30_000) }
}

fn limits_json(tier: i32, used_today: i64) -> Value {
    let (per_order, daily) = tier_caps(tier);
    let next = (tier < 1).then(|| {
        let (per_order, daily) = tier_caps(1);
        json!({ "currency": "NGN", "tier": 1, "perOrder": per_order, "daily": daily, "usedToday": 0, "nextTier": null })
    });
    json!({
        "currency": "NGN",
        "tier": tier,
        "perOrder": per_order,
        "daily": daily,
        "usedToday": used_today,
        "nextTier": next,
    })
}

async fn limits(State(app): State<Arc<App>>, AuthUser(user_id): AuthUser) -> ApiResult<Json<Value>> {
    let mut tx = app.db.begin().await?;
    let tier = lock_user(&mut tx, user_id).await?;
    let used = used_today(&mut tx, user_id, None).await?;
    tx.commit().await?;
    Ok(Json(limits_json(tier, used)))
}

/// Locks the user's row, so concurrent orders can't both fit under a
/// limit only one of them fits under. Returns their KYC tier.
async fn lock_user(tx: &mut Transaction<'_, Postgres>, user_id: Uuid) -> ApiResult<i32> {
    let row: Option<(i32,)> =
        sqlx::query_as("SELECT kyc_tier FROM users WHERE id = $1 FOR UPDATE").bind(user_id).fetch_optional(&mut **tx).await?;
    row.map(|(tier,)| tier).ok_or_else(|| ApiError::unauthorized("Your session has ended. Log in again."))
}

/// Start of today in Nigeria (WAT, UTC+1).
fn start_of_today() -> DateTime<Utc> {
    let wat = FixedOffset::east_opt(3600).unwrap();
    let midnight = Utc::now().with_timezone(&wat).date_naive().and_hms_opt(0, 0, 0).unwrap();
    midnight.and_local_timezone(wat).unwrap().with_timezone(&Utc)
}

/// Today's spend: paid orders and unexpired quotes (which hold the limit
/// until they expire). Expired, failed and refunded orders don't count.
async fn used_today(tx: &mut Transaction<'_, Postgres>, user_id: Uuid, excluding: Option<&str>) -> ApiResult<i64> {
    let (used,): (Option<i64>,) = sqlx::query_as(
        "SELECT SUM(amount)::BIGINT FROM orders
         WHERE user_id = $1 AND created_at >= $2 AND ($3::TEXT IS NULL OR id <> $3)
           AND status NOT IN ('refundable', 'refunded')
           AND NOT (status = 'awaitingPayment' AND expires_at <= now())",
    )
    .bind(user_id)
    .bind(start_of_today())
    .bind(excluding)
    .fetch_one(&mut **tx)
    .await?;
    Ok(used.unwrap_or(0))
}

// ---------------------------------------------------------------------
// Customer check
// ---------------------------------------------------------------------

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ValidateRequest {
    biller_id: String,
    target: String,
    // The app also sends optionId (meter type); no provider needs it yet.
}

async fn validate_customer(
    State(app): State<Arc<App>>,
    AuthUser(_): AuthUser,
    ApiJson(body): ApiJson<ValidateRequest>,
) -> ApiResult<Json<Value>> {
    let catalog = app.catalog().await;
    let biller = find_biller(&catalog, &body.biller_id)?;
    let target = checked_target(biller, &body.target)?;
    let (name, address) = lookup_customer(&app, biller, &target).await?;
    Ok(Json(json!({ "name": name, "address": address })))
}

async fn lookup_customer(app: &App, biller: &Biller, target: &str) -> ApiResult<(String, Option<String>)> {
    match app.providers.validate_customer(biller.provider, biller.category, target).await {
        Ok(CustomerLookup::Found(c)) => Ok((c.name, c.address)),
        Ok(CustomerLookup::NotFound) => Err(ApiError::unprocessable(
            "customerNotFound",
            format!(
                "We couldn't find a customer with that {}. Check it and try again.",
                biller.target.label.to_lowercase()
            ),
        )),
        Err(err) => {
            tracing::warn!(biller = biller.id, "customer check: {err:#}");
            Err(ApiError::unavailable("billerUnavailable", format!("{} is unavailable right now. Try again later.", biller.name)))
        }
    }
}

fn find_biller<'a>(catalog: &'a crate::catalog::Catalog, id: &str) -> ApiResult<&'a Biller> {
    catalog.biller(id).ok_or_else(|| ApiError::not_found("Unknown biller."))
}

/// The target without spaces or dashes, if it matches the biller's pattern.
fn checked_target(biller: &Biller, target: &str) -> ApiResult<String> {
    let target: String = target.chars().filter(|c| !matches!(c, ' ' | '-')).collect();
    let valid = Regex::new(biller.target.pattern).map(|re| re.is_match(&target)).unwrap_or(false);
    if !valid {
        return Err(ApiError::unprocessable("invalidTarget", biller.target.error_text));
    }
    Ok(target)
}

// ---------------------------------------------------------------------
// Orders and quotes
// ---------------------------------------------------------------------

/// `OrderRequest` in the app: what to buy.
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OrderRequest {
    pub biller_id: String,
    pub target: String,
    pub option_id: Option<String>,
    pub plan_id: Option<String>,
    pub amount: Option<i64>,
}

/// A checked order request: the biller, target, plan and price in naira.
pub struct Described {
    pub category: Category,
    pub biller_id: String,
    pub biller_name: String,
    pub title: String,
    pub target: String,
    pub option_id: Option<String>,
    pub option_name: Option<String>,
    pub plan_id: Option<String>,
    pub plan_name: Option<String>,
    pub requested_amount: Option<i64>,
    pub customer_name: Option<String>,
    pub amount: i64,
    pub provider: ProviderKind,
    pub biller_code: String,
    pub plan_code: Option<String>,
}

/// A described order priced in sats, with a fresh invoice, before it's saved.
struct Quote {
    described: Described,
    sats: i64,
    rate: f64,
    invoice: String,
    payment_hash: String,
    preimage: String,
    expires_at: DateTime<Utc>,
}

impl std::ops::Deref for Quote {
    type Target = Described;
    fn deref(&self) -> &Described {
        &self.described
    }
}

/// Validates `request` against the catalog (biller, target, plan or
/// amount, option, and the customer for meters and smartcards). Doesn't
/// price it in sats or check limits.
pub async fn describe(app: &App, request: &OrderRequest) -> ApiResult<Described> {
    let catalog = app.catalog().await;
    let biller = find_biller(&catalog, &request.biller_id)?;
    if !biller.available {
        return Err(ApiError::unavailable("billerUnavailable", format!("{} is unavailable right now. Try again later.", biller.name)));
    }
    let target = checked_target(biller, &request.target)?;

    let (amount, plan) = match &biller.pricing {
        Pricing::Plans { .. } => {
            let plan = biller
                .plan(request.plan_id.as_deref())
                .ok_or_else(|| ApiError::unprocessable("unknown", "Choose a plan to continue."))?;
            (plan.amount, Some(plan))
        }
        Pricing::Amount { min, max, .. } => {
            let amount = request.amount.unwrap_or(0);
            let ok = amount > 0 && min.is_none_or(|m| amount >= m) && max.is_none_or(|m| amount <= m);
            if !ok {
                let message = match (min, max) {
                    (Some(min), Some(max)) => format!("Enter an amount from {} to {}.", naira(*min), naira(*max)),
                    (Some(min), None) => format!("Enter at least {}.", naira(*min)),
                    (None, Some(max)) => format!("Enter up to {}.", naira(*max)),
                    (None, None) => "Enter an amount.".into(),
                };
                return Err(ApiError::unprocessable("unknown", message));
            }
            (amount, None)
        }
    };
    let option = biller.option(request.option_id.as_deref());
    if let (Some(options), None) = (&biller.options, option) {
        return Err(ApiError::unprocessable("unknown", format!("Choose a {} to continue.", options.label.to_lowercase())));
    }

    let customer_name = if biller.customer_check { Some(lookup_customer(app, biller, &target).await?.0) } else { None };

    let title = match biller.category {
        Category::Airtime => format!("{} airtime", biller.name),
        Category::Data => format!("{} {}", biller.name, plan.map_or("data", |p| p.name.as_str())),
        Category::Electricity => match option {
            Some(o) => format!("{} ({})", biller.name, o.name),
            None => biller.name.clone(),
        },
        Category::Tv => match plan {
            Some(p) => format!("{} {}", biller.name, p.name),
            None => biller.name.clone(),
        },
    };

    Ok(Described {
        category: biller.category,
        biller_id: biller.id.clone(),
        biller_name: biller.name.clone(),
        title,
        target,
        option_id: option.map(|o| o.id.to_string()),
        option_name: option.map(|o| o.name.to_string()),
        plan_id: plan.map(|p| p.id.clone()),
        plan_name: plan.map(|p| p.name.clone()),
        requested_amount: plan.is_none().then_some(amount),
        customer_name,
        amount,
        provider: biller.provider,
        biller_code: biller.provider_code.clone(),
        plan_code: plan.map(|p| p.provider_code.clone()),
    })
}

/// Describes `request`, prices it in sats and issues its invoice. Limits
/// are checked separately, under the user's lock.
async fn price(app: &App, request: &OrderRequest) -> ApiResult<Quote> {
    let described = describe(app, request).await?;
    let rate = app.rates.quote_rate().await.map_err(|e| {
        tracing::error!("no rate: {e:#}");
        ApiError::unavailable("network", "Prices are unavailable right now. Try again in a minute.")
    })?;
    let sats = sats_for(described.amount, rate);
    let quote_secs = app.config.quote_secs;
    let invoice = app
        .lightning
        .create_invoice(sats, &format!("ScorchePay: {}", described.title), quote_secs)
        .map_err(ApiError::internal)?;
    Ok(Quote {
        sats,
        // What the user effectively pays per BTC, as the app shows it.
        rate: described.amount as f64 / sats as f64 * 1e8,
        invoice: invoice.bolt11,
        payment_hash: invoice.payment_hash,
        preimage: invoice.preimage,
        expires_at: Utc::now() + Duration::seconds(quote_secs as i64),
        described,
    })
}

/// Refuses `amount` if it's over the user's per-order cap, regardless of
/// today's spend (for requests paid later, like bill links).
pub async fn check_per_order_limit(app: &App, user_id: Uuid, amount: i64) -> ApiResult<()> {
    let (tier,): (i32,) = sqlx::query_as("SELECT kyc_tier FROM users WHERE id = $1").bind(user_id).fetch_one(&app.db).await?;
    let (per_order, _) = tier_caps(tier);
    if amount > per_order {
        return Err(ApiError::unprocessable("overLimit", format!("This is over your {} limit per order.", naira(per_order))));
    }
    Ok(())
}

/// Refuses `amount` if it's over the user's per-order cap or what's left
/// of today's.
async fn check_limits(tx: &mut Transaction<'_, Postgres>, user_id: Uuid, amount: i64, order_id: Option<&str>) -> ApiResult<()> {
    let tier = lock_user(tx, user_id).await?;
    let (per_order, daily) = tier_caps(tier);
    let remaining = (daily - used_today(tx, user_id, order_id).await?).max(0);
    if amount > per_order {
        return Err(ApiError::unprocessable("overLimit", format!("This is over your {} limit per order.", naira(per_order))));
    }
    if amount > remaining {
        return Err(ApiError::unprocessable(
            "overLimit",
            format!("This is over what's left of your daily limit ({}).", naira(remaining)),
        ));
    }
    Ok(())
}

async fn create_order(
    State(app): State<Arc<App>>,
    AuthUser(user_id): AuthUser,
    ApiJson(request): ApiJson<OrderRequest>,
) -> ApiResult<Json<Value>> {
    let id = place_order(&app, user_id, &request).await?;
    Ok(Json(load_order(&app, user_id, &id).await?))
}

/// Quotes `request` for `user_id` (within their limits) and saves it as a
/// new order awaiting payment. Returns its ID.
pub async fn place_order(app: &App, user_id: Uuid, request: &OrderRequest) -> ApiResult<String> {
    let q = price(app, request).await?;
    let id = new_order_id();
    let mut tx = app.db.begin().await?;
    check_limits(&mut tx, user_id, q.amount, None).await?;
    sqlx::query(
        "INSERT INTO orders (id, user_id, status, category, biller_id, biller_name, title, target, option_id,
            option_name, plan_id, plan_name, requested_amount, customer_name, amount, currency, sats, rate, invoice,
            payment_hash, preimage, expires_at, provider, biller_code, plan_code)
         VALUES ($1, $2, 'awaitingPayment', $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, 'NGN', $15, $16,
            $17, $18, $19, $20, $21, $22, $23)",
    )
    .bind(&id)
    .bind(user_id)
    .bind(q.category.as_str())
    .bind(&q.biller_id)
    .bind(&q.biller_name)
    .bind(&q.title)
    .bind(&q.target)
    .bind(&q.option_id)
    .bind(&q.option_name)
    .bind(&q.plan_id)
    .bind(&q.plan_name)
    .bind(q.requested_amount)
    .bind(&q.customer_name)
    .bind(q.amount)
    .bind(q.sats)
    .bind(q.rate)
    .bind(&q.invoice)
    .bind(&q.payment_hash)
    .bind(&q.preimage)
    .bind(q.expires_at)
    .bind(provider_name(q.provider))
    .bind(&q.biller_code)
    .bind(&q.plan_code)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(id)
}

/// Prices an unpaid order again, under the same ID. Its old invoice
/// stops being claimable: a late payment to it is failed back.
async fn requote(
    State(app): State<Arc<App>>,
    AuthUser(user_id): AuthUser,
    Path(id): Path<String>,
    OptionalApiJson(body): OptionalApiJson<OrderRequest>,
) -> ApiResult<Json<Value>> {
    requote_order(&app, user_id, &id, body).await?;
    Ok(Json(load_order(&app, user_id, &id).await?))
}

/// Requotes `user_id`'s unpaid order `id`, with new details if given.
pub async fn requote_order(app: &App, user_id: Uuid, id: &str, request: Option<OrderRequest>) -> ApiResult<()> {
    let request = match request {
        Some(request) => request,
        None => stored_request(app, user_id, id).await?,
    };
    let q = price(app, &request).await?;

    let mut tx = app.db.begin().await?;
    check_limits(&mut tx, user_id, q.amount, Some(id)).await?;
    let status: Option<(String,)> = sqlx::query_as("SELECT status FROM orders WHERE id = $1 AND user_id = $2 FOR UPDATE")
        .bind(id)
        .bind(user_id)
        .fetch_optional(&mut *tx)
        .await?;
    match status {
        None => return Err(ApiError::not_found("Order not found.")),
        Some((status,)) if status != "awaitingPayment" => {
            return Err(ApiError::conflict("alreadyPaid", "This order has already been paid."));
        }
        _ => {}
    }
    sqlx::query(
        "UPDATE orders SET category = $3, biller_id = $4, biller_name = $5, title = $6, target = $7, option_id = $8,
            option_name = $9, plan_id = $10, plan_name = $11, requested_amount = $12, customer_name = $13,
            amount = $14, sats = $15, rate = $16, invoice = $17, payment_hash = $18, preimage = $19,
            expires_at = $20, provider = $21, biller_code = $22, plan_code = $23
         WHERE id = $1 AND user_id = $2",
    )
    .bind(id)
    .bind(user_id)
    .bind(q.category.as_str())
    .bind(&q.biller_id)
    .bind(&q.biller_name)
    .bind(&q.title)
    .bind(&q.target)
    .bind(&q.option_id)
    .bind(&q.option_name)
    .bind(&q.plan_id)
    .bind(&q.plan_name)
    .bind(q.requested_amount)
    .bind(&q.customer_name)
    .bind(q.amount)
    .bind(q.sats)
    .bind(q.rate)
    .bind(&q.invoice)
    .bind(&q.payment_hash)
    .bind(&q.preimage)
    .bind(q.expires_at)
    .bind(provider_name(q.provider))
    .bind(&q.biller_code)
    .bind(&q.plan_code)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(())
}

async fn stored_request(app: &App, user_id: Uuid, id: &str) -> ApiResult<OrderRequest> {
    let row: Option<(String, String, Option<String>, Option<String>, Option<i64>)> = sqlx::query_as(
        "SELECT biller_id, target, option_id, plan_id, requested_amount FROM orders WHERE id = $1 AND user_id = $2",
    )
    .bind(id)
    .bind(user_id)
    .fetch_optional(&app.db)
    .await?;
    let (biller_id, target, option_id, plan_id, amount) = row.ok_or_else(|| ApiError::not_found("Order not found."))?;
    Ok(OrderRequest { biller_id, target, option_id, plan_id, amount })
}

async fn get_order(State(app): State<Arc<App>>, AuthUser(user_id): AuthUser, Path(id): Path<String>) -> ApiResult<Json<Value>> {
    Ok(Json(load_order(&app, user_id, &id).await?))
}

#[derive(Deserialize)]
struct ListQuery {
    limit: Option<i64>,
}

async fn list_orders(State(app): State<Arc<App>>, AuthUser(user_id): AuthUser, Query(q): Query<ListQuery>) -> ApiResult<Json<Value>> {
    let rows: Vec<OrderRow> =
        sqlx::query_as(&format!("SELECT {ORDER_COLUMNS} FROM orders WHERE user_id = $1 ORDER BY created_at DESC LIMIT $2"))
            .bind(user_id)
            .bind(q.limit.unwrap_or(20).clamp(1, 100))
            .fetch_all(&app.db)
            .await?;
    Ok(Json(Value::Array(rows.iter().map(OrderRow::to_json).collect())))
}

// ---------------------------------------------------------------------
// Refunds
// ---------------------------------------------------------------------

#[derive(Deserialize)]
struct RefundRequest {
    invoice: String,
}

/// Pays a refundable order's sats to the user's invoice, which must be
/// for exactly the order's amount.
async fn request_refund(
    State(app): State<Arc<App>>,
    AuthUser(user_id): AuthUser,
    Path(id): Path<String>,
    ApiJson(body): ApiJson<RefundRequest>,
) -> ApiResult<Json<Value>> {
    let invalid = |m: String| ApiError::unprocessable("invalidInvoice", m);
    let (order_sats, refundable): (i64, bool) = sqlx::query_as(
        "SELECT sats, status = 'refundable' AND refund_requested_at IS NULL FROM orders WHERE id = $1 AND user_id = $2",
    )
    .bind(&id)
    .bind(user_id)
    .fetch_optional(&app.db)
    .await?
    .ok_or_else(|| ApiError::not_found("Order not found."))?;
    if !refundable {
        return Err(ApiError::conflict("unknown", "This order can't be refunded."));
    }

    let invoice = app.lightning.parse_invoice(&body.invoice).ok_or_else(|| {
        invalid("That isn't a Lightning invoice for this network. Create one in your wallet and paste it here.".into())
    })?;
    let invoice_sats = invoice.amount_milli_satoshis().map(|m| (m / 1000) as i64);
    match invoice_sats {
        None => return Err(invalid("That invoice has no amount. Create one with an amount and paste it here.".into())),
        Some(s) if s != order_sats => {
            return Err(invalid(format!(
                "The invoice must be for exactly {}; this one is for {}.",
                sats(order_sats),
                sats(s)
            )));
        }
        _ => {}
    }
    if invoice.is_expired() {
        return Err(invalid("That invoice has expired. Create a new one.".into()));
    }

    let claimed = sqlx::query(
        "UPDATE orders SET refund_invoice = $3, refund_requested_at = now()
         WHERE id = $1 AND user_id = $2 AND status = 'refundable' AND refund_requested_at IS NULL",
    )
    .bind(&id)
    .bind(user_id)
    .bind(invoice.to_string())
    .execute(&app.db)
    .await?;
    if claimed.rows_affected() == 0 {
        return Err(ApiError::conflict("unknown", "This order can't be refunded."));
    }

    match app.lightning.pay(&invoice) {
        Ok(payment_id) => {
            sqlx::query("UPDATE orders SET refund_payment_id = $2 WHERE id = $1").bind(&id).bind(payment_id).execute(&app.db).await?;
        }
        Err(err) => {
            reset_refund(&app, &id).await?;
            return Err(invalid(format!("Couldn't pay that invoice ({err}). Try another one.")));
        }
    }
    Ok(Json(load_order(&app, user_id, &id).await?))
}

/// Lets the user try another refund invoice.
async fn reset_refund(app: &App, id: &str) -> ApiResult<()> {
    sqlx::query("UPDATE orders SET refund_invoice = NULL, refund_requested_at = NULL, refund_payment_id = NULL WHERE id = $1")
        .bind(id)
        .execute(&app.db)
        .await?;
    Ok(())
}

// ---------------------------------------------------------------------
// Lightning events
// ---------------------------------------------------------------------

/// Handles the node's events, one at a time, for as long as it runs.
pub async fn run_events(app: Arc<App>) {
    loop {
        let event = app.lightning.node.next_event_async().await;
        if let Err(err) = handle_event(&app, &event).await {
            // Leave it unhandled: it's delivered again, so retry shortly.
            tracing::error!("handling {event:?}: {err:?}");
            tokio::time::sleep(StdDuration::from_secs(2)).await;
            continue;
        }
        if let Err(err) = app.lightning.node.event_handled() {
            tracing::error!("marking event handled: {err}");
        }
    }
}

async fn handle_event(app: &App, event: &Event) -> ApiResult<()> {
    match event {
        Event::PaymentClaimable { payment_hash, claimable_amount_msat, claim_deadline, .. } => {
            on_claimable(app, payment_hash, *claimable_amount_msat, *claim_deadline).await
        }
        Event::PaymentReceived { payment_hash, amount_msat, .. } => {
            tracing::info!(hash = %hex::encode(payment_hash.0), amount_msat, "payment received");
            Ok(())
        }
        Event::PaymentSuccessful { payment_id: Some(id), .. } => {
            let done = sqlx::query(
                "UPDATE orders SET status = 'refunded', refunded_at = now() WHERE refund_payment_id = $1 AND status = 'refundable'",
            )
            .bind(hex::encode(id.0))
            .execute(&app.db)
            .await?;
            if done.rows_affected() > 0 {
                tracing::info!(payment = %hex::encode(id.0), "refund paid");
            }
            Ok(())
        }
        Event::PaymentFailed { payment_id: Some(id), reason, .. } => {
            let order: Option<(String,)> =
                sqlx::query_as("SELECT id FROM orders WHERE refund_payment_id = $1 AND status = 'refundable'")
                    .bind(hex::encode(id.0))
                    .fetch_optional(&app.db)
                    .await?;
            if let Some((order_id,)) = order {
                tracing::warn!(order_id, ?reason, "refund payment failed; the user can try another invoice");
                reset_refund(app, &order_id).await?;
            }
            Ok(())
        }
        other => {
            tracing::info!("lightning: {other:?}");
            Ok(())
        }
    }
}

/// Blocks that must be left before a held payment's claim deadline for us
/// to start buying its bill. A purchase that finishes after the deadline
/// couldn't be paid for, so near it the payment is failed back instead.
const MIN_BLOCKS_LEFT: u32 = 6;

/// A payment to one of our invoices arrived. It's held, not taken: if
/// its order is waiting on that exact invoice, unexpired, for at least
/// the quoted sats, the order is marked paid and the bill is bought; the
/// payment is claimed only once the bill is delivered (`fulfil`).
/// Anything else is failed back to the payer straight away.
async fn on_claimable(app: &App, payment_hash: &PaymentHash, amount_msat: u64, claim_deadline: Option<u32>) -> ApiResult<()> {
    let hash = hex::encode(payment_hash.0);
    let mut tx = app.db.begin().await?;
    let order: Option<(String, String, i64, String, DateTime<Utc>)> =
        sqlx::query_as("SELECT id, status, sats, preimage, expires_at FROM orders WHERE payment_hash = $1 FOR UPDATE")
            .bind(&hash)
            .fetch_optional(&mut *tx)
            .await?;
    let Some((order_id, status, order_sats, preimage, expires_at)) = order else {
        tracing::info!(hash, "payment for an unknown or replaced invoice; failing it back");
        app.lightning.fail(payment_hash);
        return Ok(());
    };

    let enough = amount_msat >= order_sats as u64 * 1000;
    match status.as_str() {
        "awaitingPayment" if expires_at > Utc::now() && enough => {
            sqlx::query("UPDATE orders SET status = 'paid', paid_at = now(), held_msat = $2, claim_deadline = $3 WHERE id = $1")
                .bind(&order_id)
                .bind(amount_msat as i64)
                .bind(claim_deadline.map(|d| d as i32))
                .execute(&mut *tx)
                .await?;
            tx.commit().await?;
            tracing::info!(order_id, amount_msat, ?claim_deadline, "payment held; buying the bill");
            app.wake_fulfilment.notify_one();
        }
        // Replays of an event we already recorded (after a restart).
        "paid" | "fulfilling" => {}
        "done" | "refundable" => {
            drop(tx);
            app.lightning.claim(payment_hash, amount_msat, &preimage)?;
        }
        _ => {
            drop(tx);
            tracing::info!(order_id, status, amount_msat, "late or short payment; failing it back");
            app.lightning.fail(payment_hash);
        }
    }
    Ok(())
}

/// What's held for an order: its payment hash, amount and preimage.
/// None for simulated payments (development), which hold nothing.
async fn held_payment(app: &App, order_id: &str) -> ApiResult<Option<(PaymentHash, u64, String)>> {
    let (hash, held_msat, preimage, simulated): (String, Option<i64>, String, bool) =
        sqlx::query_as("SELECT payment_hash, held_msat, preimage, simulated FROM orders WHERE id = $1")
            .bind(order_id)
            .fetch_one(&app.db)
            .await?;
    if simulated {
        return Ok(None);
    }
    let hash: [u8; 32] = hex::decode(&hash)
        .ok()
        .and_then(|b| b.try_into().ok())
        .ok_or_else(|| ApiError::internal(format!("order {order_id} has a bad payment hash")))?;
    let held_msat = held_msat.ok_or_else(|| ApiError::internal(format!("order {order_id} has no held payment")))?;
    Ok(Some((PaymentHash(hash), held_msat as u64, preimage)))
}

/// Development only: marks an unpaid order paid as if its invoice had
/// been paid, so the rest of the flow (buying, receipt, failing back)
/// can be tried without a Lightning wallet. Enabled by
/// DEV_SIMULATE_PAYMENTS; no auth, so bill links can be tried too.
async fn simulate_payment(State(app): State<Arc<App>>, Path(id): Path<String>) -> ApiResult<Json<Value>> {
    if !app.config.dev_simulate_payments {
        return Err(ApiError::not_found("Simulated payments are off (DEV_SIMULATE_PAYMENTS)."));
    }
    let updated = sqlx::query(
        "UPDATE orders SET status = 'paid', paid_at = now(), simulated = true
         WHERE id = $1 AND status = 'awaitingPayment' AND expires_at > now()",
    )
    .bind(&id)
    .execute(&app.db)
    .await?;
    if updated.rows_affected() == 0 {
        return Err(ApiError::conflict("unknown", "Only an unpaid order with an unexpired quote can be paid."));
    }
    app.wake_fulfilment.notify_one();
    let row: OrderRow = sqlx::query_as(&format!("SELECT {ORDER_COLUMNS} FROM orders WHERE id = $1"))
        .bind(&id)
        .fetch_one(&app.db)
        .await?;
    Ok(Json(row.to_json()))
}

// ---------------------------------------------------------------------
// Fulfilment
// ---------------------------------------------------------------------

/// Delivers paid orders. Each purchase runs in its own task, so a slow
/// provider doesn't hold up the rest.
pub async fn run_fulfilment(app: Arc<App>) {
    take_interrupted(&app).await;
    loop {
        loop {
            match next_paid_order(&app).await {
                Ok(Some(order)) => {
                    let app = app.clone();
                    tokio::spawn(async move { fulfil(&app, order).await });
                }
                Ok(None) => break,
                Err(err) => {
                    tracing::error!("picking paid orders: {err:?}");
                    break;
                }
            }
        }
        tokio::select! {
            _ = app.wake_fulfilment.notified() => {}
            _ = tokio::time::sleep(StdDuration::from_secs(5)) => {}
        }
    }
}

/// Orders that were mid-purchase when the server stopped may or may not
/// have been delivered. Like a lost provider answer: take the payment
/// (so a delivered bill isn't given away) and hold the order for review.
/// Never re-buy.
async fn take_interrupted(app: &App) {
    let interrupted: Vec<(String,)> =
        match sqlx::query_as("UPDATE orders SET needs_review = true WHERE status = 'fulfilling' AND NOT needs_review RETURNING id")
            .fetch_all(&app.db)
            .await
        {
            Ok(rows) => rows,
            Err(e) => {
                tracing::error!("checking interrupted orders: {e}");
                return;
            }
        };
    for (order_id,) in interrupted {
        tracing::warn!(order_id, "order interrupted mid-purchase; taking the payment and holding it for review");
        match held_payment(app, &order_id).await {
            Ok(Some((hash, msat, preimage))) => {
                if let Err(err) = app.lightning.claim(&hash, msat, &preimage) {
                    tracing::error!(order_id, "claiming interrupted order: {err:#}");
                }
            }
            Ok(None) => {}
            Err(err) => tracing::error!(order_id, "interrupted order: {err:?}"),
        }
    }
}

async fn next_paid_order(app: &App) -> ApiResult<Option<OrderRow>> {
    Ok(sqlx::query_as(&format!(
        "UPDATE orders SET status = 'fulfilling', fulfil_started_at = now()
         WHERE id = (SELECT id FROM orders WHERE status = 'paid' ORDER BY paid_at LIMIT 1 FOR UPDATE SKIP LOCKED)
         RETURNING {ORDER_COLUMNS}"
    ))
    .fetch_optional(&app.db)
    .await?)
}

async fn fulfil(app: &App, order: OrderRow) {
    if let Err(err) = try_fulfil(app, &order).await {
        tracing::error!(order.id, "fulfilling: {err:?}");
    }
}

async fn try_fulfil(app: &App, order: &OrderRow) -> ApiResult<()> {
    let held = held_payment(app, &order.id).await?;
    let held_hash = held.as_ref().map(|(hash, ..)| *hash);
    let fail_back = |reason: String| async move {
        if let Some(hash) = &held_hash {
            app.lightning.fail(hash);
        }
        tracing::warn!(order.id, reason, "bill not delivered; payment failed back");
        sqlx::query("UPDATE orders SET status = 'refunded', refunded_at = now(), failure_reason = $2 WHERE id = $1")
            .bind(&order.id)
            .bind(format!("{reason} Your sats went straight back to your wallet."))
            .execute(&app.db)
            .await
            .map(|_| ())
    };

    // Don't start a purchase we might not be able to take payment for.
    let height = app.lightning.node.status().current_best_block.height;
    let deadline: Option<(i32,)> = sqlx::query_as("SELECT claim_deadline FROM orders WHERE id = $1 AND claim_deadline IS NOT NULL")
        .bind(&order.id)
        .fetch_optional(&app.db)
        .await?;
    if let Some((deadline,)) = deadline {
        if (deadline as u32).saturating_sub(height) < MIN_BLOCKS_LEFT {
            return Ok(fail_back(format!("{} took too long to start.", order.biller_name)).await?);
        }
    }

    let Some(category) = Category::parse(&order.category) else {
        return Ok(fail_back("This bill type isn't supported.".into()).await?);
    };
    let purchase = Purchase {
        order_id: &order.id,
        category,
        biller_name: &order.biller_name,
        biller_code: &order.biller_code,
        plan_code: order.plan_code.as_deref(),
        plan_name: order.plan_name.as_deref(),
        option_id: order.option_id.as_deref(),
        target: &order.target,
        amount: order.amount,
    };
    match app.providers.purchase(parse_provider(&order.provider), &purchase).await {
        Fulfilment::Done(receipt) => {
            // Delivered: now take the payment.
            if let Some((hash, held_msat, preimage)) = &held {
                if let Err(err) = app.lightning.claim(hash, *held_msat, preimage) {
                    tracing::error!(order.id, "bill delivered but claiming failed: {err:#}");
                    sqlx::query("UPDATE orders SET needs_review = true WHERE id = $1").bind(&order.id).execute(&app.db).await?;
                }
            }
            tracing::info!(order.id, reference = receipt.reference, "order fulfilled and payment claimed");
            sqlx::query("UPDATE orders SET status = 'done', receipt = $2, provider_ref = $3 WHERE id = $1")
                .bind(&order.id)
                .bind(serde_json::to_value(&receipt).unwrap_or_default())
                .bind(&receipt.reference)
                .execute(&app.db)
                .await?;
        }
        Fulfilment::Failed(reason) => fail_back(reason).await?,
        Fulfilment::Unknown(detail) => {
            // It may have been delivered, so take the payment; review
            // decides whether it's done or refundable.
            tracing::error!(order.id, detail, "provider outcome unknown; payment taken, order held for review");
            if let Some((hash, held_msat, preimage)) = &held {
                app.lightning.claim(hash, *held_msat, preimage)?;
            }
            sqlx::query("UPDATE orders SET needs_review = true WHERE id = $1").bind(&order.id).execute(&app.db).await?;
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------
// Rows and JSON
// ---------------------------------------------------------------------

pub const ORDER_COLUMNS: &str = "id, status, category, biller_id, biller_name, title, target, option_id, option_name, \
    plan_id, plan_name, requested_amount, customer_name, amount, currency, sats, rate, invoice, created_at, \
    expires_at, paid_at, receipt, failure_reason, refund_requested_at, provider, biller_code, plan_code";

#[derive(FromRow)]
pub struct OrderRow {
    pub id: String,
    pub status: String,
    pub category: String,
    pub biller_id: String,
    pub biller_name: String,
    pub title: String,
    pub target: String,
    pub option_id: Option<String>,
    pub option_name: Option<String>,
    pub plan_id: Option<String>,
    pub plan_name: Option<String>,
    pub requested_amount: Option<i64>,
    pub customer_name: Option<String>,
    pub amount: i64,
    pub currency: String,
    pub sats: i64,
    pub rate: f64,
    pub invoice: String,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    pub paid_at: Option<DateTime<Utc>>,
    pub receipt: Option<Value>,
    pub failure_reason: Option<String>,
    pub refund_requested_at: Option<DateTime<Utc>>,
    pub provider: String,
    pub biller_code: String,
    pub plan_code: Option<String>,
}

impl OrderRow {
    /// `VtuOrder` JSON in the app.
    pub fn to_json(&self) -> Value {
        let status = if self.status == "awaitingPayment" && self.expires_at <= Utc::now() { "expired" } else { self.status.as_str() };
        json!({
            "id": self.id,
            "title": self.title,
            "status": status,
            "category": self.category,
            "billerId": self.biller_id,
            "billerName": self.biller_name,
            "target": self.target,
            "amount": self.amount,
            "currency": self.currency,
            "sats": self.sats,
            "rate": self.rate,
            "invoice": self.invoice,
            "createdAt": self.created_at.to_rfc3339(),
            "expiresAt": self.expires_at.to_rfc3339(),
            "request": {
                "billerId": self.biller_id,
                "target": self.target,
                "optionId": self.option_id,
                "planId": self.plan_id,
                "amount": self.requested_amount,
            },
            "planName": self.plan_name,
            "optionName": self.option_name,
            "customerName": self.customer_name,
            "paidAt": self.paid_at.map(|t| t.to_rfc3339()),
            "receipt": self.receipt,
            "failureReason": self.failure_reason,
            "refundRequested": self.status == "refundable" && self.refund_requested_at.is_some(),
        })
    }
}

async fn load_order(app: &App, user_id: Uuid, id: &str) -> ApiResult<Value> {
    Ok(order_row(app, user_id, id).await?.to_json())
}

pub async fn order_row(app: &App, user_id: Uuid, id: &str) -> ApiResult<OrderRow> {
    let row: Option<OrderRow> = sqlx::query_as(&format!("SELECT {ORDER_COLUMNS} FROM orders WHERE id = $1 AND user_id = $2"))
        .bind(id)
        .bind(user_id)
        .fetch_optional(&app.db)
        .await?;
    row.ok_or_else(|| ApiError::not_found("Order not found."))
}

fn new_order_id() -> String {
    const ALPHABET: &[u8] = b"abcdefghjkmnpqrstuvwxyz23456789";
    let mut rng = rand::thread_rng();
    (0..12).map(|_| ALPHABET[rng.gen_range(0..ALPHABET.len())] as char).collect()
}

pub fn provider_name(kind: ProviderKind) -> &'static str {
    match kind {
        ProviderKind::Fake => "fake",
        ProviderKind::SmePlug => "smeplug",
        ProviderKind::Off => "off",
    }
}

fn parse_provider(name: &str) -> ProviderKind {
    match name {
        "fake" => ProviderKind::Fake,
        "smeplug" => ProviderKind::SmePlug,
        _ => ProviderKind::Off,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tiers_match_the_app_mock() {
        assert_eq!(tier_caps(0), (10_000, 30_000));
        assert_eq!(tier_caps(1), (200_000, 1_000_000));
        let limits = limits_json(0, 2_500);
        assert_eq!(limits["usedToday"], 2_500);
        assert_eq!(limits["nextTier"]["tier"], 1);
        assert!(limits_json(1, 0)["nextTier"].is_null());
    }

    #[test]
    fn today_starts_at_lagos_midnight() {
        let start = start_of_today();
        let wat = FixedOffset::east_opt(3600).unwrap();
        assert_eq!(start.with_timezone(&wat).format("%H:%M").to_string(), "00:00");
        assert!(start <= Utc::now() && Utc::now() - start < Duration::days(1));
    }

    #[test]
    fn order_ids_are_twelve_unambiguous_chars() {
        let id = new_order_id();
        assert_eq!(id.len(), 12);
        assert!(!id.contains(['0', 'o', '1', 'l', 'i']));
    }
}
