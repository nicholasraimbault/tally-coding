import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/brutal/agent_avatar.dart';
import 'package:tally_coding_app/widgets/brutal/cursor_blink.dart';

void main() {
  Widget wrap(Widget child) {
    final tokens = themeCatalog[defaultThemeSlug]!.tokens;
    return MaterialApp(
      theme: themeFromTokens(tokens),
      home: Scaffold(body: child),
    );
  }

  testWidgets('AgentAvatar.architect renders A in magenta', (tester) async {
    await tester.pumpWidget(wrap(
      const AgentAvatar(role: AgentRole.architect, active: false),
    ));
    expect(find.text('A'), findsOneWidget);
    final tokens = themeCatalog[defaultThemeSlug]!.tokens;
    final container = tester.widgetList<Container>(find.byType(Container)).first;
    expect(container.color, tokens.magenta);
  });

  testWidgets('AgentAvatar.coder renders C in cyan', (tester) async {
    await tester.pumpWidget(wrap(
      const AgentAvatar(role: AgentRole.coder, active: false),
    ));
    expect(find.text('C'), findsOneWidget);
    final tokens = themeCatalog[defaultThemeSlug]!.tokens;
    final container = tester.widgetList<Container>(find.byType(Container)).first;
    expect(container.color, tokens.cyan);
  });

  testWidgets('AgentAvatar.reader renders R in yellow', (tester) async {
    await tester.pumpWidget(wrap(
      const AgentAvatar(role: AgentRole.reader, active: false),
    ));
    expect(find.text('R'), findsOneWidget);
  });

  testWidgets('AgentAvatar.tester renders T in orange', (tester) async {
    await tester.pumpWidget(wrap(
      const AgentAvatar(role: AgentRole.tester, active: false),
    ));
    expect(find.text('T'), findsOneWidget);
  });

  testWidgets('AgentAvatar shows cursor blink when active', (tester) async {
    await tester.pumpWidget(wrap(
      const AgentAvatar(role: AgentRole.coder, active: true),
    ));
    expect(find.byType(CursorBlink), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('AgentAvatar hides cursor blink when inactive', (tester) async {
    await tester.pumpWidget(wrap(
      const AgentAvatar(role: AgentRole.coder, active: false),
    ));
    expect(find.byType(CursorBlink), findsNothing);
  });
}
