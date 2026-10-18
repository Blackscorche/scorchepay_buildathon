import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/amount_editing_controller.dart';
import '../../core/app_icons.dart';
import '../../core/async_action.dart';
import '../../core/formatters.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/choice_chip.dart';
import '../../core/widgets/detail_header.dart';
import '../../state/models/vtu.dart';
import '../../state/providers/vtu_providers.dart';
import '../../state/providers/wallets_provider.dart';
import '../../state/services/vtu_api.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import 'checkout_screen.dart';
import 'pay_from_wallet.dart';
import 'verify_prompt.dart';
import 'vtu_ui.dart';

/// One order form for every bill category, built from the catalog: the
/// selected [Biller] says which inputs appear (its options, target and
/// pricing), so nothing here depends on the category. Continue locks a
/// quote and opens [CheckoutScreen], where the user picks the wallet to
/// pay from.
class VtuOrderScreen extends ConsumerStatefulWidget {
  const VtuOrderScreen({super.key, required this.category});

  final BillCategory category;

  @override
  ConsumerState<VtuOrderScreen> createState() => _VtuOrderScreenState();
}

class _VtuOrderScreenState extends ConsumerState<VtuOrderScreen>
    with AsyncActionMixin {
  final _targetController = TextEditingController();
  final _amountController = AmountEditingController();

  String? _billerId;
  String? _optionId;
  String? _planId;
  String? _targetError;

  /// The customer check, for [_customerKey]'s inputs.
  AsyncValue<CustomerInfo>? _customer;
  String? _customerKey;
  Timer? _customerDebounce;

  VtuApi get _api => ref.read(vtuApiProvider);

  @override
  void initState() {
    super.initState();
    _amountController.addListener(_onInputChanged);
  }

  @override
  void dispose() {
    _customerDebounce?.cancel();
    _targetController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  void _onInputChanged() {
    clearActionError();
    setState(() {});
  }

  Biller? _selectedBiller(Catalog catalog) {
    final billers = catalog.billersFor(widget.category);
    return billers.where((b) => b.id == _billerId).firstOrNull ??
        billers.where((b) => b.available).firstOrNull;
  }

  /// The chosen option, defaulting to the biller's first one.
  String? _optionFor(Biller biller) =>
      biller.options?.find(_optionId)?.id ??
      biller.options?.choices.firstOrNull?.id;

  bool _priceChosen(Biller biller) => switch (biller.pricing) {
        final PlanPricing pricing => pricing.find(_planId) != null,
        final AmountPricing pricing => switch (_amountController.amount) {
            final amount? => pricing.allows(amount),
            null => false,
          },
      };

  void _selectBiller(Biller biller) {
    if (biller.id == _billerId) return;
    setState(() {
      _billerId = biller.id;
      _optionId = null;
      _planId = null;
    });
    clearActionError();
    _checkCustomerSoon(biller);
  }

  void _selectOption(Biller biller, String optionId) {
    setState(() => _optionId = optionId);
    _checkCustomerSoon(biller);
  }

  void _onTargetChanged(Biller biller) {
    clearActionError();
    setState(() => _targetError = null);
    _checkCustomerSoon(biller);
  }

  /// Looks up the account holder once the number is complete, for billers
  /// that ask for it.
  void _checkCustomerSoon(Biller biller) {
    _customerDebounce?.cancel();
    final target = TargetField.normalize(_targetController.text);
    final optionId = _optionFor(biller);
    final key = '${biller.id}|$optionId|$target';
    if (key == _customerKey) return;
    if (_customerKey != null && _customer != null) {
      setState(() {
        _customer = null;
        _customerKey = null;
      });
    }
    if (!biller.customerCheck || !biller.target.isValid(target)) return;

    _customerDebounce = Timer(const Duration(milliseconds: 500), () async {
      if (!mounted) return;
      setState(() {
        _customerKey = key;
        _customer = const AsyncLoading();
      });
      final result = await AsyncValue.guard(() => _api.validateCustomer(
          billerId: biller.id, target: target, optionId: optionId));
      if (!mounted || _customerKey != key) return;
      setState(() => _customer = result);
    });
  }

  Future<void> _continue(Biller biller) async {
    final target = TargetField.normalize(_targetController.text);
    if (!biller.target.isValid(target)) {
      setState(() => _targetError = biller.target.errorText);
      return;
    }
    final (String? planId, int? amount) = switch (biller.pricing) {
      PlanPricing() => (_planId, null),
      AmountPricing() => (null, _amountController.amount),
    };
    final request = OrderRequest(
      billerId: biller.id,
      target: target,
      optionId: _optionFor(biller),
      planId: planId,
      amount: amount,
    );

    var result = await runAction(() => _api.createOrder(request));
    if (!mounted) return;
    final error = result.error;
    if (error is VtuException && error.code == VtuErrorCode.overLimit) {
      final limits = ref.read(vtuLimitsProvider).valueOrNull;
      // At the top tier there's nothing to verify: the error stays shown.
      if (limits == null || limits.nextTier == null) return;
      clearActionError();
      final verified = await showVerifyPrompt(context,
          reason: error.message, limits: limits);
      if (!verified || !mounted) return;
      result = await runAction(() => _api.createOrder(request));
      if (!mounted) return;
    }

    final order = result.valueOrNull;
    if (order == null) return;
    ref.invalidate(recentOrdersProvider);
    ref.invalidate(vtuLimitsProvider);
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => CheckoutScreen(order: order)));
  }

  @override
  Widget build(BuildContext context) {
    final wallets = ref.watch(walletsProvider);
    final hasWallet = wallets.valueOrNull?.isEmpty == false;
    final catalog = ref.watch(catalogProvider);

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
                  icon: widget.category.icon,
                  title: 'Buy ${widget.category.label.toLowerCase()}',
                  subtitle: widget.category.subtitle),
              if (wallets.hasValue && !hasWallet) const ConnectWalletNotice(),
              catalog.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(24),
                  child:
                      Center(child: CircularProgressIndicator(strokeWidth: 2)),
                ),
                error: (error, _) => _CatalogError(
                    message: error.toString(),
                    onRetry: () => ref.invalidate(catalogProvider)),
                data: (catalog) => switch (_selectedBiller(catalog)) {
                  final biller? => _form(catalog, biller, hasWallet),
                  null => Text(
                      "${widget.category.label} isn't available right now.",
                      style: AppText.bodyMuted),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _form(Catalog catalog, Biller biller, bool hasWallet) {
    // An incomplete number can still Continue, which explains what's
    // wrong. A complete one must pass the customer check where there is one.
    final targetText = _targetController.text.trim();
    final customerOk = !biller.customerCheck ||
        !biller.target.isValid(targetText) ||
        (_customer?.hasValue ?? false);
    final canContinue = hasWallet &&
        biller.available &&
        targetText.isNotEmpty &&
        _priceChosen(biller) &&
        customerOk &&
        !actionRunning;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 22,
      children: [
        _Group(
          label: widget.category.billerLabel,
          child: _BillerGrid(
            billers: catalog.billersFor(widget.category),
            selectedId: biller.id,
            onSelected: _selectBiller,
          ),
        ),
        if (biller.options case final options?)
          _Group(
            label: options.label,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final choice in options.choices)
                  AppChoiceChip(
                    label: choice.name,
                    selected: choice.id == _optionFor(biller),
                    onTap: () => _selectOption(biller, choice.id),
                  ),
              ],
            ),
          ),
        _Group(
          label: biller.target.label,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 10,
            children: [
              TextField(
                controller: _targetController,
                onChanged: (_) => _onTargetChanged(biller),
                keyboardType: biller.target.kind.keyboardType,
                style: TextStyle(color: AppColors.textPrimary, fontSize: 13.5),
                decoration: InputDecoration(
                  hintText: biller.target.hint,
                  errorText: _targetError,
                  errorMaxLines: 2,
                  prefixIcon: Icon(widget.category.icon,
                      size: 18, color: AppColors.muted),
                ),
              ),
              if (_customer case final customer?)
                _CustomerResult(customer: customer),
            ],
          ),
        ),
        _Group(
          label: biller.pricing.label,
          child: switch (biller.pricing) {
            final PlanPricing pricing => _PlanPicker(
                pricing: pricing,
                currency: catalog.currency,
                selectedId: _planId,
                onSelected: (id) {
                  clearActionError();
                  setState(() => _planId = id);
                },
              ),
            final AmountPricing pricing => _AmountInput(
                pricing: pricing,
                currency: catalog.currency,
                controller: _amountController,
              ),
          },
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            const _LimitsLine(),
            if (actionError != null)
              Text(actionError!,
                  style: AppText.caption.copyWith(color: AppColors.loss)),
            PrimaryButton(
              label: 'Continue',
              loading: actionRunning,
              onPressed: canContinue ? () => _continue(biller) : null,
            ),
          ],
        ),
      ],
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 10,
      children: [Text(label, style: AppText.sectionTitle), child],
    );
  }
}

/// Billers as tiles, four to a row.
class _BillerGrid extends StatelessWidget {
  const _BillerGrid(
      {required this.billers,
      required this.selectedId,
      required this.onSelected});

  final List<Biller> billers;
  final String selectedId;
  final ValueChanged<Biller> onSelected;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      const columns = 4;
      const gap = 8.0;
      final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final biller in billers)
            SizedBox(
              width: width,
              child: BillerTile(
                biller: biller,
                selected: biller.id == selectedId,
                onTap: () => onSelected(biller),
              ),
            ),
        ],
      );
    });
  }
}

class _PlanPicker extends StatelessWidget {
  const _PlanPicker({
    required this.pricing,
    required this.currency,
    required this.selectedId,
    required this.onSelected,
  });

  final PlanPricing pricing;
  final String currency;
  final String? selectedId;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      spacing: 8,
      children: [
        for (final plan in pricing.plans)
          PlanRow(
            title: plan.name,
            subtitle: plan.validity,
            price: formatFiat(plan.amount, currency),
            selected: plan.id == selectedId,
            onTap: () => onSelected(plan.id),
          ),
      ],
    );
  }
}

/// Preset chips plus a free amount, both writing to [controller].
class _AmountInput extends StatelessWidget {
  const _AmountInput({
    required this.pricing,
    required this.currency,
    required this.controller,
  });

  final AmountPricing pricing;
  final String currency;
  final AmountEditingController controller;

  @override
  Widget build(BuildContext context) {
    final amount = controller.amount;
    final range = pricing.rangeText(currency);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 10,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in pricing.presets)
              AppChoiceChip(
                label: formatFiat(preset, currency),
                selected: amount == preset,
                onTap: () => controller.amount = preset,
              ),
          ],
        ),
        TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          style: TextStyle(color: AppColors.textPrimary, fontSize: 13.5),
          decoration: InputDecoration(
            hintText: 'Or enter an amount',
            prefixText: currencySymbol(currency),
            helperText: range,
            errorText: amount != null && !pricing.allows(amount)
                ? (range == null ? 'Enter an amount.' : 'Allowed: $range.')
                : null,
          ),
        ),
      ],
    );
  }
}

class _CustomerResult extends StatelessWidget {
  const _CustomerResult({required this.customer});

  final AsyncValue<CustomerInfo> customer;

  @override
  Widget build(BuildContext context) {
    return customer.when(
      loading: () => Row(
        spacing: 8,
        children: [
          const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2)),
          Text('Checking the account…', style: AppText.caption),
        ],
      ),
      error: (error, _) => Text(error.toString(),
          style: AppText.caption.copyWith(color: AppColors.loss)),
      data: (info) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.statusSoft(AppColors.gain),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          spacing: 10,
          children: [
            const Icon(AppIcons.check, size: 18, color: AppColors.gain),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 2,
                children: [
                  Text(info.name, style: AppText.cardTitle),
                  if (info.address case final address?)
                    Text(address, style: AppText.caption),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The user's current caps, with a way to raise them.
class _LimitsLine extends ConsumerWidget {
  const _LimitsLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final limits = ref.watch(vtuLimitsProvider).valueOrNull;
    if (limits == null) return const SizedBox.shrink();
    return Row(
      spacing: 8,
      children: [
        Expanded(
          child: Text(
              'Tier ${limits.tier}: up to ${formatFiat(limits.perOrder, limits.currency)} '
              'per order, ${formatFiat(limits.remainingToday, limits.currency)} left today.',
              style: AppText.caption),
        ),
        if (limits.nextTier != null)
          GestureDetector(
            onTap: () => showVerifyPrompt(context,
                reason: 'Your limit is ${formatFiat(limits.perOrder, limits.currency)} '
                    'per order.',
                limits: limits),
            child: Text('Raise limit',
                style: AppText.caption.copyWith(
                    color: AppColors.accent, fontWeight: FontWeight.w700)),
          ),
      ],
    );
  }
}

class _CatalogError extends StatelessWidget {
  const _CatalogError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      spacing: 12,
      children: [
        Text(message, textAlign: TextAlign.center, style: AppText.bodyMuted),
        SecondaryButton(
            label: 'Try again', icon: AppIcons.refresh, onPressed: onRetry),
      ],
    );
  }
}
