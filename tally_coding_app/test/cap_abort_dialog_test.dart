import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/cap_abort_dialog.dart';

void main() {
  testWidgets('per_task_cap reason: renders cap + cost numbers + "Raise cap"', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (ctx) {
      return ElevatedButton(onPressed: () => showDialog(
        context: ctx,
        builder: (_) => CapAbortDialog(
          reason: 'per_task_cap',
          costCredits: 105,
          capCredits: 100,
          onRaiseCapAndRetry: () {},
          onViewPartial: () {},
        ),
      ), child: const Text('open'));
    }))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('105 credits'), findsOneWidget);
    expect(find.textContaining('100-credit'), findsOneWidget);
    expect(find.text('Raise cap & retry'), findsOneWidget);
    expect(find.text('Cost cap reached'), findsOneWidget);
  });

  testWidgets('period_cap reason: renders period-cap copy + "Buy credits"', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (ctx) {
      return ElevatedButton(onPressed: () => showDialog(
        context: ctx,
        builder: (_) => CapAbortDialog(
          reason: 'period_cap',
          costCredits: 50,
          capCredits: 0,
          onRaiseCapAndRetry: () {},
          onViewPartial: () {},
        ),
      ), child: const Text('open'));
    }))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Credit balance exhausted'), findsOneWidget);
    expect(find.textContaining('50 credits'), findsOneWidget);
    expect(find.text('Buy credits'), findsOneWidget);
    expect(find.textContaining('Raise cap & retry'), findsNothing);
  });
}
