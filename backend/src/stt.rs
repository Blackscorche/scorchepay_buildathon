//! Speech to text for languages phones can't recognise.
//!
//! Phone recognisers cover English well, and Yoruba, Hausa and Igbo only on
//! some Android phones (iPhones have none of them). So the app can record a
//! short clip and send it here; the server passes it to a Whisper model
//! (any OpenAI-compatible `/audio/transcriptions`, e.g. Groq's free
//! `whisper-large-v3`) and returns the words.
//!
//! Whisper knows Yoruba and Hausa. It has no Igbo, so for Igbo it listens
//! without being told the language and does its best. Treat Igbo as
//! experimental.
//!
//! The clip is sent to the model and thrown away: nothing is stored here.
//! It uses the same provider and key as the assistant (`LLM_BASE_URL`).

use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, Instant};

use axum::Json;
use axum::Router;
use axum::body::Bytes;
use axum::extract::{Query, State};
use axum::http::{HeaderMap, header};
use axum::routing::post;
use serde::Deserialize;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::App;
use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult};

pub fn routes() -> Router<Arc<App>> {
    Router::new().route("/stt", post(transcribe))
}

const MAX_BYTES: usize = 1_500_000;
const CALLS_PER_MINUTE: usize = 20;
const CALL_TIMEOUT: Duration = Duration::from_secs(20);

static RECENT: LazyLock<Mutex<HashMap<Uuid, Vec<Instant>>>> = LazyLock::new(Mutex::default);

fn allowed_now(user: Uuid) -> bool {
    let mut recent = RECENT.lock().unwrap();
    let now = Instant::now();
    let calls = recent.entry(user).or_default();
    calls.retain(|t| now.duration_since(*t) < Duration::from_secs(60));
    if calls.len() >= CALLS_PER_MINUTE {
        return false;
    }
    calls.push(now);
    true
}

/// The language to tell Whisper, or None to let it detect. Igbo isn't one of
/// Whisper's languages, so it is detected rather than named.
pub fn whisper_language(lang: &str) -> Option<&'static str> {
    match lang {
        "yo" => Some("yo"),
        "ha" => Some("ha"),
        "en" | "pcm" => Some("en"),
        _ => None,
    }
}

/// A file name Whisper will accept for this content type.
pub fn file_name_for(content_type: &str) -> &'static str {
    let ct = content_type.to_lowercase();
    if ct.contains("wav") {
        "speech.wav"
    } else if ct.contains("webm") {
        "speech.webm"
    } else if ct.contains("ogg") {
        "speech.ogg"
    } else if ct.contains("mpeg") || ct.contains("mp3") {
        "speech.mp3"
    } else {
        "speech.m4a"
    }
}

/// A multipart/form-data body, built by hand so no extra crate is needed.
pub fn multipart(boundary: &str, fields: &[(&str, String)], file_name: &str, content_type: &str, audio: &[u8]) -> Vec<u8> {
    let mut body = Vec::with_capacity(audio.len() + 600);
    for (name, value) in fields {
        body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n").as_bytes());
    }
    body.extend_from_slice(
        format!("--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{file_name}\"\r\nContent-Type: {content_type}\r\n\r\n").as_bytes(),
    );
    body.extend_from_slice(audio);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    body
}

#[derive(Deserialize)]
struct SttQuery {
    #[serde(default)]
    lang: Option<String>,
}

/// Words in a recording. The body is the audio itself (WAV, M4A, MP3, WebM or
/// OGG, up to 1.5 MB); `?lang=` is `yo`, `ha`, `ig`, `en` or `pcm`.
async fn transcribe(State(app): State<Arc<App>>, AuthUser(user): AuthUser, Query(q): Query<SttQuery>, headers: HeaderMap, audio: Bytes) -> ApiResult<Json<Value>> {
    let Some(cfg) = app.config.llm.as_ref() else {
        return Err(ApiError::unavailable("unavailable", "Speech recognition isn't set up on this server."));
    };
    if audio.is_empty() || audio.len() > MAX_BYTES {
        return Err(ApiError::bad_request("Send a short recording, up to about 40 seconds."));
    }
    if !allowed_now(user) {
        return Err(ApiError::unavailable("unavailable", "Too many recordings. Try again in a minute."));
    }
    let content_type = headers.get(header::CONTENT_TYPE).and_then(|v| v.to_str().ok()).unwrap_or("audio/wav").to_string();
    let boundary = format!("scorche{}", Uuid::new_v4().simple());
    let mut fields = vec![
        ("model", app.config.stt_model.clone()),
        ("response_format", "json".to_string()),
        ("temperature", "0".to_string()),
        // Do not prime the recogniser with bill words: on quiet recordings
        // it can echo the prompt as a fabricated transcript.
    ];
    if let Some(language) = q.lang.as_deref().and_then(whisper_language) {
        fields.push(("language", language.to_string()));
    }
    let body = multipart(&boundary, &fields, file_name_for(&content_type), &content_type, &audio);

    let mut request = app
        .http
        .post(format!("{}/audio/transcriptions", cfg.base_url.trim_end_matches('/')))
        .timeout(CALL_TIMEOUT)
        .header(header::CONTENT_TYPE, format!("multipart/form-data; boundary={boundary}"))
        .body(body);
    if let Some(key) = &cfg.api_key {
        request = request.bearer_auth(key);
    }
    let unavailable = || ApiError::unavailable("unavailable", "Couldn't understand the recording right now.");
    let response = request.send().await.map_err(|e| {
        tracing::warn!("speech recognition: {e}");
        unavailable()
    })?;
    if !response.status().is_success() {
        tracing::warn!("speech recognition: HTTP {}", response.status());
        return Err(unavailable());
    }
    let json: Value = response.json().await.map_err(|_| unavailable())?;
    let text: String = json["text"].as_str().unwrap_or("").trim().chars().take(400).collect();
    Ok(Json(json!({ "text": text })))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn whisper_is_told_the_language_it_knows() {
        assert_eq!(whisper_language("yo"), Some("yo"));
        assert_eq!(whisper_language("ha"), Some("ha"));
        assert_eq!(whisper_language("pcm"), Some("en"));
        // Whisper has no Igbo: detect instead of naming it.
        assert_eq!(whisper_language("ig"), None);
        assert_eq!(whisper_language("klingon"), None);
    }

    #[test]
    fn file_names_follow_the_content_type() {
        assert_eq!(file_name_for("audio/wav"), "speech.wav");
        assert_eq!(file_name_for("audio/x-wav"), "speech.wav");
        assert_eq!(file_name_for("audio/mpeg"), "speech.mp3");
        assert_eq!(file_name_for("audio/mp4"), "speech.m4a");
        assert_eq!(file_name_for("audio/webm;codecs=opus"), "speech.webm");
    }

    #[test]
    fn the_multipart_body_is_well_formed() {
        let body = multipart("B", &[("model", "m".into()), ("language", "yo".into())], "speech.wav", "audio/wav", b"RIFF");
        let text = String::from_utf8_lossy(&body);
        assert!(text.starts_with("--B\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nm\r\n"));
        assert!(text.contains("name=\"language\"\r\n\r\nyo\r\n"));
        assert!(text.contains("name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\nRIFF\r\n--B--\r\n"));
        assert!(text.ends_with("--B--\r\n"));
    }
}
