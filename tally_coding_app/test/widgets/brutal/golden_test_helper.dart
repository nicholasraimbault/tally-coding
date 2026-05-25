import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/theme.dart';

/// Wrap a widget in a sized scaffold using the named theme's tokens.
Widget themedScaffold(String themeSlug, Widget widget, {Size size = const Size(300, 100)}) {
  final tokens = themeCatalog[themeSlug]!.tokens;
  return MediaQuery(
    data: MediaQueryData(size: size, devicePixelRatio: 1.0),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: themeFromTokens(tokens),
      home: Scaffold(
        body: Center(child: SizedBox(width: size.width, child: widget)),
      ),
    ),
  );
}

/// Subset of themes used for golden tests. Tokyo Night (default dark) and
/// Solarized Light (representative light) catch the dark/light split.
const goldenThemes = ['tokyo-night', 'solarized-light'];
