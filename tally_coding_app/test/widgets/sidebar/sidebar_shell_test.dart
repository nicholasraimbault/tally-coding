import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/sidebar/sidebar_shell.dart';
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

void main() {
  group('SidebarShell', () {
    testWidgets('renders exactly 240 px wide', (tester) async {
      await tester.pumpWidget(_wrap(Row(children: [
        SidebarShell(
          workspaceName: 'pronoic',
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
        ),
      ])));
      final shell = tester.getSize(find.byType(SidebarShell));
      expect(shell.width, 240.0);
    });

    testWidgets('WorkspaceRow appears at the top', (tester) async {
      await tester.pumpWidget(_wrap(Row(children: [
        SidebarShell(
          workspaceName: 'acme',
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
        ),
      ])));
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
        ),
      ])));
      expect(find.byType(SidebarMiniDash), findsOneWidget);
    });

    testWidgets('right border hairline is present', (tester) async {
      await tester.pumpWidget(_wrap(Row(children: [
        SidebarShell(
          workspaceName: 'acme',
          channels: const [],
          activeChannelName: null,
          openCount: 0,
          doneToday: 0,
          tasks: const [],
          narratorText: '',
          narratorEmphasis: const [],
          escalations: const [],
          onWorkspaceSwitcherTap: () {},
          onSearchTap: () {},
          onChannelTap: (_) {},
          onAddChannel: () {},
          onQuickReply: (_) {},
          onSkipEscalation: () {},
          onOpenChannel: () {},
        ),
      ])));
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
  });
}
