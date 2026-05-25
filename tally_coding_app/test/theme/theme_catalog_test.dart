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
  });
}
