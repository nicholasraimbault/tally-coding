import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
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
}
