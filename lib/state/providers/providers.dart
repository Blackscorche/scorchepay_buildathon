import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_state_notifier.dart';

// Derived, narrow-scoped reads so screens only rebuild on what they
// actually watch.
final totalWealthProvider = Provider<double>(
    (ref) => ref.watch(appStateProvider).requireValue.totalWealthNgn());
final ledgerProvider = Provider(
    (ref) => ref.watch(appStateProvider).requireValue.localState.ledger);
final escrowsProvider = Provider(
    (ref) => ref.watch(appStateProvider).requireValue.localState.escrows);
final savingsGoalsProvider = Provider(
    (ref) => ref.watch(appStateProvider).requireValue.localState.savingsGoals);
final automationRulesProvider = Provider((ref) =>
    ref.watch(appStateProvider).requireValue.localState.automationRules);
final notificationsProvider = Provider(
    (ref) => ref.watch(appStateProvider).requireValue.localState.notifications);
final unreadNotificationCountProvider = Provider<int>(
    (ref) => ref.watch(notificationsProvider).where((n) => !n.read).length);
final showOnboardingProvider = Provider<bool>((ref) =>
    ref.watch(appStateProvider).requireValue.localState.showOnboarding);

final hasLoggedInBeforeProvider = Provider<bool>((ref) => ref.watch(
    appStateProvider
        .select((s) => s.requireValue.localState.username.isNotEmpty)));
