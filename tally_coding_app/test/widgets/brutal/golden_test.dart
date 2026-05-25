import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:tally_coding_app/widgets/brutal/brutal.dart';
import 'golden_test_helper.dart';

void main() {
  setUpAll(() {
    // Disable HTTP fetching so tests don't try to download JetBrains Mono.
    // Google Fonts falls back to system font glyphs, which keeps goldens
    // deterministic on the CI host.
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  for (final theme in goldenThemes) {
    group('Goldens · $theme', () {
      testWidgets('BrutalCard with text content', (tester) async {
        await tester.pumpWidget(themedScaffold(
          theme,
          const BrutalCard(child: Text('Sample card content', style: TextStyle(fontSize: 14))),
        ));
        await expectLater(
          find.byType(BrutalCard),
          matchesGoldenFile('goldens/brutal_card_$theme.png'),
        );
      });

      testWidgets('BrutalBubble', (tester) async {
        await tester.pumpWidget(themedScaffold(
          theme,
          const BrutalBubble(child: Text('Diagnosed the bug. Coder is patching.')),
        ));
        await expectLater(
          find.byType(BrutalBubble),
          matchesGoldenFile('goldens/brutal_bubble_$theme.png'),
        );
      });

      testWidgets('BrutalProgressBar at 60%', (tester) async {
        await tester.pumpWidget(themedScaffold(
          theme,
          const BrutalProgressBar(value: 0.6),
          size: const Size(200, 20),
        ));
        await expectLater(
          find.byType(BrutalProgressBar),
          matchesGoldenFile('goldens/brutal_progress_$theme.png'),
        );
      });

      testWidgets('BrutalButton.primary', (tester) async {
        await tester.pumpWidget(themedScaffold(
          theme,
          BrutalButton.primary(label: '2 decimals', onPressed: () {}),
          size: const Size(160, 50),
        ));
        await expectLater(
          find.byType(BrutalButton),
          matchesGoldenFile('goldens/brutal_button_primary_$theme.png'),
        );
      });

      testWidgets('BrutalPill', (tester) async {
        await tester.pumpWidget(themedScaffold(
          theme,
          const BrutalPill(label: '1 esc'),
          size: const Size(100, 30),
        ));
        await expectLater(
          find.byType(BrutalPill),
          matchesGoldenFile('goldens/brutal_pill_$theme.png'),
        );
      });

      testWidgets('TallyAvatar', (tester) async {
        await tester.pumpWidget(themedScaffold(
          theme,
          const TallyAvatar(online: false), // disable blink for deterministic capture
          size: const Size(60, 60),
        ));
        await expectLater(
          find.byType(TallyAvatar),
          matchesGoldenFile('goldens/tally_avatar_$theme.png'),
        );
      });

      testWidgets('AgentAvatar.coder', (tester) async {
        await tester.pumpWidget(themedScaffold(
          theme,
          const AgentAvatar(role: AgentRole.coder, active: false),
          size: const Size(50, 50),
        ));
        await expectLater(
          find.byType(AgentAvatar),
          matchesGoldenFile('goldens/agent_avatar_coder_$theme.png'),
        );
      });
    });
  }
}
