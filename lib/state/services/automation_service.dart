import 'package:uuid/uuid.dart';

import '../models/app_notification.dart';
import '../models/automation.dart';
import '../models/ledger_entry.dart';
import '../providers/app_state.dart';
import 'ledger_service.dart';
import 'smart_pay_engine.dart';

const _uuid = Uuid();

/// The automation rules engine (spec §23). Every "automatic" behaviour
/// in the app is one instance of [AutomationRule]; this service is what
/// actually executes a rule when its trigger fires, whether that's a
/// scheduled due-check (see MainShell's periodic tick) or a manual
/// "Run now" from the rule detail screen.
class AutomationService {
  AutomationService._();

  static AutomationRule? find(AppState s, String id) {
    for (final r in s.localState.automationRules) {
      if (r.id == id) return r;
    }
    return null;
  }

  static String create(AppState s, AutomationRule rule) {
    s.localState.automationRules.insert(0, rule);
    _notify(s, 'Automation rule created', '"${rule.name}" is now active.');
    return rule.id;
  }

  static void pause(AppState s, String id) {
    final r = find(s, id);
    if (r == null) return;
    r.status = RuleStatus.paused;
  }

  static void resume(AppState s, String id) {
    final r = find(s, id);
    if (r == null) return;
    r.status = RuleStatus.active;
  }

  static void delete(AppState s, String id) {
    s.localState.automationRules.removeWhere((r) => r.id == id);
  }

  /// Scans every active, schedule-triggered rule and runs any whose
  /// `nextRunAt` has passed — call periodically (MainShell's timer)
  /// since there's no real backend cron in this prototype.
  static Future<void> runDueRules(AppState s) async {
    final now = DateTime.now();
    for (final r in s.localState.automationRules) {
      if (r.status != RuleStatus.active) continue;
      if (r.triggerType != TriggerType.schedule) continue;
      if (r.nextRunAt == null || now.isBefore(r.nextRunAt!)) continue;
      await runRuleNow(s, r.id);
    }
  }

  /// Executes [ruleId] immediately regardless of its trigger — used both
  /// by [runDueRules] and by the rule detail screen's manual "Run now",
  /// which deliberately hits the same real balance checks (it can fail
  /// on insufficient funds, same as a real scheduled run would).
  static Future<void> runRuleNow(AppState s, String ruleId) async {
    final r = find(s, ruleId);
    if (r == null) return;

    try {
      switch (r.actionType) {
        case AutomationActionType.send:
          _runSend(s, r);
        case AutomationActionType.payBill:
          await _runPayBill(s, r);
        case AutomationActionType.save:
          _runSave(s, r);
        case AutomationActionType.convert:
          _runConvert(s, r);
      }
    } on InsufficientFundsException catch (e) {
      _recordFailure(s, r, e.toString());
    }

    r.lastRunAt = DateTime.now();
    if (r.triggerType == TriggerType.schedule && r.scheduleFrequency != null) {
      r.nextRunAt = _nextRun(r.scheduleFrequency!, r.lastRunAt!);
    }
  }

  static void _runSend(AppState s, AutomationRule r) {
    final result = SmartPayEngine.fundOnly(s,
        title: 'Automation · ${r.name}',
        amount: r.amount,
        currency: r.currency);
    if (!result.isSuccess) {
      _recordFailure(s, r, result.message ?? 'Insufficient funds');
      return;
    }
    _recordSuccess(s, r,
        '${r.amount.toStringAsFixed(2)} ${r.currency} sent to ${r.fixedRecipientUsername ?? 'recipient'}');
  }

  static Future<void> _runPayBill(AppState s, AutomationRule r) async {
    final result = await SmartPayEngine.payBill(
      s,
      biller: r.fixedBillerName ?? 'Biller',
      customerId: r.fixedBillerCustomerId ?? '',
      amount: r.amount,
      currency: r.currency,
      fixedSourceCurrency: r.fundingSourceOverride,
    );
    if (!result.isSuccess) {
      _recordFailure(s, r, result.message ?? 'Payment failed');
      return;
    }
    _recordSuccess(s, r,
        '${r.fixedBillerName} — ${r.amount.toStringAsFixed(2)} ${r.currency} paid');
  }

  static void _runSave(AppState s, AutomationRule r) {
    if (r.savingsGoalId == null) {
      _recordFailure(s, r, 'No linked savings goal');
      return;
    }
    final result = SmartPayEngine.fundOnly(s,
        title: 'Automation · ${r.name}',
        amount: r.amount,
        currency: r.currency,
        fixedSourceCurrency: r.fundingSourceOverride);
    if (!result.isSuccess) {
      _recordFailure(s, r, result.message ?? 'Insufficient funds');
      return;
    }
    for (final g in s.localState.savingsGoals) {
      if (g.id == r.savingsGoalId) g.current += r.amount;
    }
    _recordSuccess(s, r, '${r.amount.toStringAsFixed(2)} ${r.currency} saved');
  }

  static void _runConvert(AppState s, AutomationRule r) {
    final to = r.convertToCurrency;
    if (to == null) {
      _recordFailure(s, r, 'No destination currency set');
      return;
    }
    final available = LedgerService.balanceOf(s, r.currency);
    final amount = r.amount > 0 ? r.amount : available;
    if (amount <= 0) {
      _recordFailure(s, r, 'Nothing to convert');
      return;
    }
    try {
      LedgerService.debit(s,
          currency: r.currency,
          amount: amount,
          title: 'Automation · ${r.name}',
          subtitle: 'Auto-convert to $to',
          category: LedgerCategory.automation);
      final converted = s.convert(amount, r.currency, to);
      LedgerService.credit(s,
          currency: to,
          amount: converted,
          title: 'Automation · ${r.name}',
          subtitle: 'Converted from ${r.currency}',
          category: LedgerCategory.automation);
      _recordSuccess(s, r,
          '${amount.toStringAsFixed(2)} ${r.currency} converted to ${converted.toStringAsFixed(2)} $to');
    } on InsufficientFundsException catch (e) {
      _recordFailure(s, r, e.toString());
    }
  }

  static void _recordSuccess(AppState s, AutomationRule r, String message) {
    r.runLog.insert(
        0,
        AutomationRun(
            at: DateTime.now(),
            status: RuleRunStatus.success,
            message: message));
    if (r.status == RuleStatus.pausedFailed) r.status = RuleStatus.active;
    _notify(s, 'Automation: ${r.name}', '$message — successful.');
  }

  static void _recordFailure(AppState s, AutomationRule r, String message) {
    r.runLog.insert(
        0,
        AutomationRun(
            at: DateTime.now(),
            status: RuleRunStatus.failed,
            message: message));
    r.status = RuleStatus.pausedFailed;
    _notify(s, 'Automation failed: ${r.name}',
        '$message — rule paused pending your review.');
  }

  static DateTime _nextRun(ScheduleFrequency freq, DateTime from) {
    switch (freq) {
      case ScheduleFrequency.daily:
        return from.add(const Duration(days: 1));
      case ScheduleFrequency.weekly:
        return from.add(const Duration(days: 7));
      case ScheduleFrequency.monthly:
        return DateTime(from.year, from.month + 1, from.day);
    }
  }

  static void _notify(AppState s, String title, String body) {
    s.localState.notifications.insert(
        0,
        AppNotification(
            id: _uuid.v4(),
            at: DateTime.now(),
            category: NotificationCategory.automation,
            title: title,
            body: body));
  }
}
