//! The small web pages the backend serves itself: the payer page, the "ask
//! for a top-up" page and the safety page. Each is one self-contained file
//! (no external scripts, fonts or images), with the shared stylesheet and
//! translations filled in here.

use std::sync::Arc;

use axum::Router;
use axum::response::Html;
use axum::routing::get;

use crate::App;

const COMMON_CSS: &str = include_str!("../static/common.css");
const COMMON_JS: &str = include_str!("../static/common.js");

pub fn routes() -> Router<Arc<App>> {
    Router::new().route("/ask", get(ask)).route("/safety", get(safety))
}

/// A page with the shared CSS and JS filled in.
pub fn render(page: &str) -> String {
    page.replace("/*{{COMMON_CSS}}*/", COMMON_CSS).replace("/*{{COMMON_JS}}*/", COMMON_JS)
}

async fn ask() -> Html<String> {
    Html(render(include_str!("../static/ask.html")))
}

async fn safety() -> Html<String> {
    Html(render(include_str!("../static/safety.html")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_page_gets_its_shared_parts() {
        for page in [include_str!("../static/pay.html"), include_str!("../static/ask.html"), include_str!("../static/safety.html")] {
            let html = render(page);
            assert!(!html.contains("{{COMMON"), "a placeholder was left behind");
            assert!(html.contains("--ember") && html.contains("var I18N"), "shared CSS or JS is missing");
        }
    }

    #[test]
    fn pages_load_nothing_from_other_sites() {
        for page in [include_str!("../static/pay.html"), include_str!("../static/ask.html"), include_str!("../static/safety.html")] {
            let html = render(page);
            assert!(!html.contains("src=\"http") && !html.contains("href=\"http"), "a page loads something external");
        }
    }
}
