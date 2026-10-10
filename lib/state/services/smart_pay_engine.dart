import '../models/ledger_entry.dart';
import '../providers/app_state.dart';
import 'ledger_service.dart';
import 'simulated_providers.dart';

/// One funding source's contribution to a Smart Pay payment.
class FundingLeg {
  const FundingLeg({
    required this.currency,
    required this.sourceAmount,
    required this.nativeEquivalent,
    required this.isStablecoin,
    required this.isVolatileCrypto,
  });

  final String currency;

  /// Amount taken from this source, in the source's own currency.
  final double sourceAmount;

  /// That amount's value in the payment's native currency.
  final double nativeEquivalent;

  final bool isStablecoin;
  final bool isVolatileCrypto;

  bool get needsConversion => nativeEquivalent != sourceAmount;
}

/// The result of walking the funding-priority list for a given amount —
/// either a complete plan covering the full amount, or an incomplete one
/// showing exactly how far short the user is (spec §7's "fail before
/// step 6" requirement).
class FundingPlan {
  const FundingPlan(
      {required this.nativeCurrency,
      required this.nativeAmount,
      required this.legs,
      required this.shortBy});

  final String nativeCurrency;
  final double nativeAmount;
  final List<FundingLeg> legs;
  final double shortBy;

  bool get isSufficient => shortBy <= 1e-6;

  double get coveredAmount => nativeAmount - shortBy;

  double pctOf(FundingLeg leg) =>
      nativeAmount <= 0 ? 0 : (leg.nativeEquivalent / nativeAmount) * 100;
}

/// Smart Pay — the funding engine (spec §7). This is the app's core
/// differentiator: given an amount priced in some native currency, walk
/// an ordered list of the user's balances and allocate from each until
/// the amount is fully covered, converting non-native sources at a
/// locked quote, then debit every leg atomically (all-or-nothing).
class SmartPayEngine {
  SmartPayEngine._();

  static const _stablecoins = {'USDT'};

  /// Builds the ordered candidate list per the spec's default priority:
  /// 1. native currency itself, 2. stablecoins, 3. other fiat (FX
  /// conversion), 4. volatile crypto last. Returns the plan without
  /// mutating any state — call [execute] to actually debit it.
  static FundingPlan planPayment(
    AppState s, {
    required String nativeCurrency,
    required double nativeAmount,
    String? fixedSourceCurrency,
  }) {
    if (fixedSourceCurrency != null) {
      final have = LedgerService.balanceOf(s, fixedSourceCurrency);
      final haveNative = s.convert(have, fixedSourceCurrency, nativeCurrency);
      final take = haveNative >= nativeAmount ? nativeAmount : haveNative;
      final takeSource = s.convert(take, nativeCurrency, fixedSourceCurrency);
      final legs = take > 0
          ? [
              FundingLeg(
                currency: fixedSourceCurrency,
                sourceAmount: takeSource,
                nativeEquivalent: take,
                isStablecoin: _stablecoins.contains(fixedSourceCurrency),
                isVolatileCrypto:
                    s.localState.cryptoPrices.containsKey(fixedSourceCurrency) &&
                        !_stablecoins.contains(fixedSourceCurrency),
              )
            ]
          : <FundingLeg>[];
      return FundingPlan(
          nativeCurrency: nativeCurrency,
          nativeAmount: nativeAmount,
          legs: legs,
          shortBy: nativeAmount - take);
    }

    final candidates = <String>[];
    if (s.localState.fiatBalances.containsKey(nativeCurrency)) {
      candidates.add(nativeCurrency);
    }
    for (final c in s.localState.cryptoHoldings.keys) {
      if (_stablecoins.contains(c)) candidates.add(c);
    }
    for (final c in s.localState.fiatBalances.keys) {
      if (c != nativeCurrency) candidates.add(c);
    }
    for (final c in s.localState.cryptoHoldings.keys) {
      if (!_stablecoins.contains(c)) candidates.add(c);
    }

    double remaining = nativeAmount;
    final legs = <FundingLeg>[];
    for (final currency in candidates) {
      if (remaining <= 1e-9) break;
      final available = LedgerService.balanceOf(s, currency);
      if (available <= 1e-9) continue;
      final availableNative = s.convert(available, currency, nativeCurrency);
      final takeNative =
          availableNative >= remaining ? remaining : availableNative;
      final takeSource = s.convert(takeNative, nativeCurrency, currency);
      legs.add(FundingLeg(
        currency: currency,
        sourceAmount: takeSource,
        nativeEquivalent: takeNative,
        isStablecoin: _stablecoins.contains(currency),
        isVolatileCrypto: s.localState.cryptoPrices.containsKey(currency) &&
            !_stablecoins.contains(currency),
      ));
      remaining -= takeNative;
    }

    return FundingPlan(
        nativeCurrency: nativeCurrency,
        nativeAmount: nativeAmount,
        legs: legs,
        shortBy: remaining);
  }

  /// Debits every leg of [plan] atomically — if any leg fails (should be
  /// rare here since [planPayment] already checked availability, but a
  /// balance could have changed between quote and confirm in a
  /// multi-actor system), roll back every leg already applied and
  /// rethrow, per spec §7 step 6's all-or-nothing requirement.
  static List<LedgerEntry> _debitLegs(AppState s, FundingPlan plan,
      {required String title, required String groupId}) {
    final applied = <LedgerEntry>[];
    try {
      for (final leg in plan.legs) {
        final entry = LedgerService.debit(
          s,
          currency: leg.currency,
          amount: leg.sourceAmount,
          title: title,
          subtitle: leg.needsConversion
              ? 'Smart Pay funding leg · converted to ${plan.nativeCurrency}'
              : 'Smart Pay funding leg',
          category: LedgerCategory.smartPay,
          groupId: groupId,
          meta: {
            'nativeEquivalent': leg.nativeEquivalent,
            'nativeCurrency': plan.nativeCurrency
          },
        );
        applied.add(entry);
      }
      return applied;
    } catch (e) {
      for (final entry in applied) {
        LedgerService.refund(s, entry, reasonSuffix: 'Funding leg rolled back');
      }
      rethrow;
    }
  }

  /// Full end-to-end Smart Pay execution for a bill payment (walkthrough
  /// §9): debit funding legs atomically, call the simulated biller,
  /// write the payment record on success, auto-refund every leg on
  /// failure. Returns the biller's reference/token on success.
  static Future<SmartPayResult> payBill(
    AppState s, {
    required String biller,
    required String customerId,
    required double amount,
    required String currency,
    String? fixedSourceCurrency,
  }) async {
    final plan = planPayment(s,
        nativeCurrency: currency,
        nativeAmount: amount,
        fixedSourceCurrency: fixedSourceCurrency);
    if (!plan.isSufficient) {
      return SmartPayResult.insufficientFunds(plan);
    }
    final groupId = 'sp-${DateTime.now().microsecondsSinceEpoch}';
    final legs =
        _debitLegs(s, plan, title: 'Smart Pay · $biller', groupId: groupId);

    final providerResult =
        await SimulatedProviders.payBill(biller: biller, amount: amount);
    if (providerResult.failed) {
      for (final entry in legs) {
        LedgerService.refund(s, entry,
            reasonSuffix: '$biller payment failed — refunded');
      }
      return SmartPayResult.providerFailed(
          plan, providerResult.reason ?? 'Payment failed');
    }

    LedgerService.credit(
      s,
      currency: currency,
      amount: 0,
      title: 'Smart Pay · $biller — completed',
      subtitle: 'Customer ID: $customerId',
      category: LedgerCategory.bill,
      groupId: groupId,
      meta: {
        'token': providerResult.reference,
        'funding': plan.legs
            .map((l) => {
                  'currency': l.currency,
                  'amount': l.sourceAmount,
                  'native': l.nativeEquivalent
                })
            .toList()
      },
    );

    return SmartPayResult.success(plan, providerResult.reference);
  }

  /// Generic Smart Pay funding call for flows that don't call an
  /// external biller (funding an escrow, paying a merchant, funding a
  /// savings contribution) — debits the legs atomically and returns the
  /// plan; the caller credits the destination itself.
  static SmartPayResult fundOnly(AppState s,
      {required String title,
      required double amount,
      required String currency,
      String? fixedSourceCurrency}) {
    final plan = planPayment(s,
        nativeCurrency: currency,
        nativeAmount: amount,
        fixedSourceCurrency: fixedSourceCurrency);
    if (!plan.isSufficient) {
      return SmartPayResult.insufficientFunds(plan);
    }
    final groupId = 'sp-${DateTime.now().microsecondsSinceEpoch}';
    _debitLegs(s, plan, title: title, groupId: groupId);
    return SmartPayResult.success(plan, groupId);
  }
}

enum SmartPayOutcome { success, insufficientFunds, providerFailed }

class SmartPayResult {
  const SmartPayResult._(this.outcome, this.plan, this.reference, this.message);

  factory SmartPayResult.success(FundingPlan plan, String? reference) =>
      SmartPayResult._(SmartPayOutcome.success, plan, reference, null);
  factory SmartPayResult.insufficientFunds(FundingPlan plan) => SmartPayResult._(
      SmartPayOutcome.insufficientFunds,
      plan,
      null,
      'You are short by ${plan.shortBy.toStringAsFixed(2)} ${plan.nativeCurrency}');
  factory SmartPayResult.providerFailed(FundingPlan plan, String reason) =>
      SmartPayResult._(SmartPayOutcome.providerFailed, plan, null, reason);

  final SmartPayOutcome outcome;
  final FundingPlan plan;
  final String? reference;
  final String? message;

  bool get isSuccess => outcome == SmartPayOutcome.success;
}
