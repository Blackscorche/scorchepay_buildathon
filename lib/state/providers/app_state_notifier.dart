import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:passkeys/authenticator.dart';
import 'package:passkeys/types.dart'
    show AuthenticateRequestType, RegisterRequestType;
import 'package:uuid/uuid.dart';

import '../services/backend_service.dart';
import '../models/app_notification.dart';
import '../models/automation.dart';
import '../models/escrow.dart';
import '../models/ledger_entry.dart';
import '../models/savings.dart';
import '../models/sign_up_draft.dart';
import '../services/automation_service.dart';
import '../services/escrow_service.dart';
import '../services/fx_rate_service.dart';
import '../services/ledger_service.dart';
import '../services/local_store.dart';
import '../services/passkey_service.dart';
import '../services/savings_service.dart';
import '../services/simulated_providers.dart';
import '../services/smart_pay_engine.dart';
import 'app_state.dart';

final secureStorageProvider = Provider<FlutterSecureStorage>(
  // useDataProtectionKeyChain can be used with MacOsOptions for testing
  (ref) => const FlutterSecureStorage(),
);

/// The app's one state notifier: the session (restored on startup, then
/// [login] / [logout]) plus every user-facing action on app state.
///
/// [build] restores the stored session, so this is loading until that's
/// done; ScorchePayApp shows the splash until then. Everything else reads
/// it through `requireValue`.
final appStateProvider =
    AsyncNotifierProvider<AppStateNotifier, AppState>(AppStateNotifier.new);

const _uuid = Uuid();

/// Every action follows one pattern: mutate the current state's
/// internals via the relevant service, then [_commit], which publishes a
/// clone (so Riverpod always notifies, despite the mutable internals) and
/// persists the device-local slice to disk. Backend data — identity and
/// the token — is never written to [LocalStore].
class AppStateNotifier extends AsyncNotifier<AppState> {
  static const _tokenKey = 'auth_token';

  BackendService get _backend => ref.read(backendServiceProvider);
  PasskeyAuthenticator get _passkeys => ref.read(passkeyAuthenticatorProvider);
  FlutterSecureStorage get _secure => ref.read(secureStorageProvider);
  LocalStore get _store => ref.read(localStoreProvider);

  /// The current state. Actions only run once [build] has completed.
  AppState get _appState => state.requireValue;

  // ---------------------------------------------------------------------
  // Session
  // ---------------------------------------------------------------------

  @override
  Future<AppState> build() async {
    // Failures propagate: the provider goes into AsyncError (keeping the
    // previous value on a reload), and ScorchePayApp shows the error and
    // decides whether to recover via [continueSignedOut].
    final local = await _store.load();
    final token = await _secure.read(key: _tokenKey);
    if (token == null) return AppState.signedOut(local);

    try {
      final restored = await _backend.getUser(token, local);
      if (restored.localState != local) {
        // Persist parts of the state (like username) gotten from the backend but used on the client.
        await _store.save(restored.localState);
      }

      // Run after refreshing state
      unawaited(Future(_refreshFxRates));
      return restored;
    } on AuthException {
      // Token rejected: forget it. Any other error (e.g. offline) keeps
      // the token, so the next launch or reload can try again.
      await _deleteToken();
      rethrow;
    }
  }

  /// Recovers from a failed [build] by continuing signed out on the
  /// device's data, so the app stays usable. Called by ScorchePayApp
  /// after it has shown the error.
  Future<void> continueSignedOut() async {
    state = AsyncData(AppState.signedOut(await _store.load()));
  }

  Future<void> _reload() async {
    ref.invalidateSelf();
    await future;
  }

  Future<void> login(String username, String pin) async {
    final token =
        await _backend.login(username, pin); // bad PIN still throws here
    await _startSession(token);
  }

  /// Logs in with a passkey on this device (the OS shows the biometric
  /// prompt and lets the user pick one if there are several).
  Future<void> loginWithPasskey() async {
    final options = await _backend.startPasskeyLogin();
    final assertion = await passkeyCall(() => _passkeys.authenticate(
        AuthenticateRequestType.fromJsonString(options,
            preferImmediatelyAvailableCredentials: false)));
    final token = await _backend.finishPasskeyLogin(assertion.toJsonString());
    await _startSession(token);
  }

  /// Adds a passkey on this device to the signed-in account.
  Future<void> registerPasskey() async {
    await _registerPasskey(_appState.requireToken);
  }

  Future<void> _registerPasskey(String sessionToken) async {
    final options = await _backend.startPasskeyRegistration(sessionToken);
    final credential = await passkeyCall(
        () => _passkeys.register(RegisterRequestType.fromJsonString(options)));
    await _backend.finishPasskeyRegistration(
        sessionToken, credential.toJsonString());
  }

  /// Creates the account from a completed [draft] and signs in to it.
  /// The router then leaves the sign-up flow for home.
  ///
  /// With [registerPasskey], also adds a passkey (the OS shows the
  /// biometric prompt) before signing in, while the sign-up screen is still
  /// up. That step, and uploading [SignUpDraft.photo], can fail without
  /// failing sign-up: the result says what didn't work.
  Future<SignUpResult> signUp(SignUpDraft draft,
      {bool registerPasskey = false}) async {
    final signUpToken = draft.signUpToken;
    final pin = draft.pin;
    final username = draft.username;
    if (signUpToken == null || pin == null || username == null) {
      throw StateError('Sign-up is missing a step.');
    }
    // Validation and conflicts (e.g. a taken username) throw here.
    final token = await _backend.signUp(
        signUpToken: signUpToken,
        displayName: draft.displayName,
        username: username,
        pin: pin);

    // Optional extras need a session, so they run now, while the sign-up
    // screen is still up. Neither failing fails sign-up.
    String? photoError;
    final photo = draft.photo;
    if (photo != null) {
      try {
        await _backend.uploadProfilePhoto(token, photo);
      } catch (error) {
        photoError = error.toString();
      }
    }

    String? passkeyError;
    if (registerPasskey) {
      try {
        await _registerPasskey(token);
      } catch (error) {
        passkeyError = error.toString();
      }
    }

    try {
      await _startSession(token);
    } on AuthException {
      // The account exists now, so retrying sign-up would only hit
      // "username taken". Point them at login instead.
      throw const AuthException(
          "Your account was created, but we couldn't sign you in. Please log in.");
    }
    return SignUpResult(photoError: photoError, passkeyError: passkeyError);
  }

  /// Sets the signed-in user's profile photo, or removes it if [photo] is
  /// null.
  Future<void> setProfilePhoto(Uint8List? photo) async {
    final token = _appState.token;
    if (token == null) throw StateError('Not signed in.');
    if (photo == null) {
      await _backend.deleteProfilePhoto(token);
    } else {
      await _backend.uploadProfilePhoto(token, photo);
    }
    await _reload();
  }

  /// Stores [token] and loads the signed-in state for it.
  Future<void> _startSession(String token) async {
    await _secure.write(key: _tokenKey, value: token);
    try {
      await _reload(); // throws if build() fails
    } on AuthException {
      rethrow; // build() already deleted the rejected token
    } catch (_) {
      // The user sees a failed login, so don't keep the token around to
      // sign them in silently on the next launch.
      await _deleteToken();
      throw const AuthException("Couldn't reach the server. Please try again.");
    }
  }

  Future<void> logout() async {
    await _deleteToken();
    // Not _reload(): signing out needs no backend, and a failed build()
    // here would leave the old signed-in value in place.
    await continueSignedOut();
  }

  Future<void> updateUserDetails(
      {String? username, String? displayName}) async {
    final token = _appState.token;
    if (token == null) throw StateError('Not signed in.');
    await _backend.updateUserDetails(token,
        username: username, displayName: displayName);
    await _reload();
  }

  Future<void> _deleteToken() async {
    try {
      await _secure.delete(key: _tokenKey);
    } catch (_) {}
  }

  /// Pulls live NGN-pivot FX rates (§5 of the spec — real rates, not a
  /// static table) and merges them into whatever currencies the user
  /// already holds. Falls back silently to the existing bundled rates
  /// on any failure (offline, rate-limited), same pattern as
  /// [CoinGeckoService].
  Future<void> _refreshFxRates() async {
    try {
      if (_appState.localState.fxRatesToNgn.isEmpty) return;
      final live = await FxRateService.getRatesToNgn();
      for (final code in _appState.localState.fxRatesToNgn.keys.toList()) {
        if (live.containsKey(code)) {
          _appState.localState.fxRatesToNgn[code] = live[code]!;
        }
      }
      await _commit();
    } catch (_) {
      // Offline or the free API is down — the bundled rates already cover it.
    }
  }

  Future<void> _commit() async {
    state = AsyncData(_appState.clone());
    // Only the device-local slice is written (see LocalStore).
    await _store.save(_appState.localState);
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
      final result = await SmartPayEngine.payBill(_appState,
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
    return SmartPayEngine.planPayment(_appState,
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
      LedgerService.internalTransferOut(_appState,
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
    _appState.localState.notifications.insert(
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
      final entry = LedgerService.debit(_appState,
          currency: 'NGN',
          amount: amount,
          title: 'Sent to $accountName',
          subtitle: '$bankName · bank transfer',
          category: LedgerCategory.transfer);
      final result = await SimulatedProviders.bankTransfer(
          amount: amount, bankName: bankName);
      if (result.failed) {
        LedgerService.refund(_appState, entry, reasonSuffix: result.reason);
        _appState.localState.notifications.insert(
            0,
            AppNotification(
                id: _uuid.v4(),
                at: DateTime.now(),
                category: NotificationCategory.transfers,
                title: 'Transfer failed',
                body:
                    '${result.reason} — ${amount.toStringAsFixed(2)} NGN refunded.'));
      } else {
        _appState.localState.notifications.insert(
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
      final entry = LedgerService.debit(_appState,
          currency: fundingSource,
          amount: amount,
          title: 'Buy $asset',
          subtitle: 'Crypto purchase',
          category: LedgerCategory.crypto);
      final result =
          await SimulatedProviders.executeTrade(asset: asset, amount: amount);
      if (result.failed) {
        LedgerService.refund(_appState, entry, reasonSuffix: result.reason);
      } else {
        final price = _appState.localState.cryptoPrices[asset] ?? 1;
        final usdValue = _appState.convert(amount, fundingSource, 'USD');
        final qty = usdValue / price;
        LedgerService.credit(_appState,
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
      final entry = LedgerService.debit(_appState,
          currency: asset,
          amount: quantity,
          title: 'Sell $asset',
          subtitle: 'Crypto sale',
          category: LedgerCategory.crypto);
      final result =
          await SimulatedProviders.executeTrade(asset: asset, amount: quantity);
      if (result.failed) {
        LedgerService.refund(_appState, entry, reasonSuffix: result.reason);
      } else {
        final usdValue =
            quantity * (_appState.localState.cryptoPrices[asset] ?? 1);
        final payout = _appState.convert(usdValue, 'USD', payoutCurrency);
        LedgerService.credit(_appState,
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
      final entry = LedgerService.debit(_appState,
          currency: from,
          amount: amount,
          title: 'Swap $from → $to',
          subtitle: 'Crypto swap',
          category: LedgerCategory.crypto);
      final result =
          await SimulatedProviders.executeTrade(asset: from, amount: amount);
      if (result.failed) {
        LedgerService.refund(_appState, entry, reasonSuffix: result.reason);
      } else {
        final converted = _appState.convert(amount, from, to);
        LedgerService.credit(_appState,
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
      LedgerService.debit(_appState,
          currency: asset,
          amount: amount,
          title: 'Withdraw $asset',
          subtitle: '$network · $address',
          category: LedgerCategory.crypto,
          meta: {'network': network, 'address': address});
      final result = await SimulatedProviders.broadcastWithdrawal(
          asset: asset, network: network);
      _appState.localState.notifications.insert(
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
      final entry = LedgerService.debit(_appState,
          currency: 'NGN',
          amount: amount,
          title: 'Cross-border to $recipientName',
          subtitle: corridor,
          category: LedgerCategory.transfer);
      final result = await SimulatedProviders.crossBorderTransfer(
          amount: amount, corridor: corridor);
      if (result.failed) {
        LedgerService.refund(_appState, entry, reasonSuffix: result.reason);
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
      _appState,
      currency: 'NGN',
      amount: payoutNaira,
      title: 'Gift card exchanged — $brand',
      subtitle: '\$${faceValueUsd.toStringAsFixed(0)} card',
      category: LedgerCategory.bill,
    );
    _appState.localState.notifications.insert(
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
    final id = EscrowService.create(_appState,
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
    EscrowService.counterpartyRespond(_appState, escrowId, accept: accept);
    await _commit();
  }

  Future<SmartPayResult> fundEscrow(String escrowId) async {
    try {
      final result = EscrowService.fund(_appState, escrowId);
      await _commit();
      return result;
    } on InsufficientFundsException catch (ex) {
      final e = EscrowService.find(_appState, escrowId);
      return SmartPayResult.insufficientFunds(FundingPlan(
          nativeCurrency: e?.currency ?? '',
          nativeAmount: e?.totalAmount ?? 0,
          legs: const [],
          shortBy: ex.shortBy));
    }
  }

  Future<void> simulateCounterpartyFundEscrow(String escrowId) async {
    EscrowService.simulateCounterpartyFund(_appState, escrowId);
    await _commit();
  }

  Future<void> submitEscrowEvidence(
      String escrowId, String milestoneId, String note,
      {bool bySimulatedCounterparty = false}) async {
    EscrowService.submitEvidence(_appState, escrowId, milestoneId, note,
        bySimulatedCounterparty: bySimulatedCounterparty);
    await _commit();
  }

  Future<void> releaseEscrowMilestone(
      String escrowId, String milestoneId) async {
    EscrowService.release(_appState, escrowId, milestoneId);
    await _commit();
  }

  Future<void> raiseEscrowDispute(
      String escrowId, String milestoneId, String reason,
      {bool bySimulatedCounterparty = false}) async {
    EscrowService.raiseDispute(_appState, escrowId, milestoneId, reason,
        bySimulatedCounterparty: bySimulatedCounterparty);
    await _commit();
  }

  Future<void> resolveEscrowDispute(
      String escrowId, String milestoneId, DisputeResolution resolution) async {
    EscrowService.resolveDispute(_appState, escrowId, milestoneId, resolution);
    await _commit();
  }

  Future<void> checkExpiredReviewWindows() async {
    final before =
        _appState.localState.escrows.map((e) => e.timeline.length).toList();
    EscrowService.checkExpiredReviewWindows(_appState);
    final after =
        _appState.localState.escrows.map((e) => e.timeline.length).toList();
    if (before.toString() != after.toString()) await _commit();
  }

  // ---------------------------------------------------------------------
  // Savings
  // ---------------------------------------------------------------------

  Future<String> createSavingsGoal(SavingsGoal goal) async {
    final id = SavingsService.create(_appState, goal);
    await _commit();
    return id;
  }

  Future<SmartPayResult> contributeSavings(String goalId, double amount,
      {String? fundingSource}) async {
    try {
      final result = SavingsService.contribute(_appState, goalId, amount,
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
    final net = SavingsService.withdraw(_appState, goalId, amount);
    await _commit();
    return net;
  }

  Future<void> deleteSavingsGoal(String goalId) async {
    SavingsService.deleteGoal(_appState, goalId);
    await _commit();
  }

  Future<void> groupContribute(String goalId, String memberUsername,
      {bool bySimulated = true}) async {
    SavingsService.groupContribute(_appState, goalId, memberUsername,
        bySimulated: bySimulated);
    await _commit();
  }

  // ---------------------------------------------------------------------
  // Automation
  // ---------------------------------------------------------------------

  Future<String> createAutomationRule(AutomationRule rule) async {
    final id = AutomationService.create(_appState, rule);
    await _commit();
    return id;
  }

  Future<void> pauseRule(String id) async {
    AutomationService.pause(_appState, id);
    await _commit();
  }

  Future<void> resumeRule(String id) async {
    AutomationService.resume(_appState, id);
    await _commit();
  }

  Future<void> deleteRule(String id) async {
    AutomationService.delete(_appState, id);
    await _commit();
  }

  Future<void> runRuleNow(String id) async {
    await AutomationService.runRuleNow(_appState, id);
    await _commit();
  }

  Future<void> runDueRules() async {
    await AutomationService.runDueRules(_appState);
    await _commit();
  }

  // ---------------------------------------------------------------------
  // Misc
  // ---------------------------------------------------------------------

  Future<void> toggleHideBalance() async {
    _appState.localState.hideBalance = !_appState.localState.hideBalance;
    await _commit();
  }

  Future<void> onCompleteOnboarding() async {
    _appState.localState.showOnboarding = false;
    await _commit();
  }

  Future<void> markNotificationRead(String id) async {
    for (final n in _appState.localState.notifications) {
      if (n.id == id) n.read = true;
    }
    await _commit();
  }

  Future<void> markAllNotificationsRead() async {
    for (final n in _appState.localState.notifications) {
      n.read = true;
    }
    await _commit();
  }
}

/// What didn't work during [AppStateNotifier.signUp], beyond creating the
/// account (which throws instead). Each is a user-facing message, or null.
class SignUpResult {
  const SignUpResult({this.photoError, this.passkeyError});

  final String? photoError;
  final String? passkeyError;
}
