import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/brutal/brutal_pill.dart';

void main() {
  Widget wrap(Widget child) {
    final tokens = themeCatalog[defaultThemeSlug]!.tokens;
    return MaterialApp(
      theme: themeFromTokens(tokens),
      home: Scaffold(body: child),
    );
  }

  testWidgets('BrutalPill renders uppercase label', (tester) async {
    await tester.pumpWidget(wrap(
      const BrutalPill(label: '1 esc'),
    ));
    expect(find.text('1 ESC'), findsOneWidget);
  });

  testWidgets('BrutalPill defaults to red accent color', (tester) async {
    await tester.pumpWidget(wrap(
      const BrutalPill(label: 'x'),
    ));
    final container = tester.widget<Container>(find.byType(Container));
    final decoration = container.decoration as BoxDecoration;
    final tokens = themeCatalog[defaultThemeSlug]!.tokens;
    expect(decoration.border!.top.color, tokens.red);
  });

  testWidgets('BrutalPill accepts custom accent color', (tester) async {
    await tester.pumpWidget(wrap(
      BrutalPill(label: 'x', accent: themeCatalog[defaultThemeSlug]!.tokens.green),
    ));
    final container = tester.widget<Container>(find.byType(Container));
    final decoration = container.decoration as BoxDecoration;
    final tokens = themeCatalog[defaultThemeSlug]!.tokens;
    expect(decoration.border!.top.color, tokens.green);
  });
}
