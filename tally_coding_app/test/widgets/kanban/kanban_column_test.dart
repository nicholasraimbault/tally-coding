import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/kanban/kanban_column.dart';

Widget _wrap(Widget child) {
  final tokens = themeCatalog[defaultThemeSlug]!.tokens;
  return MaterialApp(
    theme: themeFromTokens(tokens),
    home: Scaffold(body: SizedBox(width: 240, child: child)),
  );
}

void main() {
  testWidgets('renders header label uppercase', (tester) async {
    await tester.pumpWidget(_wrap(KanbanColumn(
      label: 'Running',
      count: 2,
      children: const [Text('card1'), Text('card2')],
      onNewTask: () {},
    )));
    expect(find.text('RUNNING'), findsOneWidget);
  });

  testWidgets('renders count pill', (tester) async {
    await tester.pumpWidget(_wrap(KanbanColumn(
      label: 'Running',
      count: 7,
      children: const [],
      onNewTask: () {},
    )));
    expect(find.text('7'), findsOneWidget);
  });

  testWidgets('renders each child card', (tester) async {
    await tester.pumpWidget(_wrap(KanbanColumn(
      label: 'x',
      count: 2,
      children: const [Text('alpha'), Text('beta')],
      onNewTask: () {},
    )));
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);
  });

  testWidgets('renders NewTaskRow when showNewTaskRow is true (default)', (tester) async {
    await tester.pumpWidget(_wrap(KanbanColumn(
      label: 'To do',
      count: 0,
      children: const [],
      onNewTask: () {},
      showNewTaskRow: true,
    )));
    expect(find.text('+ New task'), findsOneWidget);
  });

  testWidgets('omits NewTaskRow when showNewTaskRow is false', (tester) async {
    await tester.pumpWidget(_wrap(KanbanColumn(
      label: 'Running',
      count: 0,
      children: const [],
      onNewTask: () {},
      showNewTaskRow: false,
    )));
    expect(find.text('+ New task'), findsNothing);
  });

  testWidgets('default showNewTaskRow=true keeps NewTaskRow visible', (tester) async {
    // Backwards-compat: omitting showNewTaskRow shows the row by default.
    await tester.pumpWidget(_wrap(KanbanColumn(
      label: 'x',
      count: 0,
      children: const [],
      onNewTask: () {},
    )));
    expect(find.text('+ New task'), findsOneWidget);
  });

  testWidgets('invokes onNewTask when NewTaskRow tapped', (tester) async {
    int newTaps = 0;
    await tester.pumpWidget(_wrap(KanbanColumn(
      label: 'x',
      count: 0,
      children: const [],
      onNewTask: () => newTaps++,
    )));
    await tester.tap(find.text('+ New task'));
    expect(newTaps, 1);
  });
}
