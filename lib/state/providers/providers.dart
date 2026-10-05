export 'profile_provider.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_store.dart';
import 'app_state.dart';
import 'app_state_notifier.dart';

final localStoreProvider = Provider<LocalStore>((ref) => LocalStore());

final appStateProvider = StateNotifierProvider<AppStateNotifier, AppState>(
  (ref) => AppStateNotifier(ref.read(localStoreProvider)),
);

// Derived, narrow-scoped reads so screens only rebuild on what they
// actually watch.
final totalWealthProvider =
    Provider<double>((ref) => ref.watch(appStateProvider).totalWealthNgn());
final ledgerProvider = Provider((ref) => ref.watch(appStateProvider).ledger);
final escrowsProvider = Provider((ref) => ref.watch(appStateProvider).escrows);
final savingsGoalsProvider =
    Provider((ref) => ref.watch(appStateProvider).savingsGoals);
final automationRulesProvider =
    Provider((ref) => ref.watch(appStateProvider).automationRules);
final notificationsProvider =
    Provider((ref) => ref.watch(appStateProvider).notifications);
final unreadNotificationCountProvider = Provider<int>(
    (ref) => ref.watch(notificationsProvider).where((n) => !n.read).length);
final showOnboardingProvider = Provider<bool>(
  (ref) => ref.watch(appStateProvider).showOnboarding,
);
