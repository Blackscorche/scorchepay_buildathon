# ScorchePay API guide for the frontend

**What you're building against:** a backend that lets people in Nigeria
pay bills (airtime, data, electricity, TV) with Bitcoin over Lightning,
from their own wallet. This guide tells you, step by step, **what to
call, when, and what to show the user**. It has two parts:

- **Part 1: The flows.** Sign-up, buying a bill, failures, identity
  verification and bill links, each as "app calls → backend does →
  user sees".
- **Part 2: Endpoint reference.** Every endpoint: purpose, request,
  response, errors and UI notes.

For the architecture and diagrams, see `SYSTEM_DESIGN.md`. To try calls
live, open **Swagger** at `http://localhost:8080/docs`.

---

## 0. Five-minute start

1. **Run the backend** (`README.md`) → `http://localhost:8080`.
2. Open **`/docs`** (Swagger). Log in with `POST /v1/auth/login`:
   `{"username": "ada_lovelace", "pin": "1234"}` (or sign up; the OTP is
   `123456` in development).
3. Copy the `token`, click **Authorize**, paste it.
4. `POST /v1/vtu/orders` with
   `{"billerId": "mtn-airtime", "target": "08031234567", "amount": 500}`.
5. `POST /v1/dev/orders/{id}/simulate-payment` (Swagger can't pay a
   Lightning invoice, so this marks it paid).
6. `GET /v1/vtu/orders/{id}` two or three times: `paid` → `fulfilling`
   → `done`, with a receipt.

You've now seen the whole purchase life cycle.

---

## 1. Rules that apply to every call

| Topic | Rule |
| --- | --- |
| **Base URL** | `http://localhost:8080` locally. User routes live under `/v1`. |
| **Format** | JSON in, JSON out. Set `Content-Type: application/json`, but it isn't required: a JSON body is read whatever the content type is (Dart's `http.post` sends `text/plain` by default). Where a body is optional, an empty body is fine. |
| **Auth** | `Authorization: Bearer <token>` (a JWT from sign-up or login, valid 30 days). Routes marked **Auth: yes** below need it. |
| **Naira** | Whole naira, as integers. `5000` is ₦5,000. |
| **Bitcoin** | Whole sats, as integers. |
| **Times** | ISO 8601 UTC strings, e.g. `"2026-10-26T14:36:16.006210+00:00"`. |
| **Numbers** | Send phone, meter and smartcard numbers as typed. Spaces and dashes are stripped for you. |
| **Polling** | Poll an order every **2 seconds** while its status isn't final. Stop when it is. |
| **Double taps** | Creating an order twice creates two orders. Disable the Pay button while a call is in flight. To retry, **requote** the existing order, don't create a new one. |

### Errors

Every error has the same shape:

```json
{ "error": { "code": "overLimit", "message": "This is over your ₦10,000 limit per order." } }
```

**`message` is written for the user. Show it as is.** Branch your logic
on `code`. Every failure has this shape, including unknown routes, wrong
methods and malformed bodies, so your error handling needs only one parser.

| `code` | HTTP | What happened | What to do |
| --- | --- | --- | --- |
| `signedOut` | 401 | Missing or expired token | Send the user to login |
| `auth` | 400 | Sign-up or login problem (wrong PIN, wrong or expired code, bad username format…) | Show the message |
| `usernameTaken` | 409 | Username already used | Ask for another |
| `invalid` | 400, 404, 405 | Bad input: a missing or malformed field, a note over 140 characters, an unknown route or a wrong method | Show the message. If it appears during development, it's a bug in the request |
| `invalidTarget` | 422 | Phone, meter or smartcard number is malformed | Show under the number field |
| `customerNotFound` | 422 | No customer has that meter or smartcard | Show under the number field |
| `overLimit` | 422 | Over the user's tier limit (per order or per day) | Offer "Verify to raise your limit" |
| `alreadyPaid` | 409 | The order or bill was paid in the meantime | Reload it and show its real state |
| `billerUnavailable` | 503 | The provider is down | Show the message; try later |
| `network` | 503 | Price feed or KYC provider unreachable | Offer a retry |
| `invalidInvoice` | 422 | Refund invoice is wrong (amount, network or expired) | Show the message |
| `notFound` | 404 | Unknown order, link or biller | Go back |
| `cancelled` / `expired` / `inProgress` | 409 | Bill link states (section 5) | Show the message |
| `policyBlocked` | 422 | The user's own spending rules refused the payment (section 17) | Show the message. Offer "Change rules" or "Add to trusted numbers" |
| `forbidden` | 403 | An "ask" session (section 18) tried something only a full login may do | Ask them to log in with their PIN |
| `unknown` | 4xx | Anything else, e.g. "Choose a plan to continue." | Show the message |

---

# Part 1: The flows

## 2. Sign up and log in

| # | App calls | Backend does | User sees |
| --- | --- | --- | --- |
| 1 | `POST /v1/auth/signup/code` `{contact}` | Sends a 6-digit code to the phone or email. Calling it again resends | "Enter the code we sent" |
| 2 | `POST /v1/auth/signup/verify` `{verificationId, code}` | Checks the code (10 min, 5 tries) | Next step |
| 3 | `GET /v1/auth/usernames/{name}` *(optional)* | Checks format and availability | A ✓ or "taken" while typing |
| 4 | `POST /v1/auth/signup` `{signUpToken, displayName, username, pin}` | Creates the account at KYC tier 0 | Signed in |
| 5 | `GET /v1/me` | Returns the profile and KYC status | Home screen |

**Login:** `POST /v1/auth/login` `{username, pin}` → `token`, then
`GET /v1/me`. Five wrong PINs lock login for 15 minutes (the message
says so).

**Store the token** securely (Keychain or Keystore). On any `401
signedOut`, clear it and show login. **In development** every sign-up
code is `123456`.

## 3. Buying a bill (the main flow)

### 3.1 Build the form from the catalog

Call `GET /v1/vtu/catalog` once and cache it for a few minutes. **Don't
write code per category.** Each biller describes its own form, so one
screen handles airtime, data, electricity and TV:

1. If the biller has `options` (e.g. *Meter type*), show that choice
   first. You'll send the chosen `id` as `optionId`.
2. Show the `target` field (label, hint, keyboard from `kind`). Validate
   with `pattern` and show `errorText` if it doesn't match.
3. If `customerCheck` is `true`, call `POST /v1/vtu/customers/validate`
   when the number is complete and show *"Paying for EMEKA OKAFOR"*
   before the user can continue.
4. Pricing, depending on `pricing.type`:
   - `"amount"`: an amount field, with `min` and `max` (either can be
     `null`) and `presets` as chips. Send `amount`.
   - `"plans"`: a plan picker. Send the plan's `id` as `planId`.
5. If `available` is `false`, show the biller greyed out and not tappable.

Also call `GET /v1/vtu/limits` and show "₦X left today". If the amount
would be over the limit, offer verification (section 4) before the
user hits an error.

### 3.2 Quote, pay, deliver

| # | App calls | Backend does | User sees |
| --- | --- | --- | --- |
| 1 | `POST /v1/vtu/orders` | Checks everything, prices the bill in sats, creates a Lightning invoice valid for **2 minutes** | Quote: ₦ amount, sats, a countdown to `expiresAt` |
| 2 | *(the user's wallet pays `invoice`, via Nostr Wallet Connect or the `lightning:` link)* | Receives the payment and **holds** it (sats locked, not taken) | "Paying…" |
| 3 | `GET /v1/vtu/orders/{id}` every 2 s | `paid` → buys the bill → `fulfilling` | "Payment received. Delivering…" |
| 4a | *(same polling)* | Bill delivered → takes the payment → `done` | **Receipt** |
| 4b | *(same polling)* | Bill failed → cancels the payment → `refunded` | "Couldn't deliver. Your sats went back to your wallet." |

> **The rule behind steps 4a and 4b:** a payment is only taken once the
> bill is delivered. A failed bill needs **no refund screen** and no
> action from the user: their wallet gets the sats back by itself.
> Tell users so: *"You only pay if your bill is delivered."*

The user's wallet may show the payment as "pending" for a few seconds
while the bill is being bought. That's expected.

**What this means for the wallet call.** `pay_invoice` over Nostr Wallet
Connect doesn't answer until the payment settles. With a held payment
that takes as long as buying the bill (a few seconds), and if the bill
can't be delivered the wallet reports a **failed payment**. Don't show
that as a plain wallet error. When the wallet call ends (success,
failure or timeout), always fetch the order and show what it says:

| Wallet call | Order says | Show |
| --- | --- | --- |
| Success | `done` | The receipt |
| Failed | `refunded` | The order's `failureReason` ("…your sats went straight back to your wallet.") |
| Failed | still `awaitingPayment` | The wallet's error (e.g. not enough balance): the user can retry |
| Timed out | anything | Keep polling: the wallet may still be paying |

### 3.3 The receipt

On `done`, `receipt` carries whatever the provider returned, in a generic
shape: render it without special cases.

```json
{
  "reference": "FAKE-F72GEHSS62UQ",
  "message": "Enter the token on your meter to load the units.",
  "items": [
    { "label": "Token", "value": "1234-5678-9012-3456-7890", "primary": true,  "copyable": true },
    { "label": "Units", "value": "22.2 kWh",                 "primary": false, "copyable": false }
  ]
}
```

Show `message`, then each item. A `primary` item is what the user came for
(the meter token): show it large. A `copyable` item gets a copy button.
Airtime and data usually have only a `message`.

### 3.4 When the quote runs out

If the user doesn't pay within 2 minutes, the order reads `expired`.
Show "This quote expired" and a **Get a new quote** button that calls
`POST /v1/vtu/orders/{id}/quote`. It's the **same order** with a new
price, invoice and `expiresAt` (the old invoice can no longer be paid).
Send a body to change the details (e.g. the user went back and picked
another amount), or send none to reprice as is.

If the user taps Back from an unpaid order and continues again, requote
that order too: **one purchase is one order.**

Don't rely only on your own countdown: if the phone's clock is wrong, the
server's `status` is the truth. Treat `expired` as expired.

### 3.5 Order history

`GET /v1/vtu/orders` lists orders newest first. Tapping one opens the
order screen and polls it like any other, so an unpaid order can still be
paid or requoted.

## 4. Raising limits with identity verification

Limits per KYC tier:

| Tier | Per order | Per day | How |
| --- | --- | --- | --- |
| 0 | ₦10,000 | ₦30,000 | Every new account |
| 1 | ₦200,000 | ₦1,000,000 | Verify with Mono Prove |

"Per day" resets at midnight Lagos time. It counts paid orders and
unexpired quotes. Expired and refunded orders don't count.

| # | App calls | Backend does | User sees |
| --- | --- | --- | --- |
| 1 | `POST /v1/kyc/verify` | Starts a Mono session and returns `{status: "pending", url}` | "Verify your identity" |
| 2 | *(open `url` in an in-app browser)* | Mono's page collects the details | Mono's flow |
| 3 | `GET /v1/me` every 3 s while `kyc.status` is `pending` | Mono's webhook raises the tier | "Verifying…" |
| 4 | *(status becomes `verified`, `tier: 1`)* | | "You're verified" |

In development `url` is `null` and the tier goes up about 2 seconds
after step 1: skip step 2 and just poll. The other final status is
`rejected`: show it and let the user try again.

After verifying, retry the order that was over the limit.

## 5. Bill links ("Pay my bill")

A user asks someone else (often family abroad) to pay **one bill**. The
payer needs **no account and no app**: any Lightning wallet works. The
same rule protects them: if the bill can't be delivered, their payment
goes back.

| # | Who | Calls | What happens |
| --- | --- | --- | --- |
| 1 | Requester (app) | `POST /v1/bill-links` | Backend checks the bill now and returns `{code, url, status: "open"}`. The link lasts 7 days |
| 2 | Requester (app) | Share `url` with the share sheet | e.g. WhatsApp |
| 3 | Payer (browser) | Opens `url` | The ready-made page at `/pay/{code}` |
| 4 | Payer | Taps **Pay** → `POST /v1/public/bill-links/{code}/invoice` | Backend creates an ordinary order owned by the requester and shows its invoice and QR code |
| 5 | Payer | Pays from any Lightning wallet | Payment held; bill bought; payment taken |
| 6 | Requester (app) | `GET /v1/bill-links/{code}` | `status: "paid"` and the full `order`, including the electricity token |

**Sharing an order the user already created.** The same link can wrap an
existing order, so someone else can pay *any* unpaid order, not only a new
one. On the order screen, an "Ask someone to pay" button calls
`POST /v1/bill-links` with `{"orderId": "…"}` (and an optional `note`).

- The order must be the user's and still unpaid. An expired quote is fine:
  it's requoted when someone opens the link.
- The link **follows the order**. If the user requotes the order, the link
  shows the new price and invoice, and the old invoice is retired.
- The payer sees the order's invoice straight away, so the link reads
  `paying` from the start and the page shows the QR code without a "Pay"
  button.
- An order has one live link. Asking again returns the same link (and
  updates its note).
- Once a link is on an order, don't pay that order from the user's own
  wallet at the same time as someone else: it's the same invoice. If the
  user pays it, the link simply reads `paid`.
- Cancelling the link doesn't touch the order: the user can still pay it.

**The payer page is already built** at `/pay/{code}` (mobile-first, QR
code, countdown, live status). Use it as is, restyle it, or build your own
from the public endpoints in section 11.

What each side sees:

| | Requester | Payer |
| --- | --- | --- |
| Full meter or phone number | Yes | Masked: `1234••••901` |
| Receipt items (token) | Yes | No (just a message, number masked) |
| Note | Yes | Yes |

Link `status`:

| `status` | Meaning | Payer page shows |
| --- | --- | --- |
| `open` | Nothing paid yet, or the last attempt failed back | "Pay with Bitcoin" |
| `paying` | An invoice is out, or a payment is being delivered | QR and countdown, then "Buying the bill…" |
| `paid` | Delivered | "Bill paid ✓" |
| `cancelled` | The requester cancelled it | "Request cancelled" |
| `expired` | Older than 7 days | "Request expired" |

Good to know:

- A payer who abandons an invoice just lets it expire. The next person to
  open the link gets a fresh one.
- If an attempt fails (the bill couldn't be delivered), the payer's sats
  go back and the link returns to `open`, so they can try again.
- **Cancel** stops new invoices. An invoice already shown to a payer stays
  payable until its 2-minute quote runs out, so don't tell users cancel is
  instant for someone mid-payment. Cancel is refused once a payment is
  held or the bill is paid.
- The bill is bought with the **requester's** limits. If it's over them
  when someone pays, the payer sees a message asking the requester to
  verify or try tomorrow.

---

# Part 2: Endpoint reference

Each entry says **Auth** (whether a token is needed), what to send, what
comes back, the errors that can happen and how to use it in the UI. Real
response examples come from the running server.

| Area | Endpoints |
| --- | --- |
| Accounts | `POST /v1/auth/signup/code`, `POST /v1/auth/signup/verify`, `GET /v1/auth/usernames/{username}`, `POST /v1/auth/signup`, `POST /v1/auth/login`, `GET` and `PATCH /v1/me` |
| KYC | `POST /v1/kyc/verify` |
| Bills | `GET /v1/vtu/catalog`, `GET /v1/vtu/limits`, `POST /v1/vtu/customers/validate`, `POST` and `GET /v1/vtu/orders`, `GET /v1/vtu/orders/{id}`, `POST /v1/vtu/orders/{id}/quote`, `POST /v1/vtu/orders/{id}/refund` |
| Bill links (requester) | `POST` and `GET /v1/bill-links`, `GET` and `DELETE /v1/bill-links/{code}` |
| Bill links (payer) | `GET /v1/public/bill-links/{code}`, `POST …/invoice`, `GET …/qr.svg`, `GET /pay/{code}` |
| Policy | `GET` and `PUT /v1/policy`, `POST /v1/policy/trusted`, `DELETE /v1/policy/trusted/{id}`, `GET /v1/policy/events` |
| Ask without an account | `POST /v1/auth/ask/start`, `POST /v1/auth/ask/verify` |
| Bill helper | `POST /v1/helper/draft` |
| Web pages | `/pay/{code}`, `/ask`, `/safety` |
| Development | `POST /v1/dev/orders/{id}/simulate-payment`, `GET /v1/dev/status`, `POST /v1/dev/demo-account` |
| Not for the app | `POST /v1/webhooks/mono`, `/admin/*`, `GET /health` |

## 6. Accounts

### `POST /v1/auth/signup/code`
**Auth: no.** Sends a one-time code to a phone or email.

```json
{ "contact": "ada@example.com" }
```
→ `{ "verificationId": "7b074b14-b59f-4bcd-8d02-09a73606b172" }`

- **Errors:** `auth` (400) if the contact isn't a valid phone or email,
  or already has an account ("Log in instead").
- **UI:** keep `verificationId` for the next step. Calling it again with
  the same contact resends and invalidates the earlier code (a "Resend
  code" button). A code lasts 10 minutes. In development the SMS or email
  isn't sent; use `123456`.

### `POST /v1/auth/signup/verify`
**Auth: no.** Checks the code.

```json
{ "verificationId": "7b074b14-…", "code": "123456" }
```
→ `{ "signUpToken": "9f2c…" }`

- **Errors:** `auth` (400): "Incorrect code.", "This code has expired.
  Request a new one." or "Too many attempts." (5 tries per code).
- **UI:** show the message under the code field. Keep `signUpToken` for
  the final step; it stays valid for a short while after the code expires,
  so the profile step can take a minute.

### `GET /v1/auth/usernames/{username}`
**Auth: no.** Checks a username is valid and free. Optional, for live
feedback while typing.

→ `{ "available": true }`

- **Errors:** `auth` (400) for a bad format (3–20 characters of `a-z 0-9 _ .`);
  `usernameTaken` (409).
- **UI:** debounce it (about 400 ms). A leading `@` and capitals are fine.

### `POST /v1/auth/signup`
**Auth: no.** Creates the account (tier 0) and signs it in.

```json
{ "signUpToken": "9f2c…", "displayName": "Ada", "username": "ada_lovelace", "pin": "1234" }
```
→ `{ "token": "eyJ0eXAiOiJKV1QiLCJhbGciOi…" }`

- **Errors:** `auth` (400): expired verification (start again), a PIN that
  isn't exactly 4 digits, a missing name, a bad username;
  `usernameTaken` (409).
- **UI:** store the token, then call `GET /v1/me`.

### `POST /v1/auth/login`
**Auth: no.**

```json
{ "username": "@ada_lovelace", "pin": "1234" }
```
→ `{ "token": "eyJ0eXAiOiJKV1QiLCJhbGciOi…" }`

- **Errors:** `auth` (400): "Unknown user.", "Incorrect PIN." or, after 5
  misses, "Too many wrong PINs. Try again in a few minutes." (15-minute
  lockout).
- **UI:** show the message. Don't reveal more than it says.

### `GET /v1/me`
**Auth: yes.** The signed-in user. Call it after login and while waiting
for KYC.

```json
{
  "id": "4cfb151d-d737-49e9-83a7-267d17efab05",
  "username": "ada_lovelace",
  "displayName": "Ada",
  "kyc": { "tier": 0, "status": "unverified" },
  "photoUrl": "http://localhost:8080/v1/photos/4cfb151d-d737-49e9-83a7-267d17efab05/1a2b3c4d5e6f7a8b"
}
```

`kyc.status`: `unverified`, `pending`, `verified` or `rejected`.
`photoUrl` is the profile photo's address (a normal image URL you can load with `Image.network`), or `null` when there's none.

- **Errors:** `signedOut` (401).

### `PATCH /v1/me`
**Auth: yes.** Changes the username or display name. Send only what
changes.

```json
{ "displayName": "Ada L." }
```
→ the updated user (same shape as `GET /v1/me`).

- **Errors:** `auth` (400) for a bad username or empty name;
  `usernameTaken` (409).

### `PUT /v1/me/photo`
**Auth: yes.** Sets the profile photo. The body is the **image file's raw
bytes** (not JSON, not multipart). `POST` works too.

→ `{ "photoUrl": "http://localhost:8080/v1/photos/4cfb151d-…/1a2b3c4d5e6f7a8b" }`

- JPEG, PNG, WebP, HEIC or GIF, up to 5 MB. The type is read from the
  bytes, so the `Content-Type` you send doesn't matter.
- **Errors:** `invalid` (400): "Photos must be smaller than 5 MB." or "Use a
  JPEG, PNG, WebP, HEIC or GIF photo."; `signedOut` (401).
- **UI:** `photoUrl` changes on every upload, so there's no stale cached
  copy to worry about. Right after sign-up, upload with the new token.

### `DELETE /v1/me/photo`
**Auth: yes.** Removes the photo. → `{ "photoUrl": null }`

### `GET /v1/photos/{userId}/{version}`
**Auth: no.** The photo itself: just load the `photoUrl` from `/v1/me`.
It's safe to cache forever, because a new upload gets a new URL.

- **Errors:** `notFound` (404) for an old or removed photo.

## 7. KYC

### `POST /v1/kyc/verify`
**Auth: yes.** Starts identity verification. No body.

→ `{ "status": "pending", "url": "https://…" }`

- `url` is Mono's hosted page: open it in an in-app browser. It's `null`
  in development, where tier 1 is granted after about 2 seconds.
- If the user is already tier 1: `{ "status": "verified", "url": null }`.
- **Errors:** `network` (503) if Mono is unreachable.
- **UI:** after this call, poll `GET /v1/me` every 3 seconds until
  `kyc.status` is no longer `pending`. See section 4.

## 8. Bills

### `GET /v1/vtu/catalog?country=NG`
**Auth: no.** Every biller, each describing its own order form. Cache it
for a few minutes.

```json
{
  "country": "NG",
  "currency": "NGN",
  "billers": [
    {
      "id": "ikedc",
      "category": "electricity",
      "name": "Ikeja Electric",
      "shortName": "Ikeja",
      "brandColor": "#E30613",
      "available": true,
      "customerCheck": true,
      "target": { "kind": "number", "label": "Meter number", "hint": "11 to 13 digits",
                  "pattern": "^\\d{11,13}$", "errorText": "Meter numbers are 11 to 13 digits." },
      "options": { "label": "Meter type", "choices": [
        { "id": "prepaid", "name": "Prepaid" }, { "id": "postpaid", "name": "Postpaid" } ] },
      "pricing": { "type": "amount", "label": "Amount", "min": 1000, "max": 500000,
                   "presets": [2000, 5000, 10000, 20000] }
    },
    {
      "id": "gotv",
      "category": "tv",
      "name": "GOtv",
      "shortName": null,
      "brandColor": "#5BB947",
      "available": true,
      "customerCheck": true,
      "target": { "kind": "number", "label": "Smartcard (IUC) number", "hint": "10 or 11 digits",
                  "pattern": "^\\d{10,11}$", "errorText": "Smartcard numbers are 10 or 11 digits." },
      "options": null,
      "pricing": { "type": "plans", "label": "Choose a package", "plans": [
        { "id": "gotv-smallie", "name": "Smallie", "amount": 1900, "validity": "1 month" },
        { "id": "gotv-jolli",   "name": "Jolli",   "amount": 5800, "validity": "1 month" } ] }
    }
  ]
}
```

| Field | How to use it |
| --- | --- |
| `category` | `airtime`, `data`, `electricity` or `tv`. Group tiles by it |
| `shortName`, `name`, `brandColor` | Tile label (prefer `shortName`) and colour |
| `available` | `false`: show greyed out and not tappable |
| `options` | `null`, or a choice before anything else. Send its choice `id` as `optionId` |
| `target.kind` | `phone`, `number` or `text`: picks the keyboard |
| `target.pattern`, `errorText` | Regex for the (space-stripped) number, and the message when it fails |
| `customerCheck` | `true`: validate the customer before continuing |
| `pricing.type` | `"amount"` (free amount, with `min`, `max`, `presets`) or `"plans"` (pick one) |

- **Errors:** `notFound` (404) for a country other than `NG`.
- **Don't hardcode limits.** Read `min` and `max` from each biller's
  `pricing`. For example, airtime currently has a ₦50 minimum and no
  maximum (only the user's tier limit applies), and electricity is
  ₦1,000 to ₦500,000.
- **Note:** data plans and their prices come from the provider and can
  change between catalog calls. Always show the price from the **order**
  once it's created.

### `GET /v1/vtu/limits`
**Auth: yes.** The user's caps and today's spend.

```json
{
  "currency": "NGN", "tier": 0, "perOrder": 10000, "daily": 30000, "usedToday": 1000,
  "nextTier": { "currency": "NGN", "tier": 1, "perOrder": 200000, "daily": 1000000,
                "usedToday": 0, "nextTier": null }
}
```

- **UI:** "left today" is `daily - usedToday`. The biggest order allowed
  right now is the smaller of `perOrder` and that. `nextTier` drives the
  "Verify to raise your limit" prompt, and is `null` at the top tier.

### `POST /v1/vtu/customers/validate`
**Auth: yes.** Looks up who owns a meter or smartcard. Only for billers
with `customerCheck: true`.

```json
{ "billerId": "ikedc", "target": "12345678901", "optionId": "prepaid" }
```
→ `{ "name": "EMEKA OKAFOR", "address": "22 Allen Avenue, Ikeja, Lagos" }`

(`address` is `null` for TV.)

- **Errors:** `invalidTarget` (422), `customerNotFound` (422),
  `billerUnavailable` (503), `notFound` (404, unknown biller).
- **UI:** call it when the number reaches a valid length. Show "Paying for
  EMEKA OKAFOR" and make the user confirm. In development, a number
  ending `0000` returns `customerNotFound`.

### `POST /v1/vtu/orders`
**Auth: yes.** Creates an order: checks the request, prices it, and
creates the invoice.

`billerId` and `target` are always required. Then send:

| Biller has… | Also send |
| --- | --- |
| `options` | `optionId` |
| `pricing.type = "plans"` | `planId` |
| `pricing.type = "amount"` | `amount` (naira) |

```json
{ "billerId": "mtn-data", "target": "08031234567", "planId": "mtn-2gb-30d" }
```

Returns an **Order** (section 9). For the example above:

```json
{
  "id": "zg6zhqmhu7yh",
  "title": "MTN 2GB",
  "status": "awaitingPayment",
  "category": "data",
  "billerId": "mtn-data",
  "billerName": "MTN",
  "target": "08031234567",
  "amount": 1500,
  "currency": "NGN",
  "sats": 923,
  "rate": 162513542.79,
  "invoice": "lntbs9230n1p4d7e8gdql2d3k7unrdpj4qcte8gsy64zwyqeyws…",
  "createdAt": "2026-10-26T14:34:16.006533+00:00",
  "expiresAt": "2026-10-26T14:36:16.006210+00:00",
  "request": { "billerId": "mtn-data", "target": "08031234567", "optionId": null, "planId": "mtn-2gb-30d", "amount": null },
  "planName": "2GB",
  "optionName": null,
  "customerName": null,
  "paidAt": null,
  "receipt": null,
  "failureReason": null,
  "refundRequested": false
}
```

- **Errors:** `invalidTarget`, `customerNotFound`, `overLimit` (422);
  `unknown` (422, e.g. "Choose a plan to continue.", "Enter an amount
  from ₦1,000 to ₦500,000." or "Choose a meter type to continue.");
  `billerUnavailable`, `network` (503, the price feed is down: "try again
  in a minute"); `notFound` (404, unknown biller).
- **UI:** show `title`, the naira `amount`, `sats` and a countdown to
  `expiresAt`. Have the user's wallet pay `invoice`, then poll.
  `overLimit` messages already say which limit (per order or what's left
  today).
- **Limits are held while the quote is open.** A live quote counts against
  today's limit until it expires.

### `GET /v1/vtu/orders/{id}`
**Auth: yes.** One order, in the same shape as above. Poll it every 2 s
while the status isn't final.

- **Errors:** `notFound` (404). You can only read your own orders.
- **UI:** this is the order screen's data source. See section 9 for what to
  show per status.

### `GET /v1/vtu/orders?limit=20`
**Auth: yes.** The user's orders, newest first (`limit` is 1–100, default
20). Returns an array of Orders.

### `POST /v1/vtu/orders/{id}/quote`
**Auth: yes.** Reprices an unpaid order, keeping its ID. Use it for an
expired quote, or when the user changed details before paying.

- **Body (optional):** an OrderRequest to change the details. No body
  reprices as it was.
- **Returns:** the Order, `awaitingPayment`, with a new `sats`, `invoice`
  and `expiresAt`. The old invoice can no longer be paid: a late payment
  to it is returned automatically.
- **Errors:** `alreadyPaid` (409) if it's already paid (reload it);
  `notFound` (404); plus everything `POST /v1/vtu/orders` can return,
  since the order is checked again.

### `POST /v1/vtu/orders/{id}/refund`
**Auth: yes.** **Rarely needed.** A failed bill is returned to the
payer's wallet automatically, so most users will never see this. It's
only for an order that reads `refundable`: the provider's answer was
unclear, staff reviewed it, and found it wasn't delivered. The user then
creates a Lightning invoice in their wallet for **exactly the order's
sats** and sends it here.

```json
{ "invoice": "lntbs9230n1p4d7e8g…" }
```

Returns the Order with `refundRequested: true`. Keep polling until it
reads `refunded`. If the payment fails, `refundRequested` goes back to
`false` and the user can paste another invoice.

- **Errors:** `invalidInvoice` (422): not an invoice for this network, no
  amount, wrong amount ("The invoice must be for exactly 923 sats; this
  one is for 1,000 sats."), expired, or can't be paid;
  `unknown` (409) "This order can't be refunded."; `notFound` (404).

## 9. Orders: the object and its states

### The Order object

| Field | Meaning |
| --- | --- |
| `id` | 12-character ID. Stays the same through requotes |
| `title` | What was bought, written by the backend ("MTN 2GB", "Ikeja Electric (Prepaid)") |
| `status` | See the table below |
| `amount`, `currency` | Price in whole naira |
| `sats` | What the invoice asks for |
| `rate` | Naira per BTC the user effectively pays, spread included |
| `invoice` | BOLT11 invoice to pay (`lntbs…` on the test network) |
| `expiresAt` | When this quote and invoice stop being payable (2 minutes) |
| `request` | The OrderRequest that made this order, for requoting |
| `planName`, `optionName`, `customerName` | Display details, when they apply |
| `paidAt` | When the payment arrived |
| `receipt` | Set on `done` (section 3.3) |
| `failureReason` | Set on `refunded` and `refundable`: a user-facing sentence |
| `refundRequested` | `true` while a refund invoice is being paid |

### Status

| `status` | Final? | Show | Main action |
| --- | --- | --- | --- |
| `awaitingPayment` | No | Quote: naira, sats, countdown, "Pay from" wallet | **Pay** |
| `expired` | Until requoted | "This quote expired" | **Get a new quote** (`POST …/quote`) |
| `paid` | No | "Payment received. Delivering your bill…" (step 1 of 2) | None: keep polling |
| `fulfilling` | No | "Delivering…" (step 2 of 2) | None: keep polling |
| `done` | Yes | The receipt | Back to home |
| `refunded` | Yes | `failureReason`, e.g. "MTN couldn't complete this bill. Your sats went straight back to your wallet." | **Try again** (a new order) |
| `refundable` | Yes | `failureReason` (rare) | Paste a refund invoice |

`expired` is worked out from `expiresAt`, so it appears the moment the
quote runs out. Also keep polling while `refundRequested` is `true`.

```
awaitingPayment ──pay──▶ paid ──▶ fulfilling ──▶ done
      │  ▲                                  └──▶ refunded   (bill failed: payment returned)
  2 min│  │ requote
      ▼  │
    expired
```

## 10. Bill links (requester)

### `POST /v1/bill-links`
**Auth: yes.** Creates a link, in one of two ways (never both):

| Send | When | What happens |
| --- | --- | --- |
| `orderId` | Share an order the user already created | The link wraps that order and follows it (section 5). The order must be the user's and unpaid |
| `billerId` + `target` (+ `optionId`, `planId` or `amount`) | A new bill with no order yet | Checked now (number, plan or amount, customer name, per-order limit) and priced when someone opens an invoice |

Both accept an optional `note` (up to 140 characters).

```json
{ "orderId": "zg6zhqmhu7yh", "note": "Please help with this one 🙏" }
```
```json
{ "billerId": "ikedc", "target": "12345678901", "optionId": "prepaid", "amount": 5000,
  "note": "Light for the house this week, thank you aunty" }
```

Returns a **BillLink**:

```json
{
  "code": "n5CLSF7kBf",
  "url": "http://localhost:8080/pay/n5CLSF7kBf",
  "status": "open",
  "title": "Ikeja Electric (Prepaid)",
  "category": "electricity",
  "billerName": "Ikeja Electric",
  "target": "12345678901",
  "amount": 5000,
  "currency": "NGN",
  "note": "Light for the house this week, thank you aunty",
  "request": { "billerId": "ikedc", "target": "12345678901", "optionId": "prepaid", "planId": null, "amount": 5000 },
  "createdAt": "2026-10-26T14:33:39.216274+00:00",
  "expiresAt": "2026-11-02T14:33:39.215833+00:00",
  "order": null
}
```

For a link on an existing order, `order` holds that order from the start,
and `status` is `paying` while its quote is live.

- **Errors, new bill:** everything an order request can fail with
  (`invalidTarget`, `customerNotFound`, `billerUnavailable`, `unknown`),
  `overLimit` (the bill is over the **per-order** limit; the daily limit is
  checked when it's paid), and `invalid` (400) for a note over 140
  characters.
- **Errors, existing order:** `notFound` (404) if it isn't the user's;
  `alreadyPaid` (409) if it's already paid or being delivered; `unknown`
  (409) "Only an unpaid order can be shared." for a refunded one; `invalid`
  (400) if `orderId` is sent together with a new bill's details, or neither
  is sent.
- **UI:** this is the order form plus a note field and a "Create link"
  button. Then open the share sheet with `url`. The link works for 7 days.

### `GET /v1/bill-links`
**Auth: yes.** The user's links, newest first (up to 50). Same objects as
above.

### `GET /v1/bill-links/{code}`
**Auth: yes.** One link with its current payment attempt in `order`: a
full Order, including `receipt` and the electricity token once it's `done`.
Poll it while the link is `paying`.

- **Errors:** `notFound` (404). You can only read your own links.
- **UI:** the "paid" screen shows `order.receipt` here: this is where the
  requester gets the token.

### `DELETE /v1/bill-links/{code}`
**Auth: yes.** Cancels a link. Returns the BillLink with
`status: "cancelled"`.

- **Errors:** `alreadyPaid` (409) when a payment is held or the bill is
  paid; `notFound` (404).
- **Note:** cancelling stops new invoices, but an invoice a payer already
  has stays payable until its 2-minute quote runs out.

## 11. Bill links (payer, no auth)

The finished page lives at `GET /pay/{code}`. These endpoints are for
building your own.

### `GET /v1/public/bill-links/{code}`
**Auth: no.** What the payer sees.

```json
{
  "code": "n5CLSF7kBf",
  "status": "paying",
  "requester": "Ada",
  "title": "Ikeja Electric (Prepaid)",
  "category": "electricity",
  "billerName": "Ikeja Electric",
  "target": "1234••••901",
  "amount": 5000,
  "currency": "NGN",
  "note": "Light for the house this week, thank you aunty",
  "expiresAt": "2026-11-02T14:33:39.215833+00:00",
  "payment": {
    "status": "awaitingPayment",
    "sats": 3076,
    "approx": { "usd": 3.77, "gbp": 2.82 },
    "invoice": "lntbs30760n1p4d7ex0dp62d3k7unrdpj4qcte8gsy…",
    "expiresAt": "2026-10-26T14:35:51.590052+00:00",
    "paidAt": null,
    "message": null,
    "failureReason": null
  }
}
```

`payment` is `null` until someone asks for an invoice. Its `status` uses
the order statuses from section 9. When it's `done`, `message` is the
receipt message with the number masked (no token).

`approx` is what the sats are worth in dollars and pounds, to show people
paying from abroad ("≈ $3.77 · £2.82"). It's `null` when the price feeds
didn't give those prices. The ready-made page shows it, and supports
`?lang=ha` (Hausa) and `?lang=pcm` (Pidgin); its language picker remembers
the choice. The server's own sentences stay in English.

- **Errors:** `notFound` (404).
- **Polling:** poll this every 2 seconds while the link is `paying`.

### `POST /v1/public/bill-links/{code}/invoice`
**Auth: no.** Returns the same object with a payable `payment`. It gives the
current invoice if it's still valid, a fresh quote if it expired, or a new
attempt if the last one was returned. No body.

- **Errors:** `alreadyPaid`, `inProgress` ("A payment for this bill is
  being processed."), `cancelled` and `expired` (all 409); `overLimit`
  (422, worded for the payer: "ask them to verify their account or try
  tomorrow"); `billerUnavailable`, `network` (503); `notFound` (404).
- **UI:** the **Pay with Bitcoin** button. Show the QR code and the
  countdown, and disable the button while the call is in flight.

### `GET /v1/public/bill-links/{code}/qr.svg`
**Auth: no.** The current invoice as a QR code (SVG, encoding a
`lightning:` link). Use it as an `<img>` source. It changes when the
invoice changes, so add a cache-busting query (e.g. `?i=<last 12 chars of
the invoice>`).

- **Errors:** `notFound` (404) if no invoice has been requested yet.

### `GET /pay/{code}`
**Auth: no.** The ready-made payer page (HTML). It does everything above
itself.

## 12. Development only

### `POST /v1/dev/orders/{id}/simulate-payment`
**Auth: no.** Marks an unpaid order paid **without a Lightning payment**,
so you can test the rest of the flow. Only exists when the server runs
with `DEV_SIMULATE_PAYMENTS=true`: otherwise it returns `notFound`.

- Works on any order whose quote hasn't expired, including bill link
  orders (get the order ID from `GET /v1/bill-links/{code}` → `order.id`).
- Returns the Order, now `paid`, then moves on by itself.
- **Errors:** `unknown` (409) "Only an unpaid order with an unexpired
  quote can be paid."
- **UI:** a debug-only **Simulate payment** button on the order screen is
  handy.

**Test inputs** (fake providers, the development default):

| Input | Result |
| --- | --- |
| Sign-up code | `123456` always works |
| Meter or smartcard ending `0000` | `customerNotFound` |
| Target ending `9999` | The bill fails: the order ends `refunded` |
| Anything else | Delivered after about 1.5 seconds. Electricity returns a 20-digit token |

## 13. Not for the app

- **`POST /v1/webhooks/mono`**: Mono calls it when verification finishes.
  It's checked against a shared secret. The app never calls it.
- **`/admin/*`**: node funding, channels, setting a tier by hand and
  settling reviewed orders. Operators only, behind an admin token.
- **`GET /health`**: returns `ok`. For uptime checks.

---

## 14. Screens ↔ endpoints

| Screen | Endpoints |
| --- | --- |
| Sign-up | `signup/code`, `signup/verify`, `usernames/{u}`, `signup` |
| Login | `login`, then `me` |
| Home | `vtu/catalog`, `vtu/limits`, `vtu/orders`, `me` |
| Order form | `vtu/catalog`, `customers/validate`, `vtu/limits` |
| Order (quote, pay, receipt) | `POST vtu/orders`, `GET vtu/orders/{id}` (poll), `…/quote` |
| Verify identity | `kyc/verify`, then `me` (poll) |
| Bill links: create (new bill) | the order form, then `POST bill-links` |
| Bill links: list and detail | `GET bill-links`, `GET bill-links/{code}` (poll) |
| Order screen: "Ask someone to pay" | `POST bill-links` with `{orderId}` |
| Profile photo | `PUT` and `DELETE me/photo`, then `me` |
| Payer page | `GET /pay/{code}` (already built, in English, Hausa and Pidgin) |
| Safety (rules and log) | `GET` and `PUT policy`, `POST` and `DELETE policy/trusted`, `GET policy/events` |
| Bill helper box | `POST helper/draft`, then `POST vtu/orders` with the draft's `request` |

## 15. Things that surprise people

0. **A payment can be refused before it has an invoice.** If the user set spending rules, `POST /v1/vtu/orders` (and requotes and bill links) can fail with `policyBlocked`. That's a normal answer, not a bug: show its message.

1. **Paying doesn't make the order `done` instantly.** The wallet may
   report success while the bill is still being bought. Keep polling.
2. **A failed bill isn't a "refund request".** The payment is returned
   automatically. The `refundable` status is a rare edge case.
3. **Requote, don't recreate.** It keeps one purchase as one order and
   retires the old invoice safely.
4. **Take prices from the order, not the catalog.** Data plan prices come
   from the provider and can change.
5. **A quote also reserves daily limit** until it expires, so quotes that
   are never paid briefly count against "left today".
6. **Phone numbers:** send `0803…` as typed. The backend strips spaces and
   dashes. Don't convert to `+234`; the patterns expect the local format.
7. **Test network.** Invoices start with `lntbs` and only work with signet
   wallets until the backend moves to mainnet.

## 16. Connecting the Flutter app

Today the Flutter app (at the root of this repository) builds
`MockVtuApi` and the mock `BackendService`. Both are
small interfaces, so the real ones are HTTP versions of the same methods.
This is the mapping.

### `BackendService` (accounts)

| App method | Endpoint | Notes |
| --- | --- | --- |
| `requestSignUpCode(contact)` | `POST /v1/auth/signup/code` | Returns `verificationId` |
| `verifySignUpCode(id, code)` | `POST /v1/auth/signup/verify` | Returns `signUpToken` |
| `checkUsernameAvailable(name)` | `GET /v1/auth/usernames/{name}` | A `409 usernameTaken` becomes an `AuthException(message)` |
| `signUp(...)` | `POST /v1/auth/signup` | Returns the token |
| `login(username, pin)` | `POST /v1/auth/login` | A blank username is **not** a demo account any more |
| `getUser(token, local)` | `GET /v1/me` | `id` → `userId`, plus `displayName`, `kyc`, `photoUrl` |
| `updateUserDetails(...)` | `PATCH /v1/me` | |
| `verifyIdentity(token)` | `POST /v1/kyc/verify`, then poll `GET /v1/me` | See below |
| `uploadProfilePhoto(token, bytes)` | `PUT /v1/me/photo` | Body is the raw bytes. Returns `photoUrl` |
| `deleteProfilePhoto(token)` | `DELETE /v1/me/photo` | |
| `loadProfilePhoto(url)` | `GET {photoUrl}` | Public: no token needed |
| Passkey methods (4) | not built | Have the HTTP service report `passkeysConfigured = false`: the app then hides passkey sign-in and sign-up by itself (`passkeysAvailableProvider`) |
| `accountSummary(token)` | not needed | Only the mock `VtuApi` used it |

**`verifyIdentity`** is the one method whose behaviour differs. The mock
waits two seconds and returns the new KYC info. The real one should: call
`POST /v1/kyc/verify`; if `url` isn't `null`, open it in an in-app browser;
then poll `GET /v1/me` every 3 seconds until `kyc.status` isn't `pending`,
and return it. (In development `url` is `null`, and the tier goes up about
2 seconds later.)

### `VtuApi` (bills)

| App method | Endpoint |
| --- | --- |
| `getCatalog()` | `GET /v1/vtu/catalog?country=NG` |
| `getLimits()` | `GET /v1/vtu/limits` |
| `validateCustomer(...)` | `POST /v1/vtu/customers/validate` |
| `createOrder(request)` | `POST /v1/vtu/orders` |
| `requote(id, {request})` | `POST /v1/vtu/orders/{id}/quote`. No body when `request` is null |
| `getOrder(id)`, `listOrders(limit)` | `GET /v1/vtu/orders/{id}`, `GET /v1/vtu/orders?limit=` |
| `requestRefund(id, invoice)` | `POST /v1/vtu/orders/{id}/refund` |
| `MockVtuApi.simulatePayment(id)` (debug) | `POST /v1/dev/orders/{id}/simulate-payment` |

The models in `lib/state/models/vtu.dart` already parse these responses
as they are: every field, status and category name matches.

### Errors

Parse `{ "error": { "code", "message" } }` on any non-2xx response. For bills,
build `VtuException(code, message)`; for accounts, `AuthException(message)`.
Map `signedOut` (401) to `VtuErrorCode.signedOut`, `network` to `network`,
and any code the app doesn't list to `unknown`. The backend never sends
`quoteExpired`: an expired quote is the order's `expired` status.

### Changes the app needs

1. **An HTTP client and a base URL**, chosen with a `--dart-define` (say
   `API_BASE_URL`), keeping the mocks behind another define.
   - iOS simulator and web: `http://localhost:8080`.
   - Android emulator: `http://10.0.2.2:8080`.
   - A real phone: the computer's LAN address, or an `https` tunnel.
   - Android blocks plain `http` by default (set `usesCleartextTraffic`
     while developing); iOS needs a local-networking exception for a LAN
     address. A tunnel with `https` avoids both.
2. **Remove the demo-account hint** on the login screen ("leave it blank").
3. **`verifyIdentity`** as described above.
4. **After every wallet payment, fetch the order** and show what it says
   (section 3.2). A failed bill appears as a failed wallet payment.
5. **A debug "Simulate payment" button that works with the real backend.**
   `order_payment_panel.dart` currently takes a `MockVtuApi`. The mock
   wallets (`MOCK_WALLETS`) pay fake invoices the real backend never sees,
   and real NWC wallets are on mainnet while the backend's invoices
   (`lntbs…`) are for the signet test network. Until the backend moves to
   mainnet, use the simulate endpoint, or a signet wallet.
6. **Hide the mock-only debug menu** (the scenario picker) when the real API
   is in use.

### Not built yet, so the app shouldn't depend on it

- Passkeys (hidden as above).
- Real SMS or email delivery of the sign-up code (use `123456` in
  development).
- Electricity and TV from a real provider (the fake stands in).
- Real Mono verification (the fake approves in about 2 seconds).

## 17. Spending policy (the user's own rules)

A user can set rules for their own spending. Every payment is checked
against them **before an invoice exists**, whether it comes from the app,
a bill link, a requote or the bill helper. The rules can only narrow what
the KYC tier already allows.

| Rule | Meaning |
| --- | --- |
| `perPaymentCap` | The most for one payment, in naira. `null` is no limit |
| `dailyCap` | The most per day, in naira. `null` is no limit |
| `trustedOnly` | When `true`, payments can only go to numbers on the trusted list |
| `trusted` | Numbers (phone, meter or smartcard) with a name to refer to them by, such as "mama" |

The checks run in this order: trusted number, per-payment cap, daily cap.
A refusal is `422 policyBlocked` with a message to show as is, and it's
written to the log.

All of these are **full login only**: an "ask" session (section 18) gets
`403 forbidden`.

### `GET /v1/policy`
```json
{
  "perPaymentCap": 2000,
  "dailyCap": 5000,
  "trustedOnly": true,
  "trusted": [
    { "id": "a403ce99-c222-4701-aad6-0dbb2fa40d34", "label": "mama", "target": "08031234567", "addedAt": "2026-10-29T19:48:03.571906+00:00" }
  ],
  "tierLimits": { "perOrder": 10000, "daily": 30000 },
  "usedToday": 0
}
```
`tierLimits` is what the account already allows, to show next to the
fields ("up to ₦10,000 per order"). `usedToday` counts toward `dailyCap`.

### `PUT /v1/policy`
Send only what changes. A number sets a limit, `null` removes it, and a
missing field is left alone. Returns the new policy.

```json
{ "perPaymentCap": 2000, "dailyCap": null, "trustedOnly": true }
```
**Errors:** `invalid` (400) for a limit of ₦0 or less.

### `POST /v1/policy/trusted`
`{ "label": "mama", "target": "0803 123 4567" }` adds a number and returns
the new policy. The label is up to 30 characters, the number 10 to 13
digits (spaces and dashes are fine), and a user can trust up to 50.
**Errors:** `invalid` (400), and `unknown` (409) if it's already on the list.

### `DELETE /v1/policy/trusted/{id}`
Removes a number and returns the new policy. **Errors:** `notFound` (404).

### `GET /v1/policy/events?limit=30`
What the rules blocked and, while a rule is active, what they allowed,
newest first. Numbers are masked.

```json
[
  {
    "id": 5,
    "at": "2026-10-29T19:48:03.626991+00:00",
    "source": "order",
    "outcome": "blocked",
    "reason": "untrustedTarget",
    "message": "This number isn't on your trusted list. Add it under Safety first, or turn off \"trusted numbers only\".",
    "billerName": "MTN",
    "title": "MTN airtime",
    "target": "0805••••567",
    "amount": 500,
    "orderId": null
  }
]
```
`source` is `order`, `requote`, `billLink`, `linkPayment` or `helper`.
`reason` (when blocked) is `untrustedTarget`, `overPaymentCap` or
`overDailyCap`.

**UI:** a "Safety" screen with the two limits, the trusted-only switch, the
trusted list (add and remove) and the log as a list of Blocked and Allowed
rows. When an order fails with `policyBlocked`, offer "Add to trusted
numbers" or "Change rules". A web version of this screen is already built
at `/safety`.

## 18. Asking for a top-up without an account

Someone with no app, no wallet and no PIN can ask for a bill to be paid:
they verify a phone number, say what they need, and get a link to share.
The page for it is built at **`/ask`** (English, Hausa and Pidgin).

| # | Call | What happens |
| --- | --- | --- |
| 1 | `POST /v1/auth/ask/start` `{contact}` | Sends a code. In development the response has `demoCode` |
| 2 | `POST /v1/auth/ask/verify` `{verificationId, code, name}` | Returns `{token, displayName, isGuest}`: an **ask session**, valid for 24 hours |
| 3 | `GET /v1/vtu/catalog`, `POST /v1/vtu/customers/validate`, `POST /v1/helper/draft` | Build the request, as in section 3.1 |
| 4 | `POST /v1/bill-links` | Creates the link (section 10) |

An ask session can do **only** steps 3 and 4 and view or cancel its own
links. Anything else (`/v1/me`, orders, KYC, the policy) answers
`403 forbidden`. `name` is required the first time, so the payer knows
who is asking.

A number with no account gets a **guest account** (no PIN) to own its
links. If that person later signs up with the same number
(`/v1/auth/signup/code`, section 2), the sign-up **claims** the guest
account and keeps its links.

## 19. The bill helper

### `POST /v1/helper/draft`
`{ "text": "abeg load 500 credit for mama" }` turns a sentence into a draft
order. **It never creates an order and never pays.** Show the draft, let
the user confirm, then send `request` to `POST /v1/vtu/orders` (or to
`POST /v1/bill-links`). Works with a full login or an ask session.

It understands English, Pidgin and a few Hausa words:
`send ₦500 airtime to 08031234567`, `abeg load 1k credit for mama`,
`buy 2GB data for 0802 123 4567`, `pay my NEPA ₦5000 meter 12345678901 ikeja`,
`dstv compact 1234567890`. A saved trusted name ("mama") stands for its
number, and a number typed in the sentence wins over a name. When there's
no network name it guesses one from the number's prefix and says so.

```json
{
  "understood": true,
  "ready": true,
  "request": { "billerId": "mtn-airtime", "target": "08031234567", "optionId": null, "planId": null, "amount": 500 },
  "partial": { "category": "airtime", "billerId": "mtn-airtime", "target": "08031234567", "optionId": null, "planId": null, "amount": 500 },
  "summary": "₦500 MTN airtime to mama (0803••••567)",
  "missing": [],
  "notes": ["I guessed MTN from the number. Check it."],
  "problems": [],
  "policy": { "allowed": true }
}
```

| Field | Use |
| --- | --- |
| `ready` | `true` only when the draft is complete, valid **and** allowed by the user's rules. Enable "Confirm" only then |
| `request` | The OrderRequest to send. `null` until it's complete |
| `partial` | Whatever was understood, even if incomplete: use it to pre-fill the order form |
| `summary` | One line to show for confirmation |
| `missing` | What to ask for next: `what`, `amount`, `number`, `network`, `plan`, `disco`, `meterNumber`, `provider`, `smartcard`, `package` |
| `notes` | Things to double-check, such as a guessed network |
| `problems` | Validation errors, such as a malformed meter number |
| `policy` | `{allowed: false, reason, message}` when the rules would block it. A blocked draft is also written to the log |
| `reply` | A short question or answer in the user's own language, when the draft isn't ready. Show it, or speak it. `null` when ready |
| `usedAi` | `true` when a model helped read the sentence (see below). Tell the user |

**Follow-ups.** Send `context` with the previous sentence when the last try wasn't enough: `{"text": "500", "context": "send airtime to 0803 123 4567"}` reads as one request. The voice assistant does this so a one-word answer finishes the request.

**The optional AI model.** Rules handle clear requests with no model call. If the server has `LLM_BASE_URL` set (any OpenAI-compatible API, including free tiers) and the rules can't finish a sentence, the model is asked to read it. It copes with misspellings, garbled speech-to-text, Yoruba and Igbo, and writes the `reply`. Safeguards: phone, meter and smartcard numbers are replaced with placeholders before anything is sent, so the model never sees them and can't invent one; its answer is only a suggestion, every field is checked against the catalog, and the draft still goes through validation, the spending policy and the user's confirmation. If the model is off, slow or fails, the helper works as before. Limit: 12 model calls per user per minute.

Another example, when something is missing:
`"I need data for 08021234567"` returns `ready: false`,
`missing: ["plan"]`, a `partial` with `billerId: "airtel-data"`, and a note
listing the plans it can see.

**Errors:** `invalid` (400) for an empty sentence or one over 300 characters.

**UI:** a text box above the order form ("Just say what you need"). On
`partial`, pre-fill the form; on `missing`, say what's still needed; on
`ready`, show `summary` and a Confirm button.

### `POST /v1/assistant/chat`
**Auth: yes** (full login). One turn of talking with **Scorche**, the voice assistant: a friend for bills, money and Bitcoin, in English, Pidgin, Yoruba, Hausa or Igbo.

```json
{ "message": "What is bitcoin worth today", "lang": "yo",
  "history": [ { "role": "user", "text": "…" }, { "role": "assistant", "text": "…" } ],
  "walletSats": 260000 }
```
→
```json
{ "reply": "Bitcoin is around $78,967 right now…", "lang": "en", "end": false,
  "draft": null, "usedAi": true,
  "market": { "usd": 78967, "ngn": 106362416, "usdMarketCap": 1.59e12, "change24h": -2.9 } }
```

| Field | Use |
| --- | --- |
| `reply` | What to say back. Empty when the person asked for a bill and `draft` carries the rest |
| `lang` | The language the reply is in (`en`, `pcm`, `yo`, `ha`, `ig`). Use it to pick the voice (`POST /v1/tts` with this `lang`) |
| `end` | They said goodbye: close the assistant |
| `draft` | When they asked to buy something: the same object as `POST /v1/helper/draft`. If `ready`, read `summary` back and ask for a yes; then `POST /v1/vtu/orders` with `draft.request`. If not ready, ask for the first of `missing` |
| `market` | Bitcoin price, naira price, market cap and 24-hour change (cached 90 s), or `null` |

**It can't move money.** It can only draft a purchase; the user confirms, and paying is a separate tap. Prices, limits, recent orders and the wallet balance come from facts the server supplies, never from the model's memory, and the assistant is told not to give financial advice.

**With and without a model.** With `LLM_BASE_URL` set (see section 19) it chats freely and understands all five languages. Without one it still answers Bitcoin price questions and drafts bills from plain rules (a one-word answer like "500" is read with the user's earlier turns in `history`), so it never goes silent. Phone, meter and smartcard numbers are masked before anything reaches a model. Limit: 20 messages per user per minute.

**Languages.** The language words in the server's canned replies (Yoruba, Hausa, Igbo, Pidgin) are a first pass: have native speakers review them before launch.

### `POST /v1/stt?lang=yo`
**Auth: yes** (full login). Turns a recording into words, for the languages phones can't recognise. The **body is the audio itself** (WAV, M4A, MP3, WebM or OGG, up to 1.5 MB, about 40 seconds); `lang` is `yo`, `ha`, `ig`, `en` or `pcm`. Returns `{ "text": "…" }`.

- **Why it exists:** a phone's built-in recogniser handles English well, but Yoruba, Hausa and Igbo only on some Android phones and never on an iPhone. The voice assistant checks what the phone has; when it lacks the language it records a short clip (16 kHz WAV, ending itself after a pause) and sends it here.
- **How:** the clip goes to a Whisper model (`STT_MODEL`, default `whisper-large-v3`) through the same provider and key as the assistant (`LLM_BASE_URL`). Nothing is stored. A hint of the app's own words (MTN, airtime, naira, DStv…) is sent with it so brand names are heard correctly.
- **Quality:** English is very good. Whisper knows Yoruba and Hausa but is rougher on them, especially in noise or fast speech. **Whisper has no Igbo**, so Igbo is auto-detected and is experimental: expect more mistakes. The assistant's AI then makes sense of imperfect text, which helps a lot.
- **Errors:** `invalid` (400) for an empty or oversized clip; `unavailable` (503) when no provider is set up or it fails. 20 clips per user per minute.

### `POST /v1/tts`
**Auth: yes** (full login). `{ "text": "Say yes to continue.", "lang": "ha" }` → an **MP3** of a natural-sounding voice saying it (`Content-Type: audio/mpeg`). For the voice assistant: the phone's built-in voice sounds robotic, so the app plays this instead.

- Up to 320 characters. Pass only what the assistant is about to say, never what the user typed.
- `lang` (`en`, `pcm`, `ha`, `yo`, `ig`) picks the voice: `TTS_VOICE` by default (a soft Nigerian-English female voice), `TTS_VOICE_HA` for Hausa (free Google voice), and `TTS_VOICE_YO` / `TTS_VOICE_IG` for Yoruba and Igbo. **There is no free Yoruba or Igbo voice**, so until you set those they use the default voice, which pronounces them poorly. `scripts/free-tts-server.py` can drive Meta's MMS voices (`mms:yor`, `mms:ibo`) if you have a Hugging Face token; that path is untested.
- The server keeps recent answers, so repeated phrases return instantly. 40 new phrases per user per minute.
- **Errors:** `unavailable` (503) when the server has no voice set up (`TTS_BASE_URL`) or it is down. **The app should then use the phone's own voice** and stop asking for a few minutes.
- Free setup: `pip install edge-tts && python3 scripts/free-tts-server.py` serves Nigerian-English neural voices with no key. See `.env.example`.

## 20. Development helpers

Only when the server runs with `DEV_SIMULATE_PAYMENTS=true`.

- `GET /v1/dev/status` returns `{demoAccounts, simulatePayments}`, or `404`
  when the helpers are off. Use it to decide whether to show test buttons.
- `POST /v1/dev/demo-account` makes a throwaway, signed-in account and
  returns `{username, pin, token}` (the PIN is `1234`). The `/safety` page
  offers this as "Try it with a demo account".
- `POST /v1/dev/orders/{id}/simulate-payment`: section 12.
