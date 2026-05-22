// Sprint 53+: Stage 3 — pump DiscordShellScreen (the signed-in shell)
// with mock client + idle WS client.  Verifies the channel rail's
// rendering pipeline works under the real Linux desktop binding
// without going through Clerk auth.
//
// Stage 4 (channel-sync regression) builds on this — same pump, but
// with a REAL client + REAL WS pointed at prod, plus a channel-create
// step that the WebSocket should propagate (and currently doesn't,
// which is the bug we want to lock in).
//
// Run:
//   ./scripts/run-it.sh integration_test/discord_shell_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';

import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/screens/discord_shell.dart';
import 'package:tally_coding_app/services/notifications_ws.dart';
import 'package:tally_coding_app/state/workspace_context.dart';

TallyOrchClient _mockedClient(MockClient mock) => TallyOrchClient(
      baseUrl: Uri.parse('https://tally.pronoic.dev'),
      provider: () async => 't',
      client: mock,
    );

/// Returns a NotificationsWsClient that we deliberately never .connect() on.
/// DiscordShellScreen only triggers state updates when wsClient.onNewMessage
/// fires; an unconnected client is a no-op, which is what Stage 3 wants.
NotificationsWsClient _idleWsClient(TallyOrchClient client) =>
    NotificationsWsClient(
      api: client,
      wsUrl: Uri.parse('wss://tally.pronoic.dev/ws/notifications'),
      bearerProvider: () async => 't',
    );

/// Always responds with the static fixture JSON.  Used so the mock
/// doesn't have to switch on URL paths — DiscordShellScreen's initState
/// fires several GETs (/tasks, /channels, /health, /me/workspaces)
/// before the rail can render.
http.Response _staticJson(String body) =>
    http.Response(body, 200, headers: {'content-type': 'application/json'});

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('DiscordShellScreen renders channel rail under real Linux binding',
      (tester) async {
    final mock = MockClient((req) async {
      final path = req.url.path;
      if (path == '/health') {
        return _staticJson(
          '{"status":"ok","pool_ready":true,"pool_target":1,"pool_joined":1,'
          '"pool_last_error":null,"pool_unhealthy_since_seconds":null,'
          '"pool_circuit_open":false,"tasks_in_flight":false}',
        );
      }
      if (path == '/tasks') return _staticJson('{"tasks":[]}');
      if (path == '/channels') return _staticJson('{"channels":[]}');
      if (path.contains('/me/workspaces')) {
        return _staticJson(
          '{"workspaces":[{"id":1,"name":"admin","role":"owner","created_at":0}]}',
        );
      }
      // Other endpoints (audit-log, persistent_agents, etc.) — return
      // an empty-list / empty-object response so initState doesn't blow up.
      return _staticJson('{}');
    });
    final client = _mockedClient(mock);
    final ws = _idleWsClient(client);

    await tester.pumpWidget(MaterialApp(
      home: WorkspaceContext(
        activeWorkspaceId: 1,
        onChange: (_) {},
        child: DiscordShellScreen(client: client, wsClient: ws),
      ),
    ));
    // Five 500-ms frames — enough for the initial /health + /tasks +
    // /channels fetches to land and the rail to paint.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    expect(find.byType(DiscordShellScreen), findsOneWidget);
    // The rail always renders a #general affordance for the active
    // workspace, even with zero tasks/custom channels.
    expect(
      find.textContaining('general', findRichText: true),
      findsAtLeast(1),
    );
  });
}
