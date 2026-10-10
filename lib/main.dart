import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app_router.dart';
import 'features/onboarding/splash_screen.dart';
import 'state/providers/accent_color_provider.dart';
import 'state/providers/app_state_notifier.dart';
import 'state/providers/theme_mode_provider.dart';
import 'state/services/backend_service.dart';
import 'theme/app_colors.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer();
  // Start restoring the session (which builds app state) right away. It
  // may call the backend, so the splash shows while it loads instead of
  // holding up the first frame here (see ScorchePayApp's builder).
  container.read(appStateProvider);

  runApp(UncontrolledProviderScope(
    container: container,
    child: const ScorchePayApp(),
  ));
}

class ScorchePayApp extends ConsumerWidget {
  const ScorchePayApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final accentColor = ref.watch(accentColorProvider);
    // The splash shows (instead of the router) until app state has a first
    // value. Selecting `hasValue` means this only rebuilds when the gate
    // opens, not on every commit; it never goes back to false, since
    // reloads and errors keep the previous value.
    final ready = ref.watch(appStateProvider.select((s) => s.hasValue));
    return MaterialApp.router(
      routerConfig: ref.watch(routerProvider),
      title: 'ScorchePay',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: mode.flutterThemeMode,
      // AppColors' neutral and accent tokens are mutable static getters
      // rather than InheritedWidget-backed values, so a brightness or
      // accent change has to force every descendant to actually rebuild
      // — MaterialApp.builder is the one hook that runs with a real
      // BuildContext (for MediaQuery) before any route content builds.
      // Configuring AppColors here, then keying the child on both
      // values, remounts the whole visible subtree (not the Navigator
      // itself) so every screen re-reads fresh colors without losing
      // the current route.
      builder: (context, child) {
        final resolved = switch (mode) {
          AppThemeMode.light => Brightness.light,
          AppThemeMode.dark => Brightness.dark,
          AppThemeMode.system => MediaQuery.platformBrightnessOf(context),
        };
        AppColors.configure(resolved);
        AppColors.configureAccent(accentColor);
        return KeyedSubtree(
          key: ValueKey((resolved, accentColor)),
          child: _SessionErrorListener(
              child: ready ? child! : const SplashScreen()),
        );
      },
    );
  }
}

/// Shows errors from building app state (restoring or reloading the
/// session) and recovers from them. Sits inside MaterialApp's builder, so
/// it's below the app's ScaffoldMessenger, and above the splash, so
/// startup errors are covered too. Navigation after recovering is the
/// router's job (see `app_router.dart`).
class _SessionErrorListener extends ConsumerWidget {
  const _SessionErrorListener({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(appStateProvider, (prev, next) {
      if (!next.hasError || next.isLoading || next.error == prev?.error) return;
      final before = prev?.valueOrNull;
      final error = next.error;
      // Skip when already signed out: that's a failed login attempt,
      // which the login screen reports itself.
      if (before?.isLoggedIn != false) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(error is AuthException
                ? error.message
                : "Couldn't restore your session. Check your connection.")));
      }
      // A signed-in session survives a transient failure: the error state
      // keeps the previous value (and the token is kept). Otherwise —
      // rejected session, or nothing to fall back on (e.g. first launch) —
      // continue signed out.
      final keepSession = before?.isLoggedIn == true && error is! AuthException;
      if (!keepSession) {
        ref.read(appStateProvider.notifier).continueSignedOut();
      }
    });
    return child;
  }
}
