import 'package:flutter/material.dart';

/// The neutral (surface/border/text) half of a palette — the part that
/// actually differs between light and dark mode. Brand and semantic
/// colors (accent, gain/loss/warn/info, categorical) stay identical
/// across both, so only these fields need a light and a dark variant.
class NeutralPalette {
  const NeutralPalette({
    required this.bg,
    required this.page,
    required this.surface,
    required this.surface2,
    required this.surface3,
    required this.border,
    required this.borderStrong,
    required this.hairline,
    required this.textPrimary,
    required this.textSecondary,
    required this.muted,
  });

  final Color bg;
  final Color page;
  final Color surface;
  final Color surface2;
  final Color surface3;
  final Color border;
  final Color borderStrong;
  final Color hairline;
  final Color textPrimary;
  final Color textSecondary;
  final Color muted;
}

/// Central color system for ScorchePay.
///
/// Design intent: a neutral surface system (like Coinbase / Phantom /
/// Backpack) with the brand ember-red accent used SPARINGLY — primary
/// CTAs, the active tab, and a handful of key highlights only. Gains/
/// losses use their own semantic greens/reds, deliberately a different
/// hue from the brand accent so "brand" and "price is down" never read
/// as the same signal.
///
/// Surfaces/borders/text are theme-aware: [configure] swaps the active
/// [NeutralPalette] at runtime, and every neutral getter below reads
/// from it. Brand/semantic colors are true `const` and never change.
class AppColors {
  AppColors._();

  static const NeutralPalette darkNeutrals = NeutralPalette(
    bg: Color(0xFF000000),
    page: Color(0xFF0A0A0B),
    surface: Color(0xFF111113),
    surface2: Color(0xFF18181B),
    surface3: Color(0xFF212126),
    border: Color(0x12FFFFFF), // ~7% white
    borderStrong: Color(0x21FFFFFF), // ~13% white
    hairline: Color(0x0EFFFFFF), // ~5.5% white
    textPrimary: Color(0xFFF5F5F6),
    textSecondary: Color(0xFF9A9AA3),
    muted: Color(0xFF68686F),
  );

  static const NeutralPalette lightNeutrals = NeutralPalette(
    bg: Color(0xFFFFFFFF),
    page: Color(0xFFF7F7F8),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF0F0F2),
    surface3: Color(0xFFE7E7EA),
    border: Color(0x14000000), // ~8% black
    borderStrong: Color(0x26000000), // ~15% black
    hairline: Color(0x0F000000), // ~6% black
    textPrimary: Color(0xFF0B0B0C),
    textSecondary: Color(0xFF5B5B63),
    muted: Color(0xFF8D8D95),
  );

  static NeutralPalette _neutrals = darkNeutrals;
  static Brightness _brightness = Brightness.dark;

  static Brightness get brightness => _brightness;

  /// Swaps the active neutral palette. Called once per build from the
  /// app root (see [ScorchePayApp]'s `MaterialApp.builder`) BEFORE the
  /// rest of the tree rebuilds, so every AppColors.* neutral getter
  /// below reflects the new theme by the time descendants read it.
  static void configure(Brightness brightness) {
    _brightness = brightness;
    _neutrals = brightness == Brightness.light ? lightNeutrals : darkNeutrals;
  }

  // Surfaces
  static Color get bg => _neutrals.bg;
  static Color get page => _neutrals.page;
  static Color get surface => _neutrals.surface;
  static Color get surface2 => _neutrals.surface2;
  static Color get surface3 => _neutrals.surface3;

  // Borders
  static Color get border => _neutrals.border;
  static Color get borderStrong => _neutrals.borderStrong;
  static Color get hairline => _neutrals.hairline;

  // Text
  static Color get textPrimary => _neutrals.textPrimary;
  static Color get textSecondary => _neutrals.textSecondary;
  static Color get muted => _neutrals.muted;

  // The wealth hero card's signature gradient — still a "hero" treatment
  // with a bit more visual weight than a flat AppCard, but now it flips
  // with the app theme like everything else: a warm near-black gradient
  // in dark mode, a soft warm-white one in light mode.
  static LinearGradient get heroGradient => brightness == Brightness.light
      ? const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFFFFFF), Color(0xFFFBF4F2), Color(0xFFF6ECE9)],
        )
      : const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1A1210), Color(0xFF121012), Color(0xFF101012)],
        );

  // Brand accent — user-configurable (see AccentColorNotifier /
  // AppearanceScreen), defaulting to the ember red. [configureAccent]
  // sets the base hue; every other accent-family getter below derives
  // from it via HSL lightness shifts, so a single user pick re-tints
  // gradients, tints and shades consistently instead of looking like a
  // random grab-bag of unrelated colors.
  static Color _accentBase = const Color(0xFFFF4B1F);

  static void configureAccent(Color base) {
    _accentBase = base;
  }

  static Color _lighten(Color c, double amount) {
    final hsl = HSLColor.fromColor(c);
    return hsl
        .withLightness((hsl.lightness + amount).clamp(0.0, 1.0))
        .toColor();
  }

  static Color _darken(Color c, double amount) => _lighten(c, -amount);

  static Color get accent => _accentBase;
  static Color get accentGradStart => _lighten(_accentBase, 0.04);
  static Color get accentGradEnd => _darken(_accentBase, 0.05);
  static Color get accentSoft => _accentBase.withValues(alpha: 0.13);

  static LinearGradient get accentGradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [accentGradStart, accentGradEnd],
      );

  // Semantic status — identical in light & dark.
  static const Color gain = Color(0xFF2ED573);
  static const Color loss = Color(0xFFFF4D6D);
  static const Color warn = Color(0xFFFFB020);
  static const Color info = Color(0xFF4A9EFF);

  // Categorical data palette (charts / allocation / legends)
  static const Color catBlue = Color(0xFF4A9EFF);
  static const Color catOrange = Color(0xFFFF9F43);
  static const Color catAqua = Color(0xFF20C9A6);
  static const Color catYellow = Color(0xFFFFCD3C);
  static const Color catMagenta = Color(0xFFFF6FA3);
  static const Color catGreen = Color(0xFF2ED573);
  static const Color catViolet = Color(0xFF9C8CFF);

  static const List<Color> categorical = [
    catBlue,
    catOrange,
    catAqua,
    catYellow,
    catMagenta,
    catGreen,
    catViolet,
  ];

  // Single-hue accent ramp — for charts/legends that should read as "on
  // brand" (e.g. portfolio allocation) instead of a multi-hue rainbow.
  // Lightness steps down the family rather than switching hue, so slices
  // stay distinguishable while never competing with the brand accent.
  static Color get accentTint1 => _lighten(_accentBase, 0.22);
  static Color get accentTint2 => _lighten(_accentBase, 0.10);
  static Color get accentShade1 => _darken(_accentBase, 0.14);
  static Color get accentShade2 => _darken(_accentBase, 0.28);

  static List<Color> get accentRamp =>
      [accent, accentTint1, accentShade1, accentTint2, accentShade2];

  static Color statusSoft(Color c) => c.withValues(alpha: 0.13);
}
