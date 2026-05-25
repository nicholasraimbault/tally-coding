import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/brutal/brutal_button.dart';

void main() {
  Widget wrap(Widget child) {
    final tokens = themeCatalog[defaultThemeSlug]!.tokens;
    return MaterialApp(
      theme: themeFromTokens(tokens),
      home: Scaffold(body: child),
    );
  }

  testWidgets('BrutalButton.primary renders uppercase label', (tester) async {
    await tester.pumpWidget(
      wrap(BrutalButton.primary(label: 'send', onPressed: () {})),
    );
    expect(find.text('SEND'), findsOneWidget);
  });

  testWidgets('BrutalButton.outline has transparent background', (tester) async {
    await tester.pumpWidget(
      wrap(BrutalButton.outline(label: 'cancel', onPressed: () {})),
    );
    // Find the outermost Container in BrutalButton
    final containers = tester.widgetList<Container>(find.byType(Container));
    final outermost = containers.first;
    final decoration = outermost.decoration as BoxDecoration;
    expect(decoration.color, Colors.transparent);
  });

  testWidgets('BrutalButton.primary onPressed invoked on tap', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      wrap(BrutalButton.primary(label: 'tap me', onPressed: () => tapped = true)),
    );
    await tester.tap(find.byType(GestureDetector));
    expect(tapped, isTrue);
  });

  testWidgets('BrutalButton has square corners (borderRadius is zero)', (tester) async {
    await tester.pumpWidget(
      wrap(BrutalButton.primary(label: 'square', onPressed: () {})),
    );
    final containers = tester.widgetList<Container>(find.byType(Container));
    final outermost = containers.first;
    final decoration = outermost.decoration as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.zero);
  });
}
