# VTU (airtime, data, electricity, TV)

Users pay for bills with sats from their own connected Lightning wallet
(see [WALLETS.md](WALLETS.md)). The backend quotes a price, issues a
Lightning invoice, and pays the bill once the invoice is paid. Nigeria is
the only country for now; billers, plans and limits all come from the
catalog, so more countries are a backend change.

## Flow

1. **Dashboard.** The VTU tiles are disabled until the user connects a
   wallet. A notice explains why and points to the Wallet section below.
2. **Order form** (`VtuOrderScreen`, one screen for every category):
   - The form is built from the selected biller in the catalog: its options
     (e.g. meter type), then its target (number), then its pricing (an
     amount or a plan). The screen never checks the category.
   - Meters and smartcards show the holder's name before you can continue.
   - Shows the KYC tier limits, with a way to raise them.
3. **Order screen** (`OrderStatusScreen`): one screen for the order's whole
   life. It polls the order every 2 seconds while anything can change.
   Each stage's main action is pinned to the bottom: Pay, Get a new quote,
   Request refund, or Back to home when there's nothing to do.
   - Unpaid (`OrderPaymentPanel`): the quote (naira, sats and a 2-minute
     countdown), "Pay from" with the current wallet and its balance (tap to
     switch; the picker shows every wallet's balance and flags ones that
     don't have enough), and Pay, which sends the invoice to that wallet
     over NWC, waiting until the quote expires.
   - Once the quote expires, "Get a new quote" requotes the same order: a
     fresh price and invoice under the same order ID.
   - Back from an unpaid order returns to the form; continuing again
     requotes that order (with any changed details) instead of creating
     another one. One purchase is one order.
   - Paid: progress through processing, then the receipt (whatever items
     the backend sent, e.g. an electricity token with copy, plus the
     reference). Back now goes home.
   - Refund available: a field to paste an invoice for exactly the order's
     sats.
4. **Recent orders** on the dashboard reopen any order's screen, so an
   unpaid one can still be paid.

### Over the limit

When an order is over the user's tier limits, the backend refuses it with
`overLimit`. The app then shows "Verify to continue" (Mono myPass). After
verifying, the user's tier is raised and the same order is retried.

## API contract

All calls are made as the signed-in user. `VtuApi` holds the session
(the provider rebuilds it on login or logout), so callers never pass a
token. `VtuApi`
(`lib/state/services/vtu_api.dart`) is the interface. Models and their JSON
are in `lib/state/models/vtu.dart`.

| Call | Purpose |
| --- | --- |
| `GET /catalog?country=NG` | Billers. Each one describes its own form: `options` (e.g. meter type, with a label and choices), `target` (label, kind, pattern), `pricing` (`amount` with optional min/max and presets, or `plans` with a label), and whether the customer is checked |
| `GET /limits` | Currency, tier, limit per order, daily limit, amount used today, and the next tier's limits |
| `POST /customers/validate` `{billerId, target, optionId}` | Name (and address) on a meter or smartcard |
| `POST /orders` `{billerId, target, optionId?, planId?, amount?}` | Locks a quote; returns the order with `sats`, `rate`, `expiresAt` and a BOLT11 `invoice` |
| `POST /orders/:id/quote` `{billerId?, target?, optionId?, planId?, amount?}` | Requotes an unpaid order (awaiting payment or expired): new price, `expiresAt` and invoice, same ID. The old invoice is cancelled. An optional body replaces the order's details. `alreadyPaid` once it's paid |
| `GET /orders/:id` | One shape for every state (below), with a display `title` written by the backend |
| `GET /orders?limit=` | The user's orders, newest first |
| `POST /orders/:id/refund` `{invoice}` | Pays a refundable order's sats to the user's invoice |

Order states:

- `awaitingPayment` changes to `paid` when the invoice is paid, or to
  `expired` when it isn't.
- A requote moves `awaitingPayment` or `expired` back to `awaitingPayment`
  with a new invoice. (The system design doc treats `expired` as final; this
  is the one change to it, so retries don't create duplicate orders.)
- `paid` → `fulfilling` → `done`, with a `receipt`: a reference, an optional
  message, and labelled `items` the backend chooses per biller (e.g. an
  electricity `Token`, marked `primary` and `copyable`, and `Units`). The
  app renders items generically.
- If the provider fails, the order becomes `refundable`, with a
  `failureReason`.
- Once an invoice is submitted, `refundRequested` is set, and the order
  becomes `refunded` when the refund is paid.

Error codes: `overLimit`, `invalidTarget`, `customerNotFound`,
`quoteExpired`, `alreadyPaid`, `billerUnavailable`, `invalidInvoice`, `notFound`, `network`.

Amounts: fiat amounts are whole naira, and Bitcoin amounts are sats.

## Mock backend

`MockVtuApi` implements the contract on the device, with a Nigerian catalog.
Prices are illustrative. Orders are saved in shared preferences, and their
status is worked out from timestamps, so it continues after a restart:

- An order is marked paid as soon as a mock wallet pays its invoice.
- It moves to fulfilling after 1.5 seconds, and is done after 5 seconds.

Payments reach the mock backend through `MockLightning`, so run with
`--dart-define=MOCK_WALLETS=true`. Mock wallets start with balances of 1,500,
9,000, 48,000 or 260,000 sats, depending on the connection string, so
switching wallets matters. Their balances go down as they pay.

Things to try:

- **Limits:** Tier 0 is ₦10,000 per order and ₦30,000 a day. A DStv
  Compact order (₦19,000) shows "Verify to continue", and the mock verifies
  the user to Tier 1 after 2 seconds.
- **Customer not found:** use a meter or smartcard number ending in `0000`.
- **Debug menu** (tap "Mock: …" next to "VTU & Bills", debug builds only):
  - Success
  - Bill fails: the order becomes refundable. "Use a test invoice" fills in
    a valid refund invoice.
  - Quote expires fast: quotes last 20 seconds.
  - Server down
- **Simulate payment (debug):** on an unpaid order, this settles the invoice
  without a wallet. Use it when testing with a real NWC wallet, which can't
  pay a mock invoice.

## Not done yet

- An HTTP `VtuApi` for the real backend, and build flavours to choose it.
- A country picker (Nigeria only).
- Guessing the network from the number, and picking from contacts.
- Paying from another wallet app by QR code or link: payment is only from a
  connected NWC wallet.
- Automatic refunds: getting an invoice from the connected wallet would need
  the NWC `make_invoice` permission.
