import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_icons.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/icon_action_button.dart';
import '../../core/widgets/section_title.dart';
import '../../core/widgets/token_badge.dart';
import '../../data/coingecko_service.dart';
import '../../data/mock_data.dart';
import '../../data/models.dart';
import '../../state/providers/providers.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../bills/airtime_screen.dart';
import '../bills/bill_payment_screen.dart';
import '../bills/data_screen.dart';

double _parseHolding(String holding) =>
    double.tryParse(holding.replaceAll(',', '')) ?? 0;

String _formatPrice(double price) {
  final isWhole = price == price.roundToDouble();
  final s = isWhole ? price.toStringAsFixed(0) : price.toStringAsFixed(2);
  final parts = s.split('.');
  final intPart = parts[0];
  final buf = StringBuffer();
  for (int i = 0; i < intPart.length; i++) {
    if (i != 0 && (intPart.length - i) % 3 == 0) buf.write(',');
    buf.write(intPart[i]);
  }
  if (parts.length > 1) buf.write('.${parts[1]}');
  return buf.toString();
}

/// The entire app, trimmed to one screen: VTU/bill payments and a
/// read-only crypto balance view. No send money, escrow, savings, P2P,
/// gift cards, merchant/admin tooling or server-backed "live" mode —
/// this branch intentionally doesn't have those pages at all.
class VtuDashboardScreen extends ConsumerStatefulWidget {
  const VtuDashboardScreen({super.key});

  @override
  ConsumerState<VtuDashboardScreen> createState() => _VtuDashboardScreenState();
}

class _VtuDashboardScreenState extends ConsumerState<VtuDashboardScreen> {
  List<CryptoAsset> _assets = MockData.crypto;
  bool _live = false;

  @override
  void initState() {
    super.initState();
    _loadLivePrices();
  }

  Future<void> _loadLivePrices() async {
    try {
      final prices = await CoinGeckoService.getPrices();
      if (!mounted) return;
      setState(() {
        _assets = [
          for (final a in MockData.crypto)
            prices.containsKey(a.symbol)
                ? a.copyWith(
                    price: prices[a.symbol]!.price,
                    changePct: prices[a.symbol]!.changePct,
                    logoUrl: prices[a.symbol]!.logoUrl)
                : a,
        ];
        _live = true;
      });
    } catch (_) {
      // Offline or rate-limited — the bundled mock prices already cover it.
    }
  }

  double get _totalValue => _assets.fold<double>(
      0, (sum, a) => sum + _parseHolding(a.holding) * a.price);

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
                      Text('Hello, ${profile.displayName}',
                          style: AppText.pageTitle),
                      const SizedBox(height: 2),
                      Text('Top up and check your crypto balance',
                          style: AppText.bodyMuted),
                    ],
                  ),
                ),
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
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const SectionTitle('Crypto Balances'),
                if (_live)
                  Container(
                    margin: const EdgeInsets.only(top: 2),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                        color: AppColors.gain.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(20)),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(AppIcons.bolt, size: 10, color: AppColors.gain),
                        SizedBox(width: 3),
                        Text('Live · CoinGecko',
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: AppColors.gain)),
                      ],
                    ),
                  ),
              ],
            ),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('TOTAL VALUE',
                      style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.muted,
                          letterSpacing: 0.7)),
                  const SizedBox(height: 8),
                  Text('\$${_formatPrice(_totalValue)}',
                      style: AppText.heroNumber.copyWith(fontSize: 28)),
                ],
              ),
            ),
            AppCard(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 4),
              child: Column(
                children: [
                  for (int i = 0; i < _assets.length; i++)
                    _BalanceRow(
                      asset: _assets[i],
                      showDivider: i != _assets.length - 1,
                    ),
                ],
              ),
            ),
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

/// Read-only holding row — no tap-to-trade, this branch has no trading UI.
class _BalanceRow extends StatelessWidget {
  const _BalanceRow({required this.asset, this.showDivider = true});

  final CryptoAsset asset;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final changeColor = asset.changePct > 0
        ? AppColors.gain
        : asset.changePct < 0
            ? AppColors.loss
            : AppColors.muted;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: showDivider
            ? Border(bottom: BorderSide(color: AppColors.hairline))
            : null,
      ),
      child: Row(
        children: [
          TokenBadge(
              glyph: asset.glyph, color: asset.color, logoUrl: asset.logoUrl),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: asset.name, style: AppText.body),
                      TextSpan(
                          text: '  ${asset.symbol}',
                          style: TextStyle(
                              color: AppColors.muted,
                              fontWeight: FontWeight.w500,
                              fontSize: 11.5)),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Text('${asset.holding} ${asset.symbol}',
                    style: AppText.caption),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('\$${_formatPrice(asset.price)}',
                  style: AppText.tabular
                      .copyWith(fontWeight: FontWeight.w700, fontSize: 13.5)),
              const SizedBox(height: 3),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (asset.changePct != 0)
                    Icon(
                        asset.changePct > 0
                            ? AppIcons.arrowUpRight
                            : AppIcons.arrowDownRight,
                        size: 11,
                        color: changeColor),
                  Text('${asset.changePct.abs()}%',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: changeColor)),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
