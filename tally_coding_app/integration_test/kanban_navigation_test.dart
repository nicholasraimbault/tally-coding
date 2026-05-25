// B2 Task 14: Smoke integration test for tap-card-to-open.
//
// End-to-end: pump DiscordShellScreen with a mock client returning
// 1 running task.  Verify kanban renders, tap the task card, verify
// TaskChannelScreen appears.
//
// Run:
//   ./scripts/run-it.sh integration_test/kanban_navigation_test.dart

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/screens/discord_shell.dart';
import 'package:tally_coding_app/screens/task_channel.dart';
import 'package:tally_coding_app/services/notifications_ws.dart';
import 'package:tally_coding_app/state/workspace_context.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/kanban/kanban.dart';

TallyOrchClient _client(MockClient mock) => TallyOrchClient(
      baseUrl: Uri.parse('https://tally.pronoic.dev'),
      provider: () async => 't',
      client: mock,
    );

NotificationsWsClient _idleWs(TallyOrchClient client) => NotificationsWsClient(
      api: client,
      wsUrl: Uri.parse('wss://tally.pronoic.dev/ws/notifications'),
      bearerProvider: () async => 't',
    );

http.Response _json(String body) =>
    http.Response(body, 200, headers: {'content-type': 'application/json'});

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('tapping a kanban card opens the task channel', (tester) async {
    // Force wide layout so desktop kanban (side-by-side columns) renders.
    // KanbanView's breakpoint is 1100 logical px for the MAIN PANE, which
    // is narrower than the full window (ServerRail=60 + ChannelList=240 +
    // MembersPanel=240 + 3 separators ≈ 543 px overhead).  So the full
    // window must be at least 1643 logical px wide.  Use 4000×2000 @ dpr=2.0
    // → 2000×1000 logical px, giving the main pane ~1457 logical px.
    tester.view.physicalSize = const Size(4000, 2000);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // Mock orchestrator: return 1 running task on /tasks; correct shapes
    // for all other endpoints the shell calls during initState +
    // didChangeDependencies (_fetch, _pollHealth, _fetchDirectChannels).
    final mock = MockClient((req) async {
      final path = req.url.path;

      if (path == '/tasks') {
        return _json(jsonEncode([
          {
            'id': 'task-42xx',
            'description': 'Fix daily-deals price formatting',
            'status': 'running',
            'created_at': 0.0,
            'updated_at': 0.0,
          }
        ]));
      }

      if (path == '/channels') {
        return _json('{"channels":[]}');
      }

      if (path == '/health') {
        return _json(
          '{"status":"ok","pool_ready":true,"pool_target":1,"pool_joined":1,'
          '"pool_last_error":null,"pool_unhealthy_since_seconds":null,'
          '"pool_circuit_open":false,"tasks_in_flight":false}',
        );
      }

      if (path == '/me/workspaces') {
        return _json(
          '{"workspaces":[{"id":1,"name":"admin","role":"owner","created_at":0}]}',
        );
      }

      // All other endpoints (audit-log, persistent_agents, task events, etc.)
      // — return safe empty responses so the shell doesn't error out.
      return _json('{}');
    });

    final client = _client(mock);
    final ws = _idleWs(client);

    final themeCtrl = ThemeController();
    await themeCtrl.load();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: themeCtrl,
        child: MaterialApp(
          theme: themeFromTokens(themeCtrl.activeEntry.tokens),
          home: WorkspaceContext(
            activeWorkspaceId: 1,
            onChange: (_) {},
            child: DiscordShellScreen(client: client, wsClient: ws),
          ),
        ),
      ),
    );

    // Let initial _fetch() + _pollHealth() + _fetchDirectChannels() complete.
    // Five 500-ms frames mirrors the discord_shell_test.dart pattern that
    // proved reliable under Xvfb.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    // DiscordShellScreen defaults to BoardSelected — KanbanView should be
    // the main pane.
    expect(find.byType(KanbanView), findsOneWidget,
        reason: 'default selection is BoardSelected → KanbanView renders');

    // The task card title should be visible.
    expect(
      find.text('Fix daily-deals price formatting'),
      findsOneWidget,
      reason: 'running task title appears on the kanban card',
    );

    // Tap the card by its widget type — tapping the text is unreliable
    // because the text may render near the members-panel boundary at
    // large viewport widths; the RunningTaskCard widget is always
    // within its own Expanded column.
    await tester.tap(find.byType(RunningTaskCard));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // TaskChannelScreen should now be the main pane.
    expect(find.byType(TaskChannelScreen), findsOneWidget,
        reason: 'tapping the card navigates to TaskChannelScreen');

    // Clean up timers (periodic _refresh + _healthRefresh) before the test
    // harness tears down, avoiding "timer still pending" exceptions.
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
