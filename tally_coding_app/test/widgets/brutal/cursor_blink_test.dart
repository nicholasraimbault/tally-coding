import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/brutal/cursor_blink.dart';

void main() {
  testWidgets('CursorBlink shows child initially', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CursorBlink(
          child: Container(width: 10, height: 10, color: const Color(0xFF00FF00)),
        ),
      ),
    ));
    expect(find.byType(Container), findsOneWidget);
    final opacity = tester.widget<Opacity>(find.byType(Opacity));
    expect(opacity.opacity, 1.0);
  });

  testWidgets('CursorBlink hides child after 600ms', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CursorBlink(
          child: Container(width: 10, height: 10, color: const Color(0xFF00FF00)),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 601));
    final opacity = tester.widget<Opacity>(find.byType(Opacity));
    expect(opacity.opacity, 0.0);
  });

  testWidgets('CursorBlink alternates at 1.2s cycle', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CursorBlink(
          child: Container(width: 10, height: 10, color: const Color(0xFF00FF00)),
        ),
      ),
    ));
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 1.0);
    await tester.pump(const Duration(milliseconds: 601));
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 0.0);
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 1.0);

    // Dispose to stop the timer (avoids "pending timers" test failure).
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
