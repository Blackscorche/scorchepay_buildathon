import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app_env_vars.dart';
import '../models/kyc.dart';
import '../providers/app_state.dart';

final backendServiceProvider =
    Provider<BackendService>((ref) => BackendService());

/// Thrown by [BackendService] for credential, session or validation
/// problems. Its [toString] is the user-facing message.
class AuthException implements Exception {
  const AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Mock backend. Swap the method bodies for real HTTP calls later — the
/// signatures are what the rest of the app depends on.
///
/// Its "database" (accounts) is saved to shared preferences so accounts
/// created through sign-up survive an app restart, the way a real server's
/// would. OTP challenges are kept in memory only.
class BackendService {
  BackendService();

  /// The demo account the mock always has. The login screen mentions
  /// it, and an empty username is treated as this account too.
  static const demoUsername = 'scorche';
  static const demoPin = '1234';

  /// The mock accepts this code for every sign-up OTP.
  static const demoOtp = '123456';

  /// Passkey relying party ID: the domain that hosts the app association
  /// files (see docs/PASSKEYS.md). Set it per build with
  /// `--dart-define=PASSKEY_RP_ID=example.com`. A real backend owns this
  /// setting and would report it instead.
  ///
  /// On web, browsers require it to be the page's host (or a parent
  /// domain of it), so without the define it falls back to the host,
  /// e.g. `localhost` in development. Elsewhere, no define means passkeys
  /// stay off.
  static String get passkeyRpId {
    const configured = String.fromEnvironment(AppEnvVars.passkeyRpId);
    if (configured.isNotEmpty) return configured;
    return kIsWeb ? Uri.base.host : '';
  }

  static const _latency = Duration(milliseconds: 300);
  static const _dbKey = 'mock_backend_db_v1';
  static const _tokenPrefix = 'mock-token-';

  // Account IDs never change (usernames can), so tokens are built from
  // them.
  static const _demoAccountId = demoUsername;

  final _random = Random();
  final _secureRandom = Random.secure();
  Future<Map<String, _MockAccount>>? _accounts;
  final _challenges = <String, _OtpChallenge>{};
  final _passkeyChallenges = <String, _PasskeyChallenge>{};

  /// Whether passkeys can be used at all (see [passkeyRpId]).
  bool get passkeysConfigured => passkeyRpId.isNotEmpty;

  // ---------------------------------------------------------------------
  // Session
  // ---------------------------------------------------------------------

  /// Exchanges credentials for a session token.
  Future<String> login(String username, String pin) async {
    await Future.delayed(_latency);
    final accounts = await _db();
    final name = _normalizeUsername(username);
    final account = name.isEmpty
        ? accounts[_demoAccountId]
        : accounts.values.where((a) => a.username == name).firstOrNull;
    if (account == null) {
      throw const AuthException(
          'Unknown user. Check your username, or leave it blank for the demo account.');
    }
    if (pin != account.pin) {
      throw AuthException(account.id == _demoAccountId
          ? 'Incorrect PIN. The demo PIN is $demoPin.'
          : 'Incorrect PIN.');
    }
    return '$_tokenPrefix${account.id}';
  }

  /// Builds the [AppState] for the user behind [token]: identity, KYC
  /// tier/status (and the token) from the backend, combined with the
  /// device's [localState] data, which the backend doesn't own yet.
  Future<AppState> getUser(String token, LocalAppState localState) async {
    await Future.delayed(_latency);
    final account = await _accountFor(token);
    return AppState(
        token: token,
        userId: account.id,
        displayName: account.displayName,
        kyc: account.kyc,
        photoUrl: account.photoUrl,
        localState: localState.username == account.username
            ? localState
            : localState.cloneWith(username: account.username));
  }

  /// Updates the identity of the user behind [token]. Null fields are
  /// left unchanged.
  Future<void> updateUserDetails(String token,
      {String? username, String? displayName}) async {
    await Future.delayed(_latency);
    final account = await _accountFor(token);
    if (username != null) {
      final name = _validUsername(username);
      if (name != account.username) await _ensureUsernameFree(name);
      account.username = name;
    }
    if (displayName != null) account.displayName = displayName.trim();
    await _save();
  }

  // ---------------------------------------------------------------------
  // Profile photo
  // ---------------------------------------------------------------------
  //
  // A real backend stores the image (e.g. object storage) and returns a URL
  // the app can GET. The mock keeps it in shared preferences under its own
  // key and hands out `mock-photo://` URLs that only [loadProfilePhoto]
  // understands.

  static const _maxPhotoBytes = 5 * 1024 * 1024;
  static const _photoUrlScheme = 'mock-photo';

  /// Sets the profile photo of the user behind [token], replacing any
  /// earlier one. [photo] is the image file's contents; its type comes
  /// from the bytes themselves (see [_imageContentType]), not from the
  /// client. Returns the photo's new URL.
  Future<String> uploadProfilePhoto(String token, Uint8List photo) async {
    await Future.delayed(_latency);
    final account = await _accountFor(token);
    if (photo.isEmpty || photo.length > _maxPhotoBytes) {
      throw const AuthException('Photos must be smaller than 5 MB.');
    }
    final contentType = _imageContentType(photo);
    if (contentType == null) {
      throw const AuthException('Use a JPEG, PNG, WebP, HEIC or GIF photo.');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_photoKey(account.id), base64Encode(photo));
    // A new URL per upload, so cached copies of the old photo aren't reused.
    final url = '$_photoUrlScheme://${account.id}/${_randomId()}';
    account
      ..photoUrl = url
      // Kept to serve the photo with the right Content-Type; the mock's
      // loadProfilePhoto returns bytes only, so it isn't read back here.
      ..photoContentType = contentType;
    await _save();
    return url;
  }

  /// The image type from the file's signature ("magic") bytes, or null if
  /// it isn't one of the accepted types.
  static String? _imageContentType(Uint8List bytes) {
    bool startsWith(List<int> prefix, [int offset = 0]) {
      if (bytes.length < offset + prefix.length) return false;
      for (var i = 0; i < prefix.length; i++) {
        if (bytes[offset + i] != prefix[i]) return false;
      }
      return true;
    }

    String ascii(int offset, int length) => bytes.length < offset + length
        ? ''
        : String.fromCharCodes(bytes.sublist(offset, offset + length));

    if (startsWith(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
    if (startsWith(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
      return 'image/png';
    }
    final gif = ascii(0, 6);
    if (gif == 'GIF87a' || gif == 'GIF89a') return 'image/gif';
    if (ascii(0, 4) == 'RIFF' && ascii(8, 4) == 'WEBP') return 'image/webp';
    // HEIC/HEIF: an ISO-BMFF "ftyp" box with a HEIF brand.
    const heifBrands = {'heic', 'heix', 'hevc', 'hevx', 'heim', 'heis', 'mif1', 'msf1'};
    if (ascii(4, 4) == 'ftyp' && heifBrands.contains(ascii(8, 4))) {
      return 'image/heic';
    }
    return null;
  }

  /// Removes the profile photo of the user behind [token].
  Future<void> deleteProfilePhoto(String token) async {
    await Future.delayed(_latency);
    final account = await _accountFor(token);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_photoKey(account.id));
    account
      ..photoUrl = null
      ..photoContentType = null;
    await _save();
  }

  /// Downloads the photo at [photoUrl] (from `AppState.photoUrl`). With a
  /// real backend this is a plain HTTP GET.
  Future<Uint8List> loadProfilePhoto(String photoUrl) async {
    await Future.delayed(_latency);
    final uri = Uri.tryParse(photoUrl);
    final accounts = await _db();
    final account = uri?.scheme == _photoUrlScheme ? accounts[uri!.host] : null;
    final prefs = await SharedPreferences.getInstance();
    final encoded = account?.photoUrl == photoUrl
        ? prefs.getString(_photoKey(account!.id))
        : null;
    if (encoded == null) {
      throw const AuthException('Photo not found.');
    }
    return base64Decode(encoded);
  }

  static String _photoKey(String accountId) =>
      'mock_backend_photo_$accountId';

  // ---------------------------------------------------------------------
  // Passkeys: the backend is the WebAuthn relying party
  // ---------------------------------------------------------------------
  //
  // The app passes these JSON strings to the passkeys package and sends
  // back what it returns, so they follow the WebAuthn JSON format.
  //
  // MOCK ONLY: this checks the challenge and the credential ID but does
  // not verify the attestation or the assertion signature (that needs the
  // credential's public key and COSE/CBOR parsing). The real backend must
  // use a WebAuthn library for that, e.g. webauthn-rs in Rust.

  /// Starts adding a passkey to the account behind [token]. Returns
  /// `PublicKeyCredentialCreationOptions` as JSON.
  Future<String> startPasskeyRegistration(String token) async {
    await Future.delayed(_latency);
    _requirePasskeys();
    final account = await _accountFor(token);
    final challenge =
        _newPasskeyChallenge(type: 'webauthn.create', accountId: account.id);
    return jsonEncode({
      'challenge': challenge,
      'rp': {'id': passkeyRpId, 'name': 'ScorchePay'},
      'user': {
        'id': _base64Url(utf8.encode(account.id)),
        'name': account.username,
        'displayName': account.displayName,
      },
      'pubKeyCredParams': [
        {'type': 'public-key', 'alg': -7}, // ES256
        {'type': 'public-key', 'alg': -257}, // RS256
      ],
      'timeout': 60000,
      'authenticatorSelection': {
        'authenticatorAttachment': 'platform',
        'residentKey': 'required',
        'requireResidentKey': true,
        'userVerification': 'required',
      },
      'attestation': 'none',
      'excludeCredentials': [
        for (final id in account.passkeyIds)
          {
            'type': 'public-key',
            'id': id,
            'transports': ['internal', 'hybrid'],
          },
      ],
    });
  }

  /// Finishes adding a passkey: [credentialJson] is the registration
  /// response from the device.
  Future<void> finishPasskeyRegistration(
      String token, String credentialJson) async {
    await Future.delayed(_latency);
    final account = await _accountFor(token);
    final credential = _decodeCredential(credentialJson);
    _consumePasskeyChallenge(credential,
        type: 'webauthn.create', accountId: account.id);
    final accounts = await _db();
    if (accounts.values.any((a) => a.passkeyIds.contains(credential.id))) {
      throw const AuthException('This passkey is already registered.');
    }
    account.passkeyIds.add(credential.id);
    await _save();
  }

  /// Starts a passkey login. Returns `PublicKeyCredentialRequestOptions`
  /// as JSON. No username needed: the device offers its ScorchePay
  /// passkeys (discoverable credentials).
  Future<String> startPasskeyLogin() async {
    await Future.delayed(_latency);
    _requirePasskeys();
    return jsonEncode({
      'challenge': _newPasskeyChallenge(type: 'webauthn.get'),
      'rpId': passkeyRpId,
      'timeout': 60000,
      'userVerification': 'required',
      'allowCredentials': <Object>[],
    });
  }

  /// Finishes a passkey login: [credentialJson] is the assertion from the
  /// device. Returns a session token.
  Future<String> finishPasskeyLogin(String credentialJson) async {
    await Future.delayed(_latency);
    final credential = _decodeCredential(credentialJson);
    _consumePasskeyChallenge(credential, type: 'webauthn.get');
    final accounts = await _db();
    final account = accounts.values
        .where((a) => a.passkeyIds.contains(credential.id))
        .firstOrNull;
    if (account == null) {
      throw const AuthException(
          "This passkey isn't linked to a ScorchePay account. Log in with your PIN.");
    }
    final userHandle = credential.userHandle;
    if (userHandle != null &&
        userHandle.isNotEmpty &&
        userHandle != _base64Url(utf8.encode(account.id))) {
      throw const AuthException("This passkey couldn't be verified.");
    }
    return '$_tokenPrefix${account.id}';
  }

  void _requirePasskeys() {
    if (!passkeysConfigured) {
      throw const AuthException("Passkeys aren't set up for this app yet.");
    }
  }

  String _newPasskeyChallenge({required String type, String? accountId}) {
    final now = DateTime.now();
    _passkeyChallenges.removeWhere((_, c) => c.expiresAt.isBefore(now));
    final challenge =
        _base64Url(List.generate(32, (_) => _secureRandom.nextInt(256)));
    _passkeyChallenges[challenge] = _PasskeyChallenge(
        type: type,
        accountId: accountId,
        expiresAt: now.add(const Duration(minutes: 2)));
    return challenge;
  }

  /// Checks the client data against a challenge this backend issued, and
  /// uses the challenge up.
  void _consumePasskeyChallenge(_PasskeyCredential credential,
      {required String type, String? accountId}) {
    const expired =
        AuthException('This passkey request has expired. Please try again.');
    if (credential.clientType != type) throw expired;
    final issued = _passkeyChallenges.remove(credential.challenge);
    if (issued == null ||
        issued.type != type ||
        issued.accountId != accountId ||
        issued.expiresAt.isBefore(DateTime.now())) {
      throw expired;
    }
  }

  static _PasskeyCredential _decodeCredential(String credentialJson) {
    try {
      final json = jsonDecode(credentialJson) as Map<String, dynamic>;
      final response = json['response'] as Map<String, dynamic>;
      final clientData = jsonDecode(utf8.decode(base64Url.decode(
              base64Url.normalize(response['clientDataJSON'] as String))))
          as Map<String, dynamic>;
      return _PasskeyCredential(
        id: json['id'] as String,
        clientType: clientData['type'] as String?,
        challenge: clientData['challenge'] as String?,
        userHandle: response['userHandle'] as String?,
      );
    } catch (_) {
      throw const AuthException("This passkey response couldn't be read.");
    }
  }

  /// Base64url without padding, as WebAuthn uses.
  static String _base64Url(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  // ---------------------------------------------------------------------
  // Sign-up: verify the contact first, create the account last
  // ---------------------------------------------------------------------

  /// Sends a sign-up OTP to [contact] (a phone number or email) and
  /// returns the ID of that challenge. Rejects invalid or already
  /// registered contacts. Calling it again for the same contact replaces
  /// the earlier code (resend).
  Future<String> requestSignUpCode(String contact) async {
    await Future.delayed(_latency);
    final normalized = _normalizeContact(contact);
    if (normalized == null) {
      throw const AuthException('Enter a valid phone number or email.');
    }
    final accounts = await _db();
    if (accounts.values.any((a) => a.contact == normalized)) {
      throw const AuthException(
          'An account already uses this phone number or email. Log in instead.');
    }
    _challenges.removeWhere((_, c) => c.contact == normalized);
    final id = _randomId();
    _challenges[id] = _OtpChallenge(
        contact: normalized,
        expiresAt: DateTime.now().add(const Duration(minutes: 10)));
    return id;
  }

  /// Checks [code] against the challenge [verificationId]. Returns a
  /// sign-up token proving the contact is verified, for [signUp].
  Future<String> verifySignUpCode(String verificationId, String code) async {
    await Future.delayed(_latency);
    final challenge = _challenges[verificationId];
    if (challenge == null || challenge.expiresAt.isBefore(DateTime.now())) {
      throw const AuthException('This code has expired. Request a new one.');
    }
    if (challenge.attempts >= 5) {
      throw const AuthException('Too many attempts. Request a new code.');
    }
    if (code != demoOtp) {
      challenge.attempts++;
      throw const AuthException('Incorrect code. The demo code is $demoOtp.');
    }
    challenge.signUpToken ??= _randomId();
    return challenge.signUpToken!;
  }

  /// Checks that [username] is valid and free, so the profile step can
  /// report it there instead of at the end of sign-up.
  Future<void> checkUsernameAvailable(String username) async {
    await Future.delayed(_latency);
    await _ensureUsernameFree(_validUsername(username));
  }

  /// Creates the account and returns a session token for it. Every new
  /// account starts at KYC tier 0, unverified.
  Future<String> signUp({
    required String signUpToken,
    required String displayName,
    required String username,
    required String pin,
  }) async {
    await Future.delayed(_latency);
    final entry = _challenges.entries
        .where((e) => e.value.signUpToken == signUpToken)
        .firstOrNull;
    if (entry == null) {
      throw const AuthException(
          'Your verification has expired. Please start sign-up again.');
    }
    if (!RegExp(r'^\d{4}$').hasMatch(pin)) {
      throw const AuthException('Use a four-digit PIN.');
    }
    final name = displayName.trim();
    if (name.isEmpty || name.length > 80) {
      throw const AuthException('Enter your name.');
    }
    final uname = _validUsername(username);
    await _ensureUsernameFree(uname);

    final accounts = await _db();
    if (accounts.values.any((a) => a.contact == entry.value.contact)) {
      throw const AuthException(
          'An account already uses this phone number or email. Log in instead.');
    }
    final account = _MockAccount(
      id: _randomId(),
      username: uname,
      displayName: name,
      pin: pin,
      contact: entry.value.contact,
      kyc: const KycInfo.initial(),
    );
    accounts[account.id] = account;
    _challenges.remove(entry.key);
    await _save();
    return '$_tokenPrefix${account.id}';
  }

  // ---------------------------------------------------------------------
  // Mock internals
  // ---------------------------------------------------------------------

  Future<Map<String, _MockAccount>> _db() => _accounts ??= _load();

  Future<Map<String, _MockAccount>> _load() async {
    final accounts = <String, _MockAccount>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_dbKey);
      if (raw != null) {
        for (final json in (jsonDecode(raw) as List)) {
          final a = _MockAccount.fromJson(Map<String, dynamic>.from(json));
          accounts[a.id] = a;
        }
      }
    } catch (_) {
      // Corrupt or unreadable: start over with just the demo account.
    }
    accounts.putIfAbsent(
        _demoAccountId,
        () => _MockAccount(
              id: _demoAccountId,
              username: demoUsername,
              displayName: 'Scorche',
              pin: demoPin,
              kyc: const KycInfo.initial(),
            ));
    return accounts;
  }

  Future<void> _save() async {
    try {
      final accounts = await _db();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _dbKey, jsonEncode(accounts.values.map((a) => a.toJson()).toList()));
    } catch (_) {
      // Best-effort: the in-memory copy still serves this run.
    }
  }

  Future<_MockAccount> _accountFor(String token) async {
    final accounts = await _db();
    final account = token.startsWith(_tokenPrefix)
        ? accounts[token.substring(_tokenPrefix.length)]
        : null;
    if (account == null) {
      throw const AuthException('Your session has expired. Please log in.');
    }
    return account;
  }

  Future<void> _ensureUsernameFree(String username) async {
    final accounts = await _db();
    if (accounts.values.any((a) => a.username == username)) {
      throw const AuthException('That username is taken.');
    }
  }

  static String _normalizeUsername(String username) {
    final name = username.trim().toLowerCase();
    return name.startsWith('@') ? name.substring(1) : name;
  }

  static String _validUsername(String username) {
    final name = _normalizeUsername(username);
    if (!RegExp(r'^[a-z0-9_.]{3,20}$').hasMatch(name)) {
      throw const AuthException(
          'Usernames are 3–20 characters: letters, numbers, "_" or ".".');
    }
    return name;
  }

  /// Lowercased email, or a phone number without spaces, dashes or
  /// brackets. Null if it's neither.
  static String? _normalizeContact(String contact) {
    final value = contact.trim();
    if (value.contains('@')) {
      final email = value.toLowerCase();
      return RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)
          ? email
          : null;
    }
    final phone = value.replaceAll(RegExp(r'[\s\-()]'), '');
    return RegExp(r'^\+?\d{10,15}$').hasMatch(phone) ? phone : null;
  }

  String _randomId() =>
      List.generate(16, (_) => _random.nextInt(16).toRadixString(16)).join();
}

class _PasskeyChallenge {
  _PasskeyChallenge(
      {required this.type, required this.accountId, required this.expiresAt});

  /// `webauthn.create` or `webauthn.get`.
  final String type;

  /// The account adding a passkey; null for logins.
  final String? accountId;
  final DateTime expiresAt;
}

class _PasskeyCredential {
  const _PasskeyCredential({
    required this.id,
    required this.clientType,
    required this.challenge,
    required this.userHandle,
  });

  final String id;
  final String? clientType;
  final String? challenge;
  final String? userHandle;
}

class _OtpChallenge {
  _OtpChallenge({required this.contact, required this.expiresAt});

  final String contact;
  final DateTime expiresAt;
  int attempts = 0;

  /// Set once the code is verified.
  String? signUpToken;
}

class _MockAccount {
  _MockAccount({
    required this.id,
    required this.username,
    required this.displayName,
    required this.pin,
    required this.kyc,
    this.contact,
    this.photoUrl,
    this.photoContentType,
    Set<String>? passkeyIds,
  }) : passkeyIds = passkeyIds ?? {};

  final String id;
  String username;
  String displayName;
  final String pin;
  final String? contact;
  KycInfo kyc;
  String? photoUrl;
  String? photoContentType;

  /// Credential IDs (base64url) of this account's passkeys.
  final Set<String> passkeyIds;

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'displayName': displayName,
        'pin': pin,
        'contact': contact,
        'kyc': kyc.toJson(),
        'photoUrl': photoUrl,
        'photoContentType': photoContentType,
        'passkeyIds': passkeyIds.toList(),
      };

  factory _MockAccount.fromJson(Map<String, dynamic> json) => _MockAccount(
        id: json['id'] as String,
        username: json['username'] as String,
        displayName: json['displayName'] as String,
        pin: json['pin'] as String,
        contact: json['contact'] as String?,
        photoUrl: json['photoUrl'] as String?,
        photoContentType: json['photoContentType'] as String?,
        kyc: json['kyc'] is Map
            ? KycInfo.fromJson(Map<String, dynamic>.from(json['kyc'] as Map))
            : const KycInfo.initial(),
        passkeyIds: {
          for (final id in (json['passkeyIds'] as List? ?? const []))
            id as String
        },
      );
}
