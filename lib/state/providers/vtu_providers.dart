import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/vtu.dart';
import '../services/backend_service.dart';
import '../services/mock_vtu_api.dart';
import '../services/vtu_api.dart';
import 'app_state_notifier.dart';

/// The VTU backend, acting as the signed-in user. Rebuilt when the
/// session or the mock scenario changes, which in turn refreshes
/// everything fetched through it (catalog, limits, orders).
final vtuApiProvider = Provider<VtuApi>((ref) {
  final api = MockVtuApi(
    backend: ref.watch(backendServiceProvider),
    token: ref.watch(appStateProvider.select((s) => s.valueOrNull?.token)),
    scenario: ref.watch(mockScenarioProvider),
  );
  ref.onDispose(api.dispose);
  return api;
});

/// Debug builds only: how [MockVtuApi] behaves (see the dashboard's debug
/// menu). Change it through [MockScenarioNotifier.select].
final mockScenarioProvider =
    NotifierProvider<MockScenarioNotifier, MockScenario>(
        MockScenarioNotifier.new);

class MockScenarioNotifier extends Notifier<MockScenario> {
  @override
  MockScenario build() => MockScenario.success;

  void select(MockScenario scenario) => state = scenario;
}

/// The country's billers and plans (Nigeria only for now). Kept for the
/// session; `ref.invalidate` it to retry after an error.
final catalogProvider = FutureProvider<Catalog>((ref) async {
  return ref.watch(vtuApiProvider).getCatalog();
});

/// The user's caps at their KYC tier, refreshed when the tier changes.
final vtuLimitsProvider = FutureProvider.autoDispose<VtuLimits>((ref) async {
  ref.watch(appStateProvider.select((s) => s.valueOrNull?.kyc));
  return ref.watch(vtuApiProvider).getLimits();
});

/// The user's latest orders for the dashboard. Invalidate after creating
/// or finishing one.
final recentOrdersProvider =
    FutureProvider.autoDispose<List<VtuOrder>>((ref) async {
  return ref.watch(vtuApiProvider).listOrders(limit: 5);
});

const _pollEvery = Duration(seconds: 2);

/// One order, polled while its status can still change on its own
/// (system design: polling now, server-sent events optional later).
/// Invalidate it to resume polling, e.g. after requesting a refund.
final orderProvider =
    StreamProvider.autoDispose.family<VtuOrder, String>((ref, orderId) {
  final api = ref.watch(vtuApiProvider);
  var disposed = false;
  ref.onDispose(() => disposed = true);
  return _pollOrder(api, orderId, isDisposed: () => disposed);
});

Stream<VtuOrder> _pollOrder(VtuApi api, String orderId,
    {required bool Function() isDisposed}) async* {
  VtuOrder? last;
  while (!isDisposed()) {
    try {
      final order = await api.getOrder(orderId);
      last = order;
      yield order;
      if (!order.inProgress) return;
    } catch (_) {
      // Keep polling through a blip once there's something to show.
      if (last == null) rethrow;
    }
    await Future.delayed(_pollEvery);
  }
}
