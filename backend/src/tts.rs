//! A natural voice for the voice assistant.
//!
//! Phones' built-in text-to-speech sounds robotic. When `TTS_BASE_URL` is
//! set, the app asks this endpoint to say a sentence and plays the audio
//! it returns. The server fetches it from any OpenAI-compatible
//! `/audio/speech` API (OpenAI, Groq, a local Kokoro, or the bundled
//! `scripts/free-tts-server.py`, which uses free neural Nigerian-English
//! voices) and keeps recent answers in memory, so the assistant's fixed
//! phrases cost one call each.
//!
//! The text is only ever what the assistant is about to say back, never
//! what the user typed, and it is capped. With no voice configured the
//! endpoint answers 503 and the app falls back to the phone's own voice.

use std::collections::{HashMap, VecDeque};
use std::hash::{DefaultHasher, Hash, Hasher};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, Instant};

use axum::extract::State;
use axum::http::{HeaderValue, header};
use axum::response::{IntoResponse, Response};
use axum::routing::post;
use axum::Router;
use bytes::Bytes;
use serde::Deserialize;
use serde_json::json;
use uuid::Uuid;

use crate::App;
use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult};
use crate::json::ApiJson;

#[derive(Clone, Debug)]
pub struct TtsConfig {
    /// An OpenAI-compatible base URL, e.g. `http://127.0.0.1:5050/v1`.
    pub base_url: String,
    pub api_key: Option<String>,
    pub model: String,
    /// The default voice, used for English and anything without its own.
    pub voice: String,
    /// A voice per language code (`ha`, `yo`, `ig`, `pcm`), when set.
    pub voices: HashMap<String, String>,
}

impl TtsConfig {
    pub fn voice_for(&self, lang: Option<&str>) -> &str {
        lang.and_then(|l| self.voices.get(l)).unwrap_or(&self.voice)
    }
}

pub fn routes() -> Router<Arc<App>> {
    Router::new().route("/tts", post(speak))
}

const MAX_CHARS: usize = 320;
const CALLS_PER_MINUTE: usize = 40;
const CACHE_ENTRIES: usize = 200;
const CALL_TIMEOUT: Duration = Duration::from_secs(15);

static RECENT: LazyLock<Mutex<HashMap<Uuid, Vec<Instant>>>> = LazyLock::new(Mutex::default);
static CACHE: LazyLock<Mutex<(HashMap<u64, (Bytes, String)>, VecDeque<u64>)>> = LazyLock::new(Mutex::default);

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

fn key(voice: &str, model: &str, text: &str) -> u64 {
    let mut h = DefaultHasher::new();
    (voice, model, text).hash(&mut h);
    h.finish()
}

fn cached(k: u64) -> Option<(Bytes, String)> {
    CACHE.lock().unwrap().0.get(&k).cloned()
}

fn remember(k: u64, audio: (Bytes, String)) {
    let mut cache = CACHE.lock().unwrap();
    if cache.0.insert(k, audio).is_none() {
        cache.1.push_back(k);
        while cache.1.len() > CACHE_ENTRIES {
            if let Some(old) = cache.1.pop_front() {
                cache.0.remove(&old);
            }
        }
    }
}

#[derive(Deserialize)]
struct SpeakRequest {
    text: String,
    /// `en`, `pcm`, `ha`, `yo` or `ig`: picks the voice.
    #[serde(default)]
    lang: Option<String>,
}

/// Says a sentence and returns it as MP3.
async fn speak(State(app): State<Arc<App>>, AuthUser(user): AuthUser, ApiJson(body): ApiJson<SpeakRequest>) -> ApiResult<Response> {
    let Some(cfg) = app.config.tts.as_ref() else {
        return Err(ApiError::unavailable("unavailable", "No natural voice is set up on this server."));
    };
    let text = body.text.trim();
    if text.is_empty() || text.chars().count() > MAX_CHARS {
        return Err(ApiError::bad_request(format!("Say up to {MAX_CHARS} characters at a time.")));
    }
    let voice = cfg.voice_for(body.lang.as_deref());
    let k = key(voice, &cfg.model, text);
    let (audio, content_type) = match cached(k) {
        Some(audio) => audio,
        None => {
            if !allowed_now(user) {
                return Err(ApiError::unavailable("unavailable", "Too many voice requests. Try again in a minute."));
            }
            let mut request = app
                .http
                .post(format!("{}/audio/speech", cfg.base_url.trim_end_matches('/')))
                .timeout(CALL_TIMEOUT)
                .json(&json!({ "model": cfg.model, "input": text, "voice": voice, "response_format": "mp3" }));
            if let Some(key) = &cfg.api_key {
                request = request.bearer_auth(key);
            }
            let response = request.send().await.map_err(|e| {
                tracing::warn!("voice: request failed: {e}");
                ApiError::unavailable("unavailable", "The voice is unavailable right now.")
            })?;
            if !response.status().is_success() {
                tracing::warn!("voice: HTTP {}", response.status());
                return Err(ApiError::unavailable("unavailable", "The voice is unavailable right now."));
            }
            let content_type = response
                .headers()
                .get(header::CONTENT_TYPE)
                .and_then(|v| v.to_str().ok())
                .filter(|v| v.starts_with("audio/"))
                .unwrap_or("audio/mpeg")
                .to_string();
            let audio = response.bytes().await.map_err(|_| ApiError::unavailable("unavailable", "The voice is unavailable right now."))?;
            if audio.is_empty() {
                return Err(ApiError::unavailable("unavailable", "The voice is unavailable right now."));
            }
            remember(k, (audio.clone(), content_type.clone()));
            (audio, content_type)
        }
    };
    let mut response = audio.into_response();
    response.headers_mut().insert(header::CONTENT_TYPE, HeaderValue::from_str(&content_type).unwrap_or(HeaderValue::from_static("audio/mpeg")));
    Ok(response)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg(voice: &str) -> TtsConfig {
        TtsConfig { base_url: "http://x".into(), api_key: None, model: "m".into(), voice: voice.into(), voices: HashMap::from([("ha".to_string(), "gtts:ha".to_string())]) }
    }

    #[test]
    fn each_language_gets_its_voice_or_the_default() {
        let c = cfg("en-NG-EzinneNeural");
        assert_eq!(c.voice_for(Some("ha")), "gtts:ha");
        assert_eq!(c.voice_for(Some("yo")), "en-NG-EzinneNeural");
        assert_eq!(c.voice_for(None), "en-NG-EzinneNeural");
    }

    #[test]
    fn the_cache_key_depends_on_voice_and_text() {
        assert_eq!(key("a", "m", "hello"), key("a", "m", "hello"));
        assert_ne!(key("a", "m", "hello"), key("b", "m", "hello"));
        assert_ne!(key("a", "m", "hello"), key("a", "m", "hi"));
    }

    #[test]
    fn the_cache_is_bounded() {
        for i in 0..(CACHE_ENTRIES as u64 + 50) {
            remember(1_000_000 + i, (Bytes::from_static(b"x"), "audio/mpeg".into()));
        }
        assert!(CACHE.lock().unwrap().0.len() <= CACHE_ENTRIES);
        assert!(cached(1_000_000).is_none());
        assert!(cached(1_000_000 + CACHE_ENTRIES as u64 + 49).is_some());
    }
}
