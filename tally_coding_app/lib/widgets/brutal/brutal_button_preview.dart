// ignore_for_file: avoid_print
import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:tally_coding_app/theme/theme_builder.dart';
import 'package:tally_coding_app/theme/theme_catalog.dart';
import 'package:tally_coding_app/widgets/brutal/brutal_button.dart';

Widget _wrap(Widget child) {
  final tokens = themeCatalog['tokyo-night']!.tokens;
  return MaterialApp(
    theme: themeFromTokens(tokens),
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: tokens.bg,
      body: Center(
        child: SizedBox(
          width: 220,
          child: Padding(padding: const EdgeInsets.all(24), child: child),
        ),
      ),
    ),
  );
}

// ─── BrutalButton previews ──────────────────────────────────────────────────

@Preview(name: 'Primary — enabled', group: 'BrutalButton')
Widget brutalButtonPrimaryEnabled() => _wrap(
      BrutalButton.primary(
        label: 'Deploy',
        onPressed: () => print('deploy'),
      ),
    );

@Preview(name: 'Primary — disabled', group: 'BrutalButton')
Widget brutalButtonPrimaryDisabled() => _wrap(
      const BrutalButton.primary(
        label: 'Deploy',
        onPressed: null,
      ),
    );

@Preview(name: 'Outline — enabled', group: 'BrutalButton')
Widget brutalButtonOutlineEnabled() => _wrap(
      BrutalButton.outline(
        label: 'Cancel',
        onPressed: () => print('cancel'),
      ),
    );

@Preview(name: 'Outline — disabled', group: 'BrutalButton')
Widget brutalButtonOutlineDisabled() => _wrap(
      const BrutalButton.outline(
        label: 'Cancel',
        onPressed: null,
      ),
    );

@Preview(name: 'Primary + Outline side by side', group: 'BrutalButton')
Widget brutalButtonPair() => _wrap(
      Row(
        children: [
          Expanded(
            child: BrutalButton.primary(
              label: 'Yes',
              onPressed: () => print('yes'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: BrutalButton.outline(
              label: 'Skip',
              onPressed: () => print('skip'),
            ),
          ),
        ],
      ),
    );
