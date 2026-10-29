//! The backend's Lightning node (ldk-node), which receives order
//! payments and pays refunds.
//!
//! Order invoices are claimed by hand (`receive_for_hash`): when a
//! payment arrives, `orders::handle_event` claims it only if its order is
//! still waiting on that exact invoice. Anything else (an expired quote,
//! an invoice replaced by a requote) is failed back to the payer.

use std::str::FromStr;
use std::sync::Arc;

use anyhow::{Context, Result};
use ldk_node::bitcoin::hashes::{Hash, sha256};
use ldk_node::lightning::ln::msgs::SocketAddress;
use ldk_node::lightning_invoice::{Bolt11Invoice, Bolt11InvoiceDescription, Currency, Description};
use ldk_node::lightning_types::payment::{PaymentHash, PaymentPreimage};
use ldk_node::{Builder, Node};
use rand::RngCore;

use crate::config::Config;

pub struct Lightning {
    pub node: Arc<Node>,
    /// Invoices this node accepts for refunds: its own network's.
    currency: Currency,
}

/// A fresh invoice and the secrets needed to claim it.
pub struct NewInvoice {
    pub bolt11: String,
    pub payment_hash: String,
    pub preimage: String,
}

impl Lightning {
    /// Builds and starts the node on the configured network, sharing the
    /// server's tokio runtime.
    pub fn start(config: &Config) -> Result<Self> {
        std::fs::create_dir_all(&config.ldk_storage_dir).context("LDK_STORAGE_DIR")?;
        let mut builder = Builder::new();
        match &config.bitcoind_rpc {
            Some(rpc) => {
                let (user, password, host, port) = parse_rpc(rpc)?;
                builder.set_chain_source_bitcoind_rpc(host, port, user, password)
            }
            None => builder.set_chain_source_esplora(config.esplora_url.clone(), None),
        };
        builder
            .set_runtime(tokio::runtime::Handle::current())
            .set_network(config.network)
            .set_storage_dir_path(config.ldk_storage_dir.clone())
            .set_listening_addresses(vec![
                SocketAddress::from_str(&format!("0.0.0.0:{}", config.ldk_listen_port))
                    .map_err(|e| anyhow::anyhow!("listen address: {e:?}"))?,
            ])?;
        match &config.rgs_url {
            Some(url) => builder.set_gossip_source_rgs(url.clone()),
            None => builder.set_gossip_source_p2p(),
        };
        let node = builder.build().context("building the Lightning node")?;
        node.start().context("starting the Lightning node")?;
        tracing::info!(node_id = %node.node_id(), network = %config.network, "Lightning node running");
        Ok(Self { node: Arc::new(node), currency: config.network.into() })
    }

    /// An invoice for `sats` that only `claim` can settle.
    pub fn create_invoice(&self, sats: i64, description: &str, expiry_secs: u32) -> Result<NewInvoice> {
        let mut preimage = [0u8; 32];
        rand::rngs::OsRng.fill_bytes(&mut preimage);
        let hash = sha256::Hash::hash(&preimage).to_byte_array();
        let description = Bolt11InvoiceDescription::Direct(
            Description::new(description.to_string()).map_err(|e| anyhow::anyhow!("invoice description: {e:?}"))?,
        );
        let invoice = self
            .node
            .bolt11_payment()
            .receive_for_hash(sats as u64 * 1000, &description, expiry_secs, PaymentHash(hash))
            .map_err(|e| anyhow::anyhow!("creating invoice: {e}"))?;
        Ok(NewInvoice { bolt11: invoice.to_string(), payment_hash: hex::encode(hash), preimage: hex::encode(preimage) })
    }

    pub fn claim(&self, payment_hash: &PaymentHash, amount_msat: u64, preimage_hex: &str) -> Result<()> {
        let preimage: [u8; 32] =
            hex::decode(preimage_hex)?.try_into().map_err(|_| anyhow::anyhow!("preimage isn't 32 bytes"))?;
        self.node
            .bolt11_payment()
            .claim_for_hash(*payment_hash, amount_msat, PaymentPreimage(preimage))
            .map_err(|e| anyhow::anyhow!("claiming payment: {e}"))
    }

    pub fn fail(&self, payment_hash: &PaymentHash) {
        if let Err(e) = self.node.bolt11_payment().fail_for_hash(*payment_hash) {
            tracing::warn!("failing payment back: {e}");
        }
    }

    /// Starts paying `invoice` and returns the payment's ID (its hash, as
    /// hex). The result arrives as a PaymentSuccessful or PaymentFailed
    /// event.
    pub fn pay(&self, invoice: &Bolt11Invoice) -> Result<String> {
        let id = self.node.bolt11_payment().send(invoice, None).map_err(|e| anyhow::anyhow!("{e}"))?;
        Ok(hex::encode(id.0))
    }
}

impl Lightning {
    /// Parses a BOLT11 invoice pasted by a user, checking it's for this
    /// node's network. `lightning:` prefixes and case are ignored.
    pub fn parse_invoice(&self, value: &str) -> Option<Bolt11Invoice> {
        let value = value.trim().to_lowercase();
        let value = value.strip_prefix("lightning:").unwrap_or(&value);
        let invoice = Bolt11Invoice::from_str(value).ok()?;
        (invoice.currency() == self.currency).then_some(invoice)
    }
}

/// Splits `user:password@host:port`.
fn parse_rpc(rpc: &str) -> Result<(String, String, String, u16)> {
    let (auth, addr) = rpc.rsplit_once('@').context("BITCOIND_RPC must be user:password@host:port")?;
    let (user, password) = auth.split_once(':').context("BITCOIND_RPC must be user:password@host:port")?;
    let (host, port) = addr.rsplit_once(':').context("BITCOIND_RPC must be user:password@host:port")?;
    Ok((user.into(), password.into(), host.into(), port.parse().context("BITCOIND_RPC port")?))
}
