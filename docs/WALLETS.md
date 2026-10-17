# Wallets (Nostr Wallet Connect)

Users connect their own Lightning wallets with
[Nostr Wallet Connect](https://github.com/nostr-protocol/nips/blob/master/47.md)
(NWC, NIP-47). ScorchePay reads the balance and, in the order flow, pays
invoices from the connected wallet. It never holds funds: payments go from
the user's wallet straight to the backend's invoice.

## How it works

1. In their wallet, the user creates an app connection for ScorchePay and
   copies its connection string (`nostr+walletconnect://<wallet-pubkey>?relay=…&secret=…`).
2. On the dashboard they tap **Connect wallet** and paste it. The app checks
   that the wallet answers and that the connection allows `get_balance` and
   `pay_invoice`.
3. The dashboard shows the current wallet's balance. Tapping the wallet opens
   a switcher to pick another wallet, connect one more, remove one, or remove
   all.

Wallets that can create NWC connections include Alby Hub, Zeus, Coinos,
Primal, Minibits and LNbits (see [awesome-nwc](https://github.com/getAlby/awesome-nwc)).
Users can usually set a spending budget per connection, or have the wallet
ask them to approve each payment.

## Where things live

| Piece | File |
| --- | --- |
| NWC client (on `ndk` + `ndk_flutter`'s verifier) and mock | `lib/state/services/wallet_service.dart` |
| Storage | `lib/state/services/wallet_store.dart` |
| State (`walletsProvider`, `currentWalletBalanceProvider`) | `lib/state/providers/wallets_provider.dart` |
| Dashboard section, switcher sheet, connect screen | `lib/features/wallet/` |

Connection strings can spend up to the connection's budget, so they are
stored only on the device, in secure storage, under the signed-in account's
ID. They never go to the backend and aren't part of any state the UI reads. The key
is defined in `lib/state/services/secure_storage_keys.dart`.
Another account signing in on the same device sees no wallets.

## Developing without a wallet

```sh
flutter run --dart-define=MOCK_WALLETS=true
```

`MockWalletService` accepts any well-formed connection string; the connect
screen gets a **Use a demo connection** button that fills one in. Balances
are made up (stable per connection). For payments, an invoice containing
`budget` fails as over budget and one containing `fail` fails as a payment
failure.

## Build requirement: Rust toolchain

The NWC client comes from [`ndk`](https://pub.dev/packages/ndk), with
[`ndk_flutter`](https://pub.dev/packages/ndk_flutter) providing the event
verifier the NDK docs recommend for Flutter apps (`NdkEventVerifier`). It
checks the signatures on the wallet's replies:

- on Android, iOS, macOS and desktop, with ndk's Rust verifier on a separate
  thread. `ndk` compiles that Rust library during every native build;
- on web, with Web Crypto through a script `ndk_flutter` injects itself (no
  `index.html` change).

So every machine that builds for native platforms, CI included, needs Rust:

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Android
rustup target add aarch64-linux-android armv7-linux-androideabi \
  x86_64-linux-android i686-linux-android

# iOS
rustup target add aarch64-apple-ios x86_64-apple-ios aarch64-apple-ios-sim
```

Web builds don't need it. We only use `ndk_flutter`'s verifier, not its
account or wallet widgets, so its login persistence and localization setup
aren't needed.

## Known limitations

- `ndk` marks its NWC API (`ndk.nwc`) as experimental, so it may change
  between releases. It's only read in `NwcWalletService` (one `ignore` for
  the `experimental_member_use` warning), so an upgrade touches one class.
  Check its changelog before bumping `ndk`.
- Requests are encrypted with NIP-04 (what `ndk` 0.10 sends). NWC wallets
  accept it today; NIP-44 is the newer option.
- `ndk` doesn't let us add NIP-47's request `expiration` tag, so payments
  rely on the app's own timeout (`payInvoice(timeout:)`), which the order
  flow should set to the quote's expiry.
- `ndk`'s NWC client ignores `NdkConfig.defaultQueryTimeout` (it uses 20s +
  5s per relay to connect, 5s per request). Connecting keeps ndk's default;
  `NwcWalletService` sets a longer `defaultQueryTimeout` on its config and
  passes it to `get_balance` explicitly, since phone-based wallets can be
  slow to answer.
- `ndk` reports wallet errors as plain `Exception`s with the NIP-47 code in
  the message (`… code: QUOTA_EXCEEDED …`); it has no typed error and doesn't
  export its `ErrorCode` enum. `_mapError` reads the code from the text, so
  it's the place to change if ndk adds a typed exception.
- Removing a wallet only removes it from ScorchePay. To stop the connection
  completely, the user revokes it in their wallet app.
- Wallets don't follow the account to a new device; they're connected again
  there.
- Connecting is paste-only for now; scanning the connection QR code needs a
  camera package (e.g. `mobile_scanner`).
