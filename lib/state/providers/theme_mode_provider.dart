import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/shared_prefs_keys.dart';

/// The user's theme preference. [system] follows the OS setting.
enum AppThemeMode {
  system,
  light,
  dark;

  ThemeMode get flutterThemeMode => switch (this) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      };
}

class ThemeModeNotifier extends StateNotifier<AppThemeMode> {
  ThemeModeNotifier() : super(AppThemeMode.dark) {
    _loadFromPrefs();
  }

  Future<void> _loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(SharedPrefsKeys.themeMode);
      for (final mode in AppThemeMode.values) {
        if (mode.name == saved) {
          state = mode;
          break;
        }
      }
    } catch (_) {}
  }

  Future<void> setMode(AppThemeMode mode) async {
    state = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(SharedPrefsKeys.themeMode, mode.name);
    } catch (_) {}
  }
}

final themeModeProvider =
    StateNotifierProvider<ThemeModeNotifier, AppThemeMode>((ref) {
  return ThemeModeNotifier();
});
