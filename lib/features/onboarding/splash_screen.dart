import 'package:flutter/material.dart';
import '../../core/widgets/scorchepay_logo.dart';
import '../../core/widgets/decorative_rings.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';

/// First screen shown on app launch: the brand mark, displayed while app
/// state loads. ScorchePayApp moves on from here (to onboarding, home,
/// login or welcome) once the session has been restored.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

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
