import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/kanban/kanban_view.dart';

Task _t({String id = 't', String status = 'running', String desc = 'task',
         Map<String, dynamic>? teamSpec, double updatedAt = 0}) {
  return Task.fromJson({
    'id': id,
    'description': desc,
    'status': status,
    'created_at': 0.0,
    'updated_at': updatedAt,
    if (teamSpec != null) 'team_spec': teamSpec,
  });
}

Widget _wrap(Widget child) {
  final tokens = themeCatalog[defaultThemeSlug]!.tokens;
  return MaterialApp(
    theme: themeFromTokens(tokens),
    home: Scaffold(body: child),
  );
}

/// Set the test surface to [width] x 800 so LayoutBuilder sees the right
/// maxWidth, then restore the default 800 x 600 after the test.
Future<void> _setWidth(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() => tester.view.resetPhysicalSize());
}

void main() {
  testWidgets('renders 5 columns with correct labels', (tester) async {
    await _setWidth(tester, 1400);
    await tester.pumpWidget(_wrap(
      KanbanView(tasks: const [], onTaskTap: (_) {}, onNewTask: () {}),
    ));
    expect(find.text('TO DO'), findsOneWidget);
    expect(find.text('PLANNING'), findsOneWidget);
    expect(find.text('RUNNING'), findsOneWidget);
    expect(find.text('AWAITING'), findsOneWidget);
    expect(find.text('DONE'), findsOneWidget);
  });

  testWidgets('groups tasks into correct columns', (tester) async {
    await _setWidth(tester, 1400);
    final tasks = [
      _t(id: '1', status: 'pending', desc: 'todo task'),
      _t(id: '2', status: 'pending', teamSpec: {'agents': []}, desc: 'planning task'),
      _t(id: '3', status: 'running', desc: 'running task'),
      _t(id: '4', status: 'recovering', desc: 'awaiting task'),
      _t(id: '5', status: 'completed', desc: 'done task'),
    ];
    await tester.pumpWidget(_wrap(
      KanbanView(tasks: tasks, onTaskTap: (_) {}, onNewTask: () {}),
    ));
    expect(find.text('todo task'), findsOneWidget);
    expect(find.text('planning task'), findsOneWidget);
    expect(find.text('running task'), findsOneWidget);
    expect(find.text('awaiting task'), findsOneWidget);
    expect(find.text('done task'), findsOneWidget);
  });

  testWidgets('count pills reflect column populations', (tester) async {
    await _setWidth(tester, 1400);
    final tasks = [
      _t(id: '1', status: 'running'),
      _t(id: '2', status: 'running'),
      _t(id: '3', status: 'completed'),
    ];
    await tester.pumpWidget(_wrap(
      KanbanView(tasks: tasks, onTaskTap: (_) {}, onNewTask: () {}),
    ));
    // Expect a column with count '2' (running) and one with '1' (done).
    expect(find.text('2'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('tap on task card invokes onTaskTap with the task', (tester) async {
    await _setWidth(tester, 1400);
    Task? tapped;
    final task = _t(id: 'x', status: 'running', desc: 'tap me');
    await tester.pumpWidget(_wrap(
      KanbanView(
        tasks: [task],
        onTaskTap: (t) => tapped = t,
        onNewTask: () {},
      ),
    ));
    await tester.tap(find.text('tap me'));
    expect(tapped?.id, 'x');
  });

  testWidgets('horizontal scroll on narrow viewport', (tester) async {
    await _setWidth(tester, 400);
    await tester.pumpWidget(_wrap(
      KanbanView(tasks: const [], onTaskTap: (_) {}, onNewTask: () {}),
    ));
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    final scroll = tester.widget<SingleChildScrollView>(find.byType(SingleChildScrollView));
    expect(scroll.scrollDirection, Axis.horizontal);
  });

  testWidgets('side-by-side on wide viewport (no horizontal scroll)', (tester) async {
    await _setWidth(tester, 1400);
    await tester.pumpWidget(_wrap(
      KanbanView(tasks: const [], onTaskTap: (_) {}, onNewTask: () {}),
    ));
    expect(find.byType(SingleChildScrollView), findsNothing);
  });
}
