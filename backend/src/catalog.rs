//! `GET /catalog?country=NG`: the billers, each describing its own order
//! form (docs/VTU.md). Serialises to the app's `Catalog` JSON; provider
//! codes stay on the server.
//!
//! Airtime and data come from SMEPlug (its live data plans, plus a
//! markup) or the fake provider; electricity and TV from the fake
//! provider until N3TData is wired up.

use std::sync::Arc;
use std::time::{Duration, Instant};

use serde::Serialize;
use tokio::sync::Mutex;

use crate::config::{Config, ProviderKind};
use crate::providers::smeplug::SmePlug;

const CACHE_FOR: Duration = Duration::from_secs(10 * 60);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Category {
    Airtime,
    Data,
    Electricity,
    Tv,
}

impl Category {
    pub fn as_str(self) -> &'static str {
        match self {
            Category::Airtime => "airtime",
            Category::Data => "data",
            Category::Electricity => "electricity",
            Category::Tv => "tv",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        [Category::Airtime, Category::Data, Category::Electricity, Category::Tv].into_iter().find(|c| c.as_str() == value)
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct Target {
    pub kind: &'static str,
    pub label: &'static str,
    pub hint: &'static str,
    pub pattern: &'static str,
    #[serde(rename = "errorText")]
    pub error_text: &'static str,
}

#[derive(Clone, Debug, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Pricing {
    Amount { label: &'static str, min: Option<i64>, max: Option<i64>, presets: Vec<i64> },
    Plans { label: &'static str, plans: Vec<Plan> },
}

#[derive(Clone, Debug, Serialize)]
pub struct Plan {
    pub id: String,
    pub name: String,
    pub amount: i64,
    pub validity: Option<String>,
    #[serde(skip)]
    pub provider_code: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct Options {
    pub label: &'static str,
    pub choices: Vec<Choice>,
}

#[derive(Clone, Debug, Serialize)]
pub struct Choice {
    pub id: &'static str,
    pub name: &'static str,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Biller {
    pub id: String,
    pub category: Category,
    pub name: String,
    pub short_name: Option<String>,
    pub brand_color: Option<String>,
    pub target: Target,
    pub pricing: Pricing,
    pub options: Option<Options>,
    pub customer_check: bool,
    pub available: bool,
    #[serde(skip)]
    pub provider: ProviderKind,
    /// The biller's code at its provider (e.g. SMEPlug's network ID).
    #[serde(skip)]
    pub provider_code: String,
}

impl Biller {
    pub fn plan(&self, id: Option<&str>) -> Option<&Plan> {
        match &self.pricing {
            Pricing::Plans { plans, .. } => plans.iter().find(|p| Some(p.id.as_str()) == id),
            Pricing::Amount { .. } => None,
        }
    }

    pub fn option(&self, id: Option<&str>) -> Option<&Choice> {
        self.options.as_ref()?.choices.iter().find(|c| Some(c.id) == id)
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct Catalog {
    pub country: &'static str,
    pub currency: &'static str,
    pub billers: Vec<Biller>,
}

impl Catalog {
    pub fn biller(&self, id: &str) -> Option<&Biller> {
        self.billers.iter().find(|b| b.id == id)
    }
}

/// Builds the catalog and keeps it for a few minutes, since SMEPlug's
/// plan list changes rarely.
pub struct CatalogSource {
    airtime_data: ProviderKind,
    bills: ProviderKind,
    data_markup_percent: u32,
    cached: Mutex<Option<(Arc<Catalog>, Instant)>>,
}

impl CatalogSource {
    pub fn new(config: &Config) -> Self {
        Self {
            airtime_data: config.airtime_data_provider,
            bills: config.bills_provider,
            data_markup_percent: config.data_markup_percent,
            cached: Mutex::new(None),
        }
    }

    pub async fn get(&self, smeplug: Option<&SmePlug>) -> Arc<Catalog> {
        let mut cached = self.cached.lock().await;
        if let Some((catalog, at)) = &*cached {
            if at.elapsed() < CACHE_FOR {
                return catalog.clone();
            }
        }
        let catalog = Arc::new(self.build(smeplug).await);
        // Don't keep a catalog missing SMEPlug's plans for long.
        let healthy = catalog.billers.iter().all(|b| b.available || b.provider == ProviderKind::Off);
        let at = if healthy { Instant::now() } else { Instant::now() - CACHE_FOR + Duration::from_secs(30) };
        *cached = Some((catalog.clone(), at));
        catalog
    }

    async fn build(&self, smeplug: Option<&SmePlug>) -> Catalog {
        let mut billers = Vec::new();

        // SMEPlug network IDs: 1 MTN, 2 Airtel, 3 9mobile, 4 Glo.
        let networks = [("mtn", "MTN", "#FFCC08", "1"), ("airtel", "Airtel", "#FF3B30", "2"), ("glo", "Glo", "#00A651", "4"), ("9mobile", "9mobile", "#00A99D", "3")];

        let smeplug_plans = match (self.airtime_data, smeplug) {
            (ProviderKind::SmePlug, Some(client)) => match client.data_plans().await {
                Ok(plans) => Some(plans),
                Err(err) => {
                    tracing::warn!("SMEPlug data plans: {err:#}");
                    None
                }
            },
            _ => None,
        };

        for (id, name, color, code) in networks {
            billers.push(Biller {
                id: format!("{id}-airtime"),
                category: Category::Airtime,
                name: name.into(),
                short_name: None,
                brand_color: Some(color.into()),
                target: PHONE,
                pricing: Pricing::Amount { label: "Amount", min: Some(50), max: None, presets: vec![100, 200, 500, 1000, 2000, 5000] },
                options: None,
                customer_check: false,
                available: self.airtime_data != ProviderKind::Off,
                provider: self.airtime_data,
                provider_code: code.into(),
            });
        }

        for (i, (id, name, color, code)) in networks.into_iter().enumerate() {
            let (plans, available) = match self.airtime_data {
                ProviderKind::SmePlug => match smeplug_plans.as_ref().and_then(|p| p.get(code)) {
                    Some(list) => (
                        list.iter()
                            .map(|p| Plan {
                                id: format!("{id}-sp{}", p.id),
                                name: p.name.clone(),
                                amount: with_markup(p.price, self.data_markup_percent),
                                validity: None,
                                provider_code: p.id.clone(),
                            })
                            .collect::<Vec<_>>(),
                        true,
                    ),
                    None => (vec![], false),
                },
                ProviderKind::Fake => (fake_data_plans(id, i), true),
                ProviderKind::Off => (vec![], false),
            };
            billers.push(Biller {
                id: format!("{id}-data"),
                category: Category::Data,
                name: name.into(),
                short_name: None,
                brand_color: Some(color.into()),
                target: PHONE,
                available: available && !plans.is_empty(),
                pricing: Pricing::Plans { label: "Choose a plan", plans },
                options: None,
                customer_check: false,
                provider: self.airtime_data,
                provider_code: code.into(),
            });
        }

        let bills_on = self.bills != ProviderKind::Off;
        for (id, name, short, color) in DISCOS {
            billers.push(Biller {
                id: id.into(),
                category: Category::Electricity,
                name: name.into(),
                short_name: Some(short.into()),
                brand_color: Some(color.into()),
                target: METER,
                pricing: Pricing::Amount { label: "Amount", min: Some(1000), max: Some(500_000), presets: vec![2000, 5000, 10_000, 20_000] },
                options: Some(Options {
                    label: "Meter type",
                    choices: vec![Choice { id: "prepaid", name: "Prepaid" }, Choice { id: "postpaid", name: "Postpaid" }],
                }),
                customer_check: true,
                available: bills_on,
                provider: self.bills,
                provider_code: id.into(),
            });
        }

        for (id, name, color, plans) in TV {
            billers.push(Biller {
                id: id.into(),
                category: Category::Tv,
                name: name.into(),
                short_name: None,
                brand_color: Some(color.into()),
                target: SMARTCARD,
                pricing: Pricing::Plans {
                    label: "Choose a package",
                    plans: plans
                        .iter()
                        .map(|(plan_id, plan_name, price)| Plan {
                            id: format!("{id}-{plan_id}"),
                            name: (*plan_name).into(),
                            amount: *price,
                            validity: Some("1 month".into()),
                            provider_code: (*plan_id).into(),
                        })
                        .collect(),
                },
                options: None,
                customer_check: true,
                available: bills_on,
                provider: self.bills,
                provider_code: id.into(),
            });
        }

        Catalog { country: "NG", currency: "NGN", billers }
    }
}

/// Our price for a plan SMEPlug sells at `cost`: the markup, rounded up
/// to the next ₦10.
fn with_markup(cost: f64, percent: u32) -> i64 {
    let price = cost * (1.0 + percent as f64 / 100.0);
    ((price / 10.0).ceil() * 10.0) as i64
}

fn fake_data_plans(network: &str, index: usize) -> Vec<Plan> {
    let sizes = [("1gb-1d", "1GB", "1 day", 500), ("1gb-7d", "1GB", "7 days", 800), ("2gb-30d", "2GB", "30 days", 1500), ("5gb-30d", "5GB", "30 days", 3500), ("10gb-30d", "10GB", "30 days", 6000), ("20gb-30d", "20GB", "30 days", 10_000)];
    sizes
        .iter()
        .enumerate()
        .map(|(i, (plan_id, size, validity, price))| Plan {
            id: format!("{network}-{plan_id}"),
            name: (*size).into(),
            // Small per-network differences, like real price lists.
            amount: price + if index == 0 { 0 } else { (i as i64 + 1) * 50 },
            validity: Some((*validity).into()),
            provider_code: (*plan_id).into(),
        })
        .collect()
}

const PHONE: Target = Target {
    kind: "phone",
    label: "Phone number",
    hint: "0803 123 4567",
    pattern: r"^0[789][01]\d{8}$",
    error_text: "Enter an 11-digit Nigerian number, like 0803 123 4567.",
};

const METER: Target = Target {
    kind: "number",
    label: "Meter number",
    hint: "11 to 13 digits",
    pattern: r"^\d{11,13}$",
    error_text: "Meter numbers are 11 to 13 digits.",
};

const SMARTCARD: Target = Target {
    kind: "number",
    label: "Smartcard (IUC) number",
    hint: "10 or 11 digits",
    pattern: r"^\d{10,11}$",
    error_text: "Smartcard numbers are 10 or 11 digits.",
};

const DISCOS: [(&str, &str, &str, &str); 5] = [
    ("ikedc", "Ikeja Electric", "Ikeja", "#E30613"),
    ("ekedc", "Eko Electric", "Eko", "#0072BC"),
    ("aedc", "Abuja Electric", "Abuja", "#00A651"),
    ("phed", "Port Harcourt Electric", "PH", "#F7941D"),
    ("ibedc", "Ibadan Electric", "Ibadan", "#662D91"),
];

type TvPlans = &'static [(&'static str, &'static str, i64)];

const TV: [(&str, &str, &str, TvPlans); 3] = [
    ("dstv", "DStv", "#0098DA", &[("padi", "Padi", 4400), ("yanga", "Yanga", 6000), ("confam", "Confam", 11_000), ("compact", "Compact", 19_000)]),
    ("gotv", "GOtv", "#5BB947", &[("smallie", "Smallie", 1900), ("jinja", "Jinja", 3900), ("jolli", "Jolli", 5800), ("max", "Max", 8500)]),
    ("startimes", "StarTimes", "#F28C00", &[("nova", "Nova", 2100), ("basic", "Basic", 4000), ("classic", "Classic", 6000)]),
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn marks_up_to_the_next_ten() {
        assert_eq!(with_markup(220.0, 5), 240); // 231 → 240
        assert_eq!(with_markup(400.0, 0), 400);
    }

    #[tokio::test]
    async fn fake_catalog_matches_the_app_shape() {
        let source = CatalogSource {
            airtime_data: ProviderKind::Fake,
            bills: ProviderKind::Fake,
            data_markup_percent: 5,
            cached: Mutex::new(None),
        };
        let catalog = source.get(None).await;
        let json = serde_json::to_value(&*catalog).unwrap();
        let mtn_data = json["billers"].as_array().unwrap().iter().find(|b| b["id"] == "mtn-data").unwrap();
        assert_eq!(mtn_data["category"], "data");
        assert_eq!(mtn_data["pricing"]["type"], "plans");
        assert_eq!(mtn_data["pricing"]["plans"][0]["id"], "mtn-1gb-1d");
        assert!(mtn_data["pricing"]["plans"][0].get("provider_code").is_none());
        let ikeja = json["billers"].as_array().unwrap().iter().find(|b| b["id"] == "ikedc").unwrap();
        assert_eq!(ikeja["options"]["choices"][1]["id"], "postpaid");
        assert_eq!(ikeja["target"]["errorText"], "Meter numbers are 11 to 13 digits.");
        assert_eq!(ikeja["customerCheck"], true);
    }
}
