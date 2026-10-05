import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';

/// A single selectable pill — provider pickers, funding sources, trigger/
/// action pickers, anywhere a screen needs "choose one of these words".
class AppChoiceChip extends StatelessWidget {
  const AppChoiceChip(
      {super.key,
      required this.label,
      required this.selected,
      required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.accentSoft : AppColors.surface2,
          border: Border.all(
              color: selected
                  ? AppColors.accent.withValues(alpha: 0.5)
                  : AppColors.border),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: selected ? AppColors.accent : AppColors.textSecondary),
        ),
      ),
    );
  }
}
