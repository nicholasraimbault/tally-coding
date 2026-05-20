import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/cap_abort_dialog.dart';

void main() {
  testWidgets('renders cap + cost numbers', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (ctx) {
      return ElevatedButton(onPressed: () => showDialog(
        context: ctx,
        builder: (_) => CapAbortDialog(
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
  });
}
