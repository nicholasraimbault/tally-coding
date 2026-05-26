import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/brutal/brutal_card.dart';

void main() {
  Widget wrap(Widget child) {
    final tokens = themeCatalog[defaultThemeSlug]!.tokens;
    return MaterialApp(
      theme: themeFromTokens(tokens),
      home: Scaffold(body: child),
    );
  }

  testWidgets('BrutalCard renders child', (tester) async {
    await tester.pumpWidget(wrap(
      const BrutalCard(child: Text('hello')),
    ));
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('BrutalCard has square corners (radius 0)', (tester) async {
    await tester.pumpWidget(wrap(
      const BrutalCard(child: SizedBox(width: 100, height: 100)),
    ));
    final container = tester.widget<Container>(
      find.descendant(of: find.byType(BrutalCard), matching: find.byType(Container)).first,
    );
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.zero);
  });

  testWidgets('BrutalCard uses 1px border from tokens.border', (tester) async {
    await tester.pumpWidget(wrap(
      const BrutalCard(child: SizedBox(width: 100, height: 100)),
    ));
    final container = tester.widget<Container>(
      find.descendant(of: find.byType(BrutalCard), matching: find.byType(Container)).first,
    );
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.border!.top.width, 1.0);
  });

  testWidgets('BrutalCard has no shadow', (tester) async {
    await tester.pumpWidget(wrap(
      const BrutalCard(child: SizedBox(width: 100, height: 100)),
    ));
    final container = tester.widget<Container>(
      find.descendant(of: find.byType(BrutalCard), matching: find.byType(Container)).first,
    );
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.boxShadow, anyOf(isNull, isEmpty));
  });
}
