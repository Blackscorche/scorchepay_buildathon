import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_icons.dart';
import '../../core/async_action.dart';
import '../../core/formatters.dart';
import '../../core/widgets/app_modal.dart';
import '../../core/widgets/buttons.dart';
import '../../state/models/vtu.dart';
import '../../state/providers/app_state_notifier.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';

/// "Verify to continue": shown when an order is over the user's tier
/// limits ([reason] says which). Verifying raises the tier; resolves to
/// true once verified, so the caller can retry the same order.
Future<bool> showVerifyPrompt(BuildContext context,
    {required String reason, required VtuLimits limits}) async {
  final verified = await showAppSheet<bool>(
    context,
    builder: (_) => _VerifyPrompt(reason: reason, limits: limits),
  );
  return verified ?? false;
}

class _VerifyPrompt extends ConsumerStatefulWidget {
  const _VerifyPrompt({required this.reason, required this.limits});

  final String reason;
  final VtuLimits limits;

  @override
  ConsumerState<_VerifyPrompt> createState() => _VerifyPromptState();
}

class _VerifyPromptState extends ConsumerState<_VerifyPrompt>
    with AsyncActionMixin {
  Future<void> _verify() async {
    final result = await runAction(
        () => ref.read(appStateProvider.notifier).verifyIdentity());
    if (mounted && result.hasValue) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final next = widget.limits.nextTier;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 20,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 6,
          children: [
            Container(
              width: 46,
              height: 46,
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: AppColors.accentSoft,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(AppIcons.shieldCheck, size: 21, color: AppColors.accent),
            ),
            Text('Verify to continue', style: AppText.detailTitle),
            Text(
                [
                  widget.reason,
                  if (next != null)
                    'Verify once with myPass to raise it to '
                        '${formatFiat(next.perOrder, next.currency)} per order and '
                        '${formatFiat(next.daily, next.currency)} a day. You share '
                        'verified details; ScorchePay stores no ID documents.',
                ].join(' '),
                style: AppText.bodyMuted),
            if (actionError != null)
              Text(actionError!,
                  style: AppText.caption.copyWith(color: AppColors.loss)),
          ],
        ),
        Column(
          spacing: 8,
          children: [
            PrimaryButton(
              label: 'Verify with myPass',
              icon: AppIcons.shieldCheck,
              loading: actionRunning,
              onPressed: _verify,
            ),
            SecondaryButton(
              label: 'Not now',
              onPressed: actionRunning
                  ? null
                  : () => Navigator.of(context).pop(false),
            ),
          ],
        ),
      ],
    );
  }
}
