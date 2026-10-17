import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_icons.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/icon_action_button.dart';
import '../../core/widgets/kyc_status_badge.dart';
import '../../core/widgets/section_title.dart';
import '../../data/coingecko_service.dart';
import '../../state/providers/app_state_notifier.dart';
import '../../state/providers/profile_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../bills/airtime_screen.dart';
import '../bills/bill_payment_screen.dart';
import '../bills/data_screen.dart';
import '../wallet/wallet_section.dart';

/// The entire app, trimmed to one screen: VTU/bill payments and the
/// user's connected Lightning wallets. No send money, escrow, savings, P2P,
/// gift cards, merchant/admin tooling or server-backed "live" mode —
/// this branch intentionally doesn't have those pages at all.
class VtuDashboardScreen extends ConsumerStatefulWidget {
  const VtuDashboardScreen({super.key});

  @override
  ConsumerState<VtuDashboardScreen> createState() => _VtuDashboardScreenState();
}

class _VtuDashboardScreenState extends ConsumerState<VtuDashboardScreen> {
  /// Live BTC price in USD for the wallet's dollar estimate; null until
  /// loaded (or when offline).
  double? _btcUsd;

  @override
  void initState() {
    super.initState();
    _loadLivePrices();
  }

  Future<void> _loadLivePrices() async {
    try {
      final prices = await CoinGeckoService.getPrices();
      if (!mounted) return;
      setState(() => _btcUsd = prices['BTC']?.price);
    } catch (_) {
      // Offline or rate-limited: the wallet shows sats only.
    }
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text('You will need your PIN to log back in.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      // ScorchePayApp navigates to the signed-out entry point.
      await ref.read(appStateProvider.notifier).logout();
    } catch (_) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Could not log out. Please try again.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(userProfileProvider);
    return Scaffold(
      backgroundColor: AppColors.page,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 40),
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          profile.displayName.isEmpty
                              ? 'Hello'
                              : 'Hello, ${profile.displayName}',
                          style: AppText.pageTitle),
                      const SizedBox(height: 2),
                      Text('Top up and check your crypto balance',
                          style: AppText.bodyMuted),
                      const SizedBox(height: 8),
                      KycStatusBadge(kyc: profile.kyc),
                    ],
                  ),
                ),
                IconCircleButton(icon: AppIcons.logout, onTap: _logout),
              ],
            ),
            const SizedBox(height: 22),
            const SectionTitle('VTU & Bills'),
            AppCard(
              padding: const EdgeInsets.all(16),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const cols = 4;
                  const hGap = 4.0;
                  final itemWidth =
                      (constraints.maxWidth - hGap * (cols - 1)) / cols;
                  return Wrap(
                    spacing: hGap,
                    runSpacing: 16,
                    children: [
                      for (final entry in _vtuEntries)
                        SizedBox(
                          width: itemWidth,
                          child: IconActionButton(
                            icon: entry.icon,
                            label: entry.label,
                            onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) => entry.build())),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            const SectionTitle('Wallet'),
            WalletSection(btcUsdPrice: _btcUsd),
          ],
        ),
      ),
    );
  }
}

class _VtuEntry {
  const _VtuEntry(this.icon, this.label, this.build);
  final IconData icon;
  final String label;
  final Widget Function() build;
}

final List<_VtuEntry> _vtuEntries = [
  _VtuEntry(AppIcons.phone, 'Airtime', () => const AirtimeScreen()),
  _VtuEntry(AppIcons.wifi, 'Data', () => const DataScreen()),
  _VtuEntry(
      AppIcons.bolt,
      'Electricity',
      () => const BillPaymentScreen(
            icon: AppIcons.bolt,
            title: 'Electricity',
            subtitle: 'Instant token generation for meter recharge',
            providers: [
              'Ikeja Electric',
              'Eko Electric',
              'Abuja DisCo',
              'PHED'
            ],
            idLabel: 'Meter number',
            idHint: 'Enter your 11-digit meter number',
          )),
  _VtuEntry(
      AppIcons.monitor,
      'Cable TV',
      () => const BillPaymentScreen(
            icon: AppIcons.monitor,
            title: 'Cable TV',
            subtitle: 'Renew your subscription bouquet',
            providers: ['DSTV', 'GOtv', 'Startimes'],
            idLabel: 'Smart card / IUC number',
            idHint: 'Enter your 10-digit smart card number',
            packages: [
              BillPackage('DSTV Padi', '₦4,400'),
              BillPackage('DSTV Yanga', '₦6,000'),
              BillPackage('DSTV Compact', '₦19,800'),
              BillPackage('GOtv Max', '₦8,500'),
            ],
          )),
  _VtuEntry(
      AppIcons.globe,
      'Internet',
      () => const BillPaymentScreen(
            icon: AppIcons.globe,
            title: 'Internet',
            subtitle: 'Spectranet, Smile, Starlink & fibre plans',
            providers: ['Spectranet', 'Smile', 'MTN 5G WiFi', 'Starlink'],
            idLabel: 'Account / Customer ID',
            idHint: 'Enter your subscriber ID',
          )),
  _VtuEntry(
      AppIcons.book,
      'Education',
      () => const BillPaymentScreen(
            icon: AppIcons.book,
            title: 'Education',
            subtitle: 'WAEC, JAMB e-PIN and school fees',
            providers: ['WAEC e-PIN', 'JAMB UTME', 'NECO'],
            idLabel: 'Candidate / Registration ID',
            idHint: 'Enter candidate registration number',
            payLabel: 'Buy e-PIN',
          )),
  _VtuEntry(
      AppIcons.chartBar,
      'Betting',
      () => const BillPaymentScreen(
            icon: AppIcons.chartBar,
            title: 'Betting',
            subtitle: 'Instant funding for betting accounts',
            providers: ['Bet9ja', 'SportyBet', '1xBet', 'Betway'],
            idLabel: 'User Account ID',
            idHint: 'Enter your betting account ID',
            payLabel: 'Fund Wallet',
          )),
];
