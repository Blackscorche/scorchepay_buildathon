//! A stand-in provider for development and demos: it spends nothing and
//! succeeds after a short delay, like `MockVtuApi` in the app.
//!
//! Test cases, by target:
//! - ending in `0000`: customer not found (meters and smartcards);
//! - ending in `9999`: the purchase fails, so the payment goes back to
//!   the payer.

use std::time::Duration;

use super::{CustomerInfo, CustomerLookup, Fulfilment, Purchase, Receipt, ReceiptItem};
use crate::catalog::Category;
use crate::error::naira;

const NAMES: [&str; 6] =
    ["ADEBAYO OLUWASEUN", "CHIOMA NWOSU", "IBRAHIM MUSA", "FUNMILAYO ADEYEMI", "EMEKA OKAFOR", "HALIMA BELLO"];
const ADDRESSES: [&str; 4] = [
    "14 Admiralty Way, Lekki, Lagos",
    "7 Aminu Kano Crescent, Wuse 2, Abuja",
    "22 Allen Avenue, Ikeja, Lagos",
    "3 Stadium Road, Port Harcourt",
];

pub async fn purchase(p: &Purchase<'_>) -> Fulfilment {
    tokio::time::sleep(Duration::from_millis(1500)).await;
    if p.target.ends_with("9999") {
        return Fulfilment::Failed(format!("{} couldn't complete this bill.", p.biller_name));
    }
    let reference = format!("FAKE-{}", p.order_id.to_uppercase());
    let amount = naira(p.amount);
    let plan = p.plan_name.unwrap_or_default();
    let receipt = match p.category {
        Category::Airtime => Receipt {
            reference,
            message: Some(format!("{amount} {} airtime sent to {}.", p.biller_name, p.target)),
            items: vec![],
        },
        Category::Data => Receipt { reference, message: Some(format!("{plan} sent to {}.", p.target)), items: vec![] },
        Category::Electricity if p.option_id == Some("postpaid") => {
            Receipt { reference, message: Some(format!("{amount} paid to meter {}.", p.target)), items: vec![] }
        }
        Category::Electricity => Receipt {
            reference,
            message: Some("Enter the token on your meter to load the units.".into()),
            items: vec![
                ReceiptItem { label: "Token".into(), value: meter_token(p.order_id), primary: true, copyable: true },
                ReceiptItem {
                    label: "Units".into(),
                    value: format!("{:.1} kWh", p.amount as f64 / 225.0),
                    primary: false,
                    copyable: false,
                },
            ],
        },
        Category::Tv => Receipt {
            reference,
            message: Some(format!("{} {plan} active on smartcard {}.", p.biller_name, p.target)),
            items: vec![],
        },
    };
    Fulfilment::Done(receipt)
}

pub fn validate_customer(category: Category, target: &str) -> CustomerLookup {
    if target.ends_with("0000") {
        return CustomerLookup::NotFound;
    }
    let seed = target.bytes().fold(0u64, |a, b| a.wrapping_mul(31).wrapping_add(b as u64)) as usize;
    CustomerLookup::Found(CustomerInfo {
        name: NAMES[seed % NAMES.len()].into(),
        address: (category == Category::Electricity).then(|| ADDRESSES[seed % ADDRESSES.len()].into()),
    })
}

/// A 20-digit prepaid token, stable per order, as `1234-5678-…`.
fn meter_token(order_id: &str) -> String {
    let seed = order_id.bytes().fold(7u64, |a, b| (a * 131 + b as u64) % 100_000_000_000);
    let digits = format!("{seed:011}{:09}", seed * 7 % 1_000_000_000);
    digits.as_bytes().chunks(4).map(|c| std::str::from_utf8(c).unwrap()).collect::<Vec<_>>().join("-")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokens_are_twenty_digits_in_groups() {
        let token = meter_token("abc123");
        assert_eq!(token.len(), 24);
        assert_eq!(token.split('-').count(), 5);
        assert_eq!(token, meter_token("abc123"));
    }

    #[test]
    fn unknown_customers_end_in_zeros() {
        assert!(matches!(validate_customer(Category::Tv, "1234560000"), CustomerLookup::NotFound));
        assert!(matches!(validate_customer(Category::Electricity, "12345678901"), CustomerLookup::Found(c) if c.address.is_some()));
    }
}
