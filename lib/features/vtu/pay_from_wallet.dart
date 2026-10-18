import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_icons.dart';
import '../../core/widgets/app_modal.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/status_badge.dart';
import '../../state/models/connected_wallet.dart';
import '../../state/providers/wallets_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../wallet/connect_wallet_screen.dart';
import '../wallet/wallet_tile.dart';

/// The wallet to pay from on a bill: [walletId] when it's still
/// connected, otherwise the current wallet. Null when there are none.
ConnectedWallet? payingWallet(WidgetRef ref, String? walletId) {
  final state = ref.watch(walletsProvider).valueOrNull;
  if (state == null) return null;
  return state.wallets.where((w) => w.id == walletId).firstOrNull ??
      state.current;
}

/// "Pay from" card, like a bank's account-to-debit picker: the chosen
/// wallet with its balance. Tapping it opens [showWalletPicker].
/// With [requiredSats], warns when the balance doesn't cover it.
class PayFromWalletCard extends ConsumerWidget {
  const PayFromWalletCard({
    super.key,
    required this.wallet,
    required this.onChanged,
    this.requiredSats,
  });

  final ConnectedWallet wallet;
  final ValueChanged<String> onChanged;
  final int? requiredSats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final balance = ref.watch(walletBalanceProvider(wallet.id));
    final enough = coversAmount(balance, requiredSats);
    final ConnectedWallet(:testNetworkLabel) = wallet;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 6,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () async {
            final picked = await showWalletPicker(context,
                selectedId: wallet.id, requiredSats: requiredSats);
            if (picked != null) onChanged(picked);
          },
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            decoration: BoxDecoration(
              color: AppColors.surface2,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: enough == false
                      ? AppColors.loss.withValues(alpha: 0.6)
                      : AppColors.border),
            ),
            child: Row(
              spacing: 12,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 4,
                    children: [
                      Row(
                        spacing: 6,
                        children: [
                          Flexible(
                            child: Text(wallet.name,
                                style: AppText.cardTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                          ),
                          Icon(AppIcons.chevronDown,
                              size: 18, color: AppColors.accent),
                        ],
                      ),
                      Row(
                        spacing: 6,
                        children: [
                          Text('Pay from this wallet', style: AppText.caption),
                          if (testNetworkLabel != null)
                            StatusBadge(
                                label: testNetworkLabel, tone: BadgeTone.info),
                        ],
                      ),
                    ],
                  ),
                ),
                WalletBalanceText(
                    balance: balance,
                    style: AppText.cardTitle.copyWith(fontSize: 17)),
              ],
            ),
          ),
        ),
        if (enough == false)
          Text(
              "Not enough in this wallet. Pick another wallet or add funds to it.",
              style: AppText.caption.copyWith(color: AppColors.loss)),
        if (balance.hasError && !balance.isLoading)
          GestureDetector(
            onTap: () => ref.invalidate(walletBalanceProvider(wallet.id)),
            child: Text("Couldn't check the balance. Tap to try again.",
                style: AppText.caption.copyWith(color: AppColors.warn)),
          ),
      ],
    );
  }
}

/// Bottom sheet listing every connected wallet with its balance, so the
/// user can pick one that covers the bill. Resolves to the picked wallet's
/// ID, or null if dismissed.
Future<String?> showWalletPicker(BuildContext context,
    {required String selectedId, int? requiredSats}) async {
  final result = await showAppSheet<String>(
    context,
    builder: (_) =>
        _WalletPicker(selectedId: selectedId, requiredSats: requiredSats),
  );
  if (result == _connectAnother && context.mounted) {
    final wallet = await openConnectWallet(context);
    return wallet?.id;
  }
  return result;
}

const _connectAnother = '__connect__';

class _WalletPicker extends ConsumerWidget {
  const _WalletPicker({required this.selectedId, this.requiredSats});

  final String selectedId;
  final int? requiredSats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wallets =
        ref.watch(walletsProvider).valueOrNull?.wallets ?? const [];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 10,
      children: [
        Text('Wallet to pay from', style: AppText.detailTitle),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              spacing: 8,
              children: [
                for (final wallet in wallets)
                  WalletTile(
                    wallet: wallet,
                    selected: wallet.id == selectedId,
                    requiredSats: requiredSats,
                    onTap: () => Navigator.of(context).pop(wallet.id),
                  ),
              ],
            ),
          ),
        ),
        SecondaryButton(
          label: 'Connect another wallet',
          icon: AppIcons.plus,
          onPressed: () => Navigator.of(context).pop(_connectAnother),
        ),
      ],
    );
  }
}

/// Shown in place of the VTU flows while no wallet is connected: bills
/// are paid from the user's own wallet, so they need one first.
///
/// Without [showConnectButton] it points to the wallet section below
/// instead (the dashboard, which has its own Connect wallet button).
class ConnectWalletNotice extends StatelessWidget {
  const ConnectWalletNotice({super.key, this.showConnectButton = true});

  final bool showConnectButton;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.statusSoft(AppColors.warn),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.warn.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 10,
            children: [
              Icon(AppIcons.lock, size: 18, color: AppColors.warn),
              Expanded(
                child: Text(
                    showConnectButton
                        ? 'Connect a Lightning wallet to pay bills. You pay '
                            'from your own wallet, so ScorchePay never holds '
                            'your funds.'
                        : 'Connect a Lightning wallet below to pay bills. You '
                            'pay from your own wallet, so ScorchePay never '
                            'holds your funds.',
                    style: AppText.body.copyWith(fontSize: 13)),
              ),
            ],
          ),
          if (showConnectButton)
            PrimaryButton(
              label: 'Connect wallet',
              icon: AppIcons.plus,
              onPressed: () => openConnectWallet(context),
            ),
        ],
      ),
    );
  }
}
