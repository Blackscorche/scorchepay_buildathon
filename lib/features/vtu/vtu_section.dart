import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_icons.dart';
import '../../core/formatters.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/app_modal.dart';
import '../../core/widgets/icon_action_button.dart';
import '../../core/widgets/list_row.dart';
import '../../core/widgets/section_title.dart';
import '../../core/widgets/status_badge.dart';
import '../../state/models/vtu.dart';
import '../../state/providers/vtu_providers.dart';
import '../../state/providers/wallets_provider.dart';
import '../../state/services/mock_vtu_api.dart';
import '../../theme/app_text_styles.dart';
import 'order_status_screen.dart';
import 'pay_from_wallet.dart';
import 'vtu_order_screen.dart';
import 'vtu_ui.dart';

/// Dashboard "VTU & Bills": one tile per category. Disabled, with a prompt
/// to connect one, until the user has a wallet to pay from.
class VtuSection extends ConsumerWidget {
  const VtuSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wallets = ref.watch(walletsProvider);
    final hasWallet = wallets.valueOrNull?.isEmpty == false;
    final scenario = ref.watch(mockScenarioProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(
          'VTU & Bills',
          action: kDebugMode ? 'Mock: ${scenario.label}' : null,
          onAction: kDebugMode ? () => _showScenarioPicker(context) : null,
        ),
        AppCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 16,
            children: [
              IgnorePointer(
                ignoring: !hasWallet,
                child: Opacity(
                  opacity: hasWallet ? 1 : 0.4,
                  child: Row(
                    spacing: 4,
                    children: [
                      for (final category in BillCategory.values)
                        Expanded(
                          child: IconActionButton(
                            icon: category.icon,
                            label: category.label,
                            onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) =>
                                        VtuOrderScreen(category: category))),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // Only once loaded: no flash of the prompt on startup.
              if (wallets.hasValue && !hasWallet)
                const ConnectWalletNotice(showConnectButton: false),
            ],
          ),
        ),
      ],
    );
  }

  static void _showScenarioPicker(BuildContext context) {
    showAppSheet<void>(context, builder: (_) => const _ScenarioPicker());
  }
}

/// Debug builds: how the mock backend behaves.
class _ScenarioPicker extends ConsumerWidget {
  const _ScenarioPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(mockScenarioProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        Text('Mock backend scenario', style: AppText.detailTitle),
        Text('Debug builds only. Applies to new requests.',
            style: AppText.caption),
        const SizedBox(height: 6),
        for (final (i, scenario) in MockScenario.values.indexed)
          AppListRow(
            icon: scenario == current ? AppIcons.radioOn : AppIcons.radioOff,
            tint: scenario == current ? RowIconTint.accent : RowIconTint.neutral,
            title: scenario.label,
            subtitle: scenario.description,
            showChevron: false,
            showDivider: i < MockScenario.values.length - 1,
            onTap: () {
              ref.read(mockScenarioProvider.notifier).select(scenario);
              Navigator.of(context).pop();
            },
          ),
      ],
    );
  }
}

/// Dashboard "Recent orders": the latest few, each opening its receipt.
/// Hidden until there's at least one.
class RecentOrdersSection extends ConsumerWidget {
  const RecentOrdersSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orders = ref.watch(recentOrdersProvider).valueOrNull;
    if (orders == null || orders.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle('Recent orders'),
        AppCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(
            children: [
              for (final (i, order) in orders.indexed)
                AppListRow(
                  icon: order.category.icon,
                  tint: switch (order.status) {
                    OrderStatus.done => RowIconTint.good,
                    OrderStatus.refundable => RowIconTint.loss,
                    _ => RowIconTint.neutral,
                  },
                  title: order.title,
                  subtitle:
                      '${formatFiat(order.amount, order.currency)} · ${order.target}',
                  trailing: StatusBadge(
                      label: order.status.label, tone: order.status.tone),
                  showDivider: i < orders.length - 1,
                  onTap: () => openOrderStatus(context, order.id),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
