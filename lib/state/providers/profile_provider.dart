import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/kyc.dart';
import '../services/backend_service.dart';
import 'app_state_notifier.dart';
import '../services/shared_prefs_keys.dart';

class UserProfile {
  const UserProfile({
    required this.username,
    required this.displayName,
    required this.email,
    required this.phone,
    required this.bio,
    required this.kyc,
    this.photoUrl,
  });

  final String username;
  final String displayName;
  final String email;
  final String phone;
  final String bio;

  /// Backend-derived (from app state), so not editable via [copyWith]:
  /// change the photo with `AppStateNotifier.setProfilePhoto`, and show it
  /// with [profilePhotoProvider].
  final String? photoUrl;
  final KycInfo kyc;

  UserProfile copyWith({
    String? username,
    String? displayName,
    String? email,
    String? phone,
    String? bio,
  }) {
    return UserProfile(
      username: username ?? this.username,
      displayName: displayName ?? this.displayName,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      bio: bio ?? this.bio,
      photoUrl: photoUrl,
      kyc: kyc,
    );
  }
}

class UserProfileNotifier extends StateNotifier<UserProfile> {
  UserProfileNotifier(
    this._ref,
    String username,
    String displayName,
    KycInfo kyc,
    String? photoUrl,
  ) : super(UserProfile(
          // Identity, KYC and photo come from the backend user via
          // AppState — see
          // [userProfileProvider].
          username: username,
          displayName: displayName,
          kyc: kyc,
          photoUrl: photoUrl,
          email: 'issaabu399@gmail.com',
          phone: '+234 810 456 2311',
          bio: 'Building on ScorchePay · Money OS',
        )) {
    _loadFromPrefs();
  }
  final Ref _ref;

  Future<void> _loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final email = prefs.getString(SharedPrefsKeys.profileEmail);
      final phone = prefs.getString(SharedPrefsKeys.profilePhone);
      final bio = prefs.getString(SharedPrefsKeys.profileBio);

      state = state.copyWith(
        email: email,
        phone: phone,
        bio: bio,
      );
    } catch (_) {}
  }

  Future<void> updateProfile({
    String? displayName,
    String? username,
    String? email,
    String? phone,
    String? bio,
  }) async {
    final identityChanged = (username != null && username != state.username) ||
        (displayName != null && displayName != state.displayName);
    state = state.copyWith(
      displayName: displayName,
      username: username,
      email: email,
      phone: phone,
      bio: bio,
    );

    // Device-only fields: best-effort, independent of the backend call.
    try {
      final prefs = await SharedPreferences.getInstance();
      if (email != null) await prefs.setString(SharedPrefsKeys.profileEmail, email);
      if (phone != null) await prefs.setString(SharedPrefsKeys.profilePhone, phone);
      if (bio != null) await prefs.setString(SharedPrefsKeys.profileBio, bio);
    } catch (_) {}

    // Identity is owned by the backend (via app state). While signed out
    // there's no session to save it to, so it only lives in this profile
    // state (sign-up sends identity with the account instead). Errors
    // propagate so the caller can show them.
    if (identityChanged &&
        _ref.read(appStateProvider).requireValue.isLoggedIn) {
      await _ref
          .read(appStateProvider.notifier)
          .updateUserDetails(username: username, displayName: displayName);
    }
  }
}

final userProfileProvider =
    StateNotifierProvider<UserProfileNotifier, UserProfile>((ref) {
  final (username, displayName, kyc, photoUrl) =
      ref.watch(appStateProvider.select((s) => (
            s.requireValue.localState.username,
            s.requireValue.displayName,
            s.requireValue.kyc,
            s.requireValue.photoUrl,
          )));
  return UserProfileNotifier(ref, username, displayName, kyc, photoUrl);
});

/// The signed-in user's profile photo, downloaded from the backend; null
/// if they have none. Reloads when the photo URL changes.
final profilePhotoProvider = FutureProvider<Uint8List?>((ref) async {
  final url = ref.watch(
      appStateProvider.select((s) => s.valueOrNull?.photoUrl));
  if (url == null) return null;
  return ref.read(backendServiceProvider).loadProfilePhoto(url);
});
