import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_icons.dart';
import '../../core/formatters.dart';
import '../../core/widgets/status_badge.dart';
import '../../state/models/connected_wallet.dart';
import '../../state/providers/wallets_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';

/// Whether [balance] covers [sats]: null while unknown (loading or
/// failed, or no amount to cover), so callers don't block a payment on a
/// balance they couldn't read.
bool? coversAmount(AsyncValue<int> balance, int? sats) {
  final value = balance.valueOrNull;
  if (sats == null || value == null || balance.isLoading) return null;
  return value >= sats;
}

/// One wallet in a list, with a live balance preview so the user can pick
/// one that has funds: used by the dashboard's wallet switcher and the
/// checkout's "Wallet to pay from" sheet. With [requiredSats], flags a
/// balance that doesn't cover it. [trailing] adds actions (e.g. remove).
class WalletTile extends ConsumerWidget {
  const WalletTile({
    super.key,
    required this.wallet,
    required this.selected,
    required this.onTap,
    this.requiredSats,
    this.trailing,
  });

  final ConnectedWallet wallet;
  final bool selected;
  final VoidCallback onTap;
  final int? requiredSats;
  final Widget? trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final balance = ref.watch(walletBalanceProvider(wallet.id));
    final enough = coversAmount(balance, requiredSats);
    final ConnectedWallet(:testNetworkLabel, :detailLine) = wallet;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: EdgeInsets.fromLTRB(14, 12, trailing == null ? 14 : 4, 12),
        decoration: BoxDecoration(
          color: selected ? AppColors.accentSoft : AppColors.surface3,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: selected
                  ? AppColors.accent.withValues(alpha: 0.5)
                  : AppColors.border),
        ),
        child: Row(
          spacing: 12,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: selected ? AppColors.accent : AppColors.surface2,
                shape: BoxShape.circle,
              ),
              child: Icon(AppIcons.bolt,
                  size: 18,
                  color: selected ? Colors.white : AppColors.textSecondary),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 2,
                children: [
                  Row(
                    spacing: 8,
                    children: [
                      Flexible(
                        child: Text(wallet.name,
                            style: AppText.cardTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                      if (testNetworkLabel != null)
                        StatusBadge(
                            label: testNetworkLabel, tone: BadgeTone.info),
                    ],
                  ),
                  if (detailLine != null)
                    Text(detailLine,
                        style: AppText.caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  if (enough == false)
                    Text('${formatSats(balance.requireValue)} · not enough',
                        style:
                            AppText.caption.copyWith(color: AppColors.loss))
                  else
                    WalletBalanceText(balance: balance),
                ],
              ),
            ),
            if (selected)
              Icon(AppIcons.check, size: 18, color: AppColors.accent),
            if (trailing case final trailing?) trailing,
          ],
        ),
      ),
    );
  }
}

/// A wallet's balance in sats: a spinner while loading, a dash when it
/// couldn't be read.
class WalletBalanceText extends StatelessWidget {
  const WalletBalanceText({super.key, required this.balance, this.style});

  final AsyncValue<int> balance;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    if (balance.isLoading) {
      return const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2));
    }
    final sats = balance.valueOrNull;
    return Text(sats == null ? '—' : formatSats(sats),
        style: style ?? AppText.caption);
  }
}
