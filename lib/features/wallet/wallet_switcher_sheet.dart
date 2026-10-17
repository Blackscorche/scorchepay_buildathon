import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_icons.dart';
import '../../core/widgets/app_modal.dart';
import '../../core/widgets/status_badge.dart';
import '../../state/models/connected_wallet.dart';
import '../../state/providers/wallets_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import 'connect_wallet_screen.dart';

/// Bottom sheet listing the connected wallets, like a bank app's account
/// switcher: pick one to make it current, connect another, or remove them.
Future<void> showWalletSwitcher(BuildContext context) async {
  final action = await showAppSheet<_SheetAction>(
    context,
    builder: (_) => const _WalletSwitcher(),
  );
  if (action == _SheetAction.connect && context.mounted) {
    await openConnectWallet(context);
  }
}

enum _SheetAction { connect }

class _WalletSwitcher extends ConsumerWidget {
  const _WalletSwitcher();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(walletsProvider).valueOrNull;
    final wallets = state?.wallets ?? const <ConnectedWallet>[];
    final currentId = state?.current?.id;
    final notifier = ref.read(walletsProvider.notifier);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 10,
      children: [
        Text('Your wallets', style: AppText.detailTitle),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              spacing: 8,
              children: [
              for (final wallet in wallets)
                _WalletRow(
                  wallet: wallet,
                  selected: wallet.id == currentId,
                  onTap: () async {
                    await notifier.select(wallet.id);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  onRemove: () async {
                    final confirmed = await _confirm(
                      context,
                      title: 'Remove ${wallet.name}?',
                      message: _revokeHint,
                      action: 'Remove',
                    );
                    if (confirmed) await notifier.remove(wallet.id);
                    // Nothing left to switch between.
                    if (confirmed && wallets.length == 1 && context.mounted) {
                      Navigator.of(context).pop();
                    }
                  },
                ),
              ],
            ),
          ),
        ),
        Column(
          children: [
            _ActionRow(
              icon: AppIcons.plus,
              label: 'Connect another wallet',
              onTap: () => Navigator.of(context).pop(_SheetAction.connect),
            ),
            _ActionRow(
              icon: AppIcons.trash,
              label: 'Remove all wallets',
              destructive: true,
              onTap: () async {
                final confirmed = await _confirm(
                  context,
                  title: 'Remove all wallets?',
                  message: 'You can connect them again later. $_revokeHint',
                  action: 'Remove all',
                );
                if (!confirmed) return;
                await notifier.removeAll();
                if (context.mounted) Navigator.of(context).pop();
              },
            ),
          ],
        ),
      ],
    );
  }

  static const _revokeHint = 'This only removes it from ScorchePay. To stop '
      'the connection completely, revoke it in your wallet app too.';

  static Future<bool> _confirm(BuildContext context,
      {required String title,
      required String message,
      required String action}) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action, style: TextStyle(color: AppColors.loss)),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}

class _WalletRow extends StatelessWidget {
  const _WalletRow({
    required this.wallet,
    required this.selected,
    required this.onTap,
    required this.onRemove,
  });

  final ConnectedWallet wallet;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final ConnectedWallet(:testNetworkLabel, :detailLine) = wallet;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
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
            Icon(AppIcons.bolt,
                size: 18,
                color: selected ? AppColors.accent : AppColors.textSecondary),
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
                ],
              ),
            ),
            if (selected)
              Icon(AppIcons.check, size: 18, color: AppColors.accent),
            IconButton(
              tooltip: 'Remove',
              onPressed: onRemove,
              icon: Icon(AppIcons.trash, size: 17, color: AppColors.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive ? AppColors.loss : AppColors.textPrimary;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 13),
        child: Row(
          spacing: 12,
          children: [
            Icon(icon, size: 18, color: color),
            Text(label, style: AppText.body.copyWith(color: color)),
          ],
        ),
      ),
    );
  }
}
