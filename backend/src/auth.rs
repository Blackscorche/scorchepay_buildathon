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

#[derive(Serialize, Deserialize)]
struct Claims {
    sub: Uuid,
    exp: i64,
}

fn issue_token(app: &App, user_id: Uuid) -> ApiResult<String> {
    let claims = Claims { sub: user_id, exp: (Utc::now() + Duration::days(SESSION_DAYS)).timestamp() };
    jsonwebtoken::encode(&Header::default(), &claims, &EncodingKey::from_secret(app.config.jwt_secret.as_bytes()))
        .map_err(ApiError::internal)
}

/// The signed-in user, from `Authorization: Bearer <token>`.
pub struct AuthUser(pub Uuid);

impl FromRequestParts<Arc<App>> for AuthUser {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, app: &Arc<App>) -> Result<Self, Self::Rejection> {
        let signed_out = || ApiError::unauthorized("Your session has ended. Log in again.");
        let token = parts
            .headers
            .get(axum::http::header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.strip_prefix("Bearer "))
            .ok_or_else(signed_out)?;
        let data = jsonwebtoken::decode::<Claims>(
            token,
            &DecodingKey::from_secret(app.config.jwt_secret.as_bytes()),
            &Validation::default(),
        )
        .map_err(|_| signed_out())?;
        Ok(AuthUser(data.claims.sub))
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

    let id = Uuid::new_v4();
    let code = format!("{:06}", rand::thread_rng().gen_range(0..1_000_000));
    let mut tx = app.db.begin().await?;
    sqlx::query("DELETE FROM otp_challenges WHERE contact = $1").bind(&contact).execute(&mut *tx).await?;
    sqlx::query("INSERT INTO otp_challenges (id, contact, code_hash, expires_at) VALUES ($1, $2, $3, $4)")
        .bind(id)
        .bind(&contact)
        .bind(hash_code(id, &code))
        .bind(Utc::now() + Duration::minutes(OTP_MINUTES))
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;

    // No SMS or email sender yet (Termii or similar plugs in here). Until
    // then the code is only logged, so this needs OTP_DEV_CODE or log access.
    tracing::info!(%contact, "sign-up code {code}");
    Ok(Json(json!({ "verificationId": id })))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct VerifyRequest {
    verification_id: Uuid,
    code: String,
}

/// Checks the code and returns a sign-up token proving the contact.
async fn verify_signup_code(State(app): State<Arc<App>>, ApiJson(body): ApiJson<VerifyRequest>) -> ApiResult<Json<Value>> {
    let row: Option<(String, i32, chrono::DateTime<Utc>, Option<String>)> = sqlx::query_as(
        "SELECT code_hash, attempts, expires_at, signup_token FROM otp_challenges WHERE id = $1",
    )
    .bind(body.verification_id)
    .fetch_optional(&app.db)
    .await?;
    let Some((code_hash, attempts, expires_at, existing_token)) = row else {
        return Err(auth_error("This code has expired. Request a new one."));
    };
    if expires_at < Utc::now() {
        return Err(auth_error("This code has expired. Request a new one."));
    }
    if attempts >= OTP_MAX_ATTEMPTS {
        return Err(auth_error("Too many attempts. Request a new code."));
    }
    let code = body.code.trim();
    let dev_match = app.config.otp_dev_code.as_deref() == Some(code);
    if !dev_match && hash_code(body.verification_id, code) != code_hash {
        sqlx::query("UPDATE otp_challenges SET attempts = attempts + 1 WHERE id = $1")
            .bind(body.verification_id)
            .execute(&app.db)
            .await?;
        return Err(auth_error("Incorrect code."));
    }
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

    let id = Uuid::new_v4();
    let pin_hash = hash_pin(&body.pin)?;
    let mut tx = app.db.begin().await?;
    let inserted = sqlx::query(
        "INSERT INTO users (id, username, display_name, contact, pin_hash) VALUES ($1, $2, $3, $4, $5)
         ON CONFLICT DO NOTHING",
    )
    .bind(id)
    .bind(&username)
    .bind(display_name)
    .bind(&contact)
    .bind(pin_hash)
    .execute(&mut *tx)
    .await?;
    if inserted.rows_affected() == 0 {
        // Lost a race for the username or contact.
        return Err(auth_error("That username or contact was just taken. Try another."));
    }
    sqlx::query("DELETE FROM otp_challenges WHERE id = $1").bind(challenge_id).execute(&mut *tx).await?;
    tx.commit().await?;
    Ok(Json(json!({ "token": issue_token(&app, id)? })))
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
    let taken: Option<(Uuid,)> = sqlx::query_as("SELECT id FROM users WHERE contact = $1")
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
