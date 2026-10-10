import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_state_notifier.dart';

class UserProfile {
  const UserProfile({
    required this.username,
    required this.displayName,
    required this.email,
    required this.phone,
    required this.bio,
    this.photoPath,
    this.tier = 'Tier 3',
    this.kycStatus = 'Verified',
  });

  final String username;
  final String displayName;
  final String email;
  final String phone;
  final String bio;
  final String? photoPath;
  final String tier;
  final String kycStatus;

  File? get photoFile =>
      photoPath != null && photoPath!.isNotEmpty ? File(photoPath!) : null;

  UserProfile copyWith({
    String? username,
    String? displayName,
    String? email,
    String? phone,
    String? bio,
    String? photoPath,
    bool clearPhoto = false,
    String? tier,
    String? kycStatus,
  }) {
    return UserProfile(
      username: username ?? this.username,
      displayName: displayName ?? this.displayName,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      bio: bio ?? this.bio,
      photoPath: clearPhoto ? null : (photoPath ?? this.photoPath),
      tier: tier ?? this.tier,
      kycStatus: kycStatus ?? this.kycStatus,
    );
  }
}

class UserProfileNotifier extends StateNotifier<UserProfile> {
  UserProfileNotifier(
    this._ref,
    String username,
    String displayName,
  ) : super(UserProfile(
          // Identity comes from the backend user via AppState — see
          // [userProfileProvider].
          username: username,
          displayName: displayName,
          email: 'issaabu399@gmail.com',
          phone: '+234 810 456 2311',
          bio: 'Building on ScorchePay · Money OS',
          photoPath: null,
          tier: 'Tier 3',
          kycStatus: 'Verified',
        )) {
    _loadFromPrefs();
  }
  final Ref _ref;
  static const _keyPhoto = 'user_profile_photo_path';

  static const _keyEmail = 'user_profile_email';
  static const _keyPhone = 'user_profile_phone';
  static const _keyBio = 'user_profile_bio';

  Future<void> _loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final photo = prefs.getString(_keyPhoto);
      final email = prefs.getString(_keyEmail);
      final phone = prefs.getString(_keyPhone);
      final bio = prefs.getString(_keyBio);

      state = state.copyWith(
        photoPath: photo,
        email: email,
        phone: phone,
        bio: bio,
      );
    } catch (_) {}
  }

  Future<void> setPhoto(String? path) async {
    state = state.copyWith(photoPath: path, clearPhoto: path == null);
    try {
      final prefs = await SharedPreferences.getInstance();
      if (path != null && path.isNotEmpty) {
        await prefs.setString(_keyPhoto, path);
      } else {
        await prefs.remove(_keyPhoto);
      }
    } catch (_) {}
  }

  Future<void> updateProfile({
    String? displayName,
    String? username,
    String? email,
    String? phone,
    String? bio,
  }) async {
    final identityChanged =
        (username != null && username != state.username) ||
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
      if (email != null) await prefs.setString(_keyEmail, email);
      if (phone != null) await prefs.setString(_keyPhone, phone);
      if (bio != null) await prefs.setString(_keyBio, bio);
    } catch (_) {}

    // Identity is owned by the backend (via app state). While signed out
    // (e.g. during sign-up, which isn't wired to the backend yet) there's
    // no session to save it to, so it only lives in this profile state.
    // Errors propagate so the caller can show them.
    if (identityChanged && _ref.read(appStateProvider).requireValue.isLoggedIn) {
      await _ref
          .read(appStateProvider.notifier)
          .updateUserDetails(username: username, displayName: displayName);
    }
  }
}

final userProfileProvider =
    StateNotifierProvider<UserProfileNotifier, UserProfile>((ref) {
  final (username, displayName) = ref.watch(appStateProvider.select(
      (s) => (s.requireValue.username, s.requireValue.displayName)));
  return UserProfileNotifier(ref, username, displayName);
});
