import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/sidebar/sidebar_shell.dart';
import 'package:tally_coding_app/widgets/sidebar/sidebar_footer.dart';
import 'package:tally_coding_app/widgets/sidebar/workspace_row.dart';
import 'package:tally_coding_app/widgets/sidebar/sidebar_mini_dash.dart';
import 'package:tally_coding_app/theme/theme.dart';

Widget _wrap(Widget child) {
  final tokens = themeCatalog[defaultThemeSlug]!.tokens;
  return MaterialApp(
    theme: themeFromTokens(tokens),
    home: Scaffold(body: child),
  );
}

SidebarShell _shell({
  String workspaceName = 'pronoic',
  VoidCallback? onSettingsTap,
}) =>
    SidebarShell(
      workspaceName: workspaceName,
      channels: const [],
      activeChannelName: null,
      openCount: 0,
      doneToday: 0,
      tasks: const [],
      narratorText: 'Idle.',
      narratorEmphasis: const [],
      escalations: const [],
      onWorkspaceSwitcherTap: () {},
      onSearchTap: () {},
      onChannelTap: (_) {},
      onAddChannel: () {},
      onQuickReply: (_) {},
      onSkipEscalation: () {},
      onOpenChannel: () {},
      onSettingsTap: onSettingsTap ?? () {},
    );

void main() {
  group('SidebarShell', () {
    testWidgets('renders exactly 240 px wide', (tester) async {
      await tester.pumpWidget(_wrap(Row(children: [_shell()])));
      final shell = tester.getSize(find.byType(SidebarShell));
      expect(shell.width, 240.0);
    });

    testWidgets('WorkspaceRow appears at the top', (tester) async {
      await tester.pumpWidget(_wrap(Row(children: [_shell(workspaceName: 'acme')])));
      expect(find.byType(WorkspaceRow), findsOneWidget);
      // WorkspaceRow must be above SidebarMiniDash in the layout
      final workspaceY = tester.getTopLeft(find.byType(WorkspaceRow)).dy;
      final miniDashY = tester.getTopLeft(find.byType(SidebarMiniDash)).dy;
      expect(workspaceY, lessThan(miniDashY));
    });

    testWidgets('SidebarMiniDash appears at the bottom (docked)', (tester) async {
      await tester.pumpWidget(_wrap(Row(children: [
        SidebarShell(
          workspaceName: 'acme',
          channels: const [],
          activeChannelName: null,
          openCount: 3,
          doneToday: 1,
          tasks: const [],
          narratorText: 'Running.',
          narratorEmphasis: const [],
          escalations: const [],
          onWorkspaceSwitcherTap: () {},
          onSearchTap: () {},
          onChannelTap: (_) {},
          onAddChannel: () {},
          onQuickReply: (_) {},
          onSkipEscalation: () {},
          onOpenChannel: () {},
          onSettingsTap: () {},
        ),
      ])));
      expect(find.byType(SidebarMiniDash), findsOneWidget);
    });

    testWidgets('right border hairline is present', (tester) async {
      await tester.pumpWidget(_wrap(Row(children: [_shell()])));
      // At least one Container has a right border (the outer shell container)
      expect(
        find.byWidgetPredicate((w) {
          if (w is! Container) return false;
          final border = (w.decoration as BoxDecoration?)?.border;
          if (border is! Border) return false;
          return border.right.width == 1.0;
        }),
        findsAtLeastNWidgets(1),
      );
    });

    testWidgets('SidebarFooter is rendered at the bottom', (tester) async {
      await tester.pumpWidget(_wrap(Row(children: [_shell(workspaceName: 'pronoic')])));
      expect(find.byType(SidebarFooter), findsOneWidget);
    });

    testWidgets('SidebarFooter settings tap invokes onSettingsTap', (tester) async {
      var tapped = false;
      await tester.pumpWidget(_wrap(Row(children: [
        _shell(onSettingsTap: () => tapped = true),
      ])));
      await tester.tap(find.byIcon(Icons.settings_outlined));
      expect(tapped, isTrue);
    });

    testWidgets('SidebarFooter is below SidebarMiniDash', (tester) async {
      await tester.pumpWidget(_wrap(Row(children: [_shell()])));
      final miniDashY = tester.getTopLeft(find.byType(SidebarMiniDash)).dy;
      final footerY = tester.getTopLeft(find.byType(SidebarFooter)).dy;
      expect(footerY, greaterThan(miniDashY));
    });
  });
}
