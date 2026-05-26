import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/sidebar/workspace_row.dart';
import 'package:tally_coding_app/theme/theme.dart';

Widget _wrap(Widget child) {
  final tokens = themeCatalog[defaultThemeSlug]!.tokens;
  return MaterialApp(
    theme: themeFromTokens(tokens),
    home: Scaffold(body: child),
  );
}

void main() {
  group('WorkspaceRow', () {
    testWidgets('renders badge letter from workspaceName', (tester) async {
      await tester.pumpWidget(_wrap(WorkspaceRow(
        workspaceName: 'pronoic',
        onSwitcherTap: () {},
        onSearchTap: () {},
      )));
      // Badge shows first letter uppercase
      expect(find.text('P'), findsOneWidget);
      // Name appears
      expect(find.text('pronoic'), findsOneWidget);
    });

    testWidgets('chevron tap fires onSwitcherTap', (tester) async {
      var tapped = false;
      await tester.pumpWidget(_wrap(WorkspaceRow(
        workspaceName: 'acme',
        onSwitcherTap: () => tapped = true,
        onSearchTap: () {},
      )));
      // Tap the workspace name text (part of the GestureDetector area)
      await tester.tap(find.text('acme'));
      expect(tapped, isTrue);
    });

    testWidgets('search icon tap fires onSearchTap', (tester) async {
      var searched = false;
      await tester.pumpWidget(_wrap(WorkspaceRow(
        workspaceName: 'acme',
        onSwitcherTap: () {},
        onSearchTap: () => searched = true,
      )));
      await tester.tap(find.byKey(const Key('workspace_row_search')));
      expect(searched, isTrue);
    });

    testWidgets('bottom hairline border is present', (tester) async {
      await tester.pumpWidget(_wrap(WorkspaceRow(
        workspaceName: 'acme',
        onSwitcherTap: () {},
        onSearchTap: () {},
      )));
      // Container with bottom border wraps the row
      expect(
        find.byWidgetPredicate((w) =>
            w is Container &&
            (w.decoration as BoxDecoration?)?.border?.bottom.width == 1.0),
        findsOneWidget,
      );
    });
  });
}
