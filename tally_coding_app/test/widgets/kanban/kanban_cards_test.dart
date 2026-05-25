import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/brutal/brutal.dart';
import 'package:tally_coding_app/widgets/kanban/kanban_cards.dart';

Widget _wrap(Widget child) {
  final tokens = themeCatalog[defaultThemeSlug]!.tokens;
  return MaterialApp(
    theme: themeFromTokens(tokens),
    home: Scaffold(body: child),
  );
}

void main() {
  group('TodoCard', () {
    testWidgets('renders title', (tester) async {
      await tester.pumpWidget(_wrap(
        const TodoCard(title: 'Sync inventory across Shopify locations'),
      ));
      expect(find.text('Sync inventory across Shopify locations'), findsOneWidget);
    });

    testWidgets('shows QUEUED label when queued=true', (tester) async {
      await tester.pumpWidget(_wrap(const TodoCard(title: 't', queued: true)));
      expect(find.text('QUEUED'), findsOneWidget);
    });

    testWidgets('hides QUEUED label when queued=false', (tester) async {
      await tester.pumpWidget(_wrap(const TodoCard(title: 't')));
      expect(find.text('QUEUED'), findsNothing);
    });

    testWidgets('invokes onTap when tapped', (tester) async {
      int taps = 0;
      await tester.pumpWidget(_wrap(
        TodoCard(title: 't', onTap: () => taps++),
      ));
      await tester.tap(find.byType(TodoCard));
      expect(taps, 1);
    });
  });

  group('NewTaskRow', () {
    testWidgets('renders + glyph + "New task" label', (tester) async {
      await tester.pumpWidget(_wrap(NewTaskRow(onTap: () {})));
      expect(find.text('+ New task'), findsOneWidget);
    });

    testWidgets('invokes onTap when tapped', (tester) async {
      int taps = 0;
      await tester.pumpWidget(_wrap(NewTaskRow(onTap: () => taps++)));
      await tester.tap(find.byType(NewTaskRow));
      expect(taps, 1);
    });
  });

  group('PlanningCard', () {
    testWidgets('renders title', (tester) async {
      await tester.pumpWidget(_wrap(
        const PlanningCard(title: 'Wire up Stripe webhooks'),
      ));
      expect(find.text('Wire up Stripe webhooks'), findsOneWidget);
    });

    testWidgets('renders architect avatar', (tester) async {
      await tester.pumpWidget(_wrap(const PlanningCard(title: 't')));
      // Architect monogram is "A"
      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('renders PLANNING label', (tester) async {
      await tester.pumpWidget(_wrap(const PlanningCard(title: 't')));
      expect(find.text('PLANNING'), findsOneWidget);
    });

    testWidgets('invokes onTap when tapped', (tester) async {
      int taps = 0;
      await tester.pumpWidget(_wrap(
        PlanningCard(title: 't', onTap: () => taps++),
      ));
      await tester.tap(find.byType(PlanningCard));
      expect(taps, 1);
    });
  });

  group('RunningTaskCard', () {
    testWidgets('renders title', (tester) async {
      await tester.pumpWidget(_wrap(
        const RunningTaskCard(
          title: 'Build email digest worker',
          agents: [AgentRole.coder],
          progress: 0.3,
        ),
      ));
      expect(find.text('Build email digest worker'), findsOneWidget);
    });

    testWidgets('renders agent avatars (coder + tester)', (tester) async {
      await tester.pumpWidget(_wrap(
        const RunningTaskCard(
          title: 't',
          agents: [AgentRole.coder, AgentRole.tester],
          progress: 0.5,
        ),
      ));
      expect(find.text('C'), findsOneWidget); // coder monogram
      expect(find.text('T'), findsOneWidget); // tester monogram
    });

    testWidgets('renders progress bar', (tester) async {
      await tester.pumpWidget(_wrap(
        const RunningTaskCard(
          title: 't',
          agents: [AgentRole.coder],
          progress: 0.6,
        ),
      ));
      expect(find.byType(BrutalProgressBar), findsOneWidget);
      final bar = tester.widget<BrutalProgressBar>(find.byType(BrutalProgressBar));
      expect(bar.value, 0.6);
    });

    testWidgets('renders eta text if provided', (tester) async {
      await tester.pumpWidget(_wrap(
        const RunningTaskCard(
          title: 't',
          agents: [AgentRole.coder],
          progress: 0.5,
          eta: '~5m',
        ),
      ));
      expect(find.text('~5m'), findsOneWidget);
    });

    testWidgets('invokes onTap when tapped', (tester) async {
      int taps = 0;
      await tester.pumpWidget(_wrap(
        RunningTaskCard(
          title: 't',
          agents: const [AgentRole.coder],
          progress: 0.5,
          onTap: () => taps++,
        ),
      ));
      await tester.tap(find.byType(RunningTaskCard));
      expect(taps, 1);
    });
  });

  group('AwaitingCard', () {
    testWidgets('renders title', (tester) async {
      await tester.pumpWidget(_wrap(
        const AwaitingCard(
          title: 'Wire up Stripe webhooks',
          action: 'Review PR',
        ),
      ));
      expect(find.text('Wire up Stripe webhooks'), findsOneWidget);
    });

    testWidgets('renders action pill', (tester) async {
      await tester.pumpWidget(_wrap(
        const AwaitingCard(title: 't', action: 'Review PR'),
      ));
      expect(find.text('REVIEW PR'), findsOneWidget); // BrutalPill uppercase
    });

    testWidgets('invokes onTap when tapped', (tester) async {
      int taps = 0;
      await tester.pumpWidget(_wrap(
        AwaitingCard(
          title: 't',
          action: 'review',
          onTap: () => taps++,
        ),
      ));
      await tester.tap(find.byType(AwaitingCard));
      expect(taps, 1);
    });
  });
}
