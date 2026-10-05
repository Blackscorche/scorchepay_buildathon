import 'package:flutter/material.dart';
import '../../core/widgets/scorch_mascot.dart';
import '../../app_routes.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/decorative_rings.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';

class _OnboardingSlide {
  const _OnboardingSlide(
      {required this.activity,
      required this.category,
      required this.title,
      required this.body});
  final ScorchActivity activity;
  final String category;
  final String title;
  final String body;
}

const _slides = [
  _OnboardingSlide(
    activity: ScorchActivity.pay,
    category: 'EVERYDAY BILLS',
    title: 'Make room for everyday life.',
    body: 'Airtime, data, bills. Pay for everyday bills with crypto.',
  ),
];

/// A feature-led introduction with a matching Scorch scene for each pillar.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _finish() {
    Navigator.of(context).pushReplacementNamed(AppRoutes.welcome);
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _page == _slides.length - 1;
    final hasMoreThanAChild = _slides.length > 1;

    var skipText = Align(
      alignment: Alignment.topLeft,
      child: TextButton(
        onPressed: _finish,
        child: Text(
          'Skip',
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            color: AppColors.muted,
          ),
        ),
      ),
    );
    return Scaffold(
      backgroundColor: AppColors.page,
      body: Stack(
        children: [
          const Positioned.fill(child: AuthBackdrop()),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: Column(
                children: [
                  if (hasMoreThanAChild) skipText,
                  Expanded(
                    child: PageView.builder(
                      controller: _controller,
                      itemCount: _slides.length,
                      onPageChanged: (i) => setState(() => _page = i),
                      itemBuilder: (context, i) {
                        final slide = _slides[i];
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: LayoutBuilder(
                              builder: (context, constraints) =>
                                  SingleChildScrollView(
                                      child: ConstrainedBox(
                                          constraints: BoxConstraints(
                                              minHeight: constraints.maxHeight),
                                          child: Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              ScorchMascot(
                                                activity: slide.activity,
                                                size: MediaQuery.sizeOf(context)
                                                            .height <
                                                        700
                                                    ? 180
                                                    : 240,
                                                animate: i == _page,
                                              ),
                                              const SizedBox(height: 20),
                                              Text(slide.category,
                                                  textAlign: TextAlign.center,
                                                  style: TextStyle(
                                                      fontSize: 10.5,
                                                      letterSpacing: 1.4,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      color: AppColors.accent)),
                                              const SizedBox(height: 12),
                                              Text(
                                                slide.title,
                                                textAlign: TextAlign.center,
                                                style: AppText.pageTitle
                                                    .copyWith(fontSize: 22),
                                              ),
                                              const SizedBox(height: 12),
                                              Text(
                                                slide.body,
                                                textAlign: TextAlign.center,
                                                style: AppText.bodyMuted
                                                    .copyWith(
                                                        fontSize: 13.5,
                                                        height: 1.4),
                                              ),
                                            ],
                                          )))),
                        );
                      },
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(_slides.length, (i) {
                      final active = i == _page;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: active ? 20 : 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: active ? AppColors.accent : AppColors.surface3,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      );
                    }),
                  ),
                  const SizedBox(height: 24),
                  PrimaryButton(
                    label: isLast ? 'Get Started' : 'Next',
                    onPressed: () {
                      if (isLast) {
                        _finish();
                      } else if (MediaQuery.disableAnimationsOf(context)) {
                        _controller.jumpToPage(_page + 1);
                      } else {
                        _controller.nextPage(
                          duration: const Duration(milliseconds: 280),
                          curve: Curves.easeOut,
                        );
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
