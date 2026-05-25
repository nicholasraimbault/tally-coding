import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';
import 'package:tally_coding_app/theme/theme_builder.dart';

void main() {
  const sample = TCTokens(
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
  );

  // Use testWidgets so the widget-test zone absorbs the async font-load errors
  // that google_fonts fires when fonts cannot be fetched in the test environment.
  // All assertions are synchronous — the ThemeData is built immediately.
  group('themeFromTokens', () {
    testWidgets('produces ThemeData with TCTokens extension attached',
        (tester) async {
      final theme = themeFromTokens(sample);
      expect(theme.extension<TCTokens>(), sample);
    });

    testWidgets('scaffoldBackgroundColor matches tokens.bg', (tester) async {
      final theme = themeFromTokens(sample);
      expect(theme.scaffoldBackgroundColor, sample.bg);
    });

    testWidgets('uses dark brightness for dark themes', (tester) async {
      final theme = themeFromTokens(sample);
      // sample.bg luminance < 0.5 → dark
      expect(theme.brightness, Brightness.dark);
    });

    testWidgets('uses light brightness for light themes', (tester) async {
      final lightTokens = sample.copyWith(
        bg: const Color(0xFFFDF6E3),
        fg: const Color(0xFF073642),
      );
      final theme = themeFromTokens(lightTokens);
      expect(theme.brightness, Brightness.light);
    });

    testWidgets('uses JetBrains Mono for text theme', (tester) async {
      final theme = themeFromTokens(sample);
      // GoogleFonts.jetBrainsMono sets fontFamily to 'JetBrainsMono'
      expect(theme.textTheme.bodyMedium?.fontFamily, contains('JetBrainsMono'));
    });
  });
}
