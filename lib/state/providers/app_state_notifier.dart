import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/app_notification.dart';
import '../models/automation.dart';
import '../models/escrow.dart';
import '../models/ledger_entry.dart';
import '../models/savings.dart';
import '../services/automation_service.dart';
import '../services/escrow_service.dart';
import '../services/fx_rate_service.dart';
import '../services/ledger_service.dart';
import '../services/local_store.dart';
import '../services/savings_service.dart';
import '../services/simulated_providers.dart';
import '../services/smart_pay_engine.dart';
import 'app_state.dart';

const _uuid = Uuid();

/// The single write path into [AppState]. Every user-facing action is
/// one method here: mutate the state's internals via the relevant
/// service, then commit with `state = state.clone()` (guarantees
/// Riverpod notifies listeners regardless of the mutable-internals
/// pattern) and persist to disk.
class AppStateNotifier extends StateNotifier<AppState> {
  AppStateNotifier(this._store) : super(AppState.seed()) {
    _load();
  }

  final LocalStore _store;

  Future<void> _load() async {
    state = await _store.load();
    await refreshFxRates();
  }

  /// Pulls live NGN-pivot FX rates (§5 of the spec — real rates, not a
  /// static table) and merges them into whatever currencies the user
  /// already holds. Falls back silently to the existing bundled rates
  /// on any failure (offline, rate-limited), same pattern as
  /// [CoinGeckoService].
  Future<void> refreshFxRates() async {
    try {
      final live = await FxRateService.getRatesToNgn();
      for (final code in state.fxRatesToNgn.keys.toList()) {
        if (live.containsKey(code)) state.fxRatesToNgn[code] = live[code]!;
      }
      await _commit();
    } catch (_) {
      // Offline or the free API is down — the bundled rates already cover it.
    }
  }

  Future<void> _commit() async {
    state = state.clone();
    await _store.save(state);
  }

  // ---------------------------------------------------------------------
  // Smart Pay / bills
  // ---------------------------------------------------------------------

  Future<SmartPayResult> payBill(
      {required String biller,
      required String customerId,
      required double amount,
      required String currency,
      String? fixedSourceCurrency}) async {
    try {
      final result = await SmartPayEngine.payBill(state,
          biller: biller,
          customerId: customerId,
          amount: amount,
          currency: currency,
          fixedSourceCurrency: fixedSourceCurrency);
      await _commit();
      return result;
    } on InsufficientFundsException catch (ex) {
      return SmartPayResult.insufficientFunds(FundingPlan(
          nativeCurrency: currency,
          nativeAmount: amount,
          legs: const [],
          shortBy: ex.shortBy));
    }
  }

  FundingPlan planPayment(
      {required String nativeCurrency,
      required double nativeAmount,
      String? fixedSourceCurrency}) {
    return SmartPayEngine.planPayment(state,
        nativeCurrency: nativeCurrency,
        nativeAmount: nativeAmount,
        fixedSourceCurrency: fixedSourceCurrency);
  }

  // ---------------------------------------------------------------------
  // Send Money
  // ---------------------------------------------------------------------

  /// Explicit demo repository. Live transfers use the server-owned operation API.
  Future<bool> sendInternal(
      {required String toUsername,
      required String toDisplayName,
      required String currency,
      required double amount,
      String? note}) async {
    try {
      LedgerService.internalTransferOut(state,
          currency: currency,
          amount: amount,
          recipientUsername: toUsername,
          recipientDisplayName: toDisplayName,
          note: note);
      await _recordLocalSendNotification(
          currency: currency, amount: amount, toDisplayName: toDisplayName);
      await _commit();
      return true;
    } on InsufficientFundsException {
      return false;
    }
  }

  Future<void> _recordLocalSendNotification(
      {required String currency,
      required double amount,
      required String toDisplayName}) async {
    state.notifications.insert(
        0,
        AppNotification(
            id: _uuid.v4(),
            at: DateTime.now(),
            category: NotificationCategory.transfers,
            title: 'Money sent',
            body:
                '${amount.toStringAsFixed(2)} $currency sent to $toDisplayName.'));
  }

  Future<ProviderResult> sendToBank(
      {required double amount,
      required String bankName,
      required String accountName}) async {
    try {
      final entry = LedgerService.debit(state,
          currency: 'NGN',
          amount: amount,
          title: 'Sent to $accountName',
          subtitle: '$bankName · bank transfer',
          category: LedgerCategory.transfer);
      final result = await SimulatedProviders.bankTransfer(
          amount: amount, bankName: bankName);
      if (result.failed) {
        LedgerService.refund(state, entry, reasonSuffix: result.reason);
        state.notifications.insert(
            0,
            AppNotification(
                id: _uuid.v4(),
                at: DateTime.now(),
                category: NotificationCategory.transfers,
                title: 'Transfer failed',
                body:
                    '${result.reason} — ${amount.toStringAsFixed(2)} NGN refunded.'));
      } else {
        state.notifications.insert(
            0,
            AppNotification(
                id: _uuid.v4(),
                at: DateTime.now(),
                category: NotificationCategory.transfers,
                title: 'Transfer sent',
                body:
                    '${amount.toStringAsFixed(2)} NGN sent to $accountName ($bankName).'));
      }
      await _commit();
      return result;
    } on InsufficientFundsException {
      await _commit();
      return const ProviderResult.failure('Insufficient funds');
    }
  }

  // ---------------------------------------------------------------------
  // Crypto
  // ---------------------------------------------------------------------

  Future<ProviderResult> buyCrypto(
      {required String asset,
      required double amount,
      required String fundingSource}) async {
    try {
      final entry = LedgerService.debit(state,
          currency: fundingSource,
          amount: amount,
          title: 'Buy $asset',
          subtitle: 'Crypto purchase',
          category: LedgerCategory.crypto);
      final result =
          await SimulatedProviders.executeTrade(asset: asset, amount: amount);
      if (result.failed) {
        LedgerService.refund(state, entry, reasonSuffix: result.reason);
      } else {
        final price = state.cryptoPrices[asset] ?? 1;
        final usdValue = state.convert(amount, fundingSource, 'USD');
        final qty = usdValue / price;
        LedgerService.credit(state,
            currency: asset,
            amount: qty,
            title: 'Bought $asset',
            subtitle: 'Crypto purchase',
            category: LedgerCategory.crypto);
      }
      await _commit();
      return result;
    } on InsufficientFundsException {
      await _commit();
      return const ProviderResult.failure('Insufficient funds');
    }
  }

  Future<ProviderResult> sellCrypto(
      {required String asset,
      required double quantity,
      required String payoutCurrency}) async {
    try {
      final entry = LedgerService.debit(state,
          currency: asset,
          amount: quantity,
          title: 'Sell $asset',
          subtitle: 'Crypto sale',
          category: LedgerCategory.crypto);
      final result =
          await SimulatedProviders.executeTrade(asset: asset, amount: quantity);
      if (result.failed) {
        LedgerService.refund(state, entry, reasonSuffix: result.reason);
      } else {
        final usdValue = quantity * (state.cryptoPrices[asset] ?? 1);
        final payout = state.convert(usdValue, 'USD', payoutCurrency);
        LedgerService.credit(state,
            currency: payoutCurrency,
            amount: payout,
            title: 'Sold $asset',
            subtitle: 'Crypto sale',
            category: LedgerCategory.crypto);
      }
      await _commit();
      return result;
    } on InsufficientFundsException {
      await _commit();
      return const ProviderResult.failure('Insufficient funds');
    }
  }

  Future<ProviderResult> swapCrypto(
      {required String from,
      required String to,
      required double amount}) async {
    try {
      final entry = LedgerService.debit(state,
          currency: from,
          amount: amount,
          title: 'Swap $from → $to',
          subtitle: 'Crypto swap',
          category: LedgerCategory.crypto);
      final result =
          await SimulatedProviders.executeTrade(asset: from, amount: amount);
      if (result.failed) {
        LedgerService.refund(state, entry, reasonSuffix: result.reason);
      } else {
        final converted = state.convert(amount, from, to);
        LedgerService.credit(state,
            currency: to,
            amount: converted,
            title: 'Swapped to $to',
            subtitle: 'From $from',
            category: LedgerCategory.crypto);
      }
      await _commit();
      return result;
    } on InsufficientFundsException {
      await _commit();
      return const ProviderResult.failure('Insufficient funds');
    }
  }

  Future<ProviderResult> withdrawCrypto(
      {required String asset,
      required double amount,
      required String network,
      required String address}) async {
    try {
      LedgerService.debit(state,
          currency: asset,
          amount: amount,
          title: 'Withdraw $asset',
          subtitle: '$network · $address',
          category: LedgerCategory.crypto,
          meta: {'network': network, 'address': address});
      final result = await SimulatedProviders.broadcastWithdrawal(
          asset: asset, network: network);
      state.notifications.insert(
          0,
          AppNotification(
              id: _uuid.v4(),
              at: DateTime.now(),
              category: NotificationCategory.withdrawals,
              title: 'Withdrawal broadcast',
              body: '$amount $asset submitted to $network.'));
      await _commit();
      return result;
    } on InsufficientFundsException {
      await _commit();
      return const ProviderResult.failure('Insufficient funds');
    }
  }

  Future<ProviderResult> crossBorderTransfer(
      {required double amount,
      required String corridor,
      required String recipientName}) async {
    try {
      final entry = LedgerService.debit(state,
          currency: 'NGN',
          amount: amount,
          title: 'Cross-border to $recipientName',
          subtitle: corridor,
          category: LedgerCategory.transfer);
      final result = await SimulatedProviders.crossBorderTransfer(
          amount: amount, corridor: corridor);
      if (result.failed) {
        LedgerService.refund(state, entry, reasonSuffix: result.reason);
      }
      await _commit();
      return result;
    } on InsufficientFundsException {
      await _commit();
      return const ProviderResult.failure('Insufficient funds');
    }
  }

  /// Sells a gift card for cash at a discount off face value — the
  /// reverse of buying one. Real gift-card exchange platforms (in
  /// Nigeria: CardtoNaira, Prestmit) work exactly this way: the payout
  /// is computed and shown before the user commits, the card
  /// code/photo is submitted, and cash lands once the (simulated here)
  /// verification step passes.
  Future<ProviderResult> exchangeGiftCard({
    required String brand,
    required double faceValueUsd,
    required double payoutNaira,
  }) async {
    final result = await SimulatedProviders.executeTrade(
        asset: brand, amount: faceValueUsd);
    if (result.failed) return result;
    LedgerService.credit(
      state,
      currency: 'NGN',
      amount: payoutNaira,
      title: 'Gift card exchanged — $brand',
      subtitle: '\$${faceValueUsd.toStringAsFixed(0)} card',
      category: LedgerCategory.bill,
    );
    state.notifications.insert(
        0,
        AppNotification(
            id: _uuid.v4(),
            at: DateTime.now(),
            category: NotificationCategory.deposits,
            title: 'Gift card exchanged',
            body:
                '₦${payoutNaira.toStringAsFixed(2)} credited for your \$${faceValueUsd.toStringAsFixed(0)} $brand card.'));
    await _commit();
    return result;
  }

  // ---------------------------------------------------------------------
  // Escrow
  // ---------------------------------------------------------------------

  Future<String> createEscrow({
    required String escrowType,
    required String counterpartyUsername,
    required String counterpartyName,
    required EscrowRole role,
    required String description,
    required String currency,
    required List<EscrowMilestone> milestones,
  }) async {
    final id = EscrowService.create(state,
        escrowType: escrowType,
        counterpartyUsername: counterpartyUsername,
        counterpartyName: counterpartyName,
        role: role,
        description: description,
        currency: currency,
        milestones: milestones);
    await _commit();
    return id;
  }

  Future<void> respondToEscrow(String escrowId, {required bool accept}) async {
    EscrowService.counterpartyRespond(state, escrowId, accept: accept);
    await _commit();
  }

  Future<SmartPayResult> fundEscrow(String escrowId) async {
    try {
      final result = EscrowService.fund(state, escrowId);
      await _commit();
      return result;
    } on InsufficientFundsException catch (ex) {
      final e = EscrowService.find(state, escrowId);
      return SmartPayResult.insufficientFunds(FundingPlan(
          nativeCurrency: e?.currency ?? '',
          nativeAmount: e?.totalAmount ?? 0,
          legs: const [],
          shortBy: ex.shortBy));
    }
  }

  Future<void> simulateCounterpartyFundEscrow(String escrowId) async {
    EscrowService.simulateCounterpartyFund(state, escrowId);
    await _commit();
  }

  Future<void> submitEscrowEvidence(
      String escrowId, String milestoneId, String note,
      {bool bySimulatedCounterparty = false}) async {
    EscrowService.submitEvidence(state, escrowId, milestoneId, note,
        bySimulatedCounterparty: bySimulatedCounterparty);
    await _commit();
  }

  Future<void> releaseEscrowMilestone(
      String escrowId, String milestoneId) async {
    EscrowService.release(state, escrowId, milestoneId);
    await _commit();
  }

  Future<void> raiseEscrowDispute(
      String escrowId, String milestoneId, String reason,
      {bool bySimulatedCounterparty = false}) async {
    EscrowService.raiseDispute(state, escrowId, milestoneId, reason,
        bySimulatedCounterparty: bySimulatedCounterparty);
    await _commit();
  }

  Future<void> resolveEscrowDispute(
      String escrowId, String milestoneId, DisputeResolution resolution) async {
    EscrowService.resolveDispute(state, escrowId, milestoneId, resolution);
    await _commit();
  }

  Future<void> checkExpiredReviewWindows() async {
    final before = state.escrows.map((e) => e.timeline.length).toList();
    EscrowService.checkExpiredReviewWindows(state);
    final after = state.escrows.map((e) => e.timeline.length).toList();
    if (before.toString() != after.toString()) await _commit();
  }

  // ---------------------------------------------------------------------
  // Savings
  // ---------------------------------------------------------------------

  Future<String> createSavingsGoal(SavingsGoal goal) async {
    final id = SavingsService.create(state, goal);
    await _commit();
    return id;
  }

  Future<SmartPayResult> contributeSavings(String goalId, double amount,
      {String? fundingSource}) async {
    try {
      final result = SavingsService.contribute(state, goalId, amount,
          fundingSource: fundingSource);
      await _commit();
      return result;
    } on InsufficientFundsException catch (ex) {
      return SmartPayResult.insufficientFunds(FundingPlan(
          nativeCurrency: fundingSource ?? '',
          nativeAmount: amount,
          legs: const [],
          shortBy: ex.shortBy));
    }
  }

  Future<double> withdrawSavings(String goalId, double amount) async {
    final net = SavingsService.withdraw(state, goalId, amount);
    await _commit();
    return net;
  }

  Future<void> deleteSavingsGoal(String goalId) async {
    SavingsService.deleteGoal(state, goalId);
    await _commit();
  }

  Future<void> groupContribute(String goalId, String memberUsername,
      {bool bySimulated = true}) async {
    SavingsService.groupContribute(state, goalId, memberUsername,
        bySimulated: bySimulated);
    await _commit();
  }

  // ---------------------------------------------------------------------
  // Automation
  // ---------------------------------------------------------------------

  Future<String> createAutomationRule(AutomationRule rule) async {
    final id = AutomationService.create(state, rule);
    await _commit();
    return id;
  }

  Future<void> pauseRule(String id) async {
    AutomationService.pause(state, id);
    await _commit();
  }

  Future<void> resumeRule(String id) async {
    AutomationService.resume(state, id);
    await _commit();
  }

  Future<void> deleteRule(String id) async {
    AutomationService.delete(state, id);
    await _commit();
  }

  Future<void> runRuleNow(String id) async {
    await AutomationService.runRuleNow(state, id);
    await _commit();
  }

  Future<void> runDueRules() async {
    await AutomationService.runDueRules(state);
    await _commit();
  }

  // ---------------------------------------------------------------------
  // Misc
  // ---------------------------------------------------------------------

  Future<void> toggleHideBalance() async {
    state.hideBalance = !state.hideBalance;
    await _commit();
  }

  Future<void> onCompleteOnboarding() async {
    state.showOnboarding = false;
    await _commit();
  }

  Future<void> markNotificationRead(String id) async {
    for (final n in state.notifications) {
      if (n.id == id) n.read = true;
    }
    await _commit();
  }

  Future<void> markAllNotificationsRead() async {
    for (final n in state.notifications) {
      n.read = true;
    }
    await _commit();
  }
}
