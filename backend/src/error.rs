use axum::Json;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde_json::json;

/// An API error: an HTTP status, a machine-readable code and a
/// user-facing message. Serialised as
/// `{"error": {"code": "overLimit", "message": "…"}}`. VTU codes match
/// `VtuErrorCode` in the app (docs/VTU.md).
#[derive(Debug)]
pub struct ApiError {
    pub status: StatusCode,
    pub code: &'static str,
    pub message: String,
}

pub type ApiResult<T> = Result<T, ApiError>;

impl ApiError {
    pub fn new(status: StatusCode, code: &'static str, message: impl Into<String>) -> Self {
        Self { status, code, message: message.into() }
    }

    pub fn bad_request(message: impl Into<String>) -> Self {
        Self::new(StatusCode::BAD_REQUEST, "invalid", message)
    }

    pub fn unauthorized(message: impl Into<String>) -> Self {
        Self::new(StatusCode::UNAUTHORIZED, "signedOut", message)
    }

    pub fn not_found(message: impl Into<String>) -> Self {
        Self::new(StatusCode::NOT_FOUND, "notFound", message)
    }

    pub fn conflict(code: &'static str, message: impl Into<String>) -> Self {
        Self::new(StatusCode::CONFLICT, code, message)
    }

    pub fn unprocessable(code: &'static str, message: impl Into<String>) -> Self {
        Self::new(StatusCode::UNPROCESSABLE_ENTITY, code, message)
    }

    pub fn unavailable(code: &'static str, message: impl Into<String>) -> Self {
        Self::new(StatusCode::SERVICE_UNAVAILABLE, code, message)
    }

    pub fn internal(err: impl std::fmt::Display) -> Self {
        tracing::error!("internal error: {err}");
        Self::new(StatusCode::INTERNAL_SERVER_ERROR, "unknown", "Something went wrong. Try again.")
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let body = json!({ "error": { "code": self.code, "message": self.message } });
        (self.status, Json(body)).into_response()
    }
}

impl From<sqlx::Error> for ApiError {
    fn from(err: sqlx::Error) -> Self {
        Self::internal(err)
    }
}

impl From<anyhow::Error> for ApiError {
    fn from(err: anyhow::Error) -> Self {
        Self::internal(format!("{err:#}"))
    }
}

/// `₦12,500`.
pub fn naira(amount: i64) -> String {
    let digits = amount.abs().to_string();
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(c);
    }
    format!("{}₦{out}", if amount < 0 { "-" } else { "" })
}

/// `12,500 sats`.
pub fn sats(amount: i64) -> String {
    let n = naira(amount);
    format!("{} sats", n.replace('₦', ""))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_naira() {
        assert_eq!(naira(0), "₦0");
        assert_eq!(naira(999), "₦999");
        assert_eq!(naira(1000), "₦1,000");
        assert_eq!(naira(1234567), "₦1,234,567");
        assert_eq!(sats(21000), "21,000 sats");
    }
}
