import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/ambient_mini_dash.dart';

Widget _wrap(Widget child) {
  final tokens = themeCatalog[defaultThemeSlug]!.tokens;
  return MaterialApp(theme: themeFromTokens(tokens), home: Scaffold(body: child));
}

void main() {
  testWidgets('renders open + done stat counts', (tester) async {
    await tester.pumpWidget(_wrap(const AmbientMiniDash(
      openCount: 6, doneCount: 3, taskRows: [], narratorText: null,
    )));
    expect(find.text('6'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('open'), findsOneWidget);
    expect(find.text('done today'), findsOneWidget);
  });

  testWidgets('renders drag handle pill', (tester) async {
    await tester.pumpWidget(_wrap(const AmbientMiniDash(
      openCount: 0, doneCount: 0, taskRows: [], narratorText: null,
    )));
    expect(find.byKey(const ValueKey('drag-handle')), findsOneWidget);
  });

  testWidgets('renders MiniTaskRow children inside body', (tester) async {
    await tester.pumpWidget(_wrap(const AmbientMiniDash(
      openCount: 1, doneCount: 0,
      taskRows: [
        MiniTaskRow(title: 'Fix daily-deals', progress: 0.6),
      ],
      narratorText: null,
    )));
    expect(find.text('Fix daily-deals'), findsOneWidget);
  });

  testWidgets('MiniTaskRow renders progress', (tester) async {
    await tester.pumpWidget(_wrap(const Padding(
      padding: EdgeInsets.all(16),
      child: MiniTaskRow(title: 'x', progress: 0.7),
    )));
    expect(find.byType(MiniTaskRow), findsOneWidget);
  });
}
