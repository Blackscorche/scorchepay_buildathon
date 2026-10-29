//! The companies that deliver bills. Airtime and data go to SMEPlug;
//! electricity and TV to N3TData once it's wired up. Each has a fake
//! stand-in for development (`fake.rs`).

pub mod fake;
pub mod smeplug;

use serde::Serialize;

use crate::catalog::Category;
use crate::config::ProviderKind;

/// What a purchase came to.
#[derive(Debug)]
pub enum Fulfilment {
    Done(Receipt),
    /// The provider refused or failed it: nothing was delivered, so the
    /// order can be refunded. The message is shown to the user.
    Failed(String),
    /// The answer was lost (timeout, server error after sending). It may
    /// or may not have been delivered, so it's held for review instead of
    /// being refunded automatically.
    Unknown(String),
}

/// `OrderReceipt` in the app.
#[derive(Debug, Serialize)]
pub struct Receipt {
    pub reference: String,
    pub message: Option<String>,
    pub items: Vec<ReceiptItem>,
}

#[derive(Debug, Serialize)]
pub struct ReceiptItem {
    pub label: String,
    pub value: String,
    pub primary: bool,
    pub copyable: bool,
}

/// One purchase, as a provider needs it.
pub struct Purchase<'a> {
    /// Our order ID, sent as the provider's customer reference.
    pub order_id: &'a str,
    pub category: Category,
    pub biller_name: &'a str,
    /// The biller's code at the provider (e.g. SMEPlug's network ID).
    pub biller_code: &'a str,
    /// The plan's code at the provider, for plan billers.
    pub plan_code: Option<&'a str>,
    pub plan_name: Option<&'a str>,
    pub option_id: Option<&'a str>,
    pub target: &'a str,
    pub amount: i64,
}

pub struct CustomerInfo {
    pub name: String,
    pub address: Option<String>,
}

pub enum CustomerLookup {
    Found(CustomerInfo),
    NotFound,
}

pub struct Providers {
    pub smeplug: Option<smeplug::SmePlug>,
}

impl Providers {
    pub async fn purchase(&self, provider: ProviderKind, purchase: &Purchase<'_>) -> Fulfilment {
        match provider {
            ProviderKind::Fake => fake::purchase(purchase).await,
            ProviderKind::SmePlug => match &self.smeplug {
                Some(client) => client.purchase(purchase).await,
                None => Fulfilment::Failed("This biller isn't set up.".into()),
            },
            ProviderKind::Off => Fulfilment::Failed("This biller is unavailable.".into()),
        }
    }

    pub async fn validate_customer(
        &self,
        provider: ProviderKind,
        category: Category,
        target: &str,
    ) -> anyhow::Result<CustomerLookup> {
        match provider {
            ProviderKind::Fake => Ok(fake::validate_customer(category, target)),
            // SMEPlug sells airtime and data only, which need no check.
            ProviderKind::SmePlug | ProviderKind::Off => anyhow::bail!("no customer check for this provider"),
        }
    }
}
