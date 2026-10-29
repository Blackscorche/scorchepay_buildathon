//! SMEPlug (https://smeplug.ng), for airtime and data. API reference:
//! https://documenter.getpostman.com/view/2351511/SzS5umB5
//!
//! Bearer auth with the account's private key. There's no sandbox: every
//! purchase spends from the SMEPlug wallet, so use `VTU_PROVIDER=fake`
//! for development.

use std::collections::HashMap;
use std::time::Duration;

use anyhow::{Context, Result};
use serde::Deserialize;
use serde_json::{Value, json};

use super::{Fulfilment, Purchase, Receipt};
use crate::catalog::Category;

const BASE_URL: &str = "https://smeplug.ng/api/v1";
const PURCHASE_TIMEOUT: Duration = Duration::from_secs(60);

pub struct SmePlug {
    http: reqwest::Client,
    key: String,
}

/// A data plan as SMEPlug prices it to us.
#[derive(Clone, Debug, Deserialize)]
pub struct DataPlan {
    pub id: String,
    pub name: String,
    #[serde(deserialize_with = "number_or_string")]
    pub price: f64,
}

impl SmePlug {
    pub fn new(http: reqwest::Client, key: String) -> Self {
        Self { http, key }
    }

    /// Data plans per SMEPlug network ID (1 MTN, 2 Airtel, 3 9mobile, 4 Glo).
    pub async fn data_plans(&self) -> Result<HashMap<String, Vec<DataPlan>>> {
        let json: Value = self
            .http
            .get(format!("{BASE_URL}/data/plans"))
            .bearer_auth(&self.key)
            .timeout(Duration::from_secs(15))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        anyhow::ensure!(json["status"] == json!(true), "SMEPlug data plans: {json}");
        serde_json::from_value(json["data"].clone()).context("SMEPlug data plans")
    }

    pub async fn purchase(&self, p: &Purchase<'_>) -> Fulfilment {
        let (path, body) = match p.category {
            Category::Airtime => (
                "airtime/purchase",
                json!({
                    "network_id": p.biller_code,
                    "phone": p.target,
                    "amount": p.amount,
                    "customer_reference": p.order_id,
                }),
            ),
            Category::Data => (
                "data/purchase",
                json!({
                    "network_id": p.biller_code,
                    "plan_id": p.plan_code,
                    "phone": p.target,
                    "customer_reference": p.order_id,
                }),
            ),
            _ => return Fulfilment::Failed("SMEPlug doesn't sell this bill.".into()),
        };

        let response = self
            .http
            .post(format!("{BASE_URL}/{path}"))
            .bearer_auth(&self.key)
            .timeout(PURCHASE_TIMEOUT)
            .json(&body)
            .send()
            .await;
        let response = match response {
            Ok(r) => r,
            // Never reached SMEPlug, so nothing was bought.
            Err(e) if e.is_connect() => return Fulfilment::Failed(format!("{} is unreachable right now.", p.biller_name)),
            Err(e) => return Fulfilment::Unknown(format!("SMEPlug request failed after sending: {e}")),
        };
        let status = response.status();
        let json: Value = match response.json().await {
            Ok(json) => json,
            Err(e) => return Fulfilment::Unknown(format!("SMEPlug {status}, unreadable body: {e}")),
        };
        parse_purchase(status, &json, p)
    }
}

fn parse_purchase(status: reqwest::StatusCode, json: &Value, p: &Purchase<'_>) -> Fulfilment {
    if json["status"] == json!(true) {
        let data = &json["data"];
        return Fulfilment::Done(Receipt {
            reference: data["reference"].as_str().unwrap_or(p.order_id).to_string(),
            message: data["msg"].as_str().map(str::to_string),
            items: vec![],
        });
    }
    if status.is_server_error() {
        return Fulfilment::Unknown(format!("SMEPlug {status}: {json}"));
    }
    // A refusal (bad number, out of stock, low wallet balance).
    tracing::warn!(%status, %json, order = p.order_id, "SMEPlug refused purchase");
    Fulfilment::Failed(format!("{} couldn't complete this purchase.", p.biller_name))
}

fn number_or_string<'de, D: serde::Deserializer<'de>>(d: D) -> Result<f64, D::Error> {
    match Value::deserialize(d)? {
        Value::Number(n) => n.as_f64().ok_or_else(|| serde::de::Error::custom("bad number")),
        Value::String(s) => s.trim().parse().map_err(serde::de::Error::custom),
        other => Err(serde::de::Error::custom(format!("expected a price, got {other}"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn purchase() -> Purchase<'static> {
        Purchase {
            order_id: "ord1",
            category: Category::Airtime,
            biller_name: "MTN",
            biller_code: "1",
            plan_code: None,
            plan_name: None,
            option_id: None,
            target: "08031234567",
            amount: 100,
        }
    }

    #[test]
    fn reads_documented_success() {
        let json = json!({"status": true, "data": {"reference": "53d202a6f23740ed2828", "msg": "20 airtime purchase for 09061668519"}});
        match parse_purchase(reqwest::StatusCode::OK, &json, &purchase()) {
            Fulfilment::Done(r) => assert_eq!(r.reference, "53d202a6f23740ed2828"),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn refusals_fail_and_server_errors_are_unknown() {
        let refused = json!({"status": false, "msg": "Insufficient balance"});
        assert!(matches!(parse_purchase(reqwest::StatusCode::BAD_REQUEST, &refused, &purchase()), Fulfilment::Failed(_)));
        assert!(matches!(
            parse_purchase(reqwest::StatusCode::BAD_GATEWAY, &json!({}), &purchase()),
            Fulfilment::Unknown(_)
        ));
    }

    #[test]
    fn parses_documented_plans() {
        let json = json!({"1": [{"id": "1", "name": "500MB [SME]", "price": "220", "telco_price": "0"}]});
        let plans: HashMap<String, Vec<DataPlan>> = serde_json::from_value(json).unwrap();
        assert_eq!(plans["1"][0].price, 220.0);
    }
}
