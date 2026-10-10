import 'package:uuid/uuid.dart';

import '../models/app_notification.dart';
import '../models/escrow.dart';
import '../models/ledger_entry.dart';
import '../providers/app_state.dart';
import 'ledger_service.dart';
import 'smart_pay_engine.dart';

const _uuid = Uuid();

/// The full escrow state machine (spec §10, walkthrough §5). Every
/// transition below writes a timeline event on the contract (spec's
/// "full chronological history... with timestamps and actor" is not
/// optional) and, per §20, fires a notification.
///
/// This prototype has exactly one real (local) user, so every contract
/// records which side the local user plays via `currentUserRole`
/// (EscrowService.create) — the counterparty's actions (accept, fund
/// when the local user is seller, submit evidence when the local user
/// is buyer) are triggered explicitly by the UI's "Simulate: {name}
/// does X" affordances (see the flow screens), never automatically.
class EscrowService {
  EscrowService._();

  /// Compressed for demo purposes — 72h in production. Stated on-screen
  /// wherever the countdown is shown.
  static const reviewWindow = Duration(seconds: 90);

  static EscrowContract? find(AppState s, String id) {
    for (final e in s.localState.escrows) {
      if (e.id == id) return e;
    }
    return null;
  }

  static EscrowMilestone? findMilestone(EscrowContract e, String milestoneId) {
    for (final m in e.milestones) {
      if (m.id == milestoneId) return m;
    }
    return null;
  }

  static String create(
    AppState s, {
    required String escrowType,
    required String counterpartyUsername,
    required String counterpartyName,
    required EscrowRole role,
    required String description,
    required String currency,
    required List<EscrowMilestone> milestones,
  }) {
    final contract = EscrowContract(
      id: _uuid.v4(),
      escrowType: escrowType,
      counterpartyUsername: counterpartyUsername,
      counterpartyName: counterpartyName,
      currentUserRole: role,
      description: description,
      currency: currency,
      milestones: milestones,
      createdAt: DateTime.now(),
    );
    contract.log('You',
        'Escrow created — ${role == EscrowRole.buyer ? 'you are the buyer' : 'you are the seller'}');
    s.localState.escrows.insert(0, contract);
    _notify(s, 'Escrow created',
        '"$description" with $counterpartyName is awaiting acceptance.');
    return contract.id;
  }

  /// Simulated counterparty response to a just-created contract —
  /// draft → awaitingFunding, or → cancelled.
  static void counterpartyRespond(AppState s, String escrowId,
      {required bool accept}) {
    final e = find(s, escrowId);
    if (e == null || e.status != EscrowStatus.draft) return;
    if (accept) {
      e.status = EscrowStatus.awaitingFunding;
      e.log(e.counterpartyName, 'Accepted the escrow terms');
      _notify(s, 'Escrow accepted',
          '${e.counterpartyName} accepted "${e.description}" — ready to fund.');
    } else {
      e.status = EscrowStatus.cancelled;
      e.log(e.counterpartyName, 'Rejected the escrow terms');
      _notify(s, 'Escrow rejected',
          '${e.counterpartyName} declined "${e.description}".');
    }
  }

  /// Buyer funds the contract via Smart Pay's funding engine — the full
  /// milestone total moves out of spendable balance in one call. Only
  /// meaningful when the local user is the buyer.
  static SmartPayResult fund(AppState s, String escrowId) {
    final e = find(s, escrowId);
    if (e == null || e.status != EscrowStatus.awaitingFunding) {
      return SmartPayResult.providerFailed(
          const FundingPlan(
              nativeCurrency: '', nativeAmount: 0, legs: [], shortBy: 0),
          'Escrow is not awaiting funding');
    }
    final result = SmartPayEngine.fundOnly(s,
        title: 'Escrow funding — ${e.description}',
        amount: e.totalAmount,
        currency: e.currency);
    if (result.isSuccess) {
      e.status = EscrowStatus.funded;
      for (final m in e.milestones) {
        if (m.status == MilestoneStatus.pending) {
          m.status = MilestoneStatus.inProgress;
        }
      }
      e.log('You',
          'Funded ${e.totalAmount.toStringAsFixed(2)} ${e.currency} — funds now held in escrow');
      _notify(s, 'Escrow funded',
          '"${e.description}" is now active — funds are held until release.');
    }
    return result;
  }

  /// Seller-role contracts have no real buyer balance to debit — the
  /// demo counterparty's funding is simulated directly.
  static void simulateCounterpartyFund(AppState s, String escrowId) {
    final e = find(s, escrowId);
    if (e == null || e.status != EscrowStatus.awaitingFunding) return;
    e.status = EscrowStatus.funded;
    for (final m in e.milestones) {
      if (m.status == MilestoneStatus.pending) {
        m.status = MilestoneStatus.inProgress;
      }
    }
    e.log(e.counterpartyName,
        'Funded ${e.totalAmount.toStringAsFixed(2)} ${e.currency} (simulated) — funds now held in escrow');
    _notify(s, 'Escrow funded',
        '${e.counterpartyName} funded "${e.description}" — you can now deliver and submit evidence.');
  }

  static void submitEvidence(
      AppState s, String escrowId, String milestoneId, String note,
      {bool bySimulatedCounterparty = false}) {
    final e = find(s, escrowId);
    final m = e == null ? null : findMilestone(e, milestoneId);
    if (e == null || m == null) return;
    m.status = MilestoneStatus.evidenceSubmitted;
    m.evidenceNote = note;
    m.evidenceSubmittedAt = DateTime.now();
    m.reviewDeadline = DateTime.now().add(reviewWindow);
    final actor = bySimulatedCounterparty ? e.counterpartyName : 'You';
    e.log(actor, 'Submitted evidence for "${m.description}": "$note"');
    _notify(s, 'Evidence submitted',
        '${m.description} — review before the window closes or it auto-releases.');
  }

  /// Manual release — buyer-initiated, or system-initiated when
  /// [auto] is true (an expired review window with no dispute).
  static void release(AppState s, String escrowId, String milestoneId,
      {bool auto = false}) {
    final e = find(s, escrowId);
    final m = e == null ? null : findMilestone(e, milestoneId);
    if (e == null || m == null) return;
    if (m.status != MilestoneStatus.evidenceSubmitted &&
        m.status != MilestoneStatus.reviewWindow) {
      return;
    }
    m.status = MilestoneStatus.released;
    LedgerService.credit(
      s,
      currency: e.currency,
      amount: 0,
      title: 'Escrow released to ${e.counterpartyName}',
      subtitle: e.description,
      category: LedgerCategory.escrow,
      counterparty: e.counterpartyUsername,
      meta: {'escrowId': e.id, 'milestoneId': m.id, 'amount': m.amount},
    );
    e.log(auto ? 'System (auto-release)' : 'You',
        'Released ${m.amount.toStringAsFixed(2)} ${e.currency} for "${m.description}"${auto ? ' — review window expired with no dispute' : ''}');
    if (e.milestones.every((mm) => mm.status == MilestoneStatus.released)) {
      e.status = EscrowStatus.completed;
    }
    _notify(s, auto ? 'Escrow auto-released' : 'Escrow released',
        '${m.amount.toStringAsFixed(2)} ${e.currency} released to ${e.counterpartyName} for "${m.description}".');
  }

  /// Called periodically (see MainShell's timer) — auto-releases any
  /// milestone whose buyer review window has passed with no dispute.
  static void checkExpiredReviewWindows(AppState s) {
    final now = DateTime.now();
    for (final e in s.localState.escrows) {
      if (e.status != EscrowStatus.funded) continue;
      for (final m in e.milestones) {
        if (m.status == MilestoneStatus.evidenceSubmitted &&
            m.reviewDeadline != null &&
            now.isAfter(m.reviewDeadline!)) {
          release(s, e.id, m.id, auto: true);
        }
      }
    }
  }

  static void raiseDispute(
      AppState s, String escrowId, String milestoneId, String reason,
      {bool bySimulatedCounterparty = false}) {
    final e = find(s, escrowId);
    final m = e == null ? null : findMilestone(e, milestoneId);
    if (e == null || m == null) return;
    m.status = MilestoneStatus.disputed;
    m.disputeReason = reason;
    e.status = EscrowStatus.disputed;
    final actor = bySimulatedCounterparty ? e.counterpartyName : 'You';
    e.log(actor, 'Raised a dispute on "${m.description}": "$reason"');
    _notify(s, 'Escrow disputed',
        '"${m.description}" is now disputed and frozen pending resolution.');
  }

  /// Simulated arbitration — the local user stands in for ScorchePay ops
  /// on the Dispute Resolution screen and picks the outcome directly.
  /// "Split" is a straight 50/50 for this prototype (no partial-fault
  /// weighting model implemented).
  static void resolveDispute(AppState s, String escrowId, String milestoneId,
      DisputeResolution resolution) {
    final e = find(s, escrowId);
    final m = e == null ? null : findMilestone(e, milestoneId);
    if (e == null || m == null) return;
    e.disputeResolution = resolution;

    switch (resolution) {
      case DisputeResolution.releaseToSeller:
        m.status = MilestoneStatus.released;
        LedgerService.credit(
          s,
          currency: e.currency,
          amount: 0,
          title: 'Dispute resolved — released to ${e.counterpartyName}',
          subtitle: m.description,
          category: LedgerCategory.escrow,
          meta: {'escrowId': e.id, 'milestoneId': m.id},
        );
      case DisputeResolution.refundToBuyer:
        m.status = MilestoneStatus.released;
        LedgerService.credit(
          s,
          currency: e.currency,
          amount: m.amount,
          title: 'Dispute resolved — refunded',
          subtitle: m.description,
          category: LedgerCategory.escrow,
          meta: {'escrowId': e.id, 'milestoneId': m.id},
        );
      case DisputeResolution.split:
        m.status = MilestoneStatus.released;
        final half = m.amount / 2;
        LedgerService.credit(
          s,
          currency: e.currency,
          amount: half,
          title: 'Dispute resolved — 50% refunded',
          subtitle: m.description,
          category: LedgerCategory.escrow,
          meta: {'escrowId': e.id, 'milestoneId': m.id},
        );
    }

    e.log('ScorchePay support (simulated arbitration)',
        'Resolved dispute on "${m.description}": ${_resolutionLabel(resolution)}');

    final allDone =
        e.milestones.every((mm) => mm.status == MilestoneStatus.released);
    if (allDone) {
      e.status = resolution == DisputeResolution.refundToBuyer
          ? EscrowStatus.refunded
          : EscrowStatus.completed;
    } else {
      e.status = EscrowStatus.funded;
    }
    _notify(s, 'Dispute resolved',
        '"${m.description}" — ${_resolutionLabel(resolution)}.');
  }

  static String _resolutionLabel(DisputeResolution r) {
    switch (r) {
      case DisputeResolution.releaseToSeller:
        return 'released in full to the seller';
      case DisputeResolution.refundToBuyer:
        return 'refunded in full to the buyer';
      case DisputeResolution.split:
        return 'split 50/50';
    }
  }

  static void _notify(AppState s, String title, String body) {
    s.localState.notifications.insert(
        0,
        AppNotification(
            id: _uuid.v4(),
            at: DateTime.now(),
            category: NotificationCategory.escrow,
            title: title,
            body: body));
  }
}
