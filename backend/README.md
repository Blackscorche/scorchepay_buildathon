# ScorchePay backend

The server behind the ScorchePay app: accounts and KYC, a bills API
(airtime, data, electricity, TV), and a Lightning node that receives the
payments. It's built in Rust (axum, sqlx with Postgres, and ldk-node) and
runs on **Mutinynet** (signet) for now.

The Flutter app is at the root of this repository. The older Express
`server/` folder next to it belongs to the fiat version of the app and
isn't used here.

## How a purchase works

The payment is **held until the bill is delivered**. If the provider
can't deliver, the payment is cancelled and the sats go straight back to
the user's wallet: there's no refund to request.

1. The app asks for a quote (`POST /v1/vtu/orders`). The server checks the
   biller, target and tier limits, prices the bill in sats from the live
   BTC/NGN rate plus `SPREAD_BPS`, and creates a BOLT11 invoice that lasts
   `QUOTE_SECS`. It's a manual-claim invoice (ldk-node
   `receive_for_hash`): the server keeps the preimage.
2. The user's wallet pays it over NWC. The payment reaches the node as
   `PaymentClaimable`: locked in, but not taken yet.
3. If the order is still waiting on **that exact invoice**, unexpired,
   for at least the quoted sats, it's marked `paid` and the bill is
   bought. Anything else (a late payment, or one to an invoice a requote
   replaced) is failed back immediately.
4. The provider's answer decides what happens to the held payment:
   - **Delivered:** the node claims it (reveals the preimage) and the
     order is `done`, with a receipt.
   - **Refused:** the node fails it back. The payer's wallet gets the
     sats back, and the order reads `refunded`.
   - **No answer** (timeout, server error after sending): it may have
     been delivered, so the node claims it and the order is held for
     review (`/admin/orders/review`). If review finds it wasn't
     delivered, it's marked `refundable` and the user pastes an invoice
     to be paid back.
5. A purchase only starts with at least six blocks left before the held
   payment's claim deadline, so a bill is never delivered after its
   payment can no longer be claimed.

## Bill links

A user can ask anyone, for example family abroad, to pay one bill:
`POST /v1/bill-links` returns a link (`/pay/{code}`) to share. It takes
either a new bill or the `orderId` of an unpaid order the user already
created, so someone else can pay any order. The payer
opens it in any browser, taps Pay and pays the QR code from any Lightning
wallet: no account, no app. Each attempt is an ordinary order owned by the
requester, so limits, holding until delivery and failing back all apply.
The payer sees a masked target and no receipt items; the requester sees
everything, including any meter token.

## Run it

You need Rust (rustup) and Postgres.

```sh
cd backend
cp .env.example .env    # then fill in DATABASE_URL, JWT_SECRET, ADMIN_TOKEN
createdb scorchepay_backend
cargo run               # migrates, starts the node, listens on :8080
cargo test                    # unit tests
scripts/e2e-regtest.sh        # end-to-end, real Lightning payments (below)
```

`LDK_STORAGE_DIR` (default `./data/ldk`) holds the node's seed and channel
state. Back it up. Losing it loses the node's funds.

### Give the node inbound liquidity (once)

The node can only receive payments through a channel with room on its
side. On Mutinynet, test sats are free, so open a channel and push half
of it to the other side:

```sh
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
curl -X POST localhost:8080/admin/node/address -H "$ADMIN"   # → tb1q…
# Send ~500,000 sats to that address at https://faucet.mutinynet.com
# (log in with GitHub). Blocks are about 30 seconds apart.
curl localhost:8080/admin/node -H "$ADMIN"                    # wait for onchainSats
# Open a channel to a well-connected Mutinynet node. The faucet page
# lists its node as pubkey@host:port.
curl -X POST localhost:8080/admin/node/channels -H "$ADMIN" -H 'content-type: application/json' \
  -d '{"peer":"<pubkey>@<host>:<port>","amountSats":400000,"pushSats":200000}'
```

Once `/admin/node` shows the channel as `usable`, orders can be paid from
any Mutinynet Lightning wallet, or from the faucet's "pay invoice" box.

### End-to-end test (regtest)

`scripts/e2e-regtest.sh` starts a throwaway regtest bitcoind and the
backend (fake providers), then runs `examples/e2e_regtest.rs`: a second
LDK node opens a channel to the backend and pays real invoices. It
checks that a delivered bill takes the payment, a failed one hands it
back, a replaced invoice can't be paid, and the payer only spends for
the delivered bill. Needs `bitcoind` on PATH (`brew install bitcoin`)
and Postgres (`PGPORT=5433 scripts/e2e-regtest.sh` for another port).

```
✓ ₦500 airtime delivered and 308 sats claimed
✓ failed bill handed the payment back
✓ payment to a replaced invoice refused; the order still awaits its new one
✓ payer spent exactly 308 sats, for the one delivered bill
```

### Prices

The BTC/NGN price comes from CoinGecko, then CoinPaprika, then
Blockchain.com: the first that answers is used, and it's cached for a
minute. If every source fails, the last good price is used for up to 15
minutes, and after that quotes fail with `network` ("Prices are
unavailable right now") rather than guess. A failing feed is retried at
most every 15 seconds, so quotes fail fast. The startup log says where the
price came from:

```
INFO scorchepay_backend::rates: BTC/NGN: ₦109823858 per BTC (from CoinGecko)
```

If you see "no BTC/NGN price" instead, the log lists why each source failed
(for example a blocked network). Don't set `FALLBACK_NGN_PER_BTC` to make
the error go away unless you're working offline: it isn't the market price.

## Configuration

Everything is in `.env.example`. These are the switches:

| Variable | Values | Notes |
| --- | --- | --- |
| `VTU_PROVIDER` | `fake`, `smeplug` | Airtime and data. SMEPlug has **no sandbox**: `smeplug` spends real naira from your SMEPlug wallet, even when users pay with test sats |
| `BILLS_PROVIDER` | `fake`, `off` | Electricity and TV. N3TData comes next |
| `KYC_PROVIDER` | `fake`, `mono` | Fake approves tier 1 after 2 s. Mono needs `MONO_SECRET_KEY` and `MONO_WEBHOOK_SECRET` |
| `BITCOIN_NETWORK` | `signet`, `regtest` | Signet is Mutinynet; regtest is for local tests |
| `BITCOIND_RPC` | `user:pass@host:port` | Read the chain from Bitcoin Core instead of Esplora |
| `DEV_SIMULATE_PAYMENTS` | `true`, `false` | Development only. Enables the simulate-payment endpoint. Never in production |
| `COINGECKO_API_KEY` | a CoinGecko demo key | Optional, for higher rate limits on the price feed |
| `FALLBACK_NGN_PER_BTC` | a number, or empty | Development only. A made-up price used when no live source answers. **Leave it empty** to see real prices: it hides a broken feed |
| `OTP_DEV_CODE` | e.g. `123456` | Development only. It's accepted for every sign-up code. Codes are logged, not sent: there's no SMS or email sender yet |

Fake provider test cases: a target ending in `0000` is "customer not
found", and one ending in `9999` makes the purchase fail, so the payment
goes back to the payer.

## API

User routes are under `/v1` and take `Authorization: Bearer <token>` from
sign-up or login. Errors are
`{"error": {"code": "...", "message": "..."}}`, where `message` is
written for the user and the VTU codes match `VtuErrorCode` in the app.

| Route | Purpose |
| --- | --- |
| `POST /v1/auth/signup/code` `{contact}` | Sends the OTP and returns `{verificationId}` |
| `POST /v1/auth/signup/verify` `{verificationId, code}` | Returns `{signUpToken}` |
| `GET /v1/auth/usernames/:name` | Checks a username is free (`usernameTaken` if not) |
| `POST /v1/auth/signup` `{signUpToken, displayName, username, pin}` | Returns `{token}` |
| `POST /v1/auth/login` `{username, pin}` | Returns `{token}`. Five wrong PINs lock the account for 15 minutes |
| `GET` / `PATCH /v1/me` | `{id, username, displayName, kyc: {tier, status}, photoUrl}` |
| `POST /v1/kyc/verify` | Returns `{status, url}`. Open `url` (Mono's page), then poll `/v1/me` |
| `POST /v1/webhooks/mono` | Mono Prove events. Checked against the `mono-webhook-secret` header |
| `POST /v1/bill-links`, `GET /v1/bill-links`, `GET`/`DELETE /v1/bill-links/:code` | The user's bill links |
| `GET /v1/public/bill-links/:code`, `POST …/invoice`, `GET …/qr.svg` | For payers, no auth |
| `GET /pay/:code` | The payer page |
| `GET /v1/vtu/catalog`, `/v1/vtu/limits` | See [docs/API_GUIDE.md](docs/API_GUIDE.md) |
| `POST /v1/vtu/customers/validate` | See [docs/API_GUIDE.md](docs/API_GUIDE.md) |
| `POST /v1/vtu/orders`, `GET /v1/vtu/orders?limit=`, `GET /v1/vtu/orders/:id` | See [docs/API_GUIDE.md](docs/API_GUIDE.md) |
| `POST /v1/vtu/orders/:id/quote`, `POST /v1/vtu/orders/:id/refund` | See [docs/API_GUIDE.md](docs/API_GUIDE.md) |

**Try the API in the browser:** open **http://localhost:8080/docs**
(Swagger UI; the spec is at `/openapi.yaml`). Sign up or log in, click
Authorize, and call anything. With `DEV_SIMULATE_PAYMENTS=true`,
`POST /v1/dev/orders/{id}/simulate-payment` marks an order paid without a
Lightning wallet, so every state can be tried from Swagger.

For the frontend: [docs/API_GUIDE.md](docs/API_GUIDE.md) walks through the
flows and every endpoint (requests, responses, errors, UI notes), and
[docs/SYSTEM_DESIGN.md](docs/SYSTEM_DESIGN.md) explains how the backend works.

Admin routes take `Authorization: Bearer $ADMIN_TOKEN`:

| Route | Purpose |
| --- | --- |
| `GET /admin/node` | Node ID, balances and channels |
| `POST /admin/node/address` | An on-chain address for funding the node |
| `POST /admin/node/channels` `{peer, amountSats, pushSats}` | Opens a channel |
| `POST /admin/users/:username/kyc` `{tier}` | Sets a user's tier by hand |
| `GET /admin/orders/review` | Orders whose provider outcome is unknown |
| `POST /admin/orders/:id/resolve` `{outcome: done\|refundable, reference?, message?}` | Settles a reviewed order |

## Not done yet

- **N3TData** for electricity and TV. Its API docs aren't public: they're
  in the N3TData dashboard.
- **SMS and email OTPs.** Codes are only logged for now.
- **Passkeys.** The app's mock still handles them; the app hides the
  option when the backend says passkeys aren't configured.
- **Wiring the app to this server.** An HTTP `VtuApi` and
  `BackendService`, chosen with a `--dart-define`.
- **Mainnet**, which needs real liquidity, monitoring and backups of
  `LDK_STORAGE_DIR`.
