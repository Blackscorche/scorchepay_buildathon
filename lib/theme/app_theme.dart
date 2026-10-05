import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'app_colors.dart';

class AppRadius {
  AppRadius._();
  static const double xl = 26;
  static const double lg = 20;
  static const double md = 14;
  static const double sm = 10;
}

class AppSpace {
  AppSpace._();
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
}

class AppTheme {
  AppTheme._();

  static ThemeData get dark =>
      _build(Brightness.dark, AppColors.darkNeutrals, AppColors.accent);
  static ThemeData get light =>
      _build(Brightness.light, AppColors.lightNeutrals, AppColors.accent);

  /// Builds a [ThemeData] from an explicit [NeutralPalette] and accent
  /// [Color] rather than the mutable `AppColors.*` getters —
  /// `theme:`/`darkTheme:` are both constructed up front on every
  /// MaterialApp rebuild, before [AppColors.configure] /
  /// [AppColors.configureAccent] have run for the resolved
  /// brightness/accent, so reading the live getters here would make one
  /// of the two variants briefly wrong (or both identical). Semantic
  /// colors (gain/loss/warn/info) are true consts and safe to use
  /// directly either way.
  static ThemeData _build(
      Brightness brightness, NeutralPalette n, Color accent) {
    final base = ThemeData(brightness: brightness, useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: n.page,
      colorScheme: base.colorScheme.copyWith(
        brightness: brightness,
        primary: accent,
        secondary: accent,
        surface: n.surface,
        error: AppColors.loss,
      ),
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      dividerColor: n.hairline,
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: accent,
        selectionColor: accent.withValues(alpha: 0.13),
        selectionHandleColor: accent,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        iconTheme: IconThemeData(color: n.textPrimary),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: n.surface,
        hintStyle: TextStyle(
            color: n.muted, fontSize: 13.5, fontWeight: FontWeight.w500),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: n.borderStrong),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: n.borderStrong),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: accent, width: 1.4),
        ),
      ),
      textTheme: base.textTheme.apply(
        bodyColor: n.textPrimary,
        displayColor: n.textPrimary,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      }),
    );
  }
}
