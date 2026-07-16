import 'package:flutter/material.dart';

/// NavAlert visual identity — deep purple night-commute theme
/// per the Chapter 3 GUI design (Figures 14–33).
class NavAlertColors {
  static const Color background = Color(0xFF241539);
  static const Color surface = Color(0xFF33224E);
  static const Color card = Color(0xFF3D2A5C);
  static const Color primary = Color(0xFF8E7CC3);
  static const Color primaryButton = Color(0xFF7C6BC4);
  static const Color accent = Color(0xFFB39DDB);
  static const Color textPrimary = Color(0xFFF4F0FA);
  static const Color textSecondary = Color(0xFFBFB3D9);
  static const Color danger = Color(0xFFE53935);
  static const Color warning = Color(0xFFFFA726);
  static const Color success = Color(0xFF66BB6A);
}

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
