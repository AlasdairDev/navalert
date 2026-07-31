import 'package:flutter/material.dart';

// ═══════════════════════════════════════════════════════════════════════
//  UI/UX POLISH LEGEND  —  READ THIS FIRST (used across lib/views/*)
// ═══════════════════════════════════════════════════════════════════════
//  For the UI team: every screen has a "UI/UX MAP" header comment listing
//  what's safe to restyle. Inside the code you'll also see inline markers:
//
//  // TODO (UI Team): ...   → apply your styling HERE (padding, typography,
//                            colors, layout). This is your green light.
//  // DO NOT MODIFY LOGIC:  → this line is wired to the backend (a
//                            view-model call, a stream, the routing isolate,
//                            the MediaSession, a Navigator route, setState).
//                            You may restyle the WIDGET around it, but do not
//                            change, remove, or reorder the marked call, or a
//                            feature breaks. When unsure, keep the call and
//                            only change how it LOOKS.
//  // USE THEME: ...        → pull from NavAlertColors / the ThemeData below
//                            instead of hardcoding a Color or TextStyle, so
//                            one change restyles the whole app.
//
//  The older tags mean the same thing and still apply:
//  [EDIT] cosmetic, restyle freely.  [WANT] polish/redesign candidate.
//  [NEED] functional wiring — restyle the look, keep the behaviour.
//
//  Rule of thumb:  onPressed / onTap / controller / context.read|watch /
//  Navigator / setState / .listen  == DO NOT MODIFY LOGIC / [NEED].
//  Everything visual == [EDIT] / TODO (UI Team).
//
//  This whole file is the central style surface — almost all polish happens
//  here. Change these tokens and every screen updates at once.
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
    // [EDIT] Screen titles ("Settings", "Trip History", "Favorites", "All
    // Recordings") are drawn large and LEFT-aligned to match the Chapter 3
    // GUI figures, where each page leads with a big flush-left heading rather
    // than a centred bar title. Colours stay on the existing tokens.
    appBarTheme: const AppBarTheme(
      backgroundColor: NavAlertColors.background,
      foregroundColor: NavAlertColors.textPrimary,
      elevation: 0,
      centerTitle: false,
      titleSpacing: 20,
      titleTextStyle: TextStyle(
        color: NavAlertColors.textPrimary,
        fontSize: 24,
        fontWeight: FontWeight.w800,
      ),
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
