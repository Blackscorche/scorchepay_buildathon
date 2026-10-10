import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/widgets/scorchepay_logo.dart';
import '../../app_routes.dart';
import '../auth/auth_entry.dart';
import '../../core/widgets/decorative_rings.dart';
import '../../state/providers/app_state_notifier.dart';
import '../../state/providers/providers.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';

/// First screen shown on app launch — brand mark, then auto-advances to
/// onboarding (first run), home (stored session), login (returning user)
/// or welcome (new user).
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _goNext();
  }

  Future<void> _goNext() async {
    // Session restore may call the backend, so it runs alongside the
    // minimum splash time rather than blocking app startup in main().
    final (appState, _) = await (
      ref.read(appStateProvider.future),
      Future<void>.delayed(const Duration(milliseconds: 1400)),
    ).wait;
    // Guard on isCurrent, not just mounted: Navigator's default initial
    // route generation always builds "/" as the base of the stack
    // beneath whatever initialRoute is actually shown, so this timer
    // still fires even when Splash was never the visible screen. Without
    // this check it would hijack navigation on top of an unrelated route.
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return;

    final navigator = Navigator.of(context);
    if (ref.read(showOnboardingProvider)) {
      navigator.pushReplacementNamed(AppRoutes.onboarding);
      return;
    }
    if (appState.isLoggedIn) {
      navigator.pushReplacementNamed(AppRoutes.home);
    } else {
      openAuthEntry(navigator,
          returningUser: ref.read(hasLoggedInBeforeProvider));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.page,
      body: Stack(
        children: [
          const Positioned.fill(child: AuthBackdrop()),
          SafeArea(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const ScorchePayLogo(size: 96),
                  const SizedBox(height: 18),
                  Text(
                    'ScorchePay',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text('Your Money OS', style: AppText.caption),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
