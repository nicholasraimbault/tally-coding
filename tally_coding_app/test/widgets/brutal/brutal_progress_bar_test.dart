import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/brutal/brutal_progress_bar.dart';

void main() {
  Widget wrap(Widget child) {
    final tokens = themeCatalog[defaultThemeSlug]!.tokens;
    return MaterialApp(
      theme: themeFromTokens(tokens),
      home: Scaffold(body: SizedBox(width: 200, child: child)),
    );
  }

  testWidgets('BrutalProgressBar renders at correct percentage', (tester) async {
    await tester.pumpWidget(wrap(const BrutalProgressBar(value: 0.6)));
    final fractional = tester.widget<FractionallySizedBox>(find.byType(FractionallySizedBox));
    expect(fractional.widthFactor, 0.6);
  });

  testWidgets('BrutalProgressBar clamps value to [0,1]', (tester) async {
    await tester.pumpWidget(wrap(const BrutalProgressBar(value: 1.5)));
    final fractional = tester.widget<FractionallySizedBox>(find.byType(FractionallySizedBox));
    expect(fractional.widthFactor, 1.0);
  });

  testWidgets('BrutalProgressBar uses tokens.green for fill', (tester) async {
    await tester.pumpWidget(wrap(const BrutalProgressBar(value: 0.5)));
    final fillContainer = tester.widgetList<Container>(find.byType(Container)).last;
    final decoration = fillContainer.decoration as BoxDecoration;
    final tokens = themeCatalog[defaultThemeSlug]!.tokens;
    expect(decoration.color, tokens.green);
  });

  testWidgets('BrutalProgressBar default height is 3px', (tester) async {
    await tester.pumpWidget(wrap(const BrutalProgressBar(value: 0.5)));
    final box = tester.getSize(find.byType(BrutalProgressBar));
    expect(box.height, 3);
  });
}
