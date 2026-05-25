import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/brutal/cursor_blink.dart';
import 'package:tally_coding_app/widgets/brutal/tally_avatar.dart';

void main() {
  Widget wrap(Widget child) {
    final tokens = themeCatalog[defaultThemeSlug]!.tokens;
    return MaterialApp(
      theme: themeFromTokens(tokens),
      home: Scaffold(body: child),
    );
  }

  testWidgets('TallyAvatar renders T monogram', (tester) async {
    await tester.pumpWidget(wrap(const TallyAvatar()));
    expect(find.text('T'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink()); // dispose timer
  });

  testWidgets('TallyAvatar uses green bg from tokens', (tester) async {
    await tester.pumpWidget(wrap(const TallyAvatar()));
    final tokens = themeCatalog[defaultThemeSlug]!.tokens;
    final container = tester.widgetList<Container>(find.byType(Container)).first;
    expect(container.color, tokens.green);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TallyAvatar shows badge with CursorBlink when online', (tester) async {
    await tester.pumpWidget(wrap(const TallyAvatar(online: true)));
    expect(find.byType(CursorBlink), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TallyAvatar hides badge when online=false', (tester) async {
    await tester.pumpWidget(wrap(const TallyAvatar(online: false)));
    expect(find.byType(CursorBlink), findsNothing);
  });

  testWidgets('TallyAvatar is square (radius 0)', (tester) async {
    await tester.pumpWidget(wrap(const TallyAvatar()));
    final container = tester.widgetList<Container>(find.byType(Container)).first;
    expect(container.decoration, isNull); // bg via color prop, no decoration
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
