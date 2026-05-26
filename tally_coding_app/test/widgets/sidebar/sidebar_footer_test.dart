import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/sidebar/sidebar_footer.dart';

Widget _wrap(Widget child) {
  final tokens = themeCatalog[defaultThemeSlug]!.tokens;
  return MaterialApp(
    theme: themeFromTokens(tokens),
    home: Scaffold(
      body: SizedBox(width: 240, child: child),
    ),
  );
}

void main() {
  group('SidebarFooter', () {
    testWidgets('renders workspace name', (tester) async {
      await tester.pumpWidget(_wrap(SidebarFooter(
        workspaceName: 'pronoic',
        onSettingsTap: () {},
      )));
      expect(find.text('pronoic'), findsOneWidget);
    });

    testWidgets('renders settings_outlined icon', (tester) async {
      await tester.pumpWidget(_wrap(SidebarFooter(
        workspaceName: 'pronoic',
        onSettingsTap: () {},
      )));
      expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    });

    testWidgets('tapping settings icon invokes onSettingsTap', (tester) async {
      var tapped = false;
      await tester.pumpWidget(_wrap(SidebarFooter(
        workspaceName: 'pronoic',
        onSettingsTap: () => tapped = true,
      )));
      await tester.tap(find.byIcon(Icons.settings_outlined));
      expect(tapped, isTrue);
    });

    testWidgets('workspace badge shows first letter uppercase', (tester) async {
      await tester.pumpWidget(_wrap(SidebarFooter(
        workspaceName: 'acme',
        onSettingsTap: () {},
      )));
      // Badge shows 'A' (uppercase first letter of 'acme')
      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('badge shows uppercase W when workspaceName is empty', (tester) async {
      await tester.pumpWidget(_wrap(SidebarFooter(
        workspaceName: '',
        onSettingsTap: () {},
      )));
      // Empty workspace → fallback badge 'W'
      expect(find.text('W'), findsOneWidget);
    });

    testWidgets('shows (no workspace) text when workspaceName is empty', (tester) async {
      await tester.pumpWidget(_wrap(SidebarFooter(
        workspaceName: '',
        onSettingsTap: () {},
      )));
      expect(find.text('(no workspace)'), findsOneWidget);
    });

    testWidgets('shows uppercase first letter of workspace name in badge',
        (tester) async {
      await tester.pumpWidget(_wrap(SidebarFooter(
        workspaceName: 'Zephyr',
        onSettingsTap: () {},
      )));
      expect(find.text('Z'), findsOneWidget);
    });
  });
}
