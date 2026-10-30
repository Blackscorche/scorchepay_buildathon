//! Accounts and sessions: sign-up (contact OTP, then profile and PIN),
//! PIN login, and the bearer-token extractor every user route uses.
//! Mirrors `BackendService` in the app; messages match its mock.

use std::sync::{Arc, LazyLock};

use argon2::password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use argon2::password_hash::rand_core::OsRng;
use argon2::Argon2;
use axum::extract::{FromRequestParts, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, post};
use axum::{Json, Router};
use chrono::{Duration, Utc};
use jsonwebtoken::{DecodingKey, EncodingKey, Header, Validation};
use ldk_node::bitcoin::hashes::{Hash, sha256};
use rand::Rng;
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::App;
use crate::json::ApiJson;
use crate::error::{ApiError, ApiResult};

const SESSION_DAYS: i64 = 30;
const OTP_MINUTES: i64 = 10;
const OTP_MAX_ATTEMPTS: i32 = 5;
const MAX_FAILED_LOGINS: i32 = 5;
const LOCKOUT_MINUTES: i64 = 15;

static USERNAME: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[a-z0-9_.]{3,20}$").unwrap());
static EMAIL: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[^\s@]+@[^\s@]+\.[^\s@]+$").unwrap());
static PHONE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\+?\d{10,15}$").unwrap());
static PIN: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\d{4}$").unwrap());

pub fn routes() -> Router<Arc<App>> {
    Router::new()
        .route("/dev/status", get(dev_status))
        .route("/dev/demo-account", post(dev_demo_account))
        .route("/auth/ask/start", post(ask_start))
        .route("/auth/ask/verify", post(ask_verify))
        .route("/auth/signup/code", post(request_signup_code))
        .route("/auth/signup/verify", post(verify_signup_code))
        .route("/auth/usernames/{username}", get(check_username))
        .route("/auth/signup", post(sign_up))
        .route("/auth/login", post(login))
        .route("/me", get(me).patch(update_me))
}

fn auth_error(message: impl Into<String>) -> ApiError {
    ApiError::new(StatusCode::BAD_REQUEST, "auth", message)
}

// ---------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------

/// What a session may do. `full` is a normal login. `ask` comes from the
/// "ask for a top-up" page (phone code only, no PIN): it can create and view
/// bill links, check customers and use the bill helper, and nothing else.
const FULL: &str = "full";
const ASK: &str = "ask";
const ASK_SESSION_HOURS: i64 = 24;

#[derive(Serialize, Deserialize)]
struct Claims {
    sub: Uuid,
    exp: i64,
    /// Tokens issued before scopes existed are full sessions.
    #[serde(default = "full_scope")]
    scope: String,
}

fn full_scope() -> String {
    FULL.into()
}

fn issue_token(app: &App, user_id: Uuid) -> ApiResult<String> {
    issue(app, user_id, FULL, Duration::days(SESSION_DAYS))
}

fn issue(app: &App, user_id: Uuid, scope: &str, lasts: Duration) -> ApiResult<String> {
    let claims = Claims { sub: user_id, exp: (Utc::now() + lasts).timestamp(), scope: scope.into() };
    jsonwebtoken::encode(&Header::default(), &claims, &EncodingKey::from_secret(app.config.jwt_secret.as_bytes()))
        .map_err(ApiError::internal)
}

fn claims_from(parts: &Parts, app: &App) -> Result<Claims, ApiError> {
    let signed_out = || ApiError::unauthorized("Your session has ended. Log in again.");
    let token = parts
        .headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .ok_or_else(signed_out)?;
    jsonwebtoken::decode::<Claims>(token, &DecodingKey::from_secret(app.config.jwt_secret.as_bytes()), &Validation::default())
        .map(|data| data.claims)
        .map_err(|_| signed_out())
}

/// The signed-in user, from `Authorization: Bearer <token>`. Only a full
/// login: a session from the "ask" page is refused.
pub struct AuthUser(pub Uuid);

impl FromRequestParts<Arc<App>> for AuthUser {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, app: &Arc<App>) -> Result<Self, Self::Rejection> {
        let claims = claims_from(parts, app)?;
        if claims.scope != FULL {
            return Err(ApiError::new(
                StatusCode::FORBIDDEN,
                "forbidden",
                "This session can only ask for top-ups. Log in with your PIN to do more.",
            ));
        }
        Ok(AuthUser(claims.sub))
    }
}

/// A user who may ask for top-ups: a full login or an "ask" session.
pub struct AskUser(pub Uuid);

impl FromRequestParts<Arc<App>> for AskUser {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, app: &Arc<App>) -> Result<Self, Self::Rejection> {
        let claims = claims_from(parts, app)?;
        if claims.scope != FULL && claims.scope != ASK {
            return Err(ApiError::unauthorized("Your session has ended. Log in again."));
        }
        Ok(AskUser(claims.sub))
    }
}

// ---------------------------------------------------------------------
// Sign-up
// ---------------------------------------------------------------------

#[derive(Deserialize)]
struct CodeRequest {
    contact: String,
}

/// Sends a sign-up OTP and returns the challenge's ID. Asking again for
/// the same contact replaces the earlier code (resend).
async fn request_signup_code(State(app): State<Arc<App>>, ApiJson(body): ApiJson<CodeRequest>) -> ApiResult<Json<Value>> {
    let contact = normalize_contact(&body.contact).ok_or_else(|| auth_error("Enter a valid phone number or email."))?;
    ensure_contact_free(&app, &contact).await?;
    let id = create_otp(&app, &contact).await?;
    Ok(Json(json!({ "verificationId": id })))
}

/// Makes (or replaces) a code for `contact` and returns the challenge's ID.
async fn create_otp(app: &App, contact: &str) -> ApiResult<Uuid> {
    let id = Uuid::new_v4();
    let code = format!("{:06}", rand::thread_rng().gen_range(0..1_000_000));
    let mut tx = app.db.begin().await?;
    sqlx::query("DELETE FROM otp_challenges WHERE contact = $1").bind(contact).execute(&mut *tx).await?;
    sqlx::query("INSERT INTO otp_challenges (id, contact, code_hash, expires_at) VALUES ($1, $2, $3, $4)")
        .bind(id)
        .bind(contact)
        .bind(hash_code(id, &code))
        .bind(Utc::now() + Duration::minutes(OTP_MINUTES))
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;

    // No SMS or email sender yet (Termii or similar plugs in here). Until
    // then the code is only logged, so this needs OTP_DEV_CODE or log access.
    tracing::info!(%contact, "one-time code {code}");
    Ok(id)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct VerifyRequest {
    verification_id: Uuid,
    code: String,
}

/// A code that checked out: the contact it proves, and the sign-up token
/// already issued for it, if any.
struct Verified {
    contact: String,
    existing_token: Option<String>,
}

/// Checks a one-time code: not expired, not guessed at too often, correct.
async fn check_code(app: &App, verification_id: Uuid, code: &str) -> ApiResult<Verified> {
    let row: Option<(String, String, i32, chrono::DateTime<Utc>, Option<String>)> = sqlx::query_as(
        "SELECT contact, code_hash, attempts, expires_at, signup_token FROM otp_challenges WHERE id = $1",
    )
    .bind(verification_id)
    .fetch_optional(&app.db)
    .await?;
    let Some((contact, code_hash, attempts, expires_at, existing_token)) = row else {
        return Err(auth_error("This code has expired. Request a new one."));
    };
    if expires_at < Utc::now() {
        return Err(auth_error("This code has expired. Request a new one."));
    }
    if attempts >= OTP_MAX_ATTEMPTS {
        return Err(auth_error("Too many attempts. Request a new code."));
    }
    let code = code.trim();
    let dev_match = app.config.otp_dev_code.as_deref() == Some(code);
    if !dev_match && hash_code(verification_id, code) != code_hash {
        sqlx::query("UPDATE otp_challenges SET attempts = attempts + 1 WHERE id = $1").bind(verification_id).execute(&app.db).await?;
        return Err(auth_error("Incorrect code."));
    }
    Ok(Verified { contact, existing_token })
}

/// Checks the code and returns a sign-up token proving the contact.
async fn verify_signup_code(State(app): State<Arc<App>>, ApiJson(body): ApiJson<VerifyRequest>) -> ApiResult<Json<Value>> {
    let Verified { existing_token, .. } = check_code(&app, body.verification_id, &body.code).await?;
    let token = match existing_token {
        Some(token) => token,
        None => {
            let token = random_hex(24);
            sqlx::query("UPDATE otp_challenges SET signup_token = $2 WHERE id = $1")
                .bind(body.verification_id)
                .bind(&token)
                .execute(&app.db)
                .await?;
            token
        }
    };
    Ok(Json(json!({ "signUpToken": token })))
}

async fn check_username(State(app): State<Arc<App>>, Path(username): Path<String>) -> ApiResult<Json<Value>> {
    let name = valid_username(&username)?;
    ensure_username_free(&app, &name, None).await?;
    Ok(Json(json!({ "available": true })))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SignUpRequest {
    sign_up_token: String,
    display_name: String,
    username: String,
    pin: String,
}

/// Creates the account (tier 0, unverified) and signs it in.
async fn sign_up(State(app): State<Arc<App>>, ApiJson(body): ApiJson<SignUpRequest>) -> ApiResult<Json<Value>> {
    let expired = || auth_error("Your verification has expired. Please start sign-up again.");
    let challenge: Option<(Uuid, String, chrono::DateTime<Utc>)> =
        sqlx::query_as("SELECT id, contact, expires_at FROM otp_challenges WHERE signup_token = $1")
            .bind(&body.sign_up_token)
            .fetch_optional(&app.db)
            .await?;
    // Sign-up tokens outlive the code a little: the profile step takes time.
    let (challenge_id, contact, expires_at) = challenge.ok_or_else(expired)?;
    if expires_at + Duration::minutes(30) < Utc::now() {
        return Err(expired());
    }
    if !PIN.is_match(&body.pin) {
        return Err(auth_error("Use a four-digit PIN."));
    }
    let display_name = body.display_name.trim();
    if display_name.is_empty() || display_name.chars().count() > 80 {
        return Err(auth_error("Enter your name."));
    }
    let username = valid_username(&body.username)?;
    ensure_username_free(&app, &username, None).await?;
    ensure_contact_free(&app, &contact).await?;

    let pin_hash = hash_pin(&body.pin)?;
    let taken = || auth_error("That username or contact was just taken. Try another.");
    let mut tx = app.db.begin().await?;
    // Someone who asked for a top-up before has a guest account on this
    // contact. Signing up claims it, so their links and history stay theirs.
    let guest: Option<(Uuid,)> = sqlx::query_as("SELECT id FROM users WHERE contact = $1 AND is_guest FOR UPDATE")
        .bind(&contact)
        .fetch_optional(&mut *tx)
        .await?;
    let id = match guest {
        Some((id,)) => {
            let claimed = sqlx::query(
                "UPDATE users SET username = $2, display_name = $3, pin_hash = $4, is_guest = false, failed_logins = 0,
                    locked_until = NULL WHERE id = $1",
            )
            .bind(id)
            .bind(&username)
            .bind(display_name)
            .bind(&pin_hash)
            .execute(&mut *tx)
            .await;
            match claimed {
                Ok(_) => id,
                Err(sqlx::Error::Database(e)) if e.is_unique_violation() => return Err(taken()),
                Err(e) => return Err(e.into()),
            }
        }
        None => {
            let id = Uuid::new_v4();
            let inserted = sqlx::query(
                "INSERT INTO users (id, username, display_name, contact, pin_hash) VALUES ($1, $2, $3, $4, $5)
                 ON CONFLICT DO NOTHING",
            )
            .bind(id)
            .bind(&username)
            .bind(display_name)
            .bind(&contact)
            .bind(&pin_hash)
            .execute(&mut *tx)
            .await?;
            if inserted.rows_affected() == 0 {
                return Err(taken());
            }
            id
        }
    };
    sqlx::query("DELETE FROM otp_challenges WHERE id = $1").bind(challenge_id).execute(&mut *tx).await?;
    tx.commit().await?;
    Ok(Json(json!({ "token": issue_token(&app, id)? })))
}

// ---------------------------------------------------------------------
// Asking for a top-up without an account
// ---------------------------------------------------------------------

/// Sends a code to a phone number or email, for the "ask for a top-up" page.
/// Unlike sign-up it works for numbers that already have an account.
async fn ask_start(State(app): State<Arc<App>>, ApiJson(body): ApiJson<CodeRequest>) -> ApiResult<Json<Value>> {
    let contact = normalize_contact(&body.contact).ok_or_else(|| auth_error("Enter a valid phone number or email."))?;
    let id = create_otp(&app, &contact).await?;
    // With OTP_DEV_CODE set (development), say so, so the page can show a hint.
    Ok(Json(json!({ "verificationId": id, "demoCode": app.config.otp_dev_code })))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AskVerify {
    verification_id: Uuid,
    code: String,
    /// What to call a new person, so the payer knows who is asking.
    name: Option<String>,
}

/// Checks the code and returns an "ask" session: it can create and view bill
/// links, check customers and use the bill helper, and nothing else. A
/// number with no account gets a guest account (no PIN) to own its links.
async fn ask_verify(State(app): State<Arc<App>>, ApiJson(body): ApiJson<AskVerify>) -> ApiResult<Json<Value>> {
    let Verified { contact, .. } = check_code(&app, body.verification_id, &body.code).await?;
    let name = body.name.as_deref().map(str::trim).filter(|n| !n.is_empty());
    if name.is_some_and(|n| n.chars().count() > 80) {
        return Err(auth_error("Use a name of up to 80 characters."));
    }

    let existing: Option<(Uuid, String, bool)> = sqlx::query_as("SELECT id, display_name, is_guest FROM users WHERE contact = $1")
        .bind(&contact)
        .fetch_optional(&app.db)
        .await?;
    let (id, display_name, is_guest) = match existing {
        Some((id, display_name, true)) if name.is_some() && name != Some(display_name.as_str()) => {
            let name = name.unwrap_or_default();
            sqlx::query("UPDATE users SET display_name = $2 WHERE id = $1").bind(id).bind(name).execute(&app.db).await?;
            (id, name.to_string(), true)
        }
        Some((id, display_name, is_guest)) => (id, display_name, is_guest),
        None => {
            let name = name.ok_or_else(|| auth_error("Enter your name, so they know it's you."))?;
            let id = Uuid::new_v4();
            // No PIN: the account is unusable for a PIN login until it's claimed.
            let unusable = hash_pin(&random_hex(16))?;
            sqlx::query(
                "INSERT INTO users (id, username, display_name, contact, pin_hash, is_guest) VALUES ($1, $2, $3, $4, $5, true)
                 ON CONFLICT DO NOTHING",
            )
            .bind(id)
            .bind(format!("guest_{}", random_hex(5)))
            .bind(name)
            .bind(&contact)
            .bind(unusable)
            .execute(&app.db)
            .await?;
            // Another request may have created it first: read back whichever won.
            let (id, display_name, is_guest): (Uuid, String, bool) =
                sqlx::query_as("SELECT id, display_name, is_guest FROM users WHERE contact = $1").bind(&contact).fetch_one(&app.db).await?;
            (id, display_name, is_guest)
        }
    };
    sqlx::query("DELETE FROM otp_challenges WHERE id = $1").bind(body.verification_id).execute(&app.db).await?;
    let token = issue(&app, id, ASK, Duration::hours(ASK_SESSION_HOURS))?;
    Ok(Json(json!({ "token": token, "displayName": display_name, "isGuest": is_guest })))
}

// ---------------------------------------------------------------------
// Development helpers (DEV_SIMULATE_PAYMENTS)
// ---------------------------------------------------------------------

fn require_dev(app: &App) -> ApiResult<()> {
    if app.config.dev_simulate_payments {
        Ok(())
    } else {
        Err(ApiError::not_found("Development features are off (DEV_SIMULATE_PAYMENTS)."))
    }
}

/// Whether this server offers development helpers. 404 when it doesn't.
async fn dev_status(State(app): State<Arc<App>>) -> ApiResult<Json<Value>> {
    require_dev(&app)?;
    Ok(Json(json!({ "demoAccounts": true, "simulatePayments": true })))
}

/// A throwaway account for trying the API and the web pages: signed in,
/// tier 0, with a known PIN. Only in development.
async fn dev_demo_account(State(app): State<Arc<App>>) -> ApiResult<Json<Value>> {
    require_dev(&app)?;
    let id = Uuid::new_v4();
    let tag = random_hex(3);
    let username = format!("demo_{tag}");
    let pin = "1234";
    sqlx::query("INSERT INTO users (id, username, display_name, contact, pin_hash) VALUES ($1, $2, 'Demo user', $3, $4)")
        .bind(id)
        .bind(&username)
        .bind(format!("demo-{tag}@demo.local"))
        .bind(hash_pin(pin)?)
        .execute(&app.db)
        .await?;
    Ok(Json(json!({ "username": username, "pin": pin, "token": issue_token(&app, id)? })))
}

// ---------------------------------------------------------------------
// Login and profile
// ---------------------------------------------------------------------

#[derive(Deserialize)]
struct LoginRequest {
    username: String,
    pin: String,
}

async fn login(State(app): State<Arc<App>>, ApiJson(body): ApiJson<LoginRequest>) -> ApiResult<Json<Value>> {
    let name = normalize_username(&body.username);
    let row: Option<(Uuid, String, i32, Option<chrono::DateTime<Utc>>)> =
        sqlx::query_as("SELECT id, pin_hash, failed_logins, locked_until FROM users WHERE username = $1")
            .bind(&name)
            .fetch_optional(&app.db)
            .await?;
    let Some((id, pin_hash, failed, locked_until)) = row else {
        return Err(auth_error("Unknown user. Check your username."));
    };
    if locked_until.is_some_and(|t| t > Utc::now()) {
        return Err(auth_error("Too many wrong PINs. Try again in a few minutes."));
    }
    if !verify_pin(&body.pin, &pin_hash) {
        let failed = failed + 1;
        let lock = (failed >= MAX_FAILED_LOGINS).then(|| Utc::now() + Duration::minutes(LOCKOUT_MINUTES));
        sqlx::query("UPDATE users SET failed_logins = $2, locked_until = $3 WHERE id = $1")
            .bind(id)
            .bind(if lock.is_some() { 0 } else { failed })
            .bind(lock)
            .execute(&app.db)
            .await?;
        return Err(auth_error("Incorrect PIN."));
    }
    sqlx::query("UPDATE users SET failed_logins = 0, locked_until = NULL WHERE id = $1")
        .bind(id)
        .execute(&app.db)
        .await?;
    Ok(Json(json!({ "token": issue_token(&app, id)? })))
}

/// `GET /me`: what `BackendService.getUser` builds the app state from.
async fn me(State(app): State<Arc<App>>, AuthUser(user_id): AuthUser) -> ApiResult<Json<Value>> {
    Ok(Json(user_json(&app, user_id).await?))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct UpdateMe {
    username: Option<String>,
    display_name: Option<String>,
}

async fn update_me(
    State(app): State<Arc<App>>,
    AuthUser(user_id): AuthUser,
    ApiJson(body): ApiJson<UpdateMe>,
) -> ApiResult<Json<Value>> {
    if let Some(username) = body.username {
        let name = valid_username(&username)?;
        ensure_username_free(&app, &name, Some(user_id)).await?;
        sqlx::query("UPDATE users SET username = $2 WHERE id = $1").bind(user_id).bind(name).execute(&app.db).await?;
    }
    if let Some(display_name) = body.display_name {
        let display_name = display_name.trim();
        if display_name.is_empty() || display_name.chars().count() > 80 {
            return Err(auth_error("Enter your name."));
        }
        sqlx::query("UPDATE users SET display_name = $2 WHERE id = $1")
            .bind(user_id)
            .bind(display_name)
            .execute(&app.db)
            .await?;
    }
    Ok(Json(user_json(&app, user_id).await?))
}

pub async fn user_json(app: &App, user_id: Uuid) -> ApiResult<Value> {
    let row: Option<(String, String, i32, String, Option<String>)> = sqlx::query_as(
        "SELECT u.username, u.display_name, u.kyc_tier, u.kyc_status, p.version
         FROM users u LEFT JOIN profile_photos p ON p.user_id = u.id WHERE u.id = $1",
    )
    .bind(user_id)
    .fetch_optional(&app.db)
    .await?;
    let (username, display_name, tier, status, photo) =
        row.ok_or_else(|| ApiError::unauthorized("Your session has ended. Log in again."))?;
    Ok(json!({
        "id": user_id,
        "username": username,
        "displayName": display_name,
        "kyc": { "tier": tier, "status": status },
        "photoUrl": photo.map(|version| crate::photos::photo_url(app, user_id, &version)),
    }))
}

// ---------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------

fn normalize_username(username: &str) -> String {
    let name = username.trim().to_lowercase();
    name.strip_prefix('@').map(str::to_string).unwrap_or(name)
}

fn valid_username(username: &str) -> ApiResult<String> {
    let name = normalize_username(username);
    if !USERNAME.is_match(&name) {
        return Err(auth_error("Usernames are 3–20 characters: letters, numbers, \"_\" or \"."));
    }
    Ok(name)
}

/// Lowercased email, or a phone number without spaces, dashes or brackets.
fn normalize_contact(contact: &str) -> Option<String> {
    let value = contact.trim();
    if value.contains('@') {
        let email = value.to_lowercase();
        return EMAIL.is_match(&email).then_some(email);
    }
    let phone: String = value.chars().filter(|c| !matches!(c, ' ' | '-' | '(' | ')')).collect();
    PHONE.is_match(&phone).then_some(phone)
}

async fn ensure_username_free(app: &App, name: &str, except: Option<Uuid>) -> ApiResult<()> {
    let taken: Option<(Uuid,)> = sqlx::query_as("SELECT id FROM users WHERE username = $1")
        .bind(name)
        .fetch_optional(&app.db)
        .await?;
    match taken {
        Some((id,)) if Some(id) != except => Err(ApiError::conflict("usernameTaken", "That username is taken.")),
        _ => Ok(()),
    }
}

async fn ensure_contact_free(app: &App, contact: &str) -> ApiResult<()> {
    // A guest account (made by the "ask" page) doesn't count: signing up with
    // its contact claims it.
    let taken: Option<(Uuid,)> = sqlx::query_as("SELECT id FROM users WHERE contact = $1 AND NOT is_guest")
        .bind(contact)
        .fetch_optional(&app.db)
        .await?;
    if taken.is_some() {
        return Err(auth_error("An account already uses this phone number or email. Log in instead."));
    }
    Ok(())
}

fn hash_code(challenge: Uuid, code: &str) -> String {
    sha256::Hash::hash(format!("{challenge}:{code}").as_bytes()).to_string()
}

fn hash_pin(pin: &str) -> ApiResult<String> {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default().hash_password(pin.as_bytes(), &salt).map(|h| h.to_string()).map_err(ApiError::internal)
}

fn verify_pin(pin: &str, hash: &str) -> bool {
    PasswordHash::new(hash).is_ok_and(|parsed| Argon2::default().verify_password(pin.as_bytes(), &parsed).is_ok())
}

pub fn random_hex(bytes: usize) -> String {
    let mut buf = vec![0u8; bytes];
    rand::rngs::OsRng.fill(&mut buf[..]);
    hex::encode(buf)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_contacts() {
        assert_eq!(normalize_contact(" Ada@Example.com ").as_deref(), Some("ada@example.com"));
        assert_eq!(normalize_contact("0803 123-4567").as_deref(), Some("08031234567"));
        assert_eq!(normalize_contact("+234 (803) 123 4567").as_deref(), Some("+2348031234567"));
        assert_eq!(normalize_contact("nope"), None);
    }

    #[test]
    fn validates_usernames() {
        assert_eq!(valid_username("@Scorche").unwrap(), "scorche");
        assert!(valid_username("ab").is_err());
        assert!(valid_username("has space").is_err());
    }

    #[test]
    fn hashes_and_checks_pins() {
        let hash = hash_pin("1234").unwrap();
        assert!(verify_pin("1234", &hash));
        assert!(!verify_pin("4321", &hash));
    }
}
