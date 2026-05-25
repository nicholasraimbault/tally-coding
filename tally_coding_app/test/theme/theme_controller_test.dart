import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tally_coding_app/theme/theme_catalog.dart';
import 'package:tally_coding_app/theme/theme_controller.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ThemeController', () {
    test('initial state defaults to tokyo-night when no preference', () async {
      final c = ThemeController();
      await c.load();
      expect(c.activeSlug, 'tokyo-night');
      expect(c.activeEntry, themeCatalog['tokyo-night']);
    });

    test('loads persisted preference on init', () async {
      SharedPreferences.setMockInitialValues({'tally_theme_slug': 'dracula'});
      final c = ThemeController();
      await c.load();
      expect(c.activeSlug, 'dracula');
    });

    test('falls back to tokyo-night if persisted slug is invalid', () async {
      SharedPreferences.setMockInitialValues({'tally_theme_slug': 'bogus'});
      final c = ThemeController();
      await c.load();
      expect(c.activeSlug, 'tokyo-night');
    });

    test('setTheme updates active slug and persists', () async {
      final c = ThemeController();
      await c.load();
      await c.setTheme('catppuccin-mocha');
      expect(c.activeSlug, 'catppuccin-mocha');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('tally_theme_slug'), 'catppuccin-mocha');
    });

    test('setTheme to invalid slug is a no-op', () async {
      final c = ThemeController();
      await c.load();
      final initial = c.activeSlug;
      await c.setTheme('bogus');
      expect(c.activeSlug, initial);
    });

    test('setTheme notifies listeners', () async {
      final c = ThemeController();
      await c.load();
      var notified = 0;
      c.addListener(() => notified++);
      await c.setTheme('nord');
      expect(notified, 1);
    });
  });
}
