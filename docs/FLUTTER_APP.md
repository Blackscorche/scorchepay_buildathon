# ScorchePay — Flutter app

A real Flutter implementation of the ScorchePay prototype: dark theme, ember-red
accent used sparingly, full auth/onboarding flow, and the Home / Wallet / Crypto
/ Smart Pay / More tabs covering the full product roadmap.

## Running it

This project was written in a sandboxed environment that could not download the
Flutter/Dart SDK (its bootstrap host is blocked on that network), so it has
**not been compiled or run** the way the earlier HTML prototype was. It was
built carefully by hand and reviewed with static checks (import resolution,
brace/paren balance, cross-referencing every custom widget's constructor
against how it's called — see "What was verified" below), but you should treat
first `flutter run` as the first real compile.

```bash
flutter pub get
flutter run          # or: flutter run -d chrome
```

Requires a normal Flutter install (`flutter doctor`) — stable channel, any
recent 3.x SDK. No non-default packages are used beyond `cupertino_icons`, so
`pub get` should resolve instantly.

If `flutter analyze` turns up anything, it'll most likely be small — a missing
`const`, an unused import — rather than a structural problem; the navigation
graph and widget wiring were checked by hand end-to-end.

## App structure

```
lib/
  theme/            colors, text styles, ThemeData
  core/
    app_icons.dart  semantic icon lookup (Material Symbols, no icon packages)
    widgets/        AppCard, GlassHeroCard, buttons, list rows, badges,
                     progress bar, toggle, token/flag chips, PIN + OTP inputs,
                     charts/ (line, donut, bar — all CustomPainter, no fl_chart)
  data/             models.dart + mock_data.dart (all placeholder content)
  features/
    onboarding/     splash, 4-slide onboarding carousel
    auth/           welcome, sign up, log in, OTP, create/confirm PIN,
                     biometric prompt
    shell/          bottom-nav scaffold (Home / Wallet / Pay / Crypto / More)
    home, wallet, crypto, smart_pay, more/   the five main tabs
```

`more/book_detail_screen.dart` is one data-driven screen that renders all ~19
roadmap items (Send, Escrow, Savings, Security, Developer Platform, etc.) by
switching on `BookType` — the same approach the HTML prototype used, so the
full roadmap is reachable without 19 bespoke screen files.

## Flow

```
Splash --(1.4s)--> Onboarding (4 slides) --> Welcome
Welcome --> Sign Up --> OTP --> Create PIN --> Confirm PIN --> Biometric prompt --> Home
Welcome --> Log In (phone/email + 4-digit PIN) --> Home
```

"Home" clears the auth stack (`pushNamedAndRemoveUntil`), so the back button
never returns into onboarding/auth once you're in the app. There's no real
backend — any OTP code, any matching PIN pair, and any login PIN is accepted.

## Design notes

- The brand ember-red (`AppColors.accent`) is reserved for the primary CTA,
  the Smart Pay tab/FAB, and a couple of highlighted list rows — never for
  chart data or the whole UI, so it stays a signal instead of wallpaper.
- Gains/losses use their own green/red (`AppColors.gain` / `AppColors.loss`),
  deliberately a different hue from the brand accent.
- No custom font is bundled — text styling leans on weight/letter-spacing on
  the platform default (San Francisco / Roboto), which is how several
  production fintech apps actually ship.
- No icon-font/vector-icon package dependency — `AppIcons` maps semantic names
  onto Flutter's built-in Material Symbols so the whole thing builds offline
  once `pub get` has run once.
