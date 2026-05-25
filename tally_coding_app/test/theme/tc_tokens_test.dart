import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';

void main() {
  group('TCTokens', () {
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

    test('all required tokens present', () {
      expect(sample.bg, const Color(0xFF1A1B26));
      expect(sample.fg, const Color(0xFFC0CAF5));
      expect(sample.green, const Color(0xFF9ECE6A));
      expect(sample.red, const Color(0xFFF7768E));
    });

    test('copyWith replaces only specified fields', () {
      final modified = sample.copyWith(bg: const Color(0xFFFFFFFF));
      expect(modified.bg, const Color(0xFFFFFFFF));
      expect(modified.fg, sample.fg);
      expect(modified.green, sample.green);
    });

    test('lerp interpolates colors between two themes', () {
      final other = sample.copyWith(bg: const Color(0xFFFFFFFF));
      final mid = sample.lerp(other, 0.5)!;
      expect(mid.bg.r, closeTo(0.55, 0.05));
    });

    test('lerp returns self when other is null', () {
      final result = sample.lerp(null, 0.5);
      expect(result, sample);
    });

    test('lerp returns self at t=0', () {
      final other = sample.copyWith(bg: const Color(0xFFFFFFFF));
      final result = sample.lerp(other, 0.0)!;
      expect(result.bg, sample.bg);
    });
  });
}
