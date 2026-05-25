import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/brutal/brutal_bubble.dart';

void main() {
  Widget wrap(Widget child) {
    final tokens = themeCatalog[defaultThemeSlug]!.tokens;
    return MaterialApp(
      theme: themeFromTokens(tokens),
      home: Scaffold(body: child),
    );
  }

  testWidgets('BrutalBubble renders content', (tester) async {
    await tester.pumpWidget(wrap(
      const BrutalBubble(child: Text('Diagnosed the bug.')),
    ));
    expect(find.text('Diagnosed the bug.'), findsOneWidget);
  });

  testWidgets('BrutalBubble has square corners', (tester) async {
    await tester.pumpWidget(wrap(
      const BrutalBubble(child: Text('x')),
    ));
    final container = tester.widget<Container>(
      find.descendant(of: find.byType(BrutalBubble), matching: find.byType(Container)).first,
    );
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.zero);
  });

  testWidgets('BrutalBubble respects maxWidth', (tester) async {
    await tester.pumpWidget(wrap(
      BrutalBubble(maxWidth: 200, child: Text('x' * 100)),
    ));
    final box = tester.getSize(find.byType(BrutalBubble));
    expect(box.width, lessThanOrEqualTo(200));
  });
}
