import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme_catalog.dart';

void main() {
  group('themeCatalog', () {
    test('contains tokyo-night as the default', () {
      expect(themeCatalog.containsKey('tokyo-night'), isTrue);
      expect(defaultThemeSlug, 'tokyo-night');
    });

    test('tokyo-night has expected token values', () {
      final t = themeCatalog['tokyo-night']!;
      expect(t.tokens.bg.r, closeTo(0.10, 0.02));  // #1a1b26
      expect(t.tokens.fg.r, closeTo(0.75, 0.02));  // #c0caf5
      expect(t.tokens.green.r, closeTo(0.62, 0.02));  // #9ece6a
    });

    test('every theme entry has a name and desc', () {
      for (final entry in themeCatalog.values) {
        expect(entry.name, isNotEmpty);
        expect(entry.desc, isNotEmpty);
      }
    });

    test('theme groups are defined', () {
      expect(themeGroups.length, 4);
      expect(themeGroups, contains('Modern Favorites'));
      expect(themeGroups, contains('Classics'));
      expect(themeGroups, contains('Statement'));
      expect(themeGroups, contains('Light'));
    });

    test('exactly 28 themes ship at launch', () {
      expect(themeCatalog.length, 28);
    });

    test('all themes have valid groups', () {
      for (final entry in themeCatalog.values) {
        expect(themeGroups, contains(entry.group));
      }
    });

    test('group distribution: 9 modern, 11 classics, 4 statement, 4 light', () {
      final counts = <String, int>{};
      for (final entry in themeCatalog.values) {
        counts[entry.group] = (counts[entry.group] ?? 0) + 1;
      }
      expect(counts['Modern Favorites'], 9);
      expect(counts['Classics'], 11);
      expect(counts['Statement'], 4);
      expect(counts['Light'], 4);
    });

    test('every theme has fg/bg contrast suitable for body text (WCAG AA: 4.5:1)', () {
      double luminance(Color c) => c.computeLuminance();
      double contrast(Color a, Color b) {
        final la = luminance(a);
        final lb = luminance(b);
        final l1 = la > lb ? la : lb;
        final l2 = la > lb ? lb : la;
        return (l1 + 0.05) / (l2 + 0.05);
      }

      for (final entry in themeCatalog.entries) {
        final ratio = contrast(entry.value.tokens.fg, entry.value.tokens.bg);
        expect(ratio, greaterThan(4.5),
            reason: '${entry.key} fg/bg contrast=$ratio fails WCAG AA');
      }
    });
  });
}
