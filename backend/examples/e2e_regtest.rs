//! End-to-end test on a local regtest network, with real Lightning
//! payments: a second LDK node plays the user's wallet and pays the
//! backend's invoices. Run it through `scripts/e2e-regtest.sh`, which
//! starts bitcoind and the backend first.
//!
//! Checks that payments are held until the bill is delivered:
//! - a delivered bill takes the payment;
//! - a failed bill hands it back (the payer keeps their sats);
//! - paying an invoice a requote replaced is refused;
//! - a bill link can be paid by someone without an account;
//! - an order that already exists can be shared and paid by someone else,
//!   even after its owner requotes it;
//! - requests that trip up real HTTP clients get a proper JSON answer;
//! - profile photos upload, show on /me, serve, and delete;
//! - the payer's balance only drops for delivered bills.

use std::str::FromStr;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail, ensure};
use ldk_node::bitcoin::Network;
use ldk_node::bitcoin::secp256k1::PublicKey;
use ldk_node::lightning::ln::msgs::SocketAddress;
use ldk_node::lightning_invoice::Bolt11Invoice;
use ldk_node::{Builder, Event, Node};
use serde_json::{Value, json};

struct Env {
    api: String,
    admin_token: String,
    rpc_url: String,
    rpc_user: String,
    rpc_password: String,
    backend_ldk: String,
    http: reqwest::Client,
}

#[tokio::main(flavor = "multi_thread")]
async fn main() -> Result<()> {
    let env = Env {
        api: std::env::var("E2E_API").unwrap_or_else(|_| "http://127.0.0.1:8181".into()),
        admin_token: std::env::var("ADMIN_TOKEN").context("ADMIN_TOKEN")?,
        rpc_url: std::env::var("E2E_RPC_URL").unwrap_or_else(|_| "http://127.0.0.1:18443".into()),
        rpc_user: std::env::var("E2E_RPC_USER").unwrap_or_else(|_| "scorche".into()),
        rpc_password: std::env::var("E2E_RPC_PASSWORD").unwrap_or_else(|_| "scorche".into()),
        backend_ldk: std::env::var("E2E_BACKEND_LDK").unwrap_or_else(|_| "127.0.0.1:9737".into()),
        http: reqwest::Client::new(),
    };

    // 1. A funded bitcoind wallet.
    let _ = env.rpc("createwallet", json!(["e2e"])).await;
    let _ = env.rpc("loadwallet", json!(["e2e"])).await;
    let miner = env.rpc("getnewaddress", json!([])).await?;
    env.rpc("generatetoaddress", json!([101, miner])).await?;
    step("bitcoind regtest wallet funded");

    // 2. The payer: an LDK node standing in for the user's wallet.
    let dir = std::env::temp_dir().join(format!("scorchepay-e2e-payer-{}", std::process::id()));
    let (host, port) = env.rpc_url.trim_start_matches("http://").rsplit_once(':').unwrap();
    let mut builder = Builder::new();
    builder
        .set_runtime(tokio::runtime::Handle::current())
        .set_network(Network::Regtest)
        .set_storage_dir_path(dir.to_string_lossy().into())
        .set_chain_source_bitcoind_rpc(host.into(), port.parse()?, env.rpc_user.clone(), env.rpc_password.clone());
    let payer = builder.build()?;
    payer.start()?;
    let address = payer.onchain_payment().new_address()?;
    env.rpc("sendtoaddress", json!([address.to_string(), 0.02])).await?;
    env.mine(6, &miner).await?;
    wait("payer sees its on-chain funds", Duration::from_secs(60), || {
        let _ = payer.sync_wallets();
        payer.list_balances().spendable_onchain_balance_sats > 0
    })
    .await?;
    step(&format!("payer node {} has 2,000,000 sats on-chain", short(&payer.node_id().to_string())));

    // 3. A channel from the payer to the backend (the backend's inbound).
    let backend: Value = env.admin("/admin/node").await?;
    let backend_id = PublicKey::from_str(backend["nodeId"].as_str().unwrap())?;
    let addr = SocketAddress::from_str(&env.backend_ldk).map_err(|e| anyhow::anyhow!("{e:?}"))?;
    payer.open_channel(backend_id, addr, 1_000_000, None, None)?;
    let opened = Instant::now();
    loop {
        tokio::time::sleep(Duration::from_secs(2)).await;
        env.mine(1, &miner).await?;
        let _ = payer.sync_wallets();
        let ours = payer.list_channels().iter().any(|c| c.is_usable);
        let theirs: Value = env.admin("/admin/node").await?;
        let theirs = theirs["channels"].as_array().is_some_and(|c| c.iter().any(|c| c["usable"] == true));
        if ours && theirs {
            break;
        }
        ensure!(opened.elapsed() < Duration::from_secs(120), "channel didn't become usable");
    }
    drain(&payer);
    step("1,000,000 sat channel open: payer → ScorchePay");
    let start_balance = lightning_balance(&payer);

    // 4. A user.
    let token = env.sign_up().await?;
    step("signed up through the API");

    // 5. A bill that's delivered: the payment is taken.
    let order = env.order(&token, "08031234567").await?;
    let sats = order["sats"].as_i64().unwrap();
    pay(&payer, order["invoice"].as_str().unwrap())?;
    let done = env.wait_for_status(&token, order["id"].as_str().unwrap(), &["done"]).await?;
    expect_payment(&payer, true).await?;
    step(&format!(
        "₦500 airtime delivered and {sats} sats claimed: \"{}\"",
        done["receipt"]["message"].as_str().unwrap_or_default()
    ));

    // 6. A bill the provider can't deliver: the payment goes back.
    let failing = env.order(&token, "08031239999").await?;
    pay(&payer, failing["invoice"].as_str().unwrap())?;
    let refunded = env.wait_for_status(&token, failing["id"].as_str().unwrap(), &["refunded"]).await?;
    expect_payment(&payer, false).await?;
    step(&format!("failed bill handed the payment back: \"{}\"", refunded["failureReason"].as_str().unwrap_or_default()));

    // 7. An invoice replaced by a requote can't be paid.
    let stale = env.order(&token, "08031234567").await?;
    let id = stale["id"].as_str().unwrap();
    let fresh: Value = env.call(&token, "POST", &format!("/v1/vtu/orders/{id}/quote"), None).await?;
    ensure!(fresh["invoice"] != stale["invoice"], "requote kept the same invoice");
    pay(&payer, stale["invoice"].as_str().unwrap())?;
    expect_payment(&payer, false).await?;
    let still: Value = env.call(&token, "GET", &format!("/v1/vtu/orders/{id}"), None).await?;
    ensure!(still["status"] == "awaitingPayment", "order moved to {}", still["status"]);
    step("payment to a replaced invoice refused; the order still awaits its new one");

    // 8. A bill link: the user asks, family abroad pays (no account).
    let link = env
        .call(
            &token,
            "POST",
            "/v1/bill-links",
            Some(json!({ "billerId": "mtn-airtime", "target": "0803 123 4567", "amount": 1000, "note": "Data for the week 🙏" })),
        )
        .await?;
    let code = link["code"].as_str().unwrap();
    let public = env.call("", "GET", &format!("/v1/public/bill-links/{code}"), None).await?;
    ensure!(public["status"] == "open" && public["target"] == "0803••••567", "public view: {public}");
    let page = env.http.get(format!("{}/pay/{code}", env.api)).send().await?;
    ensure!(page.status().is_success() && page.text().await?.contains(code), "pay page didn't load");
    let with_invoice = env.call("", "POST", &format!("/v1/public/bill-links/{code}/invoice"), None).await?;
    let link_sats = with_invoice["payment"]["sats"].as_i64().unwrap();
    let qr = env.http.get(format!("{}/v1/public/bill-links/{code}/qr.svg", env.api)).send().await?;
    ensure!(qr.text().await?.starts_with("<?xml"), "QR code isn't an SVG");
    pay(&payer, with_invoice["payment"]["invoice"].as_str().unwrap())?;
    expect_payment(&payer, true).await?;
    let start = Instant::now();
    let paid = loop {
        let public = env.call("", "GET", &format!("/v1/public/bill-links/{code}"), None).await?;
        if public["status"] == "paid" {
            break public;
        }
        ensure!(start.elapsed() < Duration::from_secs(60), "link stuck at {}", public["status"]);
        tokio::time::sleep(Duration::from_millis(500)).await;
    };
    let owner = env.call(&token, "GET", &format!("/v1/bill-links/{code}"), None).await?;
    ensure!(owner["order"]["status"] == "done", "owner sees {}", owner["order"]["status"]);
    let again = env.call("", "POST", &format!("/v1/public/bill-links/{code}/invoice"), None).await;
    ensure!(again.is_err(), "a paid link handed out another invoice");
    step(&format!(
        "bill link {code} paid without an account ({link_sats} sats): \"{}\"",
        paid["payment"]["message"].as_str().unwrap_or_default()
    ));

    // 9. Share an order that already exists; someone else pays it.
    let mine = env
        .call(&token, "POST", "/v1/vtu/orders", Some(json!({ "billerId": "mtn-data", "target": "08031234567", "planId": "mtn-1gb-1d" })))
        .await?;
    let mine_id = mine["id"].as_str().unwrap();
    let shared = env.call(&token, "POST", "/v1/bill-links", Some(json!({ "orderId": mine_id, "note": "Data please 🙏" }))).await?;
    let shared_code = shared["code"].as_str().unwrap();
    ensure!(shared["order"]["id"] == mine["id"], "the link isn't on the shared order");
    let twice = env.call(&token, "POST", "/v1/bill-links", Some(json!({ "orderId": mine_id }))).await?;
    ensure!(twice["code"] == shared["code"], "sharing an order twice made a second link");
    ensure!(
        env.call(&token, "POST", "/v1/bill-links", Some(json!({ "orderId": mine_id, "billerId": "mtn-airtime" }))).await.is_err(),
        "an orderId and a new bill were both accepted"
    );
    // The owner requotes with a JSON content type and an empty body, as
    // most HTTP clients send it. The link follows the new invoice.
    let r = env.raw(&token, "POST", &format!("/v1/vtu/orders/{mine_id}/quote"), Some("application/json"), vec![]).await?;
    ensure!(r.status().is_success(), "requote with an empty JSON body gave {}", r.status());
    let requoted: Value = r.json().await?;
    ensure!(requoted["invoice"] != mine["invoice"] && requoted["id"] == mine["id"], "requote didn't keep the order");
    let seen = env.call("", "GET", &format!("/v1/public/bill-links/{shared_code}"), None).await?;
    ensure!(seen["payment"]["invoice"] == requoted["invoice"], "the link still shows the retired invoice");
    ensure!(seen["note"] == "Data please 🙏" && seen["requester"] == "E2E", "link details: {seen}");
    let data_sats = seen["payment"]["sats"].as_i64().unwrap();
    pay(&payer, seen["payment"]["invoice"].as_str().unwrap())?;
    expect_payment(&payer, true).await?;
    let done = env.wait_for_status(&token, mine_id, &["done"]).await?;
    ensure!(done["receipt"]["message"].as_str().is_some_and(|m| m.contains("sent to")), "no receipt: {done}");
    let start = Instant::now();
    while env.call("", "GET", &format!("/v1/public/bill-links/{shared_code}"), None).await?["status"] != "paid" {
        ensure!(start.elapsed() < Duration::from_secs(30), "shared link never read paid");
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    let late = env.call(&token, "POST", "/v1/bill-links", Some(json!({ "orderId": mine_id }))).await;
    ensure!(late.is_err_and(|e| e.to_string().contains("alreadyPaid")), "a paid order could be shared");
    step(&format!("existing order shared by link, requoted by its owner, paid by someone else ({data_sats} sats)"));

    // 10. Requests that trip up real HTTP clients.
    let r = env
        .raw("", "POST", "/v1/auth/login", Some("text/plain"), br#"{"username":"nobody_here","pin":"1234"}"#.to_vec())
        .await?;
    let body: Value = r.json().await?;
    ensure!(body["error"]["code"] == "auth", "a JSON body sent as text/plain wasn't read: {body}");
    let r = env.raw(&token, "POST", "/v1/vtu/orders", Some("application/json"), br#"{"target":"0803"}"#.to_vec()).await?;
    let status = r.status();
    let body: Value = r.json().await?;
    ensure!(status == 400 && body["error"]["code"] == "invalid", "missing field: {status} {body}");
    for (method, path, code, expected) in [("GET", "/v1/nope", "notFound", 404), ("DELETE", "/v1/vtu/limits", "invalid", 405)] {
        let r = env.raw(&token, method, path, None, vec![]).await?;
        let status = r.status();
        let body: Value = r.json().await.context("an error that isn't JSON")?;
        ensure!(status == expected && body["error"]["code"] == code, "{method} {path}: {status} {body}");
    }
    step("JSON sent as text/plain, empty bodies, missing fields, unknown routes: all answered in the standard error shape");

    // 11. Profile photo.
    let png: Vec<u8> = [&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A][..], &[7u8; 64][..]].concat();
    let r = env.raw(&token, "PUT", "/v1/me/photo", Some("application/octet-stream"), png.clone()).await?;
    ensure!(r.status().is_success(), "photo upload gave {}", r.status());
    let uploaded: Value = r.json().await?;
    let photo_url = uploaded["photoUrl"].as_str().unwrap().to_string();
    let me = env.call(&token, "GET", "/v1/me", None).await?;
    ensure!(me["photoUrl"] == uploaded["photoUrl"], "/me doesn't show the new photo");
    let path = photo_url.splitn(4, '/').nth(3).map(|p| format!("/{p}")).context("photo url")?;
    let served = env.raw("", "GET", &path, None, vec![]).await?;
    ensure!(served.headers()["content-type"] == "image/png", "photo served as {:?}", served.headers()["content-type"]);
    ensure!(served.bytes().await?.as_ref() == png.as_slice(), "the photo served isn't the one uploaded");
    let r = env.raw(&token, "PUT", "/v1/me/photo", Some("image/png"), b"<svg xmlns='http://www.w3.org/2000/svg'/>".to_vec()).await?;
    ensure!(r.status() == 400, "an SVG was accepted as a photo ({})", r.status());
    env.raw(&token, "DELETE", "/v1/me/photo", None, vec![]).await?;
    ensure!(env.call(&token, "GET", "/v1/me", None).await?["photoUrl"].is_null(), "photo still on /me after delete");
    ensure!(env.raw("", "GET", &path, None, vec![]).await?.status() == 404, "deleted photo still served");
    step("profile photo: uploaded, on /me, served with its type, SVG refused, deleted");

    // 12. Only the delivered bills cost anything.
    let spent = start_balance - lightning_balance(&payer);
    let expected = (sats + link_sats + data_sats) as u64;
    ensure!(spent == expected, "payer spent {spent} sats, expected {expected}");
    step(&format!("payer spent exactly {spent} sats, for the three delivered bills"));

    payer.stop()?;
    let _ = std::fs::remove_dir_all(&dir);
    println!("\nAll end-to-end checks passed.");
    Ok(())
}

fn step(message: &str) {
    println!("✓ {message}");
}

fn short(id: &str) -> String {
    format!("{}…", &id[..12])
}

fn lightning_balance(node: &Node) -> u64 {
    node.list_channels().iter().map(|c| c.outbound_capacity_msat / 1000 + c.unspendable_punishment_reserve.unwrap_or(0)).sum()
}

fn pay(node: &Node, invoice: &str) -> Result<()> {
    let invoice = Bolt11Invoice::from_str(invoice).map_err(|e| anyhow::anyhow!("{e:?}"))?;
    node.bolt11_payment().send(&invoice, None)?;
    Ok(())
}

/// Waits for the payer's next payment result and checks it.
async fn expect_payment(node: &Node, success: bool) -> Result<()> {
    let deadline = Instant::now() + Duration::from_secs(60);
    while Instant::now() < deadline {
        let event = tokio::time::timeout(Duration::from_secs(5), node.next_event_async()).await;
        let Ok(event) = event else { continue };
        node.event_handled()?;
        match event {
            Event::PaymentSuccessful { .. } if success => return Ok(()),
            Event::PaymentFailed { .. } if !success => return Ok(()),
            Event::PaymentSuccessful { .. } => bail!("payment went through, expected it to fail"),
            Event::PaymentFailed { reason, .. } => bail!("payment failed ({reason:?}), expected it to succeed"),
            _ => {}
        }
    }
    bail!("no payment result within a minute")
}

fn drain(node: &Node) {
    while node.next_event().is_some() {
        let _ = node.event_handled();
    }
}

async fn wait(what: &str, timeout: Duration, mut done: impl FnMut() -> bool) -> Result<()> {
    let start = Instant::now();
    while !done() {
        ensure!(start.elapsed() < timeout, "timed out waiting: {what}");
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    Ok(())
}

impl Env {
    async fn rpc(&self, method: &str, params: Value) -> Result<Value> {
        let body = json!({ "jsonrpc": "1.0", "id": "e2e", "method": method, "params": params });
        let url = if method == "createwallet" || method == "loadwallet" {
            self.rpc_url.clone()
        } else {
            format!("{}/wallet/e2e", self.rpc_url)
        };
        let json: Value = self
            .http
            .post(url)
            .basic_auth(&self.rpc_user, Some(&self.rpc_password))
            .json(&body)
            .send()
            .await?
            .json()
            .await?;
        if !json["error"].is_null() {
            bail!("bitcoind {method}: {}", json["error"]);
        }
        Ok(json["result"].clone())
    }

    async fn mine(&self, blocks: u32, to: &Value) -> Result<()> {
        self.rpc("generatetoaddress", json!([blocks, to])).await?;
        Ok(())
    }

    async fn admin(&self, path: &str) -> Result<Value> {
        Ok(self.http.get(format!("{}{path}", self.api)).bearer_auth(&self.admin_token).send().await?.json().await?)
    }

    async fn call(&self, token: &str, method: &str, path: &str, body: Option<Value>) -> Result<Value> {
        let url = format!("{}{path}", self.api);
        let request = match method {
            "GET" => self.http.get(url),
            "DELETE" => self.http.delete(url),
            _ => self.http.post(url),
        };
        let request = if token.is_empty() { request } else { request.bearer_auth(token) };
        let request = match body {
            Some(body) => request.json(&body),
            None => request,
        };
        let json: Value = request.send().await?.json().await?;
        if let Some(error) = json.get("error") {
            bail!("{method} {path}: {error}");
        }
        Ok(json)
    }

    /// A request with exactly the content type and body given, for testing
    /// how the server treats less tidy clients.
    async fn raw(&self, token: &str, method: &str, path: &str, content_type: Option<&str>, body: Vec<u8>) -> Result<reqwest::Response> {
        let mut request = self.http.request(method.parse()?, format!("{}{path}", self.api)).body(body);
        if let Some(content_type) = content_type {
            request = request.header("content-type", content_type);
        }
        if !token.is_empty() {
            request = request.bearer_auth(token);
        }
        Ok(request.send().await?)
    }

    async fn sign_up(&self) -> Result<String> {
        let n = std::process::id();
        let code = self.call("", "POST", "/v1/auth/signup/code", Some(json!({ "contact": format!("e2e{n}@example.com") }))).await?;
        let verified = self
            .call("", "POST", "/v1/auth/signup/verify", Some(json!({ "verificationId": code["verificationId"], "code": "123456" })))
            .await?;
        let account = self
            .call(
                "",
                "POST",
                "/v1/auth/signup",
                Some(json!({ "signUpToken": verified["signUpToken"], "displayName": "E2E", "username": format!("e2e_{n}"), "pin": "1234" })),
            )
            .await?;
        Ok(account["token"].as_str().unwrap().to_string())
    }

    async fn order(&self, token: &str, phone: &str) -> Result<Value> {
        self.call(token, "POST", "/v1/vtu/orders", Some(json!({ "billerId": "mtn-airtime", "target": phone, "amount": 500 }))).await
    }

    async fn wait_for_status(&self, token: &str, id: &str, statuses: &[&str]) -> Result<Value> {
        let start = Instant::now();
        loop {
            let order = self.call(token, "GET", &format!("/v1/vtu/orders/{id}"), None).await?;
            if statuses.iter().any(|s| order["status"] == *s) {
                return Ok(order);
            }
            ensure!(start.elapsed() < Duration::from_secs(60), "order {id} stuck at {}", order["status"]);
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
    }
}
