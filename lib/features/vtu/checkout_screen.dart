import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_icons.dart';
import '../../core/async_action.dart';
import '../../core/formatters.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/detail_header.dart';
import '../../state/models/connected_wallet.dart';
import '../../state/models/vtu.dart';
import '../../state/providers/vtu_providers.dart';
import '../../state/providers/wallets_provider.dart';
import '../../state/services/mock_vtu_api.dart';
import '../../state/services/wallet_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../wallet/wallet_tile.dart';
import 'order_status_screen.dart';
import 'pay_from_wallet.dart';
import 'vtu_ui.dart';

/// Opens [OrderStatusScreen] for [orderId], on top of the current screen
/// or in its place.
void openOrderStatus(BuildContext context, String orderId,
    {bool replace = false}) {
  final route = MaterialPageRoute<void>(
    builder: (_) => OrderStatusScreen(
      orderId: orderId,
      openCheckout: (context, order) => Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => CheckoutScreen(order: order))),
    ),
  );
  final navigator = Navigator.of(context);
  replace ? navigator.pushReplacement(route) : navigator.push(route);
}

/// The locked quote for [order]: fiat and sats, a countdown to the
/// quote's expiry, and the wallet to pay from (the current one by
/// default, switchable, with balances). Paying sends the invoice to that wallet over NWC, then
/// follows the order on [OrderStatusScreen].
class CheckoutScreen extends ConsumerStatefulWidget {
  const CheckoutScreen({super.key, required this.order});

  final VtuOrder order;

  @override
  ConsumerState<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends ConsumerState<CheckoutScreen>
    with AsyncActionMixin {
  late VtuOrder _order = widget.order;

  /// Picked on this screen; null means the current wallet.
  String? _walletId;
  late final Timer _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          // Timer ticked
        });
      }
    });
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  Future<void> _pay(ConnectedWallet wallet) async {
    final uri = ref.read(walletsProvider.notifier).connectionUri(wallet.id);
    if (uri == null) return;
    final result = await runAction(() => ref
        .read(walletServiceProvider)
        // Wallets that ask the user to approve may take a while; stop
        // waiting when the quote (and so the invoice) expires.
        .payInvoice(uri, _order.invoice, timeout: _order.timeLeft()));
    if (!mounted) return;
    ref.invalidate(walletBalanceProvider(wallet.id));
    final error = result.error;
    // A timeout isn't a failure: the wallet may still be paying. The
    // status screen finds out from the backend.
    final timedOut =
        error is WalletException && error.code == WalletErrorCode.timeout;
    if (result.hasValue || timedOut) _openStatus();
  }

  /// Debug, mock backend only: settles the invoice without a wallet, for
  /// real wallets that can't pay a mock invoice.
  Future<void> _simulatePayment(MockVtuApi api) async {
    final result = await runAction(() => api.simulatePayment(_order.id));
    if (mounted && result.hasValue) _openStatus();
  }

  Future<void> _requote() async {
    final result = await runAction(
        () => ref.read(vtuApiProvider).createOrder(_order.request));
    if (!mounted || !result.hasValue) return;
    ref.invalidate(recentOrdersProvider);
    setState(() => _order = result.requireValue);
  }

  void _openStatus() {
    ref.invalidate(recentOrdersProvider);
    openOrderStatus(context, _order.id, replace: true);
  }

  @override
  Widget build(BuildContext context) {
    final order = _order;
    final wallet = payingWallet(ref, _walletId);
    final left = order.timeLeft();
    final expired = left == Duration.zero;
    final balance =
        wallet == null ? null : ref.watch(walletBalanceProvider(wallet.id));
    final enough = balance == null ? null : coversAmount(balance, order.sats);
    final api = ref.watch(vtuApiProvider);

    return Scaffold(
      backgroundColor: AppColors.page,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 22,
            children: [
              DetailHeader(
                  icon: order.category.icon,
                  title: 'Confirm payment',
                  subtitle: order.title),
              AppCard(
                child: Column(
                  spacing: 6,
                  children: [
                    Text(formatFiat(order.amount, order.currency),
                        style: AppText.heroNumber.copyWith(fontSize: 32)),
                    Text(formatSats(order.sats),
                        style: AppText.body.copyWith(
                            color: AppColors.accent,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    _Countdown(left: left),
                  ],
                ),
              ),
              AppCard(
                child: Column(
                  spacing: 12,
                  children: [
                    DetailLine('Bill', order.title),
                    DetailLine('To', order.target),
                    if (order.customerName != null)
                      DetailLine('Customer', order.customerName!),
                    DetailLine('Rate',
                        '${formatFiat(order.rate.round(), order.currency)} per BTC'),
                    DetailLine('Order', order.id),
                  ],
                ),
              ),
              if (wallet == null)
                const ConnectWalletNotice()
              else
                PayFromWalletCard(
                  wallet: wallet,
                  requiredSats: order.sats,
                  onChanged: (id) {
                    clearActionError();
                    setState(() => _walletId = id);
                  },
                ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 12,
                children: [
                  if (actionError != null)
                    Text(actionError!,
                        style: AppText.caption.copyWith(color: AppColors.loss)),
                  if (expired)
                    PrimaryButton(
                      label: 'Get a new quote',
                      icon: AppIcons.refresh,
                      loading: actionRunning,
                      onPressed: _requote,
                    )
                  else
                    PrimaryButton(
                      label: 'Pay ${formatSats(order.sats)}',
                      icon: AppIcons.bolt,
                      loading: actionRunning,
                      onPressed: wallet == null || enough == false
                          ? null
                          : () => _pay(wallet),
                    ),
                  Text(
                      'Your wallet pays the invoice directly. If it asks you '
                      'to approve payments, confirm there.',
                      textAlign: TextAlign.center,
                      style: AppText.caption),
                  if (kDebugMode && api is MockVtuApi && !expired)
                    TextButton(
                      onPressed:
                          actionRunning ? null : () => _simulatePayment(api),
                      child: const Text('Simulate payment (debug)'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Countdown extends StatelessWidget {
  const _Countdown({required this.left});

  final Duration left;

  @override
  Widget build(BuildContext context) {
    final expired = left == Duration.zero;
    final color = expired
        ? AppColors.loss
        : left.inSeconds < 30
            ? AppColors.warn
            : AppColors.textSecondary;
    final seconds = (left.inSeconds % 60).toString().padLeft(2, '0');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        expired
            ? 'Quote expired'
            : 'Quote expires in ${left.inMinutes}:$seconds',
        style:
            AppText.caption.copyWith(color: color, fontWeight: FontWeight.w700),
      ),
    );
  }
}
