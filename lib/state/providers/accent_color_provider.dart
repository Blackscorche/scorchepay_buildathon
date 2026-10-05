import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A curated set of accent colors for the Appearance picker — kept as a
/// fixed palette (rather than a free-form color wheel) so every combo
/// still reads as "on brand": same weight/saturation family as the
/// default ember, just a different hue.
enum AccentPreset {
  ember('Ember', Color(0xFFFF4B1F)),
  crimson('Crimson', Color(0xFFFF3B5C)),
  amber('Amber', Color(0xFFFFA726)),
  lime('Lime', Color(0xFF9CCC3F)),
  emerald('Emerald', Color(0xFF16C784)),
  teal('Teal', Color(0xFF14B8A6)),
  sky('Sky', Color(0xFF2E9EFF)),
  indigo('Indigo', Color(0xFF6366F1)),
  violet('Violet', Color(0xFFA855F7)),
  magenta('Magenta', Color(0xFFEC4899)),
  mono('Mono', Color(0xFFE4E4E7));

  const AccentPreset(this.label, this.color);
  final String label;
  final Color color;
}

/// Persists the user's chosen accent color (an [AccentPreset.color]
/// value, stored as its raw ARGB int) so [AppColors]'s accent family
/// reflects it on every future launch — mirrors [ThemeModeNotifier]'s
/// persistence pattern.
class AccentColorNotifier extends StateNotifier<Color> {
  AccentColorNotifier() : super(AccentPreset.ember.color) {
    _loadFromPrefs();
  }

  static const _key = 'app_accent_color';

  Future<void> _loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getInt(_key);
      if (saved != null) state = Color(saved);
    } catch (_) {}
  }

  Future<void> setColor(Color color) async {
    state = color;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_key, color.toARGB32());
    } catch (_) {}
  }
}

final accentColorProvider = StateNotifierProvider<AccentColorNotifier, Color>(
    (ref) => AccentColorNotifier());
