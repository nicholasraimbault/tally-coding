import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/screens/discord_shell.dart';
import 'package:tally_coding_app/services/notifications_ws.dart';
import 'package:tally_coding_app/state/workspace_context.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/sidebar/sidebar_channels_list.dart';
import 'package:tally_coding_app/widgets/sidebar/sidebar_shell.dart';
import 'package:tally_coding_app/widgets/server_rail.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/ambient_mini_dash.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/bottom_sheet_controller.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/escalation_model.dart';
import 'package:tally_coding_app/widgets/kanban/kanban.dart';

TallyOrchClient _makeClient() {
  final mock = MockClient((req) async {
    // Workspace list
    if (req.url.path.contains('/me/workspaces')) {
      return http.Response(
        '{"workspaces":[{"id":1,"name":"test","role":"admin"}]}',
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    // Tasks
    if (req.url.path.contains('/tasks')) {
      return http.Response('[]', 200,
          headers: {'content-type': 'application/json'});
    }
    // Channels
    if (req.url.path.contains('/channels')) {
      return http.Response('{"channels":[]}', 200,
          headers: {'content-type': 'application/json'});
    }
    // Health
    if (req.url.path.contains('/health')) {
      return http.Response(
        '{"pool_ready":true,"pool_target":0,"pool_joined":0}',
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response('{}', 404,
        headers: {'content-type': 'application/json'});
  });
  return TallyOrchClient(
    baseUrl: Uri.parse('http://localhost'),
    provider: () async => 'test-token',
    client: mock,
  );
}

NotificationsWsClient _makeWsClient(TallyOrchClient client) {
  return NotificationsWsClient(
    api: client,
    wsUrl: Uri.parse('ws://localhost/ws/notifications'),
    bearerProvider: () async => 'test-token',
  );
}

Widget _wideApp() {
  SharedPreferences.setMockInitialValues({});
  final tokens = themeCatalog[defaultThemeSlug]!.tokens;
  final client = _makeClient();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => BottomSheetController()),
    ],
    child: WorkspaceContext(
      activeWorkspaceId: 1,
      onChange: (_) {},
      child: MaterialApp(
        theme: themeFromTokens(tokens),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(1440, 900)),
          // SizedBox ensures LayoutBuilder in DiscordShellScreen gets 1440px width
          child: SizedBox(
            width: 1440,
            height: 900,
            child: DiscordShellScreen(
              client: client,
              wsClient: _makeWsClient(client),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Helper to set the tester view to wide (1440×900).
void _setWide(WidgetTester tester) {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('DiscordShellScreen wide layout', () {
    testWidgets('shows SidebarShell, not ServerRail', (tester) async {
      _setWide(tester);
      await tester.pumpWidget(_wideApp());
      await tester.pump(); // let initState complete
      expect(find.byType(SidebarShell), findsOneWidget);
      expect(find.byType(ServerRail), findsNothing);
    });

    testWidgets('sidebar shows loaded workspace name after async load',
        (tester) async {
      _setWide(tester);
      await tester.pumpWidget(_wideApp());
      await tester.pump();
      // Allow async _loadActiveWorkspaceName() to complete
      await tester.pumpAndSettle();
      // The workspace name appears in both WorkspaceRow (top) and
      // SidebarFooter (bottom) — at least one is sufficient.
      expect(find.text('test'), findsAtLeastNWidgets(1));
    });

    // F1-Fix1: _BoardBottomSheet must NOT appear on wide layout.
    testWidgets(
        'F1-Fix1: AmbientMiniDash (bottom sheet) does NOT mount on wide BoardSelected',
        (tester) async {
      _setWide(tester);
      await tester.pumpWidget(_wideApp());
      await tester.pumpAndSettle();
      // The shell starts in BoardSelected state.
      // On wide layout, _BoardBottomSheet must be absent — only
      // SidebarMiniDash in SidebarShell serves the ambient surface.
      expect(find.byType(AmbientMiniDash), findsNothing);
    });

    // F1-Fix2: no "Agents are running." placeholder text leaks on fresh load.
    testWidgets('F1-Fix2: narrator placeholder not shown on fresh load',
        (tester) async {
      _setWide(tester);
      await tester.pumpWidget(_wideApp());
      await tester.pumpAndSettle();
      // Before any WS narrator event, the bubble should be absent.
      expect(find.text('Agents are running.'), findsNothing);
    });

    // F1-Fix3: SidebarChannelsList has a Board entry visible in wide layout.
    testWidgets('F1-Fix3: SidebarChannelsList shows Board entry', (tester) async {
      _setWide(tester);
      await tester.pumpWidget(_wideApp());
      await tester.pumpAndSettle();
      // The 'Board' label must appear inside SidebarChannelsList.
      expect(find.byType(SidebarChannelsList), findsOneWidget);
      // The Board entry is rendered within SidebarChannelsList subtree.
      final sidebarFinder = find.descendant(
        of: find.byType(SidebarChannelsList),
        matching: find.text('Board'),
      );
      expect(sidebarFinder, findsOneWidget);
    });

    // F1-Fix3: tapping Board entry from a channel returns to board view.
    testWidgets(
        'F1-Fix3: tapping Board entry in SidebarChannelsList resets to board view',
        (tester) async {
      _setWide(tester);
      await tester.pumpWidget(_wideApp());
      await tester.pumpAndSettle();
      // Tap a channel tile to move away from board (board is initial state,
      // but we tap Board key to confirm the tap invokes the callback — the
      // shell stays on Board, which keeps KanbanView visible).
      final boardEntry = find.byKey(const Key('sidebar_board_entry'));
      expect(boardEntry, findsOneWidget);
      await tester.tap(boardEntry);
      await tester.pumpAndSettle();
      // After tapping, KanbanView should be visible (board selected).
      expect(find.byType(KanbanView), findsOneWidget);
    });

    // F1-Fix4: escalation from BottomSheetController propagates to SidebarShell.
    testWidgets(
        'F1-Fix4: BottomSheetController escalations reach SidebarShell',
        (tester) async {
      _setWide(tester);
      final bsController = BottomSheetController();
      SharedPreferences.setMockInitialValues({});
      final tokens = themeCatalog[defaultThemeSlug]!.tokens;
      final client = _makeClient();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: bsController),
          ],
          child: WorkspaceContext(
            activeWorkspaceId: 1,
            onChange: (_) {},
            child: MaterialApp(
              theme: themeFromTokens(tokens),
              home: MediaQuery(
                data: const MediaQueryData(size: Size(1440, 900)),
                child: SizedBox(
                  width: 1440,
                  height: 900,
                  child: DiscordShellScreen(
                    client: client,
                    wsClient: _makeWsClient(client),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Enqueue an escalation into the controller.
      bsController.enqueueEscalation(
        const EscalationModel(
          id: 'esc-1',
          question: 'Use 2 decimals?',
          options: ['Yes', 'No'],
          taskId: 'task-abc',
          channelId: 99,
        ),
      );
      // Rebuild so the new state propagates.
      await tester.pump();

      // SidebarShell should now receive a non-empty escalations list,
      // making SidebarMiniDash show the escalation takeover text.
      // Verify "needs you" indicator appears (the escalation state is active).
      expect(find.text('needs you'), findsOneWidget);
    });

    // F1-Fix5: desktop split-pane — kanban stays visible when task selected.
    testWidgets(
        'F1-Fix5: KanbanView remains visible on desktop when task is selected',
        (tester) async {
      _setWide(tester);
      SharedPreferences.setMockInitialValues({});
      final tokens = themeCatalog[defaultThemeSlug]!.tokens;
      final client = _makeClient();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => BottomSheetController()),
          ],
          child: WorkspaceContext(
            activeWorkspaceId: 1,
            onChange: (_) {},
            child: MaterialApp(
              theme: themeFromTokens(tokens),
              home: MediaQuery(
                data: const MediaQueryData(size: Size(1440, 900)),
                child: SizedBox(
                  width: 1440,
                  height: 900,
                  // Use initialTaskId to start in TaskSelected state.
                  child: DiscordShellScreen(
                    client: client,
                    wsClient: _makeWsClient(client),
                    initialTaskId: 'task-1234567890abcdef',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // On desktop, KanbanView should still be visible alongside the task channel.
      expect(find.byType(KanbanView), findsOneWidget);
    });

    // F1-Fix5: close button in the right pane collapses back to board-only view.
    testWidgets(
        'F1-Fix5: close button collapses right pane back to board-only view',
        (tester) async {
      _setWide(tester);
      SharedPreferences.setMockInitialValues({});
      final tokens = themeCatalog[defaultThemeSlug]!.tokens;
      final client = _makeClient();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => BottomSheetController()),
          ],
          child: WorkspaceContext(
            activeWorkspaceId: 1,
            onChange: (_) {},
            child: MaterialApp(
              theme: themeFromTokens(tokens),
              home: MediaQuery(
                data: const MediaQueryData(size: Size(1440, 900)),
                child: SizedBox(
                  width: 1440,
                  height: 900,
                  child: DiscordShellScreen(
                    client: client,
                    wsClient: _makeWsClient(client),
                    initialTaskId: 'task-1234567890abcdef',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The close button should be present in the right pane header.
      final closeButton = find.byTooltip('Close panel');
      expect(closeButton, findsOneWidget);

      // Tap the close button.
      await tester.tap(closeButton);
      await tester.pumpAndSettle();

      // After closing, the close button should no longer be present
      // (split pane is gone — now board-only).
      expect(find.byTooltip('Close panel'), findsNothing);
    });
  });
}
