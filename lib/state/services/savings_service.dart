import 'package:uuid/uuid.dart';

import '../models/app_notification.dart';
import '../models/ledger_entry.dart';
import '../models/savings.dart';
import '../providers/app_state.dart';
import 'ledger_service.dart';
import 'smart_pay_engine.dart';

const _uuid = Uuid();

/// Savings mechanics (spec §13). One shared `SavingsGoal` primitive;
/// this service is where the funding-rule/withdrawal-rule differences
/// between the nine types actually live.
class SavingsService {
  SavingsService._();

  static SavingsGoal? find(AppState s, String id) {
    for (final g in s.savingsGoals) {
      if (g.id == id) return g;
    }
    return null;
  }

  static String create(AppState s, SavingsGoal goal) {
    s.savingsGoals.insert(0, goal);
    _notify(s, 'Goal created', '"${goal.name}" is ready to fund.');
    return goal.id;
  }

  /// Moves [amount] from a spendable balance (Smart Pay funding-priority
  /// unless [fundingSource] is fixed) into the goal's held balance.
  static SmartPayResult contribute(AppState s, String goalId, double amount,
      {String? fundingSource}) {
    final g = find(s, goalId);
    if (g == null) {
      return SmartPayResult.providerFailed(
          const FundingPlan(
              nativeCurrency: '', nativeAmount: 0, legs: [], shortBy: 0),
          'Goal not found');
    }
    final result = SmartPayEngine.fundOnly(s,
        title: 'Savings · ${g.name}',
        amount: amount,
        currency: g.currency,
        fixedSourceCurrency: fundingSource);
    if (result.isSuccess) {
      g.current += amount;
      g.contributionLog.insert(0,
          '${DateTime.now().toIso8601String()}: +${amount.toStringAsFixed(2)} ${g.currency}');
      _notify(s, 'Money added',
          '${amount.toStringAsFixed(2)} ${g.currency} added to "${g.name}".');
      if (g.isComplete) {
        _notify(s, 'Goal reached',
            '"${g.name}" hit its target of ${g.target} ${g.currency}!');
      }
    }
    return result;
  }

  /// Applies the disclosed locked-savings penalty (forfeited accrued
  /// interest share, per spec §13) if withdrawing before [lockUntil].
  /// Returns the net amount actually credited back to spendable balance.
  static double withdraw(AppState s, String goalId, double amount) {
    final g = find(s, goalId);
    if (g == null || amount <= 0 || amount > g.current) return 0;
    g.current -= amount;
    double net = amount;
    if (g.isLocked && g.penaltyPct != null) {
      final penalty = amount * g.penaltyPct!;
      net = amount - penalty;
      LedgerService.credit(
        s,
        currency: g.currency,
        amount: net,
        title: 'Withdrawn from "${g.name}"',
        subtitle:
            'Early withdrawal — ${(g.penaltyPct! * 100).toStringAsFixed(0)}% penalty forfeited',
        category: LedgerCategory.savings,
        meta: {'goalId': g.id, 'penalty': penalty},
      );
    } else {
      LedgerService.credit(
        s,
        currency: g.currency,
        amount: net,
        title: 'Withdrawn from "${g.name}"',
        subtitle: 'Savings withdrawal',
        category: LedgerCategory.savings,
        meta: {'goalId': g.id},
      );
    }
    g.contributionLog.insert(0,
        '${DateTime.now().toIso8601String()}: -${amount.toStringAsFixed(2)} ${g.currency}');
    _notify(s, 'Withdrawal complete',
        '${net.toStringAsFixed(2)} ${g.currency} moved from "${g.name}" to your wallet.');
    return net;
  }

  static void deleteGoal(AppState s, String goalId) {
    final g = find(s, goalId);
    if (g == null) return;
    if (g.current > 0) withdraw(s, goalId, g.current);
    s.savingsGoals.removeWhere((x) => x.id == goalId);
    _notify(s, 'Goal deleted',
        '"${g.name}" was deleted and its balance returned to your wallet.');
  }

  /// Round-up savings (spec §13) — call this from any flow that just
  /// completed a qualifying transaction. Rounds [transactionAmount] up
  /// to the nearest [SavingsGoal.roundUpUnit] and sweeps the difference
  /// in synchronously, same as the triggering transaction settling.
  static void applyRoundUp(
      AppState s, String goalId, double transactionAmount) {
    final g = find(s, goalId);
    if (g == null ||
        g.type != SavingsType.roundUp ||
        g.roundUpUnit == null ||
        !g.active) {
      return;
    }
    final unit = g.roundUpUnit!;
    final rounded = (transactionAmount / unit).ceil() * unit;
    final diff = rounded - transactionAmount;
    if (diff <= 0) return;
    try {
      SmartPayEngine.fundOnly(s,
          title: 'Round-up · ${g.name}', amount: diff, currency: g.currency);
      g.current += diff;
      g.contributionLog.insert(0,
          '${DateTime.now().toIso8601String()}: +${diff.toStringAsFixed(2)} ${g.currency} (round-up)');
    } catch (_) {
      // Insufficient funds for the round-up itself — silently skip; this
      // is a small automatic sweep, not a user-initiated action worth
      // interrupting them over.
    }
  }

  /// Rotating group savings — one member's contribution for the current
  /// cycle. Once every member has contributed, the full pool pays out to
  /// whoever is next in rotation order and the cycle advances.
  static void groupContribute(AppState s, String goalId, String memberUsername,
      {bool bySimulated = true}) {
    final g = find(s, goalId);
    if (g == null || g.type != SavingsType.group || g.groupMembers == null) {
      return;
    }
    final member =
        g.groupMembers!.where((m) => m.username == memberUsername).firstOrNull;
    if (member == null || member.hasContributedThisCycle) return;

    final amount = g.groupContributionAmount ?? 0;
    if (memberUsername == s.username) {
      // The local user's own contribution routes through real funding.
      final result = SmartPayEngine.fundOnly(s,
          title: 'Group savings · ${g.name}',
          amount: amount,
          currency: g.currency);
      if (!result.isSuccess) return;
    }
    member.hasContributedThisCycle = true;
    g.current += amount;
    _notify(s, 'Contribution received',
        '${member.displayName} contributed ${amount.toStringAsFixed(2)} ${g.currency} to "${g.name}".');

    if (g.groupMembers!.every((m) => m.hasContributedThisCycle)) {
      _payoutCycle(s, g);
    }
  }

  static void _payoutCycle(AppState s, SavingsGoal g) {
    final members = g.groupMembers!;
    final recipient = members.firstWhere(
      (m) => !m.hasReceivedPayout,
      orElse: () => members[g.groupCycleIndex % members.length],
    );
    final total = g.current;
    if (recipient.username == s.username) {
      LedgerService.credit(
        s,
        currency: g.currency,
        amount: total,
        title: 'Group payout — "${g.name}"',
        subtitle: 'Rotating savings payout, cycle ${g.groupCycleIndex + 1}',
        category: LedgerCategory.savings,
        meta: {'goalId': g.id},
      );
    }
    recipient.hasReceivedPayout = true;
    g.current = 0;
    g.groupCycleIndex += 1;
    for (final m in members) {
      m.hasContributedThisCycle = false;
    }
    _notify(s, 'Cycle payout',
        '${recipient.displayName} received the ${total.toStringAsFixed(2)} ${g.currency} payout for "${g.name}".');

    if (members.every((m) => m.hasReceivedPayout)) {
      g.active = false;
      _notify(s, 'Group savings complete',
          'Every member of "${g.name}" has received a payout — the group cycle is complete.');
    }
  }

  static void _notify(AppState s, String title, String body) {
    s.notifications.insert(
        0,
        AppNotification(
            id: _uuid.v4(),
            at: DateTime.now(),
            category: NotificationCategory.savings,
            title: title,
            body: body));
  }
}
