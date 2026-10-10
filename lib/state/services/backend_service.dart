import '../providers/app_state.dart';

/// Thrown by [BackendService] for credential or session problems. Its
/// [toString] is the user-facing message.
class AuthException implements Exception {
  const AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Mock backend. Swap the method bodies for real HTTP calls later — the
/// signatures are what the rest of the app depends on.
class BackendService {
  const BackendService();

  /// The only account the mock knows about. The login screen pre-fills
  /// this, and an empty username is treated as this account too.
  static const demoUsername = 'scorche';
  static const demoPin = '1234';

  static const _latency = Duration(milliseconds: 300);
  static const _demoToken = 'mock-token-$demoUsername';

  // The mock's "database": the demo user's identity. Kept in memory, so
  // edits survive logout/login but reset when the app restarts.
  static String _username = 'scorche';
  static String _displayName = 'Scorche';

  /// Exchanges credentials for a session token.
  Future<String> login(String username, String pin) async {
    await Future.delayed(_latency);
    final name = username.trim().toLowerCase();
    if (name.isNotEmpty && name != demoUsername) {
      throw const AuthException(
          'Unknown user. Use "$demoUsername" or leave it blank.');
    }
    if (pin != demoPin) {
      throw const AuthException('Incorrect PIN. The demo PIN is $demoPin.');
    }
    _username = name.isEmpty ? demoUsername : name;
    return _demoToken;
  }

  /// Builds the [AppState] for the user behind [token]: identity (and the
  /// token) from the backend, combined with the device's [localState] data,
  /// which the backend doesn't own yet.
  Future<AppState> getUser(String token, LocalAppState localState) async {
    await Future.delayed(_latency);
    if (token != _demoToken) {
      throw const AuthException('Your session has expired. Please log in.');
    }

    return AppState(
        token: token,
        displayName: _displayName,
        localState: localState.username == _username
            ? localState
            : localState.cloneWith(username: _username));
  }

  /// Updates the identity of the user behind [token]. Null fields are
  /// left unchanged.
  Future<void> updateUserDetails(String token,
      {String? username, String? displayName}) async {
    await Future.delayed(_latency);
    if (token != _demoToken) {
      throw const AuthException('Your session has expired. Please log in.');
    }
    if (username != null) _username = username;
    if (displayName != null) _displayName = displayName;
  }
}
