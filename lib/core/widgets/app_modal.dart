import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../../theme/app_theme.dart';
import 'buttons.dart';

/// Opens a dark, rounded bottom sheet with a drag handle — the app's one
/// modal primitive. Every "flow started" / "copied" / confirmation
/// surface in the app should go through this (or [showAppModal] below)
/// instead of a SnackBar, so acknowledging an action always feels like
/// part of the product rather than a system toast.
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool scrollable = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) {
      return Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: SafeArea(
          top: false,
          child: Container(
            margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.86),
            decoration: BoxDecoration(
              color: AppColors.surface2,
              borderRadius: BorderRadius.circular(AppRadius.xl),
              border: Border.all(color: AppColors.borderStrong),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
                    child: builder(ctx),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// Simple icon + title + message acknowledgement modal — the modal
/// equivalent of a toast, used for "flow started", "copied", and other
/// one-line confirmations that previously showed a SnackBar.
Future<void> showAppModal(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String message,
  String actionLabel = 'Got it',
  Color? iconColor,
}) {
  final color = iconColor ?? AppColors.accent;
  return showAppSheet<void>(
    context,
    builder: (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Icon(icon, size: 21, color: color),
        ),
        const SizedBox(height: 14),
        Text(title, style: AppText.detailTitle),
        const SizedBox(height: 6),
        Text(message,
            style: TextStyle(
                fontSize: 13, height: 1.45, color: AppColors.textSecondary)),
        const SizedBox(height: 20),
        PrimaryButton(
            label: actionLabel, onPressed: () => Navigator.of(ctx).pop()),
      ],
    ),
  );
}
