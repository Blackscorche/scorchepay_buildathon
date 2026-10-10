import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../app_routes.dart';
import '../../core/widgets/scorch_mascot.dart';
import '../../core/widgets/scorchepay_logo.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/decorative_rings.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';

/// Landing screen after onboarding — branches into sign up or log in.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.page,
      body: Stack(
        children: [
          const Positioned.fill(child: AuthBackdrop()),
          SafeArea(
            child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                    child: ConstrainedBox(
                        constraints:
                            BoxConstraints(minHeight: constraints.maxHeight),
                        child: IntrinsicHeight(
                            child: Center(
                                child: ConstrainedBox(
                                    constraints:
                                        const BoxConstraints(maxWidth: 480),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 24),
                                      child: Column(
                                        children: [
                                          const SizedBox(height: 32),
                                          const Spacer(flex: 2),
                                          const SizedBox(width: 170, height: 190,
                                            child: Stack(alignment: Alignment.bottomCenter, clipBehavior: Clip.none, children: [
                                              ScorchePayLogo(size: 112),
                                              Positioned(bottom: 78, child: ScorchMascot(size: 92)),
                                            ])),
                                          const SizedBox(height: 18),
                                          Text('ScorchePay',
                                              style: AppText.pageTitle),
                                          const SizedBox(height: 8),
                                          Text(
                                            'Money, sorted. Fiat and crypto in one place.',
                                            textAlign: TextAlign.center,
                                            style: AppText.bodyMuted,
                                          ),
                                          const SizedBox(height: 24),
                                          const Spacer(flex: 2),
                                          const SizedBox(height: 24),
                                          PrimaryButton(
                                            label: 'Create an account',
                                            onPressed: () {
                                              context.go(AppRoutes.signup);
                                            },
                                          ),
                                          const SizedBox(height: 10),
                                          SecondaryButton(
                                            label: 'I already have an account',
                                            onPressed: () {
                                              context.go(AppRoutes.login);
                                            },
                                          ),
                                          const SizedBox(height: 18),
                                          Text(
                                            "By continuing you agree to ScorchePay's Terms & Privacy Policy",
                                            textAlign: TextAlign.center,
                                            style: AppText.caption,
                                          ),
                                          const SizedBox(height: 12),
                                        ],
                                      ),
                                    ))))))),
          ),
        ],
      ),
    );
  }
}
