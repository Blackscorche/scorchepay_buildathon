import 'package:flutter/material.dart';

import '../../core/app_icons.dart';
import '../../core/formatters.dart';
import '../../core/widgets/status_badge.dart';
import '../../state/models/vtu.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';

/// How each bill category looks in the app.
extension BillCategoryUi on BillCategory {
  IconData get icon => switch (this) {
        BillCategory.airtime => AppIcons.phone,
        BillCategory.data => AppIcons.wifi,
        BillCategory.electricity => AppIcons.bolt,
        BillCategory.tv => AppIcons.tv,
      };

  String get subtitle => switch (this) {
        BillCategory.airtime => 'Top up any Nigerian network',
        BillCategory.data => 'Data bundles for any network',
        BillCategory.electricity => 'Prepaid tokens and postpaid bills',
        BillCategory.tv => 'Renew DStv, GOtv and StarTimes',
      };

  /// The status screen's heading once an order is done.
  String get doneTitle => switch (this) {
        BillCategory.airtime => 'Airtime sent',
        BillCategory.data => 'Data sent',
        BillCategory.electricity => 'Bill paid',
        BillCategory.tv => 'Subscription renewed',
      };

  String get billerLabel => switch (this) {
        BillCategory.airtime || BillCategory.data => 'Network',
        BillCategory.electricity => 'Electricity company',
        BillCategory.tv => 'Provider',
      };
}

extension AmountPricingUi on AmountPricing {
  /// "₦50 to ₦50,000", "At least ₦50", "Up to ₦50,000", or null when
  /// any amount goes.
  String? rangeText(String currency) => switch ((min, max)) {
        (final min?, final max?) =>
          '${formatFiat(min, currency)} to ${formatFiat(max, currency)}',
        (final min?, null) => 'At least ${formatFiat(min, currency)}',
        (null, final max?) => 'Up to ${formatFiat(max, currency)}',
        (null, null) => null,
      };
}

extension TargetKindUi on TargetKind {
  TextInputType get keyboardType => switch (this) {
        TargetKind.phone => TextInputType.phone,
        TargetKind.number => TextInputType.number,
        TargetKind.text => TextInputType.text,
      };
}

extension OrderStatusUi on OrderStatus {
  BadgeTone get tone => switch (this) {
        OrderStatus.done => BadgeTone.good,
        OrderStatus.refundable => BadgeTone.crit,
        OrderStatus.expired => BadgeTone.neutral,
        OrderStatus.refunded => BadgeTone.info,
        _ => BadgeTone.warn,
      };
}

/// A biller as a tappable tile: brand-coloured initial over its name.
class BillerTile extends StatelessWidget {
  const BillerTile(
      {super.key,
      required this.biller,
      required this.selected,
      required this.onTap});

  final Biller biller;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = biller.color ?? AppColors.accent;
    final enabled = biller.available;
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          decoration: BoxDecoration(
            color: selected ? AppColors.surface3 : AppColors.surface2,
            border: Border.all(
                color: selected
                    ? color.withValues(alpha: 0.7)
                    : AppColors.border),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 7,
            children: [
              Container(
                width: 26,
                height: 26,
                decoration:
                    BoxDecoration(color: color, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Text(
                  biller.label.characters.first,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: color.computeLuminance() > 0.5
                          ? Colors.black87
                          : Colors.white),
                ),
              ),
              Text(
                biller.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: selected
                        ? AppColors.textPrimary
                        : AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A selectable row for a data bundle or TV package.
class PlanRow extends StatelessWidget {
  const PlanRow(
      {super.key,
      required this.title,
      required this.price,
      this.subtitle,
      required this.selected,
      required this.onTap});

  final String title;
  final String? subtitle;
  final String price;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: selected ? AppColors.accentSoft : AppColors.surface2,
          border: Border.all(
              color: selected
                  ? AppColors.accent.withValues(alpha: 0.5)
                  : AppColors.border),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          spacing: 10,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                spacing: 2,
                children: [
                  Text(title, style: AppText.body),
                  if (subtitle != null)
                    Text(subtitle!, style: AppText.caption),
                ],
              ),
            ),
            Text(price,
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color:
                        selected ? AppColors.accent : AppColors.textPrimary)),
            Icon(selected ? AppIcons.check : AppIcons.chevronRight,
                size: 16, color: selected ? AppColors.accent : AppColors.muted),
          ],
        ),
      ),
    );
  }
}

/// A label/value line in a summary card.
class DetailLine extends StatelessWidget {
  const DetailLine(this.label, this.value, {super.key, this.trailing});

  final String label;
  final String value;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 12,
      children: [
        SizedBox(width: 92, child: Text(label, style: AppText.caption)),
        Expanded(
          child: Text(value,
              textAlign: TextAlign.right,
              style: AppText.body.copyWith(fontSize: 13)),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}
