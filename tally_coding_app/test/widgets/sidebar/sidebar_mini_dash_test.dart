import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/sidebar/sidebar_mini_dash.dart';
import 'package:tally_coding_app/theme/theme.dart';

Widget _wrap(Widget child) {
  final tokens = themeCatalog[defaultThemeSlug]!.tokens;
  return MaterialApp(
    theme: themeFromTokens(tokens),
    home: Scaffold(body: SizedBox(width: 240, child: child)),
  );
}

void main() {
  group('SidebarMiniDash — ambient', () {
    testWidgets('renders stat row with open and done counts', (tester) async {
      await tester.pumpWidget(_wrap(SidebarMiniDash(
        openCount: 6,
        doneToday: 3,
        tasks: const [
          SidebarMiniTaskData(
            title: 'Fix daily-deals',
            agentRoles: ['architect', 'coder'],
            progressPct: 60,
          ),
        ],
        narratorText: 'Coder is patching — PR in ~5 min.',
        narratorEmphasis: ['Coder is patching'],
        escalations: const [],
        onQuickReply: (_) {},
        onSkipEscalation: () {},
        onOpenChannel: () {},
      )));
      expect(find.text('6'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('renders task row with title', (tester) async {
      await tester.pumpWidget(_wrap(SidebarMiniDash(
        openCount: 1,
        doneToday: 0,
        tasks: const [
          SidebarMiniTaskData(
            title: 'Fix daily-deals',
            agentRoles: ['coder'],
            progressPct: 30,
          ),
        ],
        narratorText: 'All good.',
        narratorEmphasis: const [],
        escalations: const [],
        onQuickReply: (_) {},
        onSkipEscalation: () {},
        onOpenChannel: () {},
      )));
      expect(find.textContaining('Fix daily-deals'), findsOneWidget);
    });

    testWidgets('renders narrator bubble text', (tester) async {
      await tester.pumpWidget(_wrap(SidebarMiniDash(
        openCount: 1,
        doneToday: 0,
        tasks: const [],
        narratorText: 'All good.',
        narratorEmphasis: const [],
        escalations: const [],
        onQuickReply: (_) {},
        onSkipEscalation: () {},
        onOpenChannel: () {},
      )));
      expect(find.text('All good.'), findsOneWidget);
    });

    testWidgets('has top border + no drag handle', (tester) async {
      await tester.pumpWidget(_wrap(SidebarMiniDash(
        openCount: 0,
        doneToday: 0,
        tasks: const [],
        narratorText: 'Idle.',
        narratorEmphasis: const [],
        escalations: const [],
        onQuickReply: (_) {},
        onSkipEscalation: () {},
        onOpenChannel: () {},
      )));
      // Drag handle must NOT be present (no DraggableScrollableSheet, no pill)
      expect(find.byKey(const Key('drag_handle')), findsNothing);
      // At least one Container with top border (the outer ambient container)
      expect(
        find.byWidgetPredicate((w) =>
            w is Container &&
            (w.decoration as BoxDecoration?)?.border?.top.width == 1.0),
        findsAtLeastNWidgets(1),
      );
    });
  });

  group('SidebarMiniDash — escalation takeover', () {
    final escalation = SidebarEscalationData(
      channelName: 'general',
      taskName: 'Fix daily-deals',
      question: 'Round to 2 decimals or keep 4?',
      quickReplies: ['2 decimals', 'Keep 4'],
      emphasizedTerms: ['2 decimals', '4'],
    );

    testWidgets('shows channel context header', (tester) async {
      await tester.pumpWidget(_wrap(SidebarMiniDash(
        openCount: 6,
        doneToday: 3,
        tasks: const [],
        narratorText: '',
        narratorEmphasis: const [],
        escalations: [escalation],
        onQuickReply: (_) {},
        onSkipEscalation: () {},
        onOpenChannel: () {},
      )));
      // Channel name appears in the header (may also appear in Open button)
      expect(find.textContaining('general'), findsAtLeastNWidgets(1));
      expect(find.textContaining('needs you'), findsOneWidget);
    });

    testWidgets('shows question text', (tester) async {
      await tester.pumpWidget(_wrap(SidebarMiniDash(
        openCount: 0,
        doneToday: 0,
        tasks: const [],
        narratorText: '',
        narratorEmphasis: const [],
        escalations: [escalation],
        onQuickReply: (_) {},
        onSkipEscalation: () {},
        onOpenChannel: () {},
      )));
      // Question text may be in RichText (with emphasized terms) or plain Text.
      // Use byWidgetPredicate to find the question in either form.
      expect(
        find.byWidgetPredicate((w) =>
            (w is Text && (w.data?.contains('Round to') ?? false)) ||
            (w is RichText &&
                w.text.toPlainText().contains('Round to'))),
        findsAtLeastNWidgets(1),
      );
    });

    testWidgets('primary quick-reply button fires onQuickReply', (tester) async {
      String? reply;
      await tester.pumpWidget(_wrap(SidebarMiniDash(
        openCount: 0,
        doneToday: 0,
        tasks: const [],
        narratorText: '',
        narratorEmphasis: const [],
        escalations: [escalation],
        onQuickReply: (r) => reply = r,
        onSkipEscalation: () {},
        onOpenChannel: () {},
      )));
      await tester.tap(find.text('2 DECIMALS')); // uppercase via button
      expect(reply, '2 decimals');
    });

    testWidgets('outline quick-reply button fires onQuickReply', (tester) async {
      String? reply;
      await tester.pumpWidget(_wrap(SidebarMiniDash(
        openCount: 0,
        doneToday: 0,
        tasks: const [],
        narratorText: '',
        narratorEmphasis: const [],
        escalations: [escalation],
        onQuickReply: (r) => reply = r,
        onSkipEscalation: () {},
        onOpenChannel: () {},
      )));
      await tester.tap(find.text('KEEP 4')); // uppercase via button
      expect(reply, 'Keep 4');
    });

    testWidgets('Skip button fires onSkipEscalation', (tester) async {
      var skipped = false;
      await tester.pumpWidget(_wrap(SidebarMiniDash(
        openCount: 0,
        doneToday: 0,
        tasks: const [],
        narratorText: '',
        narratorEmphasis: const [],
        escalations: [escalation],
        onQuickReply: (_) {},
        onSkipEscalation: () => skipped = true,
        onOpenChannel: () {},
      )));
      await tester.tap(find.byKey(const Key('sidebar_escalation_skip')));
      expect(skipped, isTrue);
    });

    testWidgets('multi-escalation shows 1/N pill', (tester) async {
      await tester.pumpWidget(_wrap(SidebarMiniDash(
        openCount: 0,
        doneToday: 0,
        tasks: const [],
        narratorText: '',
        narratorEmphasis: const [],
        escalations: [escalation, escalation],
        onQuickReply: (_) {},
        onSkipEscalation: () {},
        onOpenChannel: () {},
      )));
      expect(find.text('1/2'), findsOneWidget);
    });

    testWidgets('has coral wash overlay in escalation state', (tester) async {
      await tester.pumpWidget(_wrap(SidebarMiniDash(
        openCount: 0,
        doneToday: 0,
        tasks: const [],
        narratorText: '',
        narratorEmphasis: const [],
        escalations: [escalation],
        onQuickReply: (_) {},
        onSkipEscalation: () {},
        onOpenChannel: () {},
      )));
      // Coral wash = rgba(247,118,142,0.06) — 0x0F = ~6%
      expect(
        find.byWidgetPredicate((w) =>
            w is Container &&
            w.color?.value == const Color(0x0FF7768E).value),
        findsOneWidget,
      );
    });

    testWidgets('skipping second escalation shows 2/2 pill', (tester) async {
      // Simulate parent rebuilding with activeEscalationIndex = 1
      final widget1 = _wrap(SidebarMiniDash(
        openCount: 0,
        doneToday: 0,
        tasks: const [],
        narratorText: '',
        narratorEmphasis: const [],
        escalations: [escalation, escalation],
        activeEscalationIndex: 0,
        onQuickReply: (_) {},
        onSkipEscalation: () {},
        onOpenChannel: () {},
      ));
      await tester.pumpWidget(widget1);
      expect(find.text('1/2'), findsOneWidget);

      final widget2 = _wrap(SidebarMiniDash(
        openCount: 0,
        doneToday: 0,
        tasks: const [],
        narratorText: '',
        narratorEmphasis: const [],
        escalations: [escalation, escalation],
        activeEscalationIndex: 1,
        onQuickReply: (_) {},
        onSkipEscalation: () {},
        onOpenChannel: () {},
      ));
      await tester.pumpWidget(widget2);
      await tester.pump();
      expect(find.text('2/2'), findsOneWidget);
    });
  });
}
