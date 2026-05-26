import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tally_coding_app/theme/theme_catalog.dart';

const String _themePrefsKey = 'tally_theme_slug';

class ThemeController extends ChangeNotifier {
  String _activeSlug = defaultThemeSlug;

  String get activeSlug => _activeSlug;
  ThemeEntry get activeEntry => themeCatalog[_activeSlug]!;

  /// Load the persisted theme preference. Falls back to default if missing
  /// or invalid. Call once at app startup before runApp.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final persisted = prefs.getString(_themePrefsKey);
    if (persisted != null && themeCatalog.containsKey(persisted)) {
      _activeSlug = persisted;
    } else {
      _activeSlug = defaultThemeSlug;
    }
    notifyListeners();
  }

  /// Set the active theme by slug. No-op if slug is unknown.
  Future<void> setTheme(String slug) async {
    if (!themeCatalog.containsKey(slug)) return;
    if (slug == _activeSlug) return;
    _activeSlug = slug;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themePrefsKey, slug);
    notifyListeners();
  }
}
