/// A Lightning wallet the user connected with Nostr Wallet Connect
/// (NIP-47). Safe to show and to persist as-is: the connection string,
/// which can spend from the wallet, is stored separately in secure
/// storage (see `WalletStore`).
class ConnectedWallet {
  const ConnectedWallet({
    required this.id,
    required this.name,
    required this.walletPubkey,
    required this.connectedAt,
    this.network,
    this.lightningAddress,
  });

  final String id;

  /// The wallet's own name (from `get_info`), or a fallback.
  final String name;

  /// The wallet service's Nostr public key (hex).
  final String walletPubkey;

  /// e.g. `mainnet` or `signet`, when the wallet reports it.
  final String? network;

  /// The wallet's Lightning address (`lud16`), when the connection has one.
  final String? lightningAddress;
  final DateTime connectedAt;

  bool get isMainnet => network == null || network == 'mainnet';

  // Display formatting, shared by every place that shows a wallet, so the
  // same detail always looks the same.

  /// The network to flag in a badge, e.g. "Signet"; null on mainnet, which
  /// needs no flag.
  String? get testNetworkLabel {
    final name = network;
    if (isMainnet || name == null || name.isEmpty) return null;
    return name[0].toUpperCase() + name.substring(1);
  }

  /// The secondary line under the wallet's name: its Lightning address,
  /// which tells similar-named wallets apart. Null when there's none.
  String? get detailLine {
    final address = lightningAddress?.trim();
    return address == null || address.isEmpty ? null : address;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'walletPubkey': walletPubkey,
        'network': network,
        'lightningAddress': lightningAddress,
        'connectedAt': connectedAt.toIso8601String(),
      };

  factory ConnectedWallet.fromJson(Map<String, dynamic> json) =>
      ConnectedWallet(
        id: json['id'] as String,
        name: json['name'] as String,
        walletPubkey: json['walletPubkey'] as String,
        network: json['network'] as String?,
        lightningAddress: json['lightningAddress'] as String?,
        connectedAt: DateTime.tryParse(json['connectedAt'] as String? ?? '') ??
            DateTime.now(),
      );
}
