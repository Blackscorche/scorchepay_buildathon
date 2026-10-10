import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app_routes.dart';
import 'features/auth/login_screen.dart';
import 'features/auth/welcome_screen.dart';
import 'features/auth/signup_screen.dart';
import 'features/dashboard/vtu_dashboard_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/onboarding/scorch_preview_screen.dart';
import 'features/onboarding/splash_screen.dart';
import 'state/providers/accent_color_provider.dart';
import 'state/providers/app_state_notifier.dart';
import 'state/providers/theme_mode_provider.dart';
import 'theme/app_colors.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer();
  // Start restoring the session (which builds app state) right away. It
  // may call the backend, so SplashScreen awaits `appStateProvider.future`
  // instead of holding up the first frame here.
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
    return MaterialApp(
      title: 'ScorchePay',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: mode.flutterThemeMode,
      initialRoute: AppRoutes.splash,
      routes: {
        if (kDebugMode) '/scorch-preview': (_) => const ScorchPreviewScreen(),
        AppRoutes.splash: (_) => const SplashScreen(),
        AppRoutes.onboarding: (_) => const OnboardingScreen(),
        AppRoutes.welcome: (_) => const WelcomeScreen(),
        AppRoutes.signup: (_) => const SignUpScreen(),
        AppRoutes.login: (_) => const LoginScreen(),
        AppRoutes.home: (_) => const VtuDashboardScreen(),
      },
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
            key: ValueKey((resolved, accentColor)), child: child!);
      },
    );
  }
}
