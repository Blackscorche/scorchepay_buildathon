import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/connected_wallet.dart';
import 'secure_storage_keys.dart';

/// What [WalletStore] persists for one account.
class StoredWallets {
  const StoredWallets({
    this.wallets = const [],
    this.connectionUris = const {},
    this.currentId,
  });

  final List<ConnectedWallet> wallets;

  /// Wallet ID -> its `nostr+walletconnect://` string. Spends from the
  /// wallet, so it only ever lives in secure storage and memory.
  final Map<String, String> connectionUris;
  final String? currentId;
}

/// Keeps one account's connected wallets in secure storage on this device
/// (agreed: device-only, so the backend never holds spending credentials).
/// Keyed by account, so another user signing in here sees none of them.
class WalletStore {
  WalletStore(this._storage, String userId)
      : _key = SecureStorageKeys.connectedWallets(userId);

  final FlutterSecureStorage _storage;
  final String _key;

  Future<StoredWallets> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return const StoredWallets();
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final wallets = <ConnectedWallet>[];
      final uris = <String, String>{};
      for (final entry in (json['wallets'] as List)) {
        final map = Map<String, dynamic>.from(entry as Map);
        final wallet = ConnectedWallet.fromJson(map);
        wallets.add(wallet);
        uris[wallet.id] = map['connectionUri'] as String;
      }
      return StoredWallets(
        wallets: wallets,
        connectionUris: uris,
        currentId: json['currentId'] as String?,
      );
    } catch (_) {
      // Unreadable (e.g. from a future format): start empty rather than
      // crash; the user can connect again.
      return const StoredWallets();
    }
  }

  Future<void> save(StoredWallets stored) async {
    if (stored.wallets.isEmpty) {
      await _storage.delete(key: _key);
      return;
    }
    await _storage.write(
      key: _key,
      value: jsonEncode({
        'currentId': stored.currentId,
        'wallets': [
          for (final wallet in stored.wallets)
            {
              ...wallet.toJson(),
              'connectionUri': stored.connectionUris[wallet.id],
            },
        ],
      }),
    );
  }
}
