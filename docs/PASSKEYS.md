# Passkeys (biometric login)

Biometric login uses passkeys through the [`passkeys`](https://pub.dev/packages/passkeys)
package. The backend is the WebAuthn relying party; the app only passes its
JSON to the OS and back.

## Turning it on

On mobile and macOS, passkeys stay hidden until a relying party domain is set:

```sh
flutter run --dart-define=PASSKEY_RP_ID=your-domain.com
```

`your-domain.com` must serve the association files below over HTTPS, with no
redirects and `Content-Type: application/json`.

## Web

Works without extra setup: `flutter run -d chrome` uses `localhost` as the
relying party ID (the mock falls back to the page's host). Browsers only allow
an RP ID equal to the page's host or a parent domain of it, and only on HTTPS
or `localhost`. So a deployed web build must be served from the RP domain (or
a subdomain of it), and a passkey made on `localhost` only works on
`localhost`.

### The JavaScript SDK (`web/passkeys_bundle.js`)

On web, `package:passkeys` calls a JavaScript SDK that `web/index.html`
loads from `web/passkeys_bundle.js`. Corbado doesn't publish builds of it for
current versions (the GitHub release downloads stop at old ones), so it's
built from source. The bundle must match the `passkeys_web` version in
`pubspec.lock`. It isn't committed, so build it after cloning and after every
`passkeys_web` upgrade:

```sh
flutter pub get
dart run tools/build_passkeys_bundle.dart          # needs git and Node.js
dart run tools/build_passkeys_bundle.dart --force  # rebuild anyway
```

The script reads the `passkeys_web` version from `pubspec.lock`, does a
shallow, sparse clone of the matching `passkeys_web-v<version>` tag of
`github.com/corbado/flutter-passkeys`, runs `npm ci` and `npm run build` in
`packages/passkeys/passkeys_web/javascript`, and copies `dist/bundle.js` to
`web/passkeys_bundle.js`. It records the version in
`web/passkeys_bundle.version` and does nothing when that already matches. It
exits non-zero if anything fails, so it can run as a CI step.

To do the same by hand:

```sh
git clone --depth 1 --filter=blob:none --sparse \
  --branch passkeys_web-v<version> https://github.com/corbado/flutter-passkeys
cd flutter-passkeys
git sparse-checkout set packages/passkeys/passkeys_web/javascript
cd packages/passkeys/passkeys_web/javascript
npm ci --ignore-scripts && npm run build   # output: dist/bundle.js
```

Without the bundle, passkeys fail on web with "Passkeys Web SDK not loaded".

## Android: Digital Asset Links

`https://your-domain.com/.well-known/assetlinks.json`

```json
[
  {
    "relation": ["delegate_permission/common.get_login_creds"],
    "target": {
      "namespace": "android_app",
      "package_name": "com.scorchepay.scorchepay",
      "sha256_cert_fingerprints": ["<SHA-256 of each signing cert>"]
    }
  }
]
```

Get the debug fingerprint with `cd android && ./gradlew signingReport`. Add the
release and Play upload keys too. The device or emulator needs a Google account
and a screen lock.

## iOS and macOS: Associated Domains

`https://your-domain.com/.well-known/apple-app-site-association`

```json
{
  "webcredentials": {
    "apps": ["<TEAM_ID>.com.scorchepay.scorchepay"]
  }
}
```

Then in Xcode, for the Runner target: Signing & Capabilities → + Capability →
Associated Domains → add `webcredentials:your-domain.com` (iOS and macOS
targets). This needs a paid Apple developer team. While developing,
`webcredentials:your-domain.com?mode=developer` skips Apple's CDN cache
(enable Associated Domains Development in the device's Developer settings).
Simulators need Face ID enrolled (Features → Face ID → Enrolled).

## Backend contract

| Call | Request | Response |
| --- | --- | --- |
| Start registration (signed in) | session token | `PublicKeyCredentialCreationOptions` JSON |
| Finish registration (signed in) | session token, registration response JSON | — |
| Start login | — | `PublicKeyCredentialRequestOptions` JSON (empty `allowCredentials`: discoverable) |
| Finish login | assertion response JSON | session token |

The mock (`BackendService`) checks the challenge, type and credential ID only.
It does **not** verify attestation or assertion signatures; the real backend
must, with a WebAuthn library (e.g. `webauthn-rs`).

## Debugging

`PasskeyAuthenticator(debugMode: true)` (in `passkey_service.dart`) runs the
package's doctor, which checks the RP ID and association files and reports
problems.
