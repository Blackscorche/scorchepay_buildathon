import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../../theme/app_theme.dart';

/// The single "service/action" icon tile used everywhere the app offers
/// a grid of shortcuts — home quick actions & services, the More hub,
/// Smart Pay's "pay for anything" grid, and the icon grids inside book
/// detail screens (Send's "more ways to send", Bills). Every one of
/// those used to be its own hand-rolled widget with a slightly different
/// flat/bordered look; this is the one, so the brand gradient only ever
/// has to be defined in [AppColors.accentGradient].
class IconActionButton extends StatelessWidget {
  const IconActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.size = 52,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final radius = size >= 50 ? AppRadius.lg : AppRadius.md;
    // Dense grids (the More hub, Bills, "more ways to send") use smaller
    // tiles and a much quieter glow than the 3-4-wide primary action
    // rows — a full bold glow on every one of many tiles reads as noisy
    // rather than lit.
    final isDense = size < 50;
    final glowOpacity = isDense ? 0.14 : 0.32;
    final glowBlur = isDense ? 8.0 : 16.0;
    // A touch darker than the raw brand gradient tokens (still derived
    // from them, not a new hardcoded hex) — the full-brightness gradient
    // read as too hot repeated across a whole tile grid.
    final gradient = LinearGradient(
      begin: AppColors.accentGradient.begin,
      end: AppColors.accentGradient.end,
      colors: [
        Color.lerp(AppColors.accentGradStart, Colors.black, 0.16)!,
        Color.lerp(AppColors.accentGradEnd, Colors.black, 0.16)!,
      ],
    );
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              gradient: gradient,
              borderRadius: BorderRadius.circular(radius),
              boxShadow: [
                BoxShadow(
                    color: AppColors.accent.withValues(alpha: glowOpacity),
                    blurRadius: glowBlur,
                    offset: const Offset(0, 4)),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              child: Stack(
                children: [
                  // Glass sheen: soft white highlight fading down from the
                  // top edge, so the tile reads as lit rather than flat.
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      height: size / 2,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.white.withValues(alpha: 0.16),
                            Colors.white.withValues(alpha: 0)
                          ],
                        ),
                      ),
                    ),
                  ),
                  Center(
                      child: Icon(icon,
                          size: size * 0.4,
                          color: Colors.white.withValues(alpha: 0.9))),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(label,
              style: AppText.navLabel
                  .copyWith(fontSize: 10.5, color: AppColors.textSecondary),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}
