import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ndk/ndk.dart'
    show
        MemCacheManager,
        Ndk,
        NdkConfig,
        NostrWalletConnectUri,
        Nwc,
        NwcConnection;
import 'package:ndk_flutter/ndk_flutter.dart' show NdkEventVerifier;

import '../../app_env_vars.dart';
import 'mock_lightning.dart';

/// Picks the wallet implementation. `--dart-define=MOCK_WALLETS=true` uses
/// [MockWalletService], which needs no real wallet or relay.
final walletServiceProvider = Provider<WalletService>((ref) {
  const useMock = bool.fromEnvironment(AppEnvVars.mockWallets);
  final service = useMock ? MockWalletService() : NwcWalletService();
  ref.onDispose(service.dispose);
  return service;
});

/// Why a wallet call failed. Lets the UI react to specific cases (e.g. a
/// spending budget) beyond showing [WalletException.message].
enum WalletErrorCode {
  invalidConnection,
  unreachable,
  notAllowed,
  insufficientBalance,
  quotaExceeded,
  paymentFailed,
  rateLimited,
  timeout,
  other,
}

/// Thrown by [WalletService]. Its [toString] is the user-facing message.
class WalletException implements Exception {
  const WalletException(this.code, this.message);

  final WalletErrorCode code;
  final String message;

  @override
  String toString() => message;
}

/// What a wallet reports about itself when connecting.
class WalletInfo {
  const WalletInfo({
    required this.name,
    required this.walletPubkey,
    this.network,
    this.lightningAddress,
  });

  final String name;
  final String walletPubkey;
  final String? network;
  final String? lightningAddress;
}

/// Talks to a user's Lightning wallet through a Nostr Wallet Connect
/// (NIP-47) connection string (`nostr+walletconnect://…`). Every call takes
/// the connection string; storing it is the caller's job.
abstract class WalletService {
  /// Checks that [connectionUri] is valid, the wallet answers, and the
  /// connection allows reading the balance and paying invoices.
  Future<WalletInfo> inspect(String connectionUri);

  Future<int> getBalanceSats(String connectionUri);

  /// Pays a BOLT11 [invoice] and returns the payment preimage. Gives up
  /// after [timeout]; wallets that ask the user to approve payments only
  /// answer once they do.
  Future<String> payInvoice(String connectionUri, String invoice,
      {Duration timeout = const Duration(minutes: 2)});

  /// Closes any open connection for [connectionUri]. Doesn't revoke it in
  /// the wallet; only the wallet app can do that.
  Future<void> disconnect(String connectionUri);

  void dispose() {}
}

/// Validates the connection string's shape (scheme, pubkey, secret,
/// relay) without contacting the wallet.
NostrWalletConnectUri parseConnectionUri(String connectionUri) {
  try {
    return NostrWalletConnectUri.parseConnectionUri(connectionUri.trim());
  } catch (_) {
    throw _invalidConnection;
  }
}

/// Whether [connectionUri] is a well-formed connection string, for callers
/// that only need a yes/no rather than the parsed parts.
bool isValidConnectionUri(String connectionUri) {
  try {
    NostrWalletConnectUri.parseConnectionUri(connectionUri.trim());
    return true;
  } catch (_) {
    return false;
  }
}

const _invalidConnection = WalletException(
    WalletErrorCode.invalidConnection,
    "That isn't a wallet connection string. It starts with "
    '"nostr+walletconnect://".');

const _requiredMethods = {'get_balance', 'pay_invoice'};

/// The real implementation, on `ndk`'s NWC client. Requests are encrypted
/// with NIP-04, which NWC wallets accept.
class NwcWalletService extends WalletService {
  NwcWalletService();

  // No bootstrap relays: each connection string names its own relays.
  // NdkEventVerifier (ndk_flutter's recommended verifier) checks the
  // wallet's signed events with Web Crypto on web and with ndk's Rust
  // verifier, off the UI thread, on native platforms.
  //
  // ndk 0.10.1's NWC client doesn't fall back to `defaultQueryTimeout`
  // (connect uses 20s + 5s per relay, other requests 5s). Connecting keeps
  // ndk's default; get_balance gets this longer one, passed explicitly,
  // since wallets running on a phone can be slow to answer.
  late final NdkConfig _config = NdkConfig(
    eventVerifier: NdkEventVerifier(),
    cache: MemCacheManager(),
    bootstrapRelays: const [],
    defaultQueryTimeout: const Duration(seconds: 20),
  );
  late final Ndk _ndk = Ndk(_config);
  final _connections = <String, Future<NwcConnection>>{};

  /// ndk marks its `nwc` getter `@experimental` ("needs more docs & tests").
  /// We accept that here, the one place it's read: everything else goes
  /// through [WalletService], so an API change in a future ndk release only
  /// touches this class.
  // ignore: experimental_member_use
  Nwc get _nwc => _ndk.nwc;

  @override
  Future<WalletInfo> inspect(String connectionUri) async {
    final uri = connectionUri.trim();
    final parsed = parseConnectionUri(uri);
    final connection = await _connection(uri);
    if (connection.permissions.isEmpty) {
      await disconnect(uri);
      throw const WalletException(WalletErrorCode.unreachable,
          "Couldn't reach this wallet. Check that it's online and try again.");
    }
    final missing = _requiredMethods.difference(connection.permissions);
    if (missing.isNotEmpty) {
      await disconnect(uri);
      throw const WalletException(
          WalletErrorCode.notAllowed,
          'This connection must allow reading the balance and paying '
          'invoices. Create a new connection in your wallet with both.');
    }
    final info = connection.info;
    final alias = info?.alias.trim() ?? '';

    return WalletInfo(
      name: alias.isNotEmpty
          ? alias
          : (parsed.lud16?.isNotEmpty ?? false)
              ? parsed.lud16!
              : 'Lightning wallet',
      walletPubkey: parsed.walletPubkey,
      network: info?.network.plaintext,
      lightningAddress: parsed.lud16,
    );
  }

  @override
  Future<int> getBalanceSats(String connectionUri) async {
    final connection = await _connection(connectionUri.trim());
    try {
      final response = await _nwc.getBalance(connection,
          timeout: _config.defaultQueryTimeout);
      return response.balanceSats;
    } catch (error) {
      throw _mapError(error);
    }
  }

  @override
  Future<String> payInvoice(String connectionUri, String invoice,
      {Duration timeout = const Duration(minutes: 2)}) async {
    final connection = await _connection(connectionUri.trim());
    try {
      final response =
          await _nwc.payInvoice(connection, invoice: invoice, timeout: timeout);
      final preimage = response.preimage;
      if (preimage == null || preimage.isEmpty) {
        throw const WalletException(WalletErrorCode.paymentFailed,
            "The wallet didn't confirm the payment.");
      }
      return preimage;
    } catch (error) {
      throw _mapError(error);
    }
  }

  @override
  Future<void> disconnect(String connectionUri) async {
    final pending = _connections.remove(connectionUri.trim());
    if (pending == null) return;
    try {
      await _nwc.disconnect(await pending);
    } catch (_) {
      // Already gone or never connected: nothing to close.
    }
  }

  @override
  void dispose() {
    unawaited(_ndk.destroy());
  }

  /// One connection per connection string, opened on first use. A failed
  /// attempt isn't cached, so the next call retries.
  Future<NwcConnection> _connection(String uri) {
    if (!isValidConnectionUri(uri)) {
      return Future.error(_invalidConnection);
    }
    return _connections[uri] ??= _nwc
        .connect(uri, doGetInfoMethod: true)
        .catchError((Object error) {
      _connections.remove(uri);
      throw _mapError(error);
    });
  }

  /// ndk reports wallet errors as exceptions whose text contains the
  /// NIP-47 error code (`… code: QUOTA_EXCEEDED …`), and timeouts as text.
  static WalletException _mapError(Object error) {
    if (error is WalletException) return error;
    final text = error.toString();
    final code = RegExp(r'code: ([A-Z_]+)').firstMatch(text)?.group(1);
    switch (code) {
      case 'QUOTA_EXCEEDED':
        return const WalletException(
            WalletErrorCode.quotaExceeded,
            'This is over the budget you set for ScorchePay in your wallet. '
            'Raise it there, or pay another way.');
      case 'INSUFFICIENT_BALANCE':
        return const WalletException(WalletErrorCode.insufficientBalance,
            "Your wallet doesn't have enough funds for this.");
      case 'PAYMENT_FAILED':
        return const WalletException(WalletErrorCode.paymentFailed,
            "Your wallet couldn't complete the payment. Try again.");
      case 'RATE_LIMITED':
        return const WalletException(WalletErrorCode.rateLimited,
            'Your wallet is busy. Try again in a few seconds.');
      case 'RESTRICTED':
      case 'UNAUTHORIZED':
        return const WalletException(
            WalletErrorCode.notAllowed,
            "Your wallet didn't allow this. The connection may have been "
            'revoked; connect the wallet again.');
    }
    if (text.contains('not in permissions')) {
      return const WalletException(WalletErrorCode.notAllowed,
          "This wallet connection doesn't allow that.");
    }
    if (text.toLowerCase().contains('timed out') ||
        text.toLowerCase().contains('timeout')) {
      return const WalletException(WalletErrorCode.timeout,
          "Your wallet didn't respond. Check that it's online and try again.");
    }
    return const WalletException(
        WalletErrorCode.other, 'Something went wrong talking to your wallet.');
  }
}

/// For development without a real wallet. Accepts any well-formed
/// connection string. Balances start from a made-up amount per string and
/// go down as it pays; payments settle through [MockLightning], so the mock
/// VTU backend sees them. Invoices containing "fail" or "budget" fail with
/// the matching error.
class MockWalletService extends WalletService {
  static const _latency = Duration(milliseconds: 600);

  @override
  Future<WalletInfo> inspect(String connectionUri) async {
    await Future.delayed(_latency);
    final parsed = parseConnectionUri(connectionUri);
    return WalletInfo(
      name:
          parsed.lud16 ?? 'Demo wallet ${parsed.walletPubkey.substring(0, 4)}',
      walletPubkey: parsed.walletPubkey,
      network: 'signet',
      lightningAddress: parsed.lud16,
    );
  }

  /// Sats spent per connection this run, so balances go down after paying.
  final _spent = <String, int>{};

  /// Starting balances, picked per connection string: some wallets are too
  /// low for bigger bills, so switching wallets is worth trying.
  static const _startingBalances = [1500, 9000, 48000, 260000];

  @override
  Future<int> getBalanceSats(String connectionUri) async {
    await Future.delayed(_latency);
    return _balance(connectionUri.trim());
  }

  int _balance(String uri) {
    final seed = uri.codeUnits.fold<int>(0, (a, b) => a + b);
    final start = _startingBalances[seed % _startingBalances.length];
    return start - (_spent[uri] ?? 0);
  }

  @override
  Future<String> payInvoice(String connectionUri, String invoice,
      {Duration timeout = const Duration(minutes: 2)}) async {
    await Future.delayed(_latency * 2);
    final uri = connectionUri.trim();
    if (invoice.contains('budget')) {
      throw const WalletException(WalletErrorCode.quotaExceeded,
          'This is over the budget you set for ScorchePay in your wallet.');
    }
    if (invoice.contains('fail')) {
      throw const WalletException(WalletErrorCode.paymentFailed,
          "Your wallet couldn't complete the payment. Try again.");
    }
    final sats = MockLightning.invoiceSats(invoice) ?? 0;
    if (sats > _balance(uri)) {
      throw const WalletException(WalletErrorCode.insufficientBalance,
          "Your wallet doesn't have enough funds for this.");
    }
    try {
      MockLightning.pay(invoice);
    } on StateError {
      throw const WalletException(WalletErrorCode.paymentFailed,
          'This invoice has expired. Get a new quote and try again.');
    }
    _spent[uri] = (_spent[uri] ?? 0) + sats;
    return 'mock-preimage-${DateTime.now().millisecondsSinceEpoch}';
  }

  @override
  Future<void> disconnect(String connectionUri) async {}
}
