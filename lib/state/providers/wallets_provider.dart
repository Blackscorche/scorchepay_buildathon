import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/connected_wallet.dart';
import '../services/wallet_service.dart';
import '../services/wallet_store.dart';
import 'app_state_notifier.dart';

/// The signed-in account's connected wallets and which one is current.
class WalletsState {
  const WalletsState({this.wallets = const [], this.currentId});

  final List<ConnectedWallet> wallets;
  final String? currentId;

  bool get isEmpty => wallets.isEmpty;

  /// The wallet shown on the dashboard and used for payments.
  ConnectedWallet? get current =>
      wallets.where((w) => w.id == currentId).firstOrNull ??
      wallets.firstOrNull;
}

final walletsProvider =
    AsyncNotifierProvider<WalletsNotifier, WalletsState>(WalletsNotifier.new);

/// Connects, switches between and removes wallets, persisting through
/// [WalletStore]. Reloads when the signed-in account changes. Connection
/// strings are kept here (and in secure storage), never in [WalletsState].
class WalletsNotifier extends AsyncNotifier<WalletsState> {
  static const _uuid = Uuid();

  WalletStore? _store;
  Map<String, String> _uris = {};

  WalletService get _service => ref.read(walletServiceProvider);

  @override
  Future<WalletsState> build() async {
    final userId = ref
        .watch(appStateProvider.select((s) => s.valueOrNull?.userId));
    _uris = {};
    if (userId == null) {
      _store = null;
      return const WalletsState();
    }
    final store = _store = WalletStore(ref.read(secureStorageProvider), userId);
    final stored = await store.load();
    _uris = Map.of(stored.connectionUris);
    return WalletsState(wallets: stored.wallets, currentId: stored.currentId);
  }

  /// The connection string for [walletId], for [WalletService] calls.
  String? connectionUri(String walletId) => _uris[walletId];

  /// Checks [connectionUri] with the wallet and adds it. The first wallet
  /// becomes the current one. Throws [WalletException].
  Future<ConnectedWallet> connect(String connectionUri) async {
    final current = await future;
    final uri = connectionUri.trim();
    if (_uris.containsValue(uri)) {
      throw const WalletException(WalletErrorCode.invalidConnection,
          'This wallet connection is already added.');
    }
    final info = await _service.inspect(uri);
    final wallet = ConnectedWallet(
      id: _uuid.v4(),
      name: info.name,
      walletPubkey: info.walletPubkey,
      network: info.network,
      lightningAddress: info.lightningAddress,
      connectedAt: DateTime.now(),
    );
    _uris = {..._uris, wallet.id: uri};
    await _save(WalletsState(
      wallets: [...current.wallets, wallet],
      currentId: current.currentId ?? wallet.id,
    ));
    return wallet;
  }

  Future<void> select(String walletId) async {
    final current = await future;
    if (!current.wallets.any((w) => w.id == walletId)) return;
    await _save(WalletsState(wallets: current.wallets, currentId: walletId));
  }

  /// Removes one wallet from ScorchePay. Its connection still exists in the
  /// wallet app until the user revokes it there.
  Future<void> remove(String walletId) async {
    final current = await future;
    final uri = _uris[walletId];
    if (uri != null) await _service.disconnect(uri);
    _uris = Map.of(_uris)..remove(walletId);
    final remaining =
        current.wallets.where((w) => w.id != walletId).toList();
    await _save(WalletsState(
      wallets: remaining,
      currentId: current.currentId == walletId
          ? remaining.firstOrNull?.id
          : current.currentId,
    ));
  }

  Future<void> removeAll() async {
    await future;
    for (final uri in _uris.values) {
      await _service.disconnect(uri);
    }
    _uris = {};
    await _save(const WalletsState());
  }

  Future<void> _save(WalletsState next) async {
    final store = _store;
    if (store == null) throw StateError('Not signed in.');
    await store.save(StoredWallets(
      wallets: next.wallets,
      connectionUris: _uris,
      currentId: next.currentId,
    ));
    state = AsyncData(next);
  }
}

/// A wallet's balance in sats, fetched from the wallet. `ref.invalidate`
/// it to refresh (e.g. after paying).
final walletBalanceProvider =
    FutureProvider.autoDispose.family<int, String>((ref, walletId) async {
  await ref.watch(walletsProvider.future);
  final uri = ref.read(walletsProvider.notifier).connectionUri(walletId);
  if (uri == null) throw StateError('Unknown wallet.');
  return ref.read(walletServiceProvider).getBalanceSats(uri);
});
