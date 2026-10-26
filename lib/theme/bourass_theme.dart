import 'package:flutter/material.dart';

class BourassTheme {
  static const Color background = Color(0xFF090D16);
  static const Color cardBg = Color(0xFF101726);
  static const Color cardBorder = Color(0xFF1B2436);
  static const Color cyanAccent = Color(0xFF00E5FF);
  static const Color greenAccent = Color(0xFF22E58A);
  static const Color amberAccent = Color(0xFFFFB020);
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFF6C7B90);
  static const Color textCyan = Color(0xFF00E5FF);
  static const Color textMuted = Color(0xFF4A5568);

  static ThemeData get themeData {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: background,
      primaryColor: cyanAccent,
      canvasColor: background,
      colorScheme: const ColorScheme.dark(
        primary: cyanAccent,
        secondary: cyanAccent,
        surface: cardBg,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: cyanAccent,
          fontSize: 20,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
        iconTheme: IconThemeData(color: cyanAccent),
      ),
    );
  }
}
