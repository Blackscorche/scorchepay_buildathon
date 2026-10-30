//! Spending policy: limits a user sets for themselves, checked on every
//! payment before an invoice is created.
//!
//! - a cap per payment and a cap per day (on top of the KYC tier limits);
//! - "trusted numbers only": payments may only go to numbers on the user's
//!   trusted list, so a mistyped number, a tricked helper or a stolen
//!   session can't send money somewhere new;
//! - a log of every decision: what was blocked and why, and what was
//!   allowed while a policy was active.
//!
//! The pure decision is `decide`; `enforce` loads the policy, applies it and
//! records blocks. The rest is the API for editing the policy.

use std::sync::Arc;

use axum::extract::{Path, Query, State};
use axum::routing::{delete, get, post};
use axum::{Json, Router};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Deserializer};
use serde_json::{Value, json};
use sqlx::PgPool;
use uuid::Uuid;

use crate::App;
use crate::auth::AuthUser;
use crate::bill_links::mask;
use crate::error::{ApiError, ApiResult, naira};
use crate::json::ApiJson;
use crate::orders::{Described, tier_caps, used_today};

const MAX_TRUSTED: i64 = 50;

pub fn routes() -> Router<Arc<App>> {
    Router::new()
        .route("/policy", get(get_policy).put(put_policy))
        .route("/policy/trusted", post(add_trusted))
        .route("/policy/trusted/{id}", delete(remove_trusted))
        .route("/policy/events", get(events))
}

/// Where a payment came from, for the log.
#[derive(Clone, Copy, Debug)]
pub enum Source {
    Order,
    Requote,
    BillLink,
    LinkPayment,
    Helper,
}

impl Source {
    fn as_str(self) -> &'static str {
        match self {
            Source::Order => "order",
            Source::Requote => "requote",
            Source::BillLink => "billLink",
            Source::LinkPayment => "linkPayment",
            Source::Helper => "helper",
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Policy {
    pub per_payment_cap: Option<i64>,
    pub daily_cap: Option<i64>,
    pub trusted_only: bool,
}

impl Policy {
    /// Nothing set: every payment passes.
    fn is_open(&self) -> bool {
        self.per_payment_cap.is_none() && self.daily_cap.is_none() && !self.trusted_only
    }
}

#[derive(Debug, PartialEq)]
pub enum Block {
    UntrustedTarget,
    OverPaymentCap { cap: i64 },
    OverDailyCap { cap: i64, remaining: i64 },
}

impl Block {
    pub fn reason(&self) -> &'static str {
        match self {
            Block::UntrustedTarget => "untrustedTarget",
            Block::OverPaymentCap { .. } => "overPaymentCap",
            Block::OverDailyCap { .. } => "overDailyCap",
        }
    }

    pub fn message(&self) -> String {
        match self {
            Block::UntrustedTarget => {
                "This number isn't on your trusted list. Add it under Safety first, or turn off \"trusted numbers only\".".into()
            }
            Block::OverPaymentCap { cap } => format!("This is over the {} per payment you set for yourself.", naira(*cap)),
            Block::OverDailyCap { cap, remaining } => {
                format!("This is over what's left of the {} a day you set for yourself ({} left).", naira(*cap), naira(*remaining))
            }
        }
    }
}

/// Whether a payment of `amount` to a target passes `policy`. The checks run
/// in order: trusted number, per-payment cap, daily cap.
pub fn decide(policy: &Policy, target_is_trusted: bool, amount: i64, used_today: i64) -> Result<(), Block> {
    if policy.trusted_only && !target_is_trusted {
        return Err(Block::UntrustedTarget);
    }
    if let Some(cap) = policy.per_payment_cap {
        if amount > cap {
            return Err(Block::OverPaymentCap { cap });
        }
    }
    if let Some(cap) = policy.daily_cap {
        let remaining = (cap - used_today).max(0);
        if amount > remaining {
            return Err(Block::OverDailyCap { cap, remaining });
        }
    }
    Ok(())
}

async fn load_policy(db: &PgPool, user_id: Uuid) -> ApiResult<Policy> {
    let row: Option<(Option<i64>, Option<i64>, bool)> =
        sqlx::query_as("SELECT per_payment_cap, daily_cap, trusted_only FROM user_policies WHERE user_id = $1")
            .bind(user_id)
            .fetch_optional(db)
            .await?;
    Ok(row.map(|(per_payment_cap, daily_cap, trusted_only)| Policy { per_payment_cap, daily_cap, trusted_only }).unwrap_or_default())
}

/// Applies `user_id`'s policy to a described bill and says what it decided,
/// without logging. The flag is whether any policy was active.
pub async fn check(app: &App, user_id: Uuid, d: &Described, excluding: Option<&str>) -> ApiResult<(bool, Result<(), Block>)> {
    let policy = load_policy(&app.db, user_id).await?;
    if policy.is_open() {
        return Ok((false, Ok(())));
    }
    let trusted = if policy.trusted_only {
        let (found,): (bool,) = sqlx::query_as("SELECT EXISTS (SELECT 1 FROM trusted_targets WHERE user_id = $1 AND target = $2)")
            .bind(user_id)
            .bind(&d.target)
            .fetch_one(&app.db)
            .await?;
        found
    } else {
        true
    };
    let used = if policy.daily_cap.is_some() { used_today(&app.db, user_id, excluding).await? } else { 0 };
    Ok((true, decide(&policy, trusted, d.amount, used)))
}

/// Applies the policy and refuses a blocked payment with `policyBlocked`,
/// logging why. Returns whether a policy was active, so a caller can log the
/// payments it allows.
pub async fn enforce(app: &App, user_id: Uuid, d: &Described, excluding: Option<&str>, source: Source) -> ApiResult<bool> {
    let (active, decision) = check(app, user_id, d, excluding).await?;
    match decision {
        Ok(()) => Ok(active),
        Err(block) => {
            log_block(app, user_id, source, &block, d).await?;
            Err(ApiError::unprocessable("policyBlocked", block.message()))
        }
    }
}

/// Logs a blocked payment.
pub async fn log_block(app: &App, user_id: Uuid, source: Source, block: &Block, d: &Described) -> ApiResult<()> {
    record(app, user_id, source, "blocked", Some(block.reason()), &block.message(), d, None).await
}

/// Logs a payment that passed an active policy.
pub async fn record_allowed(app: &App, user_id: Uuid, source: Source, d: &Described, order_id: &str) -> ApiResult<()> {
    let message = format!("{} of {} to {} passed your rules.", d.title, naira(d.amount), mask(&d.target));
    record(app, user_id, source, "allowed", None, &message, d, Some(order_id)).await
}

#[allow(clippy::too_many_arguments)]
async fn record(
    app: &App,
    user_id: Uuid,
    source: Source,
    outcome: &str,
    reason: Option<&str>,
    message: &str,
    d: &Described,
    order_id: Option<&str>,
) -> ApiResult<()> {
    sqlx::query(
        "INSERT INTO policy_events (user_id, source, outcome, reason, message, biller_name, title, target, amount, order_id)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
    )
    .bind(user_id)
    .bind(source.as_str())
    .bind(outcome)
    .bind(reason)
    .bind(message)
    .bind(&d.biller_name)
    .bind(&d.title)
    .bind(mask(&d.target))
    .bind(d.amount)
    .bind(order_id)
    .execute(&app.db)
    .await?;
    Ok(())
}

// ---------------------------------------------------------------------
// The API
// ---------------------------------------------------------------------

async fn get_policy(State(app): State<Arc<App>>, AuthUser(user_id): AuthUser) -> ApiResult<Json<Value>> {
    Ok(Json(policy_json(&app, user_id).await?))
}

async fn policy_json(app: &App, user_id: Uuid) -> ApiResult<Value> {
    let policy = load_policy(&app.db, user_id).await?;
    let (tier,): (i32,) = sqlx::query_as("SELECT kyc_tier FROM users WHERE id = $1").bind(user_id).fetch_one(&app.db).await?;
    let (tier_per_order, tier_daily) = tier_caps(tier);
    let trusted: Vec<(Uuid, String, String, DateTime<Utc>)> =
        sqlx::query_as("SELECT id, label, target, created_at FROM trusted_targets WHERE user_id = $1 ORDER BY created_at")
            .bind(user_id)
            .fetch_all(&app.db)
            .await?;
    let used = used_today(&app.db, user_id, None).await?;
    Ok(json!({
        "perPaymentCap": policy.per_payment_cap,
        "dailyCap": policy.daily_cap,
        "trustedOnly": policy.trusted_only,
        "trusted": trusted.iter().map(|(id, label, target, at)| json!({
            "id": id, "label": label, "target": target, "addedAt": at.to_rfc3339(),
        })).collect::<Vec<_>>(),
        // What the account's KYC tier already allows, which the policy can only narrow.
        "tierLimits": { "perOrder": tier_per_order, "daily": tier_daily },
        "usedToday": used,
    }))
}

/// `null` clears a cap; leaving the field out keeps it.
fn double_option<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Option<i64>>, D::Error> {
    Ok(Some(Option::deserialize(d)?))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PutPolicy {
    #[serde(default, deserialize_with = "double_option")]
    per_payment_cap: Option<Option<i64>>,
    #[serde(default, deserialize_with = "double_option")]
    daily_cap: Option<Option<i64>>,
    trusted_only: Option<bool>,
}

/// Changes the policy. Send only what changes: a number sets a cap, `null`
/// removes it, and a missing field is left alone.
async fn put_policy(State(app): State<Arc<App>>, AuthUser(user_id): AuthUser, ApiJson(body): ApiJson<PutPolicy>) -> ApiResult<Json<Value>> {
    let mut policy = load_policy(&app.db, user_id).await?;
    if let Some(cap) = body.per_payment_cap {
        policy.per_payment_cap = valid_cap(cap)?;
    }
    if let Some(cap) = body.daily_cap {
        policy.daily_cap = valid_cap(cap)?;
    }
    if let Some(on) = body.trusted_only {
        policy.trusted_only = on;
    }
    sqlx::query(
        "INSERT INTO user_policies (user_id, per_payment_cap, daily_cap, trusted_only) VALUES ($1, $2, $3, $4)
         ON CONFLICT (user_id) DO UPDATE SET per_payment_cap = $2, daily_cap = $3, trusted_only = $4, updated_at = now()",
    )
    .bind(user_id)
    .bind(policy.per_payment_cap)
    .bind(policy.daily_cap)
    .bind(policy.trusted_only)
    .execute(&app.db)
    .await?;
    Ok(Json(policy_json(&app, user_id).await?))
}

fn valid_cap(cap: Option<i64>) -> ApiResult<Option<i64>> {
    match cap {
        Some(c) if c <= 0 => Err(ApiError::bad_request("A limit must be more than ₦0. Send null to remove it.")),
        Some(c) if c > 100_000_000 => Err(ApiError::bad_request("That limit is too large.")),
        other => Ok(other),
    }
}

#[derive(Deserialize)]
struct AddTrusted {
    label: String,
    target: String,
}

async fn add_trusted(State(app): State<Arc<App>>, AuthUser(user_id): AuthUser, ApiJson(body): ApiJson<AddTrusted>) -> ApiResult<Json<Value>> {
    let label = body.label.trim();
    if label.is_empty() || label.chars().count() > 30 {
        return Err(ApiError::bad_request("Give it a name of up to 30 characters, like \"mama\"."));
    }
    let target: String = body.target.chars().filter(|c| !matches!(c, ' ' | '-')).collect();
    if !target.chars().all(|c| c.is_ascii_digit()) || !(10..=13).contains(&target.len()) {
        return Err(ApiError::bad_request("Enter a phone, meter or smartcard number: 10 to 13 digits."));
    }
    let (count,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM trusted_targets WHERE user_id = $1").bind(user_id).fetch_one(&app.db).await?;
    if count >= MAX_TRUSTED {
        return Err(ApiError::bad_request(format!("You can trust up to {MAX_TRUSTED} numbers.")));
    }
    let id = Uuid::new_v4();
    let inserted = sqlx::query("INSERT INTO trusted_targets (id, user_id, label, target) VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING")
        .bind(id)
        .bind(user_id)
        .bind(label)
        .bind(&target)
        .execute(&app.db)
        .await?;
    if inserted.rows_affected() == 0 {
        return Err(ApiError::conflict("unknown", "That number is already on your trusted list."));
    }
    Ok(Json(policy_json(&app, user_id).await?))
}

async fn remove_trusted(State(app): State<Arc<App>>, AuthUser(user_id): AuthUser, Path(id): Path<Uuid>) -> ApiResult<Json<Value>> {
    let removed = sqlx::query("DELETE FROM trusted_targets WHERE id = $1 AND user_id = $2").bind(id).bind(user_id).execute(&app.db).await?;
    if removed.rows_affected() == 0 {
        return Err(ApiError::not_found("That number isn't on your list."));
    }
    Ok(Json(policy_json(&app, user_id).await?))
}

#[derive(Deserialize)]
struct EventsQuery {
    limit: Option<i64>,
}

async fn events(State(app): State<Arc<App>>, AuthUser(user_id): AuthUser, Query(q): Query<EventsQuery>) -> ApiResult<Json<Value>> {
    type Row = (i64, DateTime<Utc>, String, String, Option<String>, String, Option<String>, Option<String>, Option<String>, Option<i64>, Option<String>);
    let rows: Vec<Row> = sqlx::query_as(
        "SELECT id, at, source, outcome, reason, message, biller_name, title, target, amount, order_id
         FROM policy_events WHERE user_id = $1 ORDER BY at DESC, id DESC LIMIT $2",
    )
    .bind(user_id)
    .bind(q.limit.unwrap_or(30).clamp(1, 100))
    .fetch_all(&app.db)
    .await?;
    Ok(Json(Value::Array(
        rows.into_iter()
            .map(|(id, at, source, outcome, reason, message, biller_name, title, target, amount, order_id)| {
                json!({
                    "id": id, "at": at.to_rfc3339(), "source": source, "outcome": outcome, "reason": reason,
                    "message": message, "billerName": biller_name, "title": title, "target": target,
                    "amount": amount, "orderId": order_id,
                })
            })
            .collect(),
    )))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn policy(per: Option<i64>, daily: Option<i64>, trusted_only: bool) -> Policy {
        Policy { per_payment_cap: per, daily_cap: daily, trusted_only }
    }

    #[test]
    fn an_empty_policy_allows_everything() {
        let p = Policy::default();
        assert!(p.is_open());
        assert_eq!(decide(&p, false, 5_000_000, 9_000_000), Ok(()));
    }

    #[test]
    fn trusted_only_blocks_new_numbers_first() {
        let p = policy(Some(100), None, true);
        // Both rules fail: the untrusted number is reported.
        assert_eq!(decide(&p, false, 500, 0), Err(Block::UntrustedTarget));
        assert_eq!(decide(&p, true, 500, 0), Err(Block::OverPaymentCap { cap: 100 }));
        assert_eq!(decide(&p, true, 100, 0), Ok(()));
    }

    #[test]
    fn the_per_payment_cap_is_inclusive() {
        let p = policy(Some(1000), None, false);
        assert_eq!(decide(&p, false, 1000, 0), Ok(()));
        assert_eq!(decide(&p, false, 1001, 0), Err(Block::OverPaymentCap { cap: 1000 }));
    }

    #[test]
    fn the_daily_cap_counts_what_is_already_spent() {
        let p = policy(None, Some(2000), false);
        assert_eq!(decide(&p, false, 500, 1500), Ok(()));
        assert_eq!(decide(&p, false, 501, 1500), Err(Block::OverDailyCap { cap: 2000, remaining: 500 }));
        // Already past the cap: nothing is left.
        assert_eq!(decide(&p, false, 1, 2500), Err(Block::OverDailyCap { cap: 2000, remaining: 0 }));
    }

    #[test]
    fn messages_name_the_rule_and_the_amounts() {
        assert!(Block::UntrustedTarget.message().contains("trusted list"));
        assert!(Block::OverPaymentCap { cap: 1000 }.message().contains("₦1,000 per payment"));
        let m = Block::OverDailyCap { cap: 2000, remaining: 500 }.message();
        assert!(m.contains("₦2,000 a day") && m.contains("₦500 left"), "{m}");
    }

    #[test]
    fn caps_are_validated() {
        assert_eq!(valid_cap(Some(500)).unwrap(), Some(500));
        assert_eq!(valid_cap(None).unwrap(), None);
        assert!(valid_cap(Some(0)).is_err());
        assert!(valid_cap(Some(-5)).is_err());
        assert!(valid_cap(Some(1_000_000_000)).is_err());
    }
}
