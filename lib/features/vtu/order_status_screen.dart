import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/app_icons.dart';
import '../../core/async_action.dart';
import '../../core/formatters.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/status_badge.dart';
import '../../state/models/vtu.dart';
import '../../state/providers/vtu_providers.dart';
import '../../state/providers/wallets_provider.dart';
import '../../state/services/mock_lightning.dart';
import '../../state/services/mock_vtu_api.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../wallet/wallet_tile.dart';
import 'order_payment_panel.dart';
import 'pay_from_wallet.dart';
import 'vtu_ui.dart';

/// Opens [OrderStatusScreen] for [orderId].
void openOrderStatus(BuildContext context, String orderId) {
  Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => OrderStatusScreen(orderId: orderId)));
}

/// One screen for an order's whole life, polled live: paying it (quote
/// and wallet, see [OrderPaymentPanel]), then payment and fulfilment,
/// then its receipt, or the refund form if the bill failed. Each stage's
/// main action sits in a bar pinned to the bottom (Pay, Get a new quote,
/// Request refund, or Back to home when there's nothing to do). The order
/// form opens it after Continue, and past orders open it from the
/// dashboard.
class OrderStatusScreen extends ConsumerStatefulWidget {
  const OrderStatusScreen({super.key, required this.orderId});

  final String orderId;

  @override
  ConsumerState<OrderStatusScreen> createState() => _OrderStatusScreenState();
}

class _OrderStatusScreenState extends ConsumerState<OrderStatusScreen>
    with AsyncActionMixin, OrderPaymentActions {
  final _refundController = TextEditingController();

  @override
  void dispose() {
    _refundController.dispose();
    super.dispose();
  }

  /// Back to the dashboard, skipping the order form.
  void _close() =>
      Navigator.of(context).popUntil((route) => route.isFirst);

  Future<void> _requestRefund(VtuOrder order) async {
    final result = await runAction(() => ref
        .read(vtuApiProvider)
        .requestRefund(order.id, invoice: _refundController.text));
    if (!mounted || !result.hasValue) return;
    // Resume polling until the refund lands.
    ref.invalidate(orderProvider(order.id));
  }

  Future<void> _pasteRefundInvoice() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || !mounted) return;
    clearActionError();
    setState(() => _refundController.text = text);
  }

  @override
  Widget build(BuildContext context) {
    final provider = orderProvider(widget.orderId);
    ref.listen(provider.select((o) {
      final order = o.valueOrNull;
      return (order?.status, order?.refundRequested);
    }), (previous, next) {
      if (previous == next) return;
      // Status changes affect the dashboard's list and today's limits.
      ref.invalidate(recentOrdersProvider);
      ref.invalidate(vtuLimitsProvider);
    });
    final order = ref.watch(provider);
    // Unpaid, back returns to the order form to change details (Continue
    // there requotes this order). Paid, it goes home.
    final unpaid = switch (order.valueOrNull?.status) {
      null || OrderStatus.awaitingPayment || OrderStatus.expired => true,
      _ => false,
    };
    void back() => unpaid ? Navigator.of(context).pop() : _close();

    return PopScope(
      canPop: unpaid,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        backgroundColor: AppColors.page,
        bottomNavigationBar: switch (order.valueOrNull) {
          final order? => SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
                child: _actionBar(order),
              ),
            ),
          null => null,
        },
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 22,
              children: [
                Row(
                  spacing: 12,
                  children: [
                    IconCircleButton(icon: AppIcons.chevronLeft, onTap: back),
                    Text('Order', style: AppText.detailTitle),
                  ],
                ),
                ...order.when<List<Widget>>(
                  skipLoadingOnRefresh: true,
                  loading: () => [
                    const Padding(
                      padding: EdgeInsets.all(40),
                      child: Center(
                          child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  ],
                  error: (error, _) => [
                    Text(error.toString(),
                        textAlign: TextAlign.center,
                        style: AppText.bodyMuted),
                    SecondaryButton(
                      label: 'Try again',
                      icon: AppIcons.refresh,
                      onPressed: () => ref.invalidate(provider),
                    ),
                  ],
                  data: _content,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _content(VtuOrder order) {
    final status = order.status;
    return [
      _StatusHero(order: order),
      if (status == OrderStatus.awaitingPayment ||
          status == OrderStatus.expired)
        OrderPaymentPanel(
          order: order,
          wallet: payingWallet(ref, payingWalletId),
          onWalletChanged: selectPayingWallet,
        ),
      if (status == OrderStatus.paid || status == OrderStatus.fulfilling)
        _Progress(status: status),
      if (status == OrderStatus.done && order.receipt != null)
        _ReceiptCard(receipt: order.receipt!),
      if (status == OrderStatus.refundable && !order.refundRequested)
        _refundForm(order),
      _DetailsCard(order: order),
    ];
  }

  /// The stage's main action, pinned to the bottom.
  Widget _actionBar(VtuOrder order) {
    final api = ref.watch(vtuApiProvider);
    final status = order.status;

    if (canPayNow(order)) {
      final wallet = payingWallet(ref, payingWalletId);
      final balance =
          wallet == null ? null : ref.watch(walletBalanceProvider(wallet.id));
      final enough =
          balance == null ? null : coversAmount(balance, order.sats);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          if (actionError != null)
            Text(actionError!,
                style: AppText.caption.copyWith(color: AppColors.loss)),
          PrimaryButton(
            label: 'Pay',
            icon: AppIcons.bolt,
            loading: actionRunning,
            onPressed: wallet == null || enough == false
                ? null
                : () => payOrder(order, wallet),
          ),
          if (kDebugMode && api is MockVtuApi)
            TextButton(
              onPressed:
                  actionRunning ? null : () => simulatePayment(order, api),
              child: const Text('Simulate payment (debug)'),
            ),
        ],
      );
    }

    if (status == OrderStatus.awaitingPayment ||
        status == OrderStatus.expired) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          if (actionError != null)
            Text(actionError!,
                style: AppText.caption.copyWith(color: AppColors.loss)),
          PrimaryButton(
            label: 'Get a new quote',
            icon: AppIcons.refresh,
            loading: actionRunning,
            onPressed: () => requoteOrder(order),
          ),
        ],
      );
    }

    if (status == OrderStatus.refundable && !order.refundRequested) {
      // Its errors show on the invoice field.
      return PrimaryButton(
        label: 'Request refund',
        loading: actionRunning,
        onPressed: _refundController.text.trim().isEmpty
            ? null
            : () => _requestRefund(order),
      );
    }

    return SecondaryButton(label: 'Back to home', onPressed: _close);
  }

  Widget _refundForm(VtuOrder order) {
    final api = ref.read(vtuApiProvider);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Text('Get your sats back', style: AppText.cardTitle),
          Text(
              'In your wallet, create an invoice for exactly '
              '${formatSats(order.sats)} and paste it here. We pay it to '
              'refund you.',
              style: AppText.bodyMuted),
          TextField(
            controller: _refundController,
            enabled: !actionRunning,
            onChanged: (_) {
              clearActionError();
              setState(() {});
            },
            minLines: 2,
            maxLines: 4,
            autocorrect: false,
            enableSuggestions: false,
            style: AppText.body.copyWith(fontSize: 13),
            decoration: InputDecoration(
              hintText: 'lnbc…',
              errorText: actionError,
              errorMaxLines: 3,
            ),
          ),
          Wrap(
            spacing: 4,
            children: [
              TextButton.icon(
                onPressed: actionRunning ? null : _pasteRefundInvoice,
                icon: Icon(AppIcons.copy, size: 16, color: AppColors.accent),
                label: Text('Paste',
                    style: TextStyle(
                        fontWeight: FontWeight.w700, color: AppColors.accent)),
              ),
              if (kDebugMode && api is MockVtuApi)
                TextButton(
                  onPressed: actionRunning
                      ? null
                      : () => setState(() => _refundController.text =
                          MockLightning.fakeInvoice(
                              order.sats, DateTime.now().millisecond)),
                  child: const Text('Use a test invoice (debug)'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusHero extends StatelessWidget {
  const _StatusHero({required this.order});

  final VtuOrder order;

  @override
  Widget build(BuildContext context) {
    final (icon, color, title, message) = _describe(order);
    return Column(
      spacing: 10,
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14), shape: BoxShape.circle),
          child: _working(order)
              ? Padding(
                  padding: const EdgeInsets.all(20),
                  child: CircularProgressIndicator(
                      strokeWidth: 2.5, color: color))
              : Icon(icon, size: 28, color: color),
        ),
        Text(title, style: AppText.pageTitle, textAlign: TextAlign.center),
        Text(message,
            style: AppText.bodyMuted, textAlign: TextAlign.center),
      ],
    );
  }

  /// Something is happening on our side (no action needed).
  static bool _working(VtuOrder order) =>
      order.status == OrderStatus.paid ||
      order.status == OrderStatus.fulfilling ||
      order.refundRequested;

  static (IconData, Color, String, String) _describe(VtuOrder order) {
    final amount = formatFiat(order.amount, order.currency);
    switch (order.status) {
      case OrderStatus.awaitingPayment:
        return (
          AppIcons.bolt,
          AppColors.accent,
          'Ready to pay',
          "Pay before the quote runs out. Already paid? If your wallet asks "
              'you to approve it, confirm there.'
        );
      case OrderStatus.paid:
        return (
          AppIcons.check,
          AppColors.info,
          'Payment received',
          'Sending your order to ${order.billerName}…'
        );
      case OrderStatus.fulfilling:
        return (
          AppIcons.bill,
          AppColors.info,
          'Processing',
          '${order.billerName} is completing your $amount bill.'
        );
      case OrderStatus.done:
        return (
          AppIcons.check,
          AppColors.gain,
          order.category.doneTitle,
          order.title
        );
      case OrderStatus.expired:
        return (
          AppIcons.warning,
          AppColors.muted,
          'Quote expired',
          "It wasn't paid in time, so nothing was charged."
        );
      case OrderStatus.refundable:
        return order.refundRequested
            ? (
                AppIcons.repeat,
                AppColors.info,
                'Refund on its way',
                'Sending ${formatSats(order.sats)} to your invoice…'
              )
            : (
                AppIcons.warning,
                AppColors.loss,
                'This bill failed',
                order.failureReason ??
                    "The provider couldn't complete it. You can get your sats back."
              );
      case OrderStatus.refunded:
        return (
          AppIcons.check,
          AppColors.info,
          'Refunded',
          '${formatSats(order.sats)} went back to your wallet.'
        );
    }
  }
}

/// Paid → Processing → Done.
class _Progress extends StatelessWidget {
  const _Progress({required this.status});

  final OrderStatus status;

  @override
  Widget build(BuildContext context) {
    final reached = switch (status) {
      OrderStatus.awaitingPayment => 0,
      OrderStatus.paid => 1,
      OrderStatus.fulfilling => 2,
      _ => 3,
    };
    const steps = ['Paid', 'Processing', 'Done'];
    return Row(
      spacing: 6,
      children: [
        for (var i = 0; i < steps.length; i++)
          Expanded(
            child: Column(
              spacing: 6,
              children: [
                Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: i < reached ? AppColors.accent : AppColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Text(steps[i],
                    style: AppText.caption.copyWith(
                        color: i < reached
                            ? AppColors.textPrimary
                            : AppColors.muted)),
              ],
            ),
          ),
      ],
    );
  }
}

/// Whatever the backend put on the receipt: primary items (e.g. a meter
/// token) large, the rest as label/value lines, then the reference.
class _ReceiptCard extends StatelessWidget {
  const _ReceiptCard({required this.receipt});

  final OrderReceipt receipt;

  @override
  Widget build(BuildContext context) {
    final primary = [for (final i in receipt.items) if (i.primary) i];
    final secondary = [for (final i in receipt.items) if (!i.primary) i];
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          for (final item in primary) _PrimaryItem(item: item),
          if (receipt.message case final message?)
            Text(message, style: AppText.body),
          for (final item in secondary)
            DetailLine(item.label, item.value,
                trailing: item.copyable
                    ? _CopyButton(value: item.value, what: item.label)
                    : null),
          DetailLine('Reference', receipt.reference,
              trailing:
                  _CopyButton(value: receipt.reference, what: 'Reference')),
        ],
      ),
    );
  }
}

class _PrimaryItem extends StatelessWidget {
  const _PrimaryItem({required this.item});

  final ReceiptItem item;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 6,
      children: [
        Text(item.label.toUpperCase(), style: AppText.eyebrow),
        Row(
          spacing: 8,
          children: [
            Expanded(
              child: SelectableText(item.value,
                  style: AppText.cardTitle.copyWith(
                      fontSize: 19,
                      letterSpacing: 0.5,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ),
            if (item.copyable) _CopyButton(value: item.value, what: item.label),
          ],
        ),
      ],
    );
  }
}

class _DetailsCard extends StatelessWidget {
  const _DetailsCard({required this.order});

  final VtuOrder order;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Row(
            children: [
              Expanded(child: Text('Details', style: AppText.cardTitle)),
              StatusBadge(label: order.status.label, tone: order.status.tone),
            ],
          ),
          DetailLine('Bill', order.title),
          DetailLine('To', order.target),
          if (order.customerName != null)
            DetailLine('Customer', order.customerName!),
          DetailLine('Amount',
              '${formatFiat(order.amount, order.currency)} · ${formatSats(order.sats)}'),
          DetailLine('Rate',
              '${formatFiat(order.rate.round(), order.currency)} per BTC'),
          DetailLine(
              'Date', DateFormat.yMMMd().add_jm().format(order.createdAt)),
          DetailLine('Order', order.id,
              trailing: _CopyButton(value: order.id, what: 'Order ID')),
        ],
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.value, required this.what});

  final String value;
  final String what;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: value));
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$what copied.')));
      },
      child: Icon(AppIcons.copy, size: 16, color: AppColors.accent),
    );
  }
}
