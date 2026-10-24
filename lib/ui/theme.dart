import 'package:flutter/material.dart';

const brandBlue = Color(0xFF1F57A4);
const brandNavy = Color(0xFF21223E);
const okGreen = Color(0xFF1E9E5A);
const warnAmber = Color(0xFFE09B12);
const errRed = Color(0xFFD23C3C);

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: brandBlue,
    brightness: b,
    primary: dark ? const Color(0xFF8DB4F0) : brandBlue,
    surface: dark ? const Color(0xFF15161F) : const Color(0xFFF4F6FA),
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? const Color(0xFF1C1D29) : Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 1,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: dark ? const Color(0xFF1F2030) : Colors.white,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: dark ? const Color(0xFF2C2E42) : const Color(0xFFE3E7EF)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF1F2030) : Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      isDense: true,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: dark ? const Color(0xFF1C1D29) : Colors.white,
      indicatorColor: scheme.primary.withValues(alpha: 0.14),
    ),
  );
}
