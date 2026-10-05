import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';

/// A single ember-tinted ring outline — the shared visual atom behind
/// both [AuthBackdrop] and the wealth hero card, so the "circles" motif
/// reads as one consistent brand device everywhere it appears.
class RingCircle extends StatelessWidget {
  const RingCircle(
      {super.key, required this.size, required this.color, this.width = 22});

  final double size;
  final Color color;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color, width: width)),
    );
  }
}

/// Full-screen decorative backdrop for auth/onboarding screens — a
/// larger-scale version of the ring cluster used on the wealth hero
/// card, so account creation feels like the same product as the rest of
/// the app instead of a bolted-on generic auth template. Purely
/// decorative: wrap it in `Positioned.fill` behind real content, and it
/// never intercepts touches.
class AuthBackdrop extends StatelessWidget {
  const AuthBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ClipRect(
        child: Stack(
          children: [
            Positioned(
                top: -110,
                right: -90,
                child: RingCircle(
                    size: 300,
                    color: AppColors.accent.withValues(alpha: 0.35),
                    width: 34)),
            Positioned(
                top: -10,
                right: -130,
                child: RingCircle(
                    size: 200,
                    color: AppColors.accent.withValues(alpha: 0.55),
                    width: 36)),
            Positioned(
                bottom: -150,
                left: -110,
                child: RingCircle(
                    size: 280,
                    color: Colors.white.withValues(alpha: 0.05),
                    width: 30)),
            Positioned(
                bottom: -40,
                left: -40,
                child: RingCircle(
                    size: 130,
                    color: AppColors.accent.withValues(alpha: 0.18),
                    width: 24)),
          ],
        ),
      ),
    );
  }
}
