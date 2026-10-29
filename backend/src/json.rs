//! Request bodies and errors that behave the same for every HTTP client.
//!
//! - [`ApiJson`] reads a JSON body whatever its `Content-Type` is. Dart's
//!   `http.post` sends `text/plain` unless told otherwise, which axum's own
//!   `Json` extractor refuses with a 415.
//! - [`OptionalApiJson`] treats an empty body as "no body", for endpoints
//!   where the body is optional. Clients often send a JSON content type
//!   with nothing in it.
//! - [`json_errors`] rewrites any error that isn't already JSON (an unknown
//!   route, a wrong method, a rejected query string) into the standard
//!   `{"error": {"code", "message"}}` shape.

use axum::body::{Body, Bytes, to_bytes};
use axum::extract::{FromRequest, Request};
use axum::http::{StatusCode, header};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use serde::de::DeserializeOwned;

use crate::error::ApiError;

pub struct ApiJson<T>(pub T);

impl<S: Send + Sync, T: DeserializeOwned> FromRequest<S> for ApiJson<T> {
    type Rejection = ApiError;

    async fn from_request(req: Request, state: &S) -> Result<Self, ApiError> {
        let bytes = read(req, state).await?;
        if is_blank(&bytes) {
            return Err(ApiError::bad_request("This request needs a JSON body."));
        }
        parse(&bytes).map(ApiJson)
    }
}

pub struct OptionalApiJson<T>(pub Option<T>);

impl<S: Send + Sync, T: DeserializeOwned> FromRequest<S> for OptionalApiJson<T> {
    type Rejection = ApiError;

    async fn from_request(req: Request, state: &S) -> Result<Self, ApiError> {
        let bytes = read(req, state).await?;
        if is_blank(&bytes) || bytes.as_ref() == b"null" {
            return Ok(OptionalApiJson(None));
        }
        parse(&bytes).map(|v| OptionalApiJson(Some(v)))
    }
}

async fn read<S: Send + Sync>(req: Request, state: &S) -> Result<Bytes, ApiError> {
    Bytes::from_request(req, state).await.map_err(|_| ApiError::bad_request("Couldn't read the request body."))
}

fn is_blank(bytes: &[u8]) -> bool {
    bytes.iter().all(u8::is_ascii_whitespace)
}

fn parse<T: DeserializeOwned>(bytes: &[u8]) -> Result<T, ApiError> {
    serde_json::from_slice(bytes).map_err(|e| ApiError::bad_request(format!("Invalid request body: {e}")))
}

/// Turns errors that aren't already JSON into the standard error shape.
pub async fn json_errors(req: Request, next: Next) -> Response {
    let response = next.run(req).await;
    let status = response.status();
    if !(status.is_client_error() || status.is_server_error()) {
        return response;
    }
    let is_json = response
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v.starts_with("application/json"));
    if is_json {
        return response;
    }

    // Any text the framework put in the body (e.g. why a query string was
    // rejected) is kept as the message.
    let (parts, body) = response.into_parts();
    let detail = to_bytes(Body::new(body), 2048).await.ok().and_then(|b| String::from_utf8(b.to_vec()).ok());
    let detail = detail.map(|d| d.trim().to_string()).filter(|d| !d.is_empty());

    let (code, message) = match status {
        StatusCode::NOT_FOUND => ("notFound", "There's no endpoint at that address.".to_string()),
        StatusCode::METHOD_NOT_ALLOWED => ("invalid", "That method isn't allowed on this endpoint.".to_string()),
        s if s.is_client_error() => ("invalid", detail.unwrap_or_else(|| "The request couldn't be understood.".into())),
        _ => ("unknown", "Something went wrong. Try again.".to_string()),
    };
    let mut response = ApiError::new(status, code, message).into_response();
    // Keep headers the handler set that still apply (e.g. `Allow` on a 405).
    if let Some(allow) = parts.headers.get(header::ALLOW) {
        response.headers_mut().insert(header::ALLOW, allow.clone());
    }
    response
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blank_bodies_are_recognised() {
        assert!(is_blank(b""));
        assert!(is_blank(b" \n\t"));
        assert!(!is_blank(b"{}"));
    }

    #[test]
    fn parse_reports_the_problem() {
        #[derive(serde::Deserialize, Debug)]
        struct Body {
            #[allow(dead_code)]
            name: String,
        }
        let err = parse::<Body>(b"{}").unwrap_err();
        assert_eq!(err.code, "invalid");
        assert!(err.message.contains("missing field `name`"), "{}", err.message);
        assert!(parse::<Body>(br#"{"name": "Ada"}"#).is_ok());
    }
}
