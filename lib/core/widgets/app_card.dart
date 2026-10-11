import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Standard surface card used across every screen: 1px hairline border,
/// rounded corners, flat neutral fill. Kept deliberately quiet so the
/// hero card and the accent color are the only things that pop.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.margin,
    this.onTap,
    this.color,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      margin: margin ?? const EdgeInsets.only(bottom: 12),
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );
    if (onTap == null) return card;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.xl),
      child: card,
    );
  }
}

/// The "hero" balance/portfolio card — a soft vertical gradient, a 1px
/// light seam along the top edge, and a cluster of ember-tinted ring
/// circles bleeding off the top-right corner. This is the one card per
/// screen allowed a bit of visual weight; everything else stays flat.
/// Its gradient flips with the app theme (see [AppColors.heroGradient]),
/// so its own content should read against either variant — use the
/// regular theme-aware AppColors.* text tokens inside it, not fixed
/// light/dark ones.
class GlassHeroCard extends StatelessWidget {
  const GlassHeroCard({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: AppColors.borderStrong),
        gradient: AppColors.heroGradient,
      ),
      child: Stack(
        children: [
          Positioned(
              top: -70,
              right: -60,
              child: _ring(230, AppColors.accent.withValues(alpha: 0.45),
                  width: 28)),
          Positioned(
              top: -6,
              right: -86,
              child: _ring(150, AppColors.accent.withValues(alpha: 0.65),
                  width: 30)),
          Positioned(
              bottom: -90,
              left: -70,
              child: _ring(190, AppColors.textPrimary.withValues(alpha: 0.07),
                  width: 26)),
          Positioned(
            top: 0,
            left: 20,
            right: 20,
            child: Container(
              height: 1,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [
                  AppColors.textPrimary.withValues(alpha: 0),
                  AppColors.textPrimary.withValues(alpha: 0.18),
                  AppColors.textPrimary.withValues(alpha: 0),
                ]),
              ),
            ),
          ),
          Padding(
            padding: padding ?? const EdgeInsets.fromLTRB(20, 20, 20, 18),
            child: child,
          ),
        ],
      ),
    );
  }

  Widget _ring(double size, Color color, {double width = 22}) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: color, width: width)),
      ),
    );
  }
}
