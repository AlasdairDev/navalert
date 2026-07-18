import 'package:flutter/material.dart';

// ═══════════════════════════════════════════════════════════════════════
//  UI/UX POLISH LEGEND  —  used in comments across lib/views/*
// ═══════════════════════════════════════════════════════════════════════
//  [EDIT] Free to restyle NOW — colors, copy/text, spacing, icons, fonts,
//         radii, sizes. Purely cosmetic; changing it can't break a feature.
//  [WANT] Suggested polish / redesign candidate — presentational, safe to
//         rework, but think about the flow (e.g. reorder, animate, re-lay-out).
//  [NEED] Functional wiring — DO NOT remove/rename. onPressed handlers,
//         controller/state, Navigator routes, view-model calls, and the
//         paper-mandated element itself (Figure #). You may restyle how it
//         LOOKS, but the behavior/route/handler must stay.
//
//  Rule of thumb:  onPressed / onTap / controller / context.read/watch /
//  Navigator / setState  == [NEED].   Everything visual == [EDIT].
//
//  This whole file is the central style surface — almost all polish happens
//  here. Change these and every screen updates at once.
// ═══════════════════════════════════════════════════════════════════════

/// NavAlert visual identity — deep purple night-commute theme
/// per the Chapter 3 GUI design (Figures 14–33).
///
/// [EDIT] Every color below is free to change. These 11 tokens drive the
/// entire app's look; restyle here first before touching individual screens.
/// (`danger`/`warning`/`success` carry meaning — keep them red/orange/green
/// so alarms and SOS stay legible, but the exact shades are yours.)
class NavAlertColors {
  static const Color background = Color(0xFF241539);    // [EDIT] app background
  static const Color surface = Color(0xFF33224E);       // [EDIT] inputs, nav bar
  static const Color card = Color(0xFF3D2A5C);          // [EDIT] cards, sheets
  static const Color primary = Color(0xFF8E7CC3);       // [EDIT] brand purple
  static const Color primaryButton = Color(0xFF7C6BC4); // [EDIT] filled buttons
  static const Color accent = Color(0xFFB39DDB);        // [EDIT] highlights, icons
  static const Color textPrimary = Color(0xFFF4F0FA);   // [EDIT] main text
  static const Color textSecondary = Color(0xFFBFB3D9); // [EDIT] muted text
  static const Color danger = Color(0xFFE53935);        // [EDIT] SOS/Stage-3 (keep red)
  static const Color warning = Color(0xFFFFA726);       // [EDIT] alerts (keep orange)
  static const Color success = Color(0xFF66BB6A);       // [EDIT] arrived (keep green)
}

/// [EDIT] Global component styling. Everything here is cosmetic — button
/// shapes, corner radii, paddings, fonts. Tweak once, applies everywhere.
/// To swap the font, add `fontFamily:` here (and the font to pubspec assets).
ThemeData buildNavAlertTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: NavAlertColors.background,
    colorScheme: base.colorScheme.copyWith(
      primary: NavAlertColors.primary,
      secondary: NavAlertColors.accent,
      surface: NavAlertColors.surface,
      error: NavAlertColors.danger,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: NavAlertColors.background,
      foregroundColor: NavAlertColors.textPrimary,
      elevation: 0,
      centerTitle: true,
    ),
    cardTheme: const CardThemeData(
      color: NavAlertColors.card,
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: NavAlertColors.primaryButton,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: NavAlertColors.textPrimary,
        side: const BorderSide(color: NavAlertColors.primary),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: NavAlertColors.surface,
      hintStyle: const TextStyle(color: NavAlertColors.textSecondary),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: BorderSide.none,
      ),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: NavAlertColors.surface,
      selectedItemColor: NavAlertColors.accent,
      unselectedItemColor: NavAlertColors.textSecondary,
      type: BottomNavigationBarType.fixed,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: NavAlertColors.card,
      contentTextStyle: TextStyle(color: NavAlertColors.textPrimary),
      behavior: SnackBarBehavior.floating,
    ),
    dialogTheme: const DialogThemeData(backgroundColor: NavAlertColors.surface),
  );
}
