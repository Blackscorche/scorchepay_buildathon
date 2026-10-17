import 'package:uuid/uuid.dart';

import '../models/app_notification.dart';
import '../models/automation.dart';
import '../models/escrow.dart';
import '../models/kyc.dart';
import '../models/ledger_entry.dart';
import '../models/savings.dart';

const _uuid = Uuid();

/// Mutable-internals app state container.
///
/// Deliberate design choice: fields on this class and on the model
/// objects it holds (`EscrowContract`, `SavingsGoal`, `AutomationRule`)
/// are mutated in place by the service layer for simplicity — but every
/// commit inside `AppStateNotifier` publishes a *new* [AppState] instance
/// via [clone], so Riverpod always sees a changed value and notifies
/// listeners even though the internals were mutated in place.
class AppState {
  AppState({
    this.token,
    this.userId,
    required this.displayName,
    this.kyc = const KycInfo.initial(),
    this.photoUrl,
    required this.localState,
  });

  /// Session token — present only while signed in. Persisted in secure
  /// storage by `AppStateNotifier`, never in [LocalAppState].
  final String? token;

  /// The backend's stable account ID (usernames can change). Null while
  /// signed out. Keys per-account data on the device, e.g. wallets.
  final String? userId;
  final String displayName;

  /// KYC tier and status — backend-derived, never computed or stored on
  /// the device. Signed out, this is the initial tier 0.
  final KycInfo kyc;

  /// Where the backend serves the profile photo; null if there isn't one.
  /// Load it with `BackendService.loadProfilePhoto` (see
  /// `profilePhotoProvider`).
  final String? photoUrl;
  LocalAppState localState;

  bool get isLoggedIn => token != null;
  String get requireToken {
    final currentToken = token;
    if (currentToken != null) return currentToken;
    throw StateError('Not signed in.');
  }

  /// Total value of all escrow contracts currently holding this user's
  /// funds (funded/disputed — not yet released/refunded), converted to
  /// NGN. This is money that left the spendable balance the moment
  /// escrow was funded — it is not "reserved but spendable."
  double escrowHeldNgn() {
    double total = 0;
    for (final e in localState.escrows) {
      if (!e.isBuyer) continue;
      if (e.status == EscrowStatus.funded ||
          e.status == EscrowStatus.disputed) {
        for (final m in e.milestones) {
          if (m.status != MilestoneStatus.released) {
            total += convertToNgn(m.amount, e.currency);
          }
        }
      }
    }
    return total;
  }

  /// Total value locked in active savings goals, converted to NGN.
  double savingsHeldNgn() {
    double total = 0;
    for (final g in localState.savingsGoals) {
      if (g.active) total += convertToNgn(g.current, g.currency);
    }
    return total;
  }

  /// NGN value of a single unit of [currency] — the shared conversion
  /// pivot used everywhere a source currency needs to be compared
  /// against or converted into another (Smart Pay's funding engine,
  /// Home's total wealth, cross-currency quotes).
  double ngnPerUnit(String currency) {
    if (currency == 'NGN') return 1;
    if (localState.cryptoPrices.containsKey(currency)) {
      return localState.cryptoPrices[currency]! *
          (localState.fxRatesToNgn['USD'] ?? 1);
    }
    return localState.fxRatesToNgn[currency] ?? 1;
  }

  double convertToNgn(double amount, String currency) =>
      amount * ngnPerUnit(currency);

  /// Converts [amount] of [from] into the equivalent amount of [to],
  /// via NGN as the pivot currency.
  double convert(double amount, String from, String to) {
    if (from == to) return amount;
    return convertToNgn(amount, from) / ngnPerUnit(to);
  }

  /// Total wealth = spendable fiat + crypto (at market) + savings-held +
  /// escrow-held, all converted to NGN (spec §3). Savings/escrow are
  /// included but should be shown as "locked" separately by the UI.
  double totalWealthNgn() {
    double total = 0;
    localState.fiatBalances
        .forEach((code, amount) => total += convertToNgn(amount, code));
    localState.cryptoHoldings
        .forEach((sym, amount) => total += convertToNgn(amount, sym));
    total += savingsHeldNgn();
    total += escrowHeldNgn();
    return total;
  }

  double spendableFiat(String currency) =>
      localState.fiatBalances[currency] ?? 0;
  double spendableCrypto(String symbol) =>
      localState.cryptoHoldings[symbol] ?? 0;

  AppState clone() {
    return AppState(
      token: token,
      userId: userId,
      displayName: displayName,
      kyc: kyc,
      photoUrl: photoUrl,
      localState: localState.cloneWith(),
    );
  }

  /// State while signed out: device-local data only, no backend data.
  factory AppState.signedOut(LocalAppState local) => AppState(
        displayName: '',
        localState: local,
      );
}

/// Device-local data: the only part of [AppState] persisted on the
/// device (see `LocalStore`). Backend data is never persisted.
class LocalAppState {
  LocalAppState({
    this.preferredCurrency = 'NGN',
    this.hideBalance = false,
    this.showOnboarding = true,
    this.username = '',
    required this.fiatBalances,
    required this.cryptoHoldings,
    required this.cryptoPrices,
    required this.fxRatesToNgn,
    required this.ledger,
    required this.escrows,
    required this.savingsGoals,
    required this.automationRules,
    required this.notifications,
  });

  final String preferredCurrency;
  bool hideBalance;
  bool showOnboarding;
  String username;

  /// Fiat balances by currency code — NGN always exists by default.
  final Map<String, double> fiatBalances;

  /// Crypto holdings by asset symbol, tracked as `double` for prototype
  /// purposes (production should use a precise decimal type per the
  /// spec's explicit warning against float quantity tracking).
  final Map<String, double> cryptoHoldings;

  /// Mock live crypto prices in USD.
  final Map<String, double> cryptoPrices;

  /// Mock live FX rates: 1 unit of currency -> NGN.
  final Map<String, double> fxRatesToNgn;

  final List<LedgerEntry> ledger;
  final List<EscrowContract> escrows;
  final List<SavingsGoal> savingsGoals;
  final List<AutomationRule> automationRules;
  final List<AppNotification> notifications;

  Map<String, dynamic> toJson() => {
        'preferredCurrency': preferredCurrency,
        'fiatBalances': fiatBalances,
        'cryptoHoldings': cryptoHoldings,
        'cryptoPrices': cryptoPrices,
        'fxRatesToNgn': fxRatesToNgn,
        'ledger': ledger.map((e) => e.toJson()).toList(),
        'escrows': escrows.map((e) => e.toJson()).toList(),
        'savingsGoals': savingsGoals.map((e) => e.toJson()).toList(),
        'automationRules': automationRules.map((e) => e.toJson()).toList(),
        'notifications': notifications.map((e) => e.toJson()).toList(),
        'hideBalance': hideBalance,
        'showOnboarding': showOnboarding,
        'username': username,
      };

  factory LocalAppState.fromJson(Map<String, dynamic> json) => LocalAppState(
        preferredCurrency: json['preferredCurrency'] as String? ?? 'NGN',
        fiatBalances: Map<String, double>.from((json['fiatBalances'] as Map)
            .map((k, v) => MapEntry(k as String, (v as num).toDouble()))),
        cryptoHoldings: Map<String, double>.from((json['cryptoHoldings'] as Map)
            .map((k, v) => MapEntry(k as String, (v as num).toDouble()))),
        cryptoPrices: Map<String, double>.from((json['cryptoPrices'] as Map)
            .map((k, v) => MapEntry(k as String, (v as num).toDouble()))),
        fxRatesToNgn: Map<String, double>.from((json['fxRatesToNgn'] as Map)
            .map((k, v) => MapEntry(k as String, (v as num).toDouble()))),
        ledger: (json['ledger'] as List)
            .map((e) =>
                LedgerEntry.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        escrows: (json['escrows'] as List)
            .map((e) =>
                EscrowContract.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        savingsGoals: (json['savingsGoals'] as List)
            .map((e) =>
                SavingsGoal.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        automationRules: (json['automationRules'] as List)
            .map((e) =>
                AutomationRule.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        notifications: (json['notifications'] as List)
            .map((e) =>
                AppNotification.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        hideBalance: json['hideBalance'] as bool? ?? false,
        showOnboarding: json['showOnboarding'] as bool? ?? true,
        username: json['username'] as String? ?? '',
      );

  LocalAppState cloneWith({String? username}) {
    return LocalAppState(
      preferredCurrency: preferredCurrency,
      fiatBalances: Map<String, double>.from(fiatBalances),
      cryptoHoldings: Map<String, double>.from(cryptoHoldings),
      cryptoPrices: Map<String, double>.from(cryptoPrices),
      fxRatesToNgn: Map<String, double>.from(fxRatesToNgn),
      ledger: List<LedgerEntry>.from(ledger),
      escrows: List<EscrowContract>.from(escrows),
      savingsGoals: List<SavingsGoal>.from(savingsGoals),
      automationRules: List<AutomationRule>.from(automationRules),
      notifications: List<AppNotification>.from(notifications),
      hideBalance: hideBalance,
      showOnboarding: showOnboarding,
      username: username ?? this.username,
    );
  }

  factory LocalAppState.seed() {
    final now = DateTime.now();

    return LocalAppState(
      fiatBalances: {
        'NGN': 6264000.00,
        'USD': 3120.40,
        'GHS': 1850.00,
        'EUR': 640.00,
        'GBP': 210.00,
      },
      cryptoHoldings: {
        'BTC': 0.0842,
        'ETH': 1.42,
        'USDT': 1850,
        'SOL': 9.6,
        'BNB': 1.1,
      },
      cryptoPrices: {
        'BTC': 96240,
        'ETH': 4120,
        'USDT': 1.00,
        'SOL': 238,
        'BNB': 712,
      },
      fxRatesToNgn: {
        'NGN': 1,
        'USD': 1545.20,
        'GHS': 103.40,
        'EUR': 1680.00,
        'GBP': 1960.00,
      },
      ledger: [
        LedgerEntry(
          id: _uuid.v4(),
          timestamp: now.subtract(const Duration(hours: 3)),
          currency: 'NGN',
          amount: 85000,
          title: 'Received from @ada_b',
          subtitle: 'Send Money · internal',
          category: LedgerCategory.transfer,
          counterparty: '@ada_b',
        ),
        LedgerEntry(
          id: _uuid.v4(),
          timestamp: now.subtract(const Duration(hours: 6)),
          currency: 'NGN',
          amount: -3500,
          title: 'Smart Pay · MTN Data',
          subtitle: 'Bills · Data',
          category: LedgerCategory.smartPay,
        ),
        LedgerEntry(
          id: _uuid.v4(),
          timestamp: now.subtract(const Duration(days: 1, hours: 2)),
          currency: 'USD',
          amount: -150,
          title: 'Bought 0.004 BTC',
          subtitle: 'Crypto · Buy',
          category: LedgerCategory.crypto,
        ),
      ],
      escrows: [],
      savingsGoals: [
        SavingsGoal(
            id: _uuid.v4(),
            name: 'New Car',
            type: SavingsType.goal,
            currency: 'NGN',
            target: 5000000,
            current: 3400000),
        SavingsGoal(
            id: _uuid.v4(),
            name: 'Rent (Locked)',
            type: SavingsType.locked,
            currency: 'NGN',
            target: 2000000,
            current: 1800000,
            lockUntil: now.add(const Duration(days: 40)),
            penaltyPct: 0.3,
            apy: 0.12),
        SavingsGoal(
            id: _uuid.v4(),
            name: 'Emergency Fund',
            type: SavingsType.emergency,
            currency: 'USD',
            target: 1000,
            current: 400),
        SavingsGoal(
            id: _uuid.v4(),
            name: 'Stablecoin Savings',
            type: SavingsType.stablecoin,
            currency: 'USDT',
            target: 1000,
            current: 250,
            apy: 0.14),
      ],
      automationRules: [
        AutomationRule(
          id: _uuid.v4(),
          name: 'Auto-pay electricity',
          triggerType: TriggerType.schedule,
          scheduleFrequency: ScheduleFrequency.monthly,
          actionType: AutomationActionType.payBill,
          amount: 15000,
          currency: 'NGN',
          fixedBillerName: 'Ikeja Electric',
          fixedBillerCustomerId: '04521199201',
          nextRunAt: DateTime(now.year, now.month + 1, 1),
        ),
        AutomationRule(
          id: _uuid.v4(),
          name: 'Weekly auto-save ₦10,000',
          triggerType: TriggerType.schedule,
          scheduleFrequency: ScheduleFrequency.weekly,
          actionType: AutomationActionType.save,
          amount: 10000,
          currency: 'NGN',
          nextRunAt: now.add(const Duration(days: 3)),
        ),
        AutomationRule(
          id: _uuid.v4(),
          name: 'Auto-convert USDT → NGN on receipt',
          triggerType: TriggerType.event,
          eventTrigger: EventTrigger.moneyReceived,
          actionType: AutomationActionType.convert,
          amount: 0,
          currency: 'USDT',
          convertToCurrency: 'NGN',
          status: RuleStatus.paused,
        ),
      ],
      notifications: [],
    );
  }
}
