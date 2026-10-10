import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'app_routes.dart';
import 'features/auth/login_screen.dart';
import 'features/auth/signup_screen.dart';
import 'features/auth/welcome_screen.dart';
import 'features/dashboard/vtu_dashboard_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/onboarding/scorch_preview_screen.dart';
import 'state/providers/app_state_notifier.dart';
import 'state/providers/providers.dart';

/// Screens that need a session. Signed out, they redirect to the
/// signed-out entry point, then continue here after login.
const _protected = {AppRoutes.home};

/// Screens for signed-out users only. Signed in, they redirect to home
/// (or wherever login was continuing to).
const _signedOutOnly = {AppRoutes.welcome, AppRoutes.signup, AppRoutes.login};

/// The app's router. All session-driven navigation happens in [_redirect]:
/// it re-runs whenever sign-in or onboarding state changes, so screens and
/// the notifier never navigate on login/logout themselves.
///
/// Screens inside a flow (sign-up -> OTP -> PIN, KYC, ...) still push plain
/// MaterialPageRoutes on top; a redirect replaces them along with the rest.
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier(0);
  ref.listen(
    appStateProvider.select((s) => (
          s.valueOrNull?.isLoggedIn,
          s.valueOrNull?.localState.showOnboarding,
        )),
    (_, __) => refresh.value++,
  );

  final router = GoRouter(
    initialLocation: AppRoutes.home,
    refreshListenable: refresh,
    redirect: (_, state) => _redirect(ref, state),
    routes: [
      GoRoute(
          path: AppRoutes.onboarding,
          builder: (_, __) => const OnboardingScreen()),
      GoRoute(
        path: AppRoutes.welcome,
        builder: (_, __) => const WelcomeScreen(),
        routes: [
          GoRoute(path: 'signup', builder: (_, __) => const SignUpScreen()),
          GoRoute(path: 'login', builder: (_, __) => const LoginScreen()),
        ],
      ),
      GoRoute(
          path: AppRoutes.home, builder: (_, __) => const VtuDashboardScreen()),
      if (kDebugMode)
        GoRoute(
            path: '/scorch-preview',
            builder: (_, __) => const ScorchPreviewScreen()),
    ],
    onException: (_, __, router) => router.go(AppRoutes.home),
  );

  ref.onDispose(() {
    router.dispose();
    refresh.dispose();
  });
  return router;
});

String? _redirect(Ref ref, GoRouterState state) {
  // ScorchePayApp only mounts the router once app state has a value (the
  // splash shows until then), so this is just a guard.
  final appState = ref.read(appStateProvider).valueOrNull;
  if (appState == null) return null;
  final location = state.matchedLocation;

  // First run: onboarding before anything else.
  if (ref.read(showOnboardingProvider)) {
    return location == AppRoutes.onboarding ? null : AppRoutes.onboarding;
  }

  if (appState.isLoggedIn) {
    if (location != AppRoutes.onboarding &&
        !_signedOutOnly.contains(location)) {
      return null;
    }
    // Just logged in (or opened a signed-out screen): continue to where
    // login was sent from, if anywhere.
    final from = state.uri.queryParameters['from'];
    return from != null && from.startsWith('/') ? from : AppRoutes.home;
  }

  // Signed out.
  if (location != AppRoutes.onboarding && !_protected.contains(location)) {
    return null;
  }
  // Returning users go to login (over welcome), new users to welcome.
  final entry =
      ref.read(hasLoggedInBeforeProvider) ? AppRoutes.login : AppRoutes.welcome;
  // Remember a protected destination so login can continue to it. Home is
  // the default after login anyway, so it isn't worth carrying.
  final continueTo = state.uri.toString();
  if (!_protected.contains(location) || continueTo == AppRoutes.home) {
    return entry;
  }
  return Uri(path: entry, queryParameters: {'from': continueTo}).toString();
}
