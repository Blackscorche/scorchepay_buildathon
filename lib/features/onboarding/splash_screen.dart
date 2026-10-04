import 'package:flutter/material.dart';
import '../../core/widgets/scorchepay_logo.dart';
import '../../app_routes.dart';
import '../../core/widgets/decorative_rings.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';

/// First screen shown on app launch — brand mark, then auto-advances into
/// the onboarding carousel.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 1400), () {
      // Guard on isCurrent, not just mounted: Navigator's default initial
      // route generation always builds "/" as the base of the stack
      // beneath whatever initialRoute is actually shown, so this timer
      // still fires even when Splash was never the visible screen. Without
      // this check it would hijack navigation on top of an unrelated route.
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) {
        Navigator.of(context).pushReplacementNamed(AppRoutes.onboarding);
      }
    });
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
