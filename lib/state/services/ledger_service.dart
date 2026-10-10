import 'package:uuid/uuid.dart';

import '../models/ledger_entry.dart';
import '../providers/app_state.dart';

const _uuid = Uuid();

class InsufficientFundsException implements Exception {
  InsufficientFundsException(this.currency, this.shortBy);
  final String currency;
  final double shortBy;

  @override
  String toString() =>
      'Insufficient $currency balance — short by ${shortBy.toStringAsFixed(2)}';
}

/// Atomic ledger primitives. Every method here either fully applies its
/// effect (balance mutation + ledger entry) or throws before touching
/// anything — callers (SmartPayEngine, EscrowService, SavingsService,
/// AutomationService) are responsible for wrapping multi-leg operations
/// in a try/catch that rolls back any legs already applied, per the
/// spec's atomicity requirement (§7 step 6).
class LedgerService {
  LedgerService._();

  static bool isCrypto(AppState s, String currency) =>
      s.localState.cryptoHoldings.containsKey(currency) ||
      s.localState.cryptoPrices.containsKey(currency);

  static double balanceOf(AppState s, String currency) {
    if (isCrypto(s, currency)) return s.localState.cryptoHoldings[currency] ?? 0;
    return s.localState.fiatBalances[currency] ?? 0;
  }

  /// Debits [amount] of [currency] from the spendable balance. Throws
  /// [InsufficientFundsException] rather than allowing a negative
  /// balance — this is what makes every higher-level flow's rollback
  /// path reliable: a failed debit never partially applies.
  static LedgerEntry debit(
    AppState s, {
    required String currency,
    required double amount,
    required String title,
    required String subtitle,
    required LedgerCategory category,
    String? groupId,
    String? counterparty,
    Map<String, dynamic> meta = const {},
  }) {
    final have = balanceOf(s, currency);
    if (have < amount - 1e-9) {
      throw InsufficientFundsException(currency, amount - have);
    }
    if (isCrypto(s, currency)) {
      s.localState.cryptoHoldings[currency] = have - amount;
    } else {
      s.localState.fiatBalances[currency] = have - amount;
    }
    final entry = LedgerEntry(
      id: _uuid.v4(),
      timestamp: DateTime.now(),
      currency: currency,
      amount: -amount,
      title: title,
      subtitle: subtitle,
      category: category,
      groupId: groupId,
      counterparty: counterparty,
      meta: meta,
    );
    s.localState.ledger.insert(0, entry);
    return entry;
  }

  /// Reverses a prior debit — used by rollback paths when a later leg of
  /// a multi-leg operation fails, and by automatic-refund paths when an
  /// external provider call fails after the debit already happened.
  static LedgerEntry refund(AppState s, LedgerEntry originalDebit,
      {String? reasonSuffix}) {
    final currency = originalDebit.currency;
    final amount = -originalDebit.amount; // original was negative
    if (isCrypto(s, currency)) {
      s.localState.cryptoHoldings[currency] = (s.localState.cryptoHoldings[currency] ?? 0) + amount;
    } else {
      s.localState.fiatBalances[currency] = (s.localState.fiatBalances[currency] ?? 0) + amount;
    }
    final entry = LedgerEntry(
      id: _uuid.v4(),
      timestamp: DateTime.now(),
      currency: currency,
      amount: amount,
      title: 'Refund — ${originalDebit.title}',
      subtitle: reasonSuffix ?? 'Automatically refunded',
      category: LedgerCategory.refund,
      groupId: originalDebit.groupId,
      counterparty: originalDebit.counterparty,
      meta: {'refundOf': originalDebit.id},
    );
    s.localState.ledger.insert(0, entry);
    return entry;
  }

  static LedgerEntry credit(
    AppState s, {
    required String currency,
    required double amount,
    required String title,
    required String subtitle,
    required LedgerCategory category,
    String? groupId,
    String? counterparty,
    Map<String, dynamic> meta = const {},
  }) {
    if (isCrypto(s, currency)) {
      s.localState.cryptoHoldings[currency] = (s.localState.cryptoHoldings[currency] ?? 0) + amount;
    } else {
      s.localState.fiatBalances[currency] = (s.localState.fiatBalances[currency] ?? 0) + amount;
    }
    final entry = LedgerEntry(
      id: _uuid.v4(),
      timestamp: DateTime.now(),
      currency: currency,
      amount: amount,
      title: title,
      subtitle: subtitle,
      category: category,
      groupId: groupId,
      counterparty: counterparty,
      meta: meta,
    );
    s.localState.ledger.insert(0, entry);
    return entry;
  }

  /// Instant internal transfer between the local user and a demo
  /// counterparty (spec §8 "by username" / walkthrough §1 and §6). Since
  /// the demo counterparty has no real wallet to credit, this records
  /// the debit + a linked "sent" entry pair on the local ledger only —
  /// the recipient side is represented, not literally credited.
  static void internalTransferOut(
    AppState s, {
    required String currency,
    required double amount,
    required String recipientUsername,
    required String recipientDisplayName,
    String? note,
  }) {
    debit(
      s,
      currency: currency,
      amount: amount,
      title: 'Sent to $recipientDisplayName',
      subtitle: note != null && note.isNotEmpty
          ? note
          : 'Send Money · $recipientUsername',
      category: LedgerCategory.transfer,
      counterparty: recipientUsername,
    );
  }

  /// Simulated inbound receipt — used to seed activity and by demo
  /// "simulate counterparty" actions (e.g. a demo escrow counterparty
  /// funding their side is not modeled since the local user is always
  /// either buyer or seller, but incoming P2P demo credits use this).
  static void internalTransferIn(
    AppState s, {
    required String currency,
    required double amount,
    required String senderUsername,
    required String senderDisplayName,
    String? note,
  }) {
    credit(
      s,
      currency: currency,
      amount: amount,
      title: 'Received from $senderDisplayName',
      subtitle: note != null && note.isNotEmpty
          ? note
          : 'Send Money · $senderUsername',
      category: LedgerCategory.transfer,
      counterparty: senderUsername,
    );
  }
}
