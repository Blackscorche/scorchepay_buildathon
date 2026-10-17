/// Names of the `--dart-define` variables the app reads. Read them only
/// through these constants, e.g. `bool.fromEnvironment(AppEnvVars.mockWallets)`,
/// so this file stays the full list of build-time settings.
class AppEnvVars {
  AppEnvVars._();

  /// `true` swaps real Nostr Wallet Connect for a mock wallet service.
  static const mockWallets = 'MOCK_WALLETS';

  /// Passkey relying-party ID (a domain). On web it defaults to the page's
  /// host; elsewhere passkeys stay off without it.
  static const passkeyRpId = 'PASSKEY_RP_ID';
}
