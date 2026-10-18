import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_icons.dart';
import '../../core/formatters.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/status_badge.dart';
import '../../state/models/connected_wallet.dart';
import '../../state/providers/app_state_notifier.dart';
import '../../state/providers/prices_provider.dart';
import '../../state/providers/wallets_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import 'connect_wallet_screen.dart';
import 'wallet_switcher_sheet.dart';

/// Dashboard section for the user's Lightning wallets: a prompt to connect
/// one, or the current wallet's balance. Tapping the wallet opens the
/// switcher. The balance comes with an estimate in the user's preferred
/// currency once the live BTC price loads.
class WalletSection extends ConsumerWidget {
  const WalletSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wallets = ref.watch(walletsProvider);
    return wallets.when(
      skipLoadingOnReload: true,
      loading: () => const AppCard(
        child: SizedBox(
          height: 96,
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      ),
      error: (error, _) => AppCard(
        onTap: () => ref.invalidate(walletsProvider),
        child: Text("Couldn't load your wallets. Tap to try again.",
            style: AppText.bodyMuted),
      ),
      data: (state) {
        final current = state.current;
        if (current == null) return const _ConnectWalletCard();
        return _CurrentWalletCard(wallet: current);
      },
    );
  }
}

class _ConnectWalletCard extends StatelessWidget {
  const _ConnectWalletCard();

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 14,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
                color: AppColors.accentSoft, shape: BoxShape.circle),
            child: Icon(AppIcons.bolt, size: 20, color: AppColors.accent),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              Text('Connect a Lightning wallet', style: AppText.cardTitle),
              Text(
                  'See your balance here and pay for top-ups from your own '
                  'wallet. ScorchePay never holds your funds.',
                  style: AppText.bodyMuted),
            ],
          ),
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

class _CurrentWalletCard extends ConsumerWidget {
  const _CurrentWalletCard({required this.wallet});

  final ConnectedWallet wallet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final balance = ref.watch(walletBalanceProvider(wallet.id));
    // Offline or rate-limited: no estimate, just sats.
    final btcPrice = ref.watch(btcPriceProvider).valueOrNull;
    final currency = ref.watch(appStateProvider
        .select((s) => s.requireValue.localState.preferredCurrency));
    final ConnectedWallet(:testNetworkLabel, :detailLine) = wallet;
    return AppCard(
      onTap: () => showWalletSwitcher(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Row(
            spacing: 8,
            children: [
              Text('LIGHTNING WALLET',
                  style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.muted,
                      letterSpacing: 0.7)),
              if (testNetworkLabel != null)
                StatusBadge(label: testNetworkLabel, tone: BadgeTone.info),
              const Spacer(),
              GestureDetector(
                onTap: () {
                  ref.invalidate(walletBalanceProvider(wallet.id));
                  ref.invalidate(btcPriceProvider);
                },
                child: Icon(AppIcons.refresh, size: 16, color: AppColors.muted),
              ),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 2,
            children: [
              Row(
                spacing: 4,
                children: [
                  Flexible(
                    child: Text(wallet.name,
                        style: AppText.cardTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
                  Icon(AppIcons.chevronDown, size: 18, color: AppColors.muted),
                ],
              ),
              if (detailLine != null)
                Text(detailLine,
                    style: AppText.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
            ],
          ),
          balance.when(
            skipLoadingOnRefresh: false,
            loading: () => const SizedBox(
              height: 34,
              child: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            ),
            error: (error, _) => Text(error.toString(),
                style: AppText.bodyMuted.copyWith(color: AppColors.loss)),
            data: (sats) {
              final converted = btcPrice == null ? null : sats / 1e8 * btcPrice;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(formatSats(sats),
                      style: AppText.heroNumber.copyWith(fontSize: 28)),
                  if (converted != null)
                    Text('≈ ${formatFiatDecimal(converted, currency)}',
                        style: AppText.caption),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
