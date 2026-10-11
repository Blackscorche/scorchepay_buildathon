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
targets). This needs a paid Apple developer team; the free personal team
can't add Associated Domains. There's no way to use passkeys in an Apple app
without this link: missing either half fails with "Passkeys aren't set up for
this app yet" (`DomainNotAssociatedException`).

### Development mode (iOS and macOS)

Normally Apple's CDN fetches and caches the association file, so the domain
must be public and changes can take a day or more to reach devices. For
development builds you can bypass the CDN so the device fetches the file
directly from your server:

1. Use `webcredentials:your-domain.com?mode=developer` as the Associated
   Domains entry.
2. Turn developer mode on for the device:
   - iPhone/iPad: Settings → Developer → Associated Domains Development.
   - Mac: `sudo swcutil developer-mode -e true`.

Then edits to the file apply right away, and the domain only has to be
reachable from the test device (a staging or tunnel host works) rather than
from Apple.

What development mode does **not** skip: the entitlement, the paid team, the
association file itself, and HTTPS with a certificate the device trusts. It
also only applies to development-signed builds; TestFlight and App Store
builds ignore `?mode=developer` and always go through Apple's CDN, so release
builds need a plain `webcredentials:your-domain.com` entry and a public file.

Simulators need Face ID enrolled (Features → Face ID → Enrolled).

Without a paid team, test passkeys on web (`localhost`, no setup) or Android
(`assetlinks.json` only); on iOS the app falls back to PIN login.

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
