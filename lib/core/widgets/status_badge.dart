import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';

enum BadgeTone { good, warn, crit, info, neutral }

/// Small soft-fill status pill (Active / Pending / Verified …).
class StatusBadge extends StatelessWidget {
  const StatusBadge(
      {super.key, required this.label, this.tone = BadgeTone.neutral});

  final String label;
  final BadgeTone tone;

  Color get _color {
    switch (tone) {
      case BadgeTone.good:
        return AppColors.gain;
      case BadgeTone.warn:
        return AppColors.warn;
      case BadgeTone.crit:
        return AppColors.loss;
      case BadgeTone.info:
        return AppColors.info;
      case BadgeTone.neutral:
        return AppColors.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: tone == BadgeTone.neutral
            ? AppColors.surface3
            : c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            color: c,
            letterSpacing: 0.1),
      ),
    );
  }
}
