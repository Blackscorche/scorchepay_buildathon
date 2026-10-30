//! The bill helper: turns a sentence like "send ₦500 airtime to mama" or
//! "pay my NEPA ₦5000 meter 12345678901 ikeja" into a draft order.
//!
//! It only drafts. It never creates an order and never pays: the app shows
//! the draft, the user confirms, and the order then goes through the normal
//! endpoints and the same spending policy. A draft that would break the
//! policy is flagged (and logged as blocked), so a helper, or whatever is
//! driving it, can't talk its way past the user's rules.
//!
//! Parsing is rules, not a model: it understands the common ways Nigerians
//! write these requests in English and Pidgin, and a few Hausa words. That
//! keeps it free, instant, offline and predictable. The word lists are
//! deliberately small and easy to extend (`AIRTIME`, `DATA`, `POWER`, `TV`).

use std::sync::{Arc, LazyLock};

use axum::extract::State;
use axum::routing::post;
use axum::{Json, Router};
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::App;
use crate::auth::AskUser;
use crate::bill_links::mask;
use crate::catalog::{Catalog, Category, Pricing};
use crate::error::{ApiError, ApiResult, naira};
use crate::json::ApiJson;
use crate::orders::{OrderRequest, describe};
use crate::policy::{self, Source};

pub fn routes() -> Router<Arc<App>> {
    Router::new().route("/helper/draft", post(draft))
}

// Words that say what is being bought. English, Pidgin and a few Hausa.
const AIRTIME: &[&str] = &["airtime", "credit", "recharge", "top up", "topup", "top-up", "load", "kiredit", "katin waya"];
const DATA: &[&str] = &["data", "bundle", "internet", "intanet"];
const POWER: &[&str] = &["light", "nepa", "phcn", "electric", "electricity", "token", "meter", "wuta", "lantarki", "current"];
const TV: &[&str] = &["dstv", "gotv", "startimes", "star times", "cable", "subscription"];

pub(crate) const NETWORKS: &[(&str, &[&str])] = &[
    ("mtn", &["mtn"]),
    ("airtel", &["airtel"]),
    ("glo", &["glo", "globacom"]),
    ("9mobile", &["9mobile", "9 mobile", "etisalat"]),
];

/// Electricity companies, by the names people use for them.
pub(crate) const DISCOS: &[(&str, &[&str])] = &[
    ("ikedc", &["ikedc", "ikeja"]),
    ("ekedc", &["ekedc", "eko"]),
    ("aedc", &["aedc", "abuja"]),
    ("phed", &["phed", "port harcourt", "portharcourt"]),
    ("ibedc", &["ibedc", "ibadan"]),
    ("kaedco", &["kaedco", "kaduna"]),
    ("kedco", &["kedco", "kano"]),
    ("jed", &["jed", "jos", "plateau"]),
    ("eedc", &["eedc", "enugu"]),
    ("bedc", &["bedc", "benin"]),
    ("yedc", &["yedc", "yola", "adamawa"]),
];

pub(crate) const TV_PROVIDERS: &[(&str, &[&str])] = &[
    ("dstv", &["dstv", "dstv"]),
    ("gotv", &["gotv", "go tv"]),
    ("startimes", &["startimes", "star times", "startime"]),
];

/// Which network a Nigerian mobile number most likely belongs to, from its
/// first four digits. Numbers can be ported, so this is only a guess.
fn network_from_prefix(number: &str) -> Option<&'static str> {
    const MTN: &[&str] = &["0703", "0706", "0803", "0806", "0810", "0813", "0814", "0816", "0903", "0906", "0913", "0916", "0704"];
    const AIRTEL: &[&str] = &["0701", "0708", "0802", "0808", "0812", "0901", "0902", "0904", "0907", "0912"];
    const GLO: &[&str] = &["0705", "0805", "0807", "0811", "0815", "0905", "0915"];
    const NINE: &[&str] = &["0809", "0817", "0818", "0908", "0909"];
    let prefix = number.get(..4)?;
    [("mtn", MTN), ("airtel", AIRTEL), ("glo", GLO), ("9mobile", NINE)].into_iter().find(|(_, set)| set.contains(&prefix)).map(|(n, _)| n)
}

static PHONE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?:\+?234[ -]?|0)[789][01]\d[ -]?\d{3}[ -]?\d{4}").unwrap());
static LONG_DIGITS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\b\d{10,13}\b").unwrap());
static DATA_SIZE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(\d+(?:\.\d+)?)\s?(gb|mb|g)\b").unwrap());
static AMOUNT_SYMBOL: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?:₦|\bn(?:gn)?\s?)(\d[\d,]*(?:\.\d+)?)\s?([km])?\b").unwrap());
static AMOUNT_WORD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(\d[\d,]*(?:\.\d+)?)\s?([km])?\s?(?:naira|ngn|₦)").unwrap());
static AMOUNT_BARE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\b(\d[\d,]*(?:\.\d+)?)\s?([km])?\b").unwrap());

/// What the sentence says, before it's matched to the catalog.
#[derive(Debug, Default, PartialEq)]
pub struct Parsed {
    pub category: Option<Category>,
    pub network: Option<&'static str>,
    pub network_guessed: bool,
    pub disco: Option<&'static str>,
    pub tv: Option<&'static str>,
    /// A TV package name as written ("compact", "jolli").
    pub tv_package: Option<String>,
    /// A phone, meter or smartcard number, digits only.
    pub target: Option<String>,
    /// The saved name the number came from ("mama").
    pub alias: Option<String>,
    pub amount: Option<i64>,
    pub data_gb: Option<f64>,
    pub postpaid: bool,
}

fn has_word(text: &str, word: &str) -> bool {
    if word.contains(' ') || word.contains('-') {
        return text.contains(word);
    }
    text.split(|c: char| !c.is_alphanumeric()).any(|w| w == word)
}

fn has_any(text: &str, words: &[&str]) -> bool {
    words.iter().any(|w| has_word(text, w))
}

fn amount_from(captures: &regex::Captures) -> Option<i64> {
    let number: f64 = captures[1].replace(',', "").parse().ok()?;
    let factor = match captures.get(2).map(|m| m.as_str()) {
        Some("k") => 1_000.0,
        Some("m") => 1_000_000.0,
        _ => 1.0,
    };
    let amount = (number * factor).round() as i64;
    (amount > 0).then_some(amount)
}

/// `trusted` is the user's saved names and numbers, so "mama" can mean a number.
pub fn parse(text: &str, trusted: &[(String, String)]) -> Parsed {
    let mut p = Parsed::default();
    let mut rest = text.to_lowercase();

    // A saved name stands for its number.
    for (label, number) in trusted {
        if has_word(&rest, &label.to_lowercase()) {
            p.alias = Some(label.clone());
            p.target = Some(number.clone());
            break;
        }
    }

    // A number written out: a phone first, then a long meter or smartcard number.
    if let Some(m) = PHONE.find(&rest) {
        let digits: String = m.as_str().chars().filter(char::is_ascii_digit).collect();
        let number = match digits.strip_prefix("234") {
            Some(tail) => format!("0{tail}"),
            None => digits,
        };
        rest.replace_range(m.range(), " ");
        p.target = Some(number);
        p.alias = None;
    } else if let Some(m) = LONG_DIGITS.find(&rest) {
        p.target = Some(m.as_str().to_string());
        p.alias = None;
        rest.replace_range(m.range(), " ");
    }

    // A data size like "2gb" or "500mb".
    if let Some(c) = DATA_SIZE.captures(&rest) {
        if let Ok(n) = c[1].parse::<f64>() {
            p.data_gb = Some(if &c[2] == "mb" { n / 1000.0 } else { n });
        }
        let range = c.get(0).unwrap().range();
        rest.replace_range(range, " ");
    }

    // Names that contain digits ("9mobile") must not look like amounts.
    for (id, words) in NETWORKS {
        if words.iter().any(|w| has_word(&rest, w)) {
            p.network = Some(id);
            for w in *words {
                rest = rest.replace(w, " ");
            }
            break;
        }
    }

    p.amount = [&*AMOUNT_SYMBOL, &*AMOUNT_WORD, &*AMOUNT_BARE].iter().find_map(|re| re.captures(&rest).and_then(|c| amount_from(&c)));

    p.disco = DISCOS.iter().find(|(_, words)| words.iter().any(|w| has_word(&rest, w))).map(|(id, _)| *id);
    p.tv = TV_PROVIDERS.iter().find(|(_, words)| words.iter().any(|w| has_word(&rest, w))).map(|(id, _)| *id);
    p.postpaid = rest.contains("postpaid") || rest.contains("post paid");
    p.tv_package = TV_PACKAGES.iter().find(|name| has_word(&rest, name)).map(|s| s.to_string());

    p.category = if p.tv.is_some() || (p.tv_package.is_some() && has_any(&rest, TV)) {
        Some(Category::Tv)
    } else if p.data_gb.is_some() || has_any(&rest, DATA) {
        Some(Category::Data)
    } else if p.disco.is_some() || has_any(&rest, POWER) {
        Some(Category::Electricity)
    } else if has_any(&rest, AIRTIME) || (p.target.is_some() && p.amount.is_some()) {
        Some(Category::Airtime)
    } else {
        None
    };

    if matches!(p.category, Some(Category::Airtime | Category::Data)) && p.network.is_none() {
        if let Some(net) = p.target.as_deref().and_then(network_from_prefix) {
            p.network = Some(net);
            p.network_guessed = true;
        }
    }
    p
}

/// Fills what the rules missed with what a model suggested (rules win), then
/// guesses the network from the number if it's still unknown.
pub fn merge(rules: Parsed, ai: Parsed) -> Parsed {
    let mut p = Parsed {
        category: rules.category.or(ai.category),
        network: rules.network.or(ai.network),
        network_guessed: false,
        disco: rules.disco.or(ai.disco),
        tv: rules.tv.or(ai.tv),
        tv_package: rules.tv_package.or(ai.tv_package),
        target: rules.target.or(ai.target),
        alias: None,
        amount: rules.amount.or(ai.amount),
        data_gb: rules.data_gb.or(ai.data_gb),
        postpaid: rules.postpaid || ai.postpaid,
    };
    p.alias = rules.alias.or(ai.alias);
    if matches!(p.category, Some(Category::Airtime | Category::Data)) && p.network.is_none() {
        if let Some(net) = p.target.as_deref().and_then(network_from_prefix) {
            p.network = Some(net);
            p.network_guessed = true;
        }
    }
    p
}

/// TV package names across the catalog's providers.
const TV_PACKAGES: &[&str] = &["padi", "yanga", "confam", "compact", "smallie", "jinja", "jolli", "max", "nova", "basic", "classic"];

fn plan_gb(name: &str) -> Option<f64> {
    let lower = name.to_lowercase();
    let c = DATA_SIZE.captures(&lower)?;
    let n: f64 = c[1].parse().ok()?;
    Some(if &c[2] == "mb" { n / 1000.0 } else { n })
}

/// What was understood so far, even when the request isn't complete, so a
/// form can be pre-filled.
#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Partial {
    pub category: Option<&'static str>,
    pub biller_id: Option<String>,
    pub target: Option<String>,
    pub option_id: Option<String>,
    pub plan_id: Option<String>,
    pub amount: Option<i64>,
}

/// A parsed sentence matched to a catalog request, plus what's still needed.
#[derive(Debug, Default)]
pub struct Resolution {
    pub partial: Partial,
    pub request: Option<OrderRequest>,
    pub missing: Vec<&'static str>,
    pub notes: Vec<String>,
}

pub fn resolve(catalog: &Catalog, p: &Parsed) -> Resolution {
    let mut r = Resolution::default();
    if p.network_guessed {
        if let Some(net) = p.network {
            r.notes.push(format!("I guessed {} from the number. Check it.", net.to_uppercase()));
        }
    }
    let Some(category) = p.category else {
        r.missing.push("what");
        return r;
    };
    let target = p.target.clone();
    match category {
        Category::Airtime => {
            let biller = p.network.map(|n| format!("{n}-airtime"));
            r.partial = Partial { category: Some("airtime"), biller_id: biller.clone(), target: target.clone(), amount: p.amount, ..Partial::default() };
            need(&mut r, "network", biller.is_none());
            need(&mut r, "number", target.is_none());
            need(&mut r, "amount", p.amount.is_none());
            if let (Some(biller_id), Some(target)) = (biller, target) {
                if r.missing.is_empty() {
                    r.request = Some(OrderRequest { biller_id, target, option_id: None, plan_id: None, amount: p.amount });
                }
            }
        }
        Category::Data => {
            let biller = p.network.map(|n| format!("{n}-data"));
            need(&mut r, "network", biller.is_none());
            need(&mut r, "number", target.is_none());
            let plan = biller.as_deref().and_then(|b| catalog.biller(b)).and_then(|b| match (&b.pricing, p.data_gb) {
                (Pricing::Plans { plans, .. }, Some(gb)) => plans
                    .iter()
                    .filter(|pl| plan_gb(&pl.name).is_some_and(|g| (g - gb).abs() < 0.01))
                    .min_by_key(|pl| pl.amount)
                    .map(|pl| pl.id.clone()),
                _ => None,
            });
            r.partial = Partial { category: Some("data"), biller_id: biller.clone(), target: target.clone(), plan_id: plan.clone(), ..Partial::default() };
            if plan.is_none() {
                r.missing.push("plan");
                if let Some(Pricing::Plans { plans, .. }) = biller.as_deref().and_then(|b| catalog.biller(b)).map(|b| &b.pricing) {
                    let sizes: Vec<_> = plans
                        .iter()
                        .take(8)
                        .map(|pl| match &pl.validity {
                            Some(days) => format!("{} ({days})", pl.name),
                            None => pl.name.clone(),
                        })
                        .collect();
                    if !sizes.is_empty() {
                        r.notes.push(format!("Plans I can see: {}.", sizes.join(", ")));
                    }
                }
            }
            if let (Some(biller_id), Some(target), Some(plan_id)) = (biller, target, plan) {
                if r.missing.is_empty() {
                    r.request = Some(OrderRequest { biller_id, target, option_id: None, plan_id: Some(plan_id), amount: None });
                }
            }
        }
        Category::Electricity => {
            r.partial = Partial {
                category: Some("electricity"),
                biller_id: p.disco.map(str::to_string),
                target: target.clone(),
                option_id: Some(if p.postpaid { "postpaid" } else { "prepaid" }.into()),
                amount: p.amount,
                ..Partial::default()
            };
            need(&mut r, "disco", p.disco.is_none());
            need(&mut r, "meterNumber", target.is_none());
            need(&mut r, "amount", p.amount.is_none());
            if let (Some(disco), Some(target)) = (p.disco, target) {
                if r.missing.is_empty() {
                    let option = if p.postpaid { "postpaid" } else { "prepaid" };
                    if !p.postpaid {
                        r.notes.push("I assumed a prepaid meter.".into());
                    }
                    r.request = Some(OrderRequest {
                        biller_id: disco.to_string(),
                        target,
                        option_id: Some(option.into()),
                        plan_id: None,
                        amount: p.amount,
                    });
                }
            }
        }
        Category::Tv => {
            // A package name can tell the provider apart ("compact" is DStv).
            let provider = p.tv.map(str::to_string).or_else(|| {
                p.tv_package.as_ref().and_then(|name| {
                    catalog.billers.iter().filter(|b| b.category == Category::Tv).find(|b| plan_named(b, name).is_some()).map(|b| b.id.clone())
                })
            });
            need(&mut r, "provider", provider.is_none());
            need(&mut r, "smartcard", target.is_none());
            let plan = provider.as_deref().and_then(|id| catalog.biller(id)).and_then(|b| p.tv_package.as_deref().and_then(|name| plan_named(b, name)));
            r.partial = Partial { category: Some("tv"), biller_id: provider.clone(), target: target.clone(), plan_id: plan.clone(), ..Partial::default() };
            if plan.is_none() {
                r.missing.push("package");
            }
            if let (Some(biller_id), Some(target), Some(plan_id)) = (provider, target, plan) {
                if r.missing.is_empty() {
                    r.request = Some(OrderRequest { biller_id, target, option_id: None, plan_id: Some(plan_id), amount: None });
                }
            }
        }
    }
    r
}

fn need(r: &mut Resolution, what: &'static str, missing: bool) {
    if missing {
        r.missing.push(what);
    }
}

/// The ID of the plan on `biller` whose name is `name` (case-insensitive).
fn plan_named(biller: &crate::catalog::Biller, name: &str) -> Option<String> {
    match &biller.pricing {
        Pricing::Plans { plans, .. } => plans.iter().find(|p| p.name.eq_ignore_ascii_case(name)).map(|p| p.id.clone()),
        Pricing::Amount { .. } => None,
    }
}

#[derive(Deserialize)]
struct DraftRequest {
    text: String,
    /// What the user said just before, when the last try wasn't enough: it is
    /// read together with `text` ("500 naira" after "send airtime").
    #[serde(default)]
    context: Option<String>,
}

/// Reads a sentence and returns a draft order to confirm. Nothing is created.
///
/// `ready` is true only when the draft is complete, valid, and passes the
/// user's spending policy. `missing` says what to ask for next, `problems`
/// are validation errors (a bad number, say), and `policy` says whether the
/// rules would let it through, and why not.
async fn draft(State(app): State<Arc<App>>, AskUser(user_id): AskUser, ApiJson(body): ApiJson<DraftRequest>) -> ApiResult<Json<Value>> {
    Ok(Json(draft_for(&app, user_id, &body.text, body.context.as_deref()).await?))
}

/// The helper's whole job for one sentence, as JSON. Shared by the helper
/// endpoint and the assistant, which drafts bills the same way.
pub async fn draft_for(app: &Arc<App>, user_id: uuid::Uuid, said: &str, context: Option<&str>) -> ApiResult<Value> {
    let said = said.trim();
    if said.is_empty() || said.chars().count() > 300 {
        return Err(ApiError::bad_request("Write what you need in a sentence, up to 300 characters."));
    }
    let combined = match context.map(str::trim).filter(|c| !c.is_empty()) {
        Some(before) => format!("{}. {said}", before.chars().take(300).collect::<String>()),
        None => said.to_string(),
    };
    let text = combined.as_str();
    let trusted: Vec<(String, String)> =
        sqlx::query_as("SELECT label, target FROM trusted_targets WHERE user_id = $1").bind(user_id).fetch_all(&app.db).await?;
    let catalog = app.catalog().await;
    let mut parsed = parse(text, &trusted);
    let mut resolution = resolve(&catalog, &parsed);

    // The rules couldn't finish it: ask the model, if there is one.
    let mut reply: Option<String> = None;
    let mut used_ai = false;
    if app.config.llm.is_some() && (parsed.category.is_none() || !resolution.missing.is_empty()) {
        if let Some(understood) = crate::llm::interpret(&app, user_id, text, &trusted).await {
            used_ai = true;
            reply = understood.reply;
            parsed = merge(parsed, understood.parsed);
            resolution = resolve(&catalog, &parsed);
        }
    }

    let mut problems: Vec<String> = Vec::new();
    let mut summary = Value::Null;
    let mut policy_json = Value::Null;
    let mut allowed = false;
    if let Some(request) = &resolution.request {
        match describe(&app, request).await {
            Ok(d) => {
                let to = match &parsed.alias {
                    Some(alias) => format!("{alias} ({})", mask(&d.target)),
                    None => mask(&d.target),
                };
                summary = json!(format!("{} {} to {to}", naira(d.amount), d.title));
                match policy::check(&app, user_id, &d, None).await? {
                    (_, Ok(())) => {
                        allowed = true;
                        policy_json = json!({ "allowed": true });
                    }
                    (_, Err(block)) => {
                        policy::log_block(&app, user_id, Source::Helper, &block, &d).await?;
                        policy_json = json!({ "allowed": false, "reason": block.reason(), "message": block.message() });
                    }
                }
            }
            Err(e) => problems.push(e.message),
        }
    }
    if !problems.is_empty() {
        resolution.request = None;
    }
    let ready = resolution.request.is_some() && resolution.missing.is_empty() && allowed;
    Ok(json!({
        "understood": parsed.category.is_some(),
        "ready": ready,
        "request": resolution.request,
        "partial": resolution.partial,
        "summary": summary,
        "missing": resolution.missing,
        "notes": resolution.notes,
        "problems": problems,
        "policy": policy_json,
        "reply": if ready { Value::Null } else { json!(reply) },
        "usedAi": used_ai,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn none() -> Vec<(String, String)> {
        vec![]
    }

    fn mama() -> Vec<(String, String)> {
        vec![("mama".into(), "08061234567".into()), ("my meter".into(), "12345678901".into())]
    }

    #[test]
    fn plain_english_airtime() {
        let p = parse("send ₦500 airtime to 08031234567", &none());
        assert_eq!(p.category, Some(Category::Airtime));
        assert_eq!(p.amount, Some(500));
        assert_eq!(p.target.as_deref(), Some("08031234567"));
        assert_eq!((p.network, p.network_guessed), (Some("mtn"), true), "0803 is an MTN prefix");
    }

    #[test]
    fn a_number_with_spaces_is_not_mistaken_for_the_amount() {
        let p = parse("airtime 500 0803 123 4567", &none());
        assert_eq!((p.amount, p.target.as_deref()), (Some(500), Some("08031234567")));
        let p = parse("recharge 0802-123-4567 with n1,500", &none());
        assert_eq!((p.amount, p.target.as_deref(), p.network), (Some(1500), Some("08021234567"), Some("airtel")));
    }

    #[test]
    fn international_format_becomes_local() {
        let p = parse("airtel airtime 200 for +234 805 123 4567", &none());
        assert_eq!((p.target.as_deref(), p.network, p.network_guessed), (Some("08051234567"), Some("airtel"), false));
    }

    #[test]
    fn k_means_thousand() {
        assert_eq!(parse("send 5k airtime 08031234567", &none()).amount, Some(5000));
        assert_eq!(parse("load 1k credit 08031234567", &none()).amount, Some(1000));
        assert_eq!(parse("airtime 2.5k 08031234567", &none()).amount, Some(2500));
    }

    #[test]
    fn a_network_with_a_digit_is_not_an_amount() {
        let p = parse("9mobile airtime 08091234567", &none());
        assert_eq!((p.network, p.amount), (Some("9mobile"), None));
    }

    #[test]
    fn data_sizes() {
        let p = parse("buy 2GB data for 08021234567", &none());
        assert_eq!((p.category, p.data_gb, p.amount), (Some(Category::Data), Some(2.0), None));
        assert_eq!(parse("500mb for 08021234567", &none()).data_gb, Some(0.5));
        assert_eq!(parse("data 1.5gb 08021234567", &none()).data_gb, Some(1.5));
    }

    #[test]
    fn electricity_with_a_company_and_a_meter() {
        let p = parse("pay my NEPA ₦5000 meter 12345678901 ikeja", &none());
        assert_eq!(p.category, Some(Category::Electricity));
        assert_eq!((p.disco, p.amount, p.target.as_deref(), p.postpaid), (Some("ikedc"), Some(5000), Some("12345678901"), false));
        let p = parse("kaduna light postpaid 3000 meter 12345678901", &none());
        assert_eq!((p.disco, p.postpaid), (Some("kaedco"), true));
    }

    #[test]
    fn tv_by_provider_or_package() {
        let p = parse("dstv compact 1234567890", &none());
        assert_eq!((p.category, p.tv, p.tv_package.as_deref(), p.target.as_deref()), (Some(Category::Tv), Some("dstv"), Some("compact"), Some("1234567890")));
        let p = parse("renew gotv jolli smartcard 1234567890", &none());
        assert_eq!((p.tv, p.tv_package.as_deref()), (Some("gotv"), Some("jolli")));
    }

    #[test]
    fn saved_names_stand_for_numbers() {
        let p = parse("abeg load 1k credit for Mama", &mama());
        assert_eq!((p.category, p.amount, p.alias.as_deref(), p.target.as_deref()), (Some(Category::Airtime), Some(1000), Some("mama"), Some("08061234567")));
        assert_eq!(p.network, Some("mtn"), "0806 is an MTN prefix");
        // A number typed in the sentence wins over a saved name.
        let p = parse("send mama 500 airtime to 08051234567", &mama());
        assert_eq!((p.target.as_deref(), p.alias), (Some("08051234567"), None));
    }

    #[test]
    fn pidgin_and_hausa_words() {
        assert_eq!(parse("abeg put credit 200 for 08031234567", &none()).category, Some(Category::Airtime));
        assert_eq!(parse("ka saya min katin waya na 500 08031234567", &none()).category, Some(Category::Airtime));
        assert_eq!(parse("wutar lantarki 2000 meter 12345678901 kano", &none()).category, Some(Category::Electricity));
        assert_eq!(parse("buy intanet 1gb 08031234567", &none()).category, Some(Category::Data));
    }

    #[test]
    fn a_number_and_an_amount_alone_default_to_airtime() {
        assert_eq!(parse("500 08031234567", &none()).category, Some(Category::Airtime));
        assert_eq!(parse("hello there", &none()).category, None);
    }

    #[test]
    fn prefixes_map_to_networks() {
        assert_eq!(network_from_prefix("08031234567"), Some("mtn"));
        assert_eq!(network_from_prefix("08021234567"), Some("airtel"));
        assert_eq!(network_from_prefix("08051234567"), Some("glo"));
        assert_eq!(network_from_prefix("08091234567"), Some("9mobile"));
        assert_eq!(network_from_prefix("0123"), None);
    }
}
