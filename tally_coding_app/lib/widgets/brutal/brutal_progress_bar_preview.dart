import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:tally_coding_app/theme/theme_builder.dart';
import 'package:tally_coding_app/theme/theme_catalog.dart';
import 'package:tally_coding_app/widgets/brutal/brutal_progress_bar.dart';

Widget _wrap(Widget child) {
  final tokens = themeCatalog['tokyo-night']!.tokens;
  return MaterialApp(
    theme: themeFromTokens(tokens),
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: tokens.bg,
      body: Center(
        child: SizedBox(
          width: 240,
          child: Padding(padding: const EdgeInsets.all(24), child: child),
        ),
      ),
    ),
  );
}

// ─── BrutalProgressBar previews ─────────────────────────────────────────────

@Preview(name: '0% — empty', group: 'BrutalProgressBar')
Widget brutalProgressBarZero() => _wrap(const BrutalProgressBar(value: 0));

@Preview(name: '30%', group: 'BrutalProgressBar')
Widget brutalProgressBar30() => _wrap(const BrutalProgressBar(value: 0.30));

@Preview(name: '50% — halfway', group: 'BrutalProgressBar')
Widget brutalProgressBar50() => _wrap(const BrutalProgressBar(value: 0.50));

@Preview(name: '75%', group: 'BrutalProgressBar')
Widget brutalProgressBar75() => _wrap(const BrutalProgressBar(value: 0.75));

@Preview(name: '100% — complete', group: 'BrutalProgressBar')
Widget brutalProgressBarFull() => _wrap(const BrutalProgressBar(value: 1.0));

@Preview(name: 'All steps stacked', group: 'BrutalProgressBar')
Widget brutalProgressBarAll() {
  final tokens = themeCatalog['tokyo-night']!.tokens;
  return MaterialApp(
    theme: themeFromTokens(tokens),
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: tokens.bg,
      body: Center(
        child: SizedBox(
          width: 240,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final pct in [0.0, 0.30, 0.50, 0.75, 1.0]) ...[
                  Row(
                    children: [
                      SizedBox(
                        width: 36,
                        child: Text(
                          '${(pct * 100).round()}%',
                          style: TextStyle(
                            color: tokens.fgXdim,
                            fontSize: 10,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: BrutalProgressBar(value: pct)),
                    ],
                  ),
                  const SizedBox(height: 10),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
