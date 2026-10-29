//! Profile photos: upload, remove, and serve. The app uploads raw image
//! bytes and shows the returned `photoUrl` (also on `GET /v1/me`).
//!
//! The file type comes from the bytes themselves, never from what the
//! client claims, and only raster formats are accepted, so a photo can't
//! be an HTML or SVG file served from the API's origin.

use std::sync::Arc;

use axum::Json;
use axum::Router;
use axum::body::Bytes;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::header;
use axum::response::IntoResponse;
use axum::routing::{get, put};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::App;
use crate::auth::{AuthUser, random_hex};
use crate::error::{ApiError, ApiResult};

const MAX_BYTES: usize = 5 * 1024 * 1024;
const HEIF_BRANDS: [&[u8; 4]; 8] = [b"heic", b"heix", b"hevc", b"hevx", b"heim", b"heis", b"mif1", b"msf1"];

pub fn routes() -> Router<Arc<App>> {
    Router::new()
        .route(
            "/v1/me/photo",
            put(upload).post(upload).delete(remove).layer(DefaultBodyLimit::max(MAX_BYTES + 4096)),
        )
        .route("/v1/photos/{user_id}/{version}", get(serve))
}

pub fn photo_url(app: &App, user_id: Uuid, version: &str) -> String {
    format!("{}/v1/photos/{user_id}/{version}", app.config.public_url.trim_end_matches('/'))
}

/// Replaces the user's photo with the image in the request body.
async fn upload(State(app): State<Arc<App>>, AuthUser(user_id): AuthUser, body: Bytes) -> ApiResult<Json<Value>> {
    if body.is_empty() || body.len() > MAX_BYTES {
        return Err(ApiError::bad_request("Photos must be smaller than 5 MB."));
    }
    let content_type = sniff(&body).ok_or_else(|| ApiError::bad_request("Use a JPEG, PNG, WebP, HEIC or GIF photo."))?;
    let version = random_hex(8);
    sqlx::query(
        "INSERT INTO profile_photos (user_id, version, content_type, data) VALUES ($1, $2, $3, $4)
         ON CONFLICT (user_id) DO UPDATE SET version = $2, content_type = $3, data = $4, updated_at = now()",
    )
    .bind(user_id)
    .bind(&version)
    .bind(content_type)
    .bind(body.as_ref())
    .execute(&app.db)
    .await?;
    Ok(Json(json!({ "photoUrl": photo_url(&app, user_id, &version) })))
}

async fn remove(State(app): State<Arc<App>>, AuthUser(user_id): AuthUser) -> ApiResult<Json<Value>> {
    sqlx::query("DELETE FROM profile_photos WHERE user_id = $1").bind(user_id).execute(&app.db).await?;
    Ok(Json(json!({ "photoUrl": null })))
}

/// The photo itself. Public: the URL carries an unguessable version, and
/// a new upload changes it, so responses can be cached for good.
async fn serve(State(app): State<Arc<App>>, Path((user_id, version)): Path<(Uuid, String)>) -> ApiResult<impl IntoResponse> {
    let row: Option<(String, Vec<u8>)> =
        sqlx::query_as("SELECT content_type, data FROM profile_photos WHERE user_id = $1 AND version = $2")
            .bind(user_id)
            .bind(&version)
            .fetch_optional(&app.db)
            .await?;
    let (content_type, data) = row.ok_or_else(|| ApiError::not_found("Photo not found."))?;
    Ok((
        [
            (header::CONTENT_TYPE, content_type),
            (header::CACHE_CONTROL, "public, max-age=31536000, immutable".to_string()),
            (header::X_CONTENT_TYPE_OPTIONS, "nosniff".to_string()),
        ],
        data,
    ))
}

/// The image type from the file's signature ("magic") bytes, if it's one
/// of the accepted types.
fn sniff(b: &[u8]) -> Option<&'static str> {
    if b.starts_with(&[0xFF, 0xD8, 0xFF]) {
        return Some("image/jpeg");
    }
    if b.starts_with(&[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
        return Some("image/png");
    }
    if b.starts_with(b"GIF87a") || b.starts_with(b"GIF89a") {
        return Some("image/gif");
    }
    if b.len() >= 12 && &b[0..4] == b"RIFF" && &b[8..12] == b"WEBP" {
        return Some("image/webp");
    }
    // HEIC/HEIF: an ISO-BMFF "ftyp" box with a HEIF brand.
    if b.len() >= 12 && &b[4..8] == b"ftyp" && HEIF_BRANDS.iter().any(|brand| &b[8..12] == brand.as_slice()) {
        return Some("image/heic");
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognises_accepted_types_by_their_bytes() {
        assert_eq!(sniff(&[0xFF, 0xD8, 0xFF, 0xE0, 0, 0]), Some("image/jpeg"));
        assert_eq!(sniff(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0]), Some("image/png"));
        assert_eq!(sniff(b"GIF89a...."), Some("image/gif"));
        assert_eq!(sniff(b"RIFF\0\0\0\0WEBPVP8 "), Some("image/webp"));
        assert_eq!(sniff(b"\0\0\0\x18ftypheic\0\0\0\0"), Some("image/heic"));
    }

    #[test]
    fn refuses_everything_else() {
        assert_eq!(sniff(b"<svg xmlns='http://www.w3.org/2000/svg'/>"), None);
        assert_eq!(sniff(b"<html><script>alert(1)</script>"), None);
        assert_eq!(sniff(b"%PDF-1.7"), None);
        assert_eq!(sniff(b"\0\0\0\x18ftypmp42\0\0\0\0"), None);
        assert_eq!(sniff(b""), None);
    }
}
