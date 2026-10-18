import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/app_state.dart';
import 'shared_prefs_keys.dart';

final localStoreProvider = Provider<LocalStore>((ref) => LocalStore());

/// Persists the device-local slice of [AppState] ([LocalAppState]) as JSON.
/// Backend data is never written here. Any failure to read or parse
/// (first run, corrupted data, a schema change) falls back to defaults
/// rather than crashing.
class LocalStore {
  Future<LocalAppState> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(SharedPrefsKeys.appState);
      if (raw == null) return LocalAppState.seed();
      return LocalAppState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return LocalAppState.seed();
    }
  }

  Future<void> save(LocalAppState state) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(SharedPrefsKeys.appState, jsonEncode(state.toJson()));
    } catch (_) {
      // Best-effort — a failed persist shouldn't crash the app; the next
      // successful save will catch state back up.
    }
  }

  Future<void> reset() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(SharedPrefsKeys.appState);
    } catch (_) {}
  }
}
