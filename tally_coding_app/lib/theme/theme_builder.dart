import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';

/// Build a Brutal Terminal ThemeData from the given token set.
///
/// Determines brightness automatically from `tokens.bg` luminance:
/// luminance < 0.5 → dark; >= 0.5 → light.
///
/// Example:
/// ```dart
/// final theme = themeFromTokens(TCPresets.tokyoNight);
/// MaterialApp(theme: theme, home: ...);
/// ```
ThemeData themeFromTokens(TCTokens tokens) {
  final isDark =
      ThemeData.estimateBrightnessForColor(tokens.bg) == Brightness.dark;
  final brightness = isDark ? Brightness.dark : Brightness.light;

  final textTheme = GoogleFonts.jetBrainsMonoTextTheme(
    isDark ? ThemeData.dark().textTheme : ThemeData.light().textTheme,
  ).apply(
    bodyColor: tokens.fg,
    displayColor: tokens.fg,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: tokens.bg,
    canvasColor: tokens.bg,
    colorScheme: ColorScheme(
      brightness: brightness,
      primary: tokens.green,
      onPrimary: tokens.bg,
      secondary: tokens.cyan,
      onSecondary: tokens.bg,
      error: tokens.red,
      onError: tokens.bg,
      surface: tokens.elev,
      onSurface: tokens.fg,
    ),
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    dividerColor: tokens.border,
    dividerTheme: DividerThemeData(color: tokens.border, thickness: 1),
    iconTheme: IconThemeData(color: tokens.fgDim, size: 18),
    extensions: [tokens],
  );
}
