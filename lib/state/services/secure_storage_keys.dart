/// Every key ScorchePay writes to `FlutterSecureStorage`, in one place so
/// they can't collide and it's easy to see what the app keeps on-device.
///
/// Bump a key's version suffix when its stored format changes.
class SecureStorageKeys {
  SecureStorageKeys._();

  /// The signed-in session token.
  static const authToken = 'auth_token';

  /// One account's connected wallets, including their NWC connection
  /// strings (spending credentials, so they never leave the device).
  static String connectedWallets(String userId) =>
      'connected_wallets_v1_$userId';
}
