/// Every key ScorchePay writes to `SharedPreferences`, in one place so
/// they can't collide and it's easy to see what the app keeps on-device.
/// Secrets don't belong here: they go in secure storage (see
/// `SecureStorageKeys`).
///
/// Bump a key's version suffix when its stored format changes.
class SharedPrefsKeys {
  SharedPrefsKeys._();

  // App
  /// The device-local slice of app state (`LocalStore`). Older blobs that
  /// also held wallet data still parse (extra keys are ignored) and are
  /// trimmed on the next save.
  static const appState = 'scorchepay_app_state_v1';
  static const themeMode = 'app_theme_mode';
  static const accentColor = 'app_accent_color';

  // Profile details not yet held by the backend
  static const profileEmail = 'user_profile_email';
  static const profilePhone = 'user_profile_phone';
  static const profileBio = 'user_profile_bio';

  // Mock backend (stands in for server storage during development)
  static const mockBackendDb = 'mock_backend_db_v1';
  static String mockBackendPhoto(String accountId) =>
      'mock_backend_photo_$accountId';
  static const mockVtuOrders = 'mock_vtu_orders_v2';
}
