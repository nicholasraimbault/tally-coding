// ignore_for_file: avoid_print
import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:tally_coding_app/theme/theme_builder.dart';
import 'package:tally_coding_app/theme/theme_catalog.dart';
import 'package:tally_coding_app/widgets/brutal/brutal_card.dart';

/// Wraps a widget in the Tokyo Night Brutal Terminal theme so previews match
/// the design system without running the full app.
Widget _wrap(Widget child) {
  final tokens = themeCatalog['tokyo-night']!.tokens;
  return MaterialApp(
    theme: themeFromTokens(tokens),
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: tokens.bg,
      body: Center(child: Padding(padding: const EdgeInsets.all(24), child: child)),
    ),
  );
}

// ─── BrutalCard previews ────────────────────────────────────────────────────

@Preview(name: 'Default (no tap)', group: 'BrutalCard')
Widget brutalCardDefault() => _wrap(
      const BrutalCard(
        child: Text('No tap handler — static card'),
      ),
    );

@Preview(name: 'With onTap', group: 'BrutalCard')
Widget brutalCardTappable() => _wrap(
      BrutalCard(
        onTap: () => print('tapped'),
        child: const Text('Tappable card — press me'),
      ),
    );

@Preview(name: 'Text content', group: 'BrutalCard')
Widget brutalCardTextContent() => _wrap(
      const BrutalCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'DAILY-DEALS v2',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            ),
            SizedBox(height: 4),
            Text('Fix product grid layout on mobile', style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );

@Preview(name: 'Mixed content (text + icon)', group: 'BrutalCard')
Widget brutalCardMixedContent() => _wrap(
      const BrutalCard(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.terminal, size: 18),
            SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('skytale-sdk', style: TextStyle(fontWeight: FontWeight.w700)),
                Text('3 agents · 72% done', style: TextStyle(fontSize: 11)),
              ],
            ),
          ],
        ),
      ),
    );

// ─── Theme matrix: BrutalCard across 4 themes ────────────────────────────────

Widget _themeMatrix() {
  const themes = [
    'tokyo-night',
    'dracula',
    'solarized-light',
    'gruvbox-dark',
  ];
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final slug in themes)
        if (themeCatalog.containsKey(slug))
          Builder(builder: (context) {
            final tokens = themeCatalog[slug]!.tokens;
            final theme = themeFromTokens(tokens);
            return Theme(
              data: theme,
              child: Container(
                width: 140,
                color: tokens.bg,
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      themeCatalog[slug]!.name,
                      style: TextStyle(
                        color: tokens.fgXdim,
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.6,
                      ),
                    ),
                    const SizedBox(height: 6),
                    BrutalCard(
                      child: Text(
                        'Sample card',
                        style: TextStyle(color: tokens.fg, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
    ],
  );
}

@Preview(name: 'Theme matrix (4 themes)', group: 'BrutalCard')
Widget brutalCardThemeMatrix() => MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF111111),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: _themeMatrix(),
          ),
        ),
      ),
    );
