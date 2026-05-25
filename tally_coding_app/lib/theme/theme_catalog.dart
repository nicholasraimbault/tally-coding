import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';

@immutable
class ThemeEntry {
  final String name;
  final String desc;
  final String group;
  final TCTokens tokens;
  const ThemeEntry({
    required this.name,
    required this.desc,
    required this.group,
    required this.tokens,
  });
}

const String defaultThemeSlug = 'tokyo-night';

const List<String> themeGroups = [
  'Modern Favorites',
  'Classics',
  'Statement',
  'Light',
];

/// All curated terminal themes that ship with Tally Coding.
/// Sourced from iTerm2-Color-Schemes / standard ANSI palette repos.
/// Populated to the full 28-theme set in Task 5.
const Map<String, ThemeEntry> themeCatalog = {
  'tokyo-night': ThemeEntry(
    name: 'Tokyo Night',
    desc: 'Deep blue-purple · sage · coral',
    group: 'Modern Favorites',
    tokens: TCTokens(
      bg: Color(0xFF1A1B26),
      elev: Color(0xFF24283B),
      sheet: Color(0xFF1F2030),
      border: Color(0xFF2F3349),
      borderStr: Color(0xFF3B3F5C),
      fg: Color(0xFFC0CAF5),
      fgDim: Color(0xFFA9B1D6),
      fgXdim: Color(0xFF7A82AF),
      fgDimmer: Color(0xFF565F89),
      green: Color(0xFF9ECE6A),
      red: Color(0xFFF7768E),
      cyan: Color(0xFF7DCFFF),
      magenta: Color(0xFFBB9AF7),
      yellow: Color(0xFFE0AF68),
      orange: Color(0xFFFF9E64),
      card: Color(0x0AC0CAF5),
      cardHov: Color(0x12C0CAF5),
      bubble: Color(0x0FC0CAF5),
    ),
  ),
};
