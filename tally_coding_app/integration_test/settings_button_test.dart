// Sprint 54+: settings-button regression.
//
// User reported tapping the gear icon does nothing on both phone +
// laptop.  Reading the handler in DiscordShellScreen:
//
//   onOpenSettings: () async {
//     final wsId = WorkspaceContext.of(context).activeWorkspaceId;
//     final myWs = await widget.client.listMyWorkspaces();
//     final mine = myWs.where((w) => w['id'] == wsId)... .firstOrNull ?? {};
//     if (mine.isEmpty || !mounted) return;     // <-- silent return
//     nav.push(...);
//   }
//
// The silent return is the suspect: when /me/workspaces doesn't
// include a workspace matching the activeWorkspaceId (stale prefs,
// removed membership, etc.), tapping settings silently does nothing.
//
// This test pumps the happy-path (matching id) — if it passes, the
// bug is the stale-id edge case and the fix is to surface a SnackBar
// + fall back to the first available workspace.  If it fails, the
// wiring itself is broken.
//
// Run:
//   ./scripts/run-it.sh integration_test/settings_button_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';

import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/screens/discord_shell.dart';
import 'package:tally_coding_app/screens/workspace_settings.dart';
import 'package:tally_coding_app/services/notifications_ws.dart';
import 'package:tally_coding_app/state/workspace_context.dart';

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

  testWidgets(
    'tapping the gear icon opens WorkspaceSettingsScreen (matching id)',
    (tester) async {
      // Force wide layout so the rail renders inline (gear icon visible).
      tester.view.physicalSize = const Size(2560, 1600);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final mock = MockClient((req) async {
        final path = req.url.path;
        if (path == '/me/workspaces') {
          // Happy path: workspace 1 IS in the response, matching the
          // WorkspaceContext below.
          return _json(
            '{"workspaces":[{"id":1,"name":"admin","role":"owner","created_at":0}]}',
          );
        }
        if (path == '/health') {
          return _json(
            '{"status":"ok","pool_ready":true,"pool_target":1,"pool_joined":1,'
            '"pool_last_error":null,"pool_unhealthy_since_seconds":null,'
            '"pool_circuit_open":false,"tasks_in_flight":false}',
          );
        }
        if (path == '/tasks') return _json('{"tasks":[]}');
        if (path == '/channels') return _json('{"channels":[]}');
        return _json('{}');
      });
      final client = _client(mock);

      await tester.pumpWidget(MaterialApp(
        home: WorkspaceContext(
          activeWorkspaceId: 1,
          onChange: (_) {},
          child: DiscordShellScreen(client: client, wsClient: _idleWs(client)),
        ),
      ));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }

      // Find the settings IconButton.  Multiple Icons.settings instances
      // could exist (rail header + nested widgets); pick the first
      // that's an Icon child of an IconButton's onPressed pointing at
      // onOpenSettings.  Simplest finder: tap any Icons.settings.
      final gearFinder = find.byIcon(Icons.settings).first;
      expect(gearFinder, findsOneWidget,
          reason: 'gear icon should be present in the wide-layout rail');
      await tester.tap(gearFinder);

      // Let the async listMyWorkspaces + nav.push complete.  runAsync
      // gives the mock HTTP call real-time room.
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(
          const Duration(milliseconds: 100),
        ));
        await tester.pump();
        if (find.byType(WorkspaceSettingsScreen).evaluate().isNotEmpty) break;
      }

      expect(find.byType(WorkspaceSettingsScreen), findsOneWidget,
          reason: 'tapping gear should push WorkspaceSettingsScreen');
    },
  );

  testWidgets(
    'gear tap with stale workspace id (no matching /me/workspaces entry) — silent return demonstrates the user-reported bug',
    (tester) async {
      tester.view.physicalSize = const Size(2560, 1600);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final mock = MockClient((req) async {
        final path = req.url.path;
        if (path == '/me/workspaces') {
          // /me/workspaces returns only workspace 1, but the
          // WorkspaceContext below points at id=999.  This is the
          // stale-prefs scenario.
          return _json(
            '{"workspaces":[{"id":1,"name":"admin","role":"owner","created_at":0}]}',
          );
        }
        if (path == '/health') {
          return _json('{"status":"ok","pool_ready":true,"pool_target":1,'
              '"pool_joined":1,"pool_last_error":null,'
              '"pool_unhealthy_since_seconds":null,"pool_circuit_open":false,'
              '"tasks_in_flight":false}');
        }
        return _json('{}');
      });
      final client = _client(mock);

      await tester.pumpWidget(MaterialApp(
        home: WorkspaceContext(
          activeWorkspaceId: 999, // <-- doesn't match anything in /me/workspaces
          onChange: (_) {},
          child: DiscordShellScreen(client: client, wsClient: _idleWs(client)),
        ),
      ));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }

      final gearFinder = find.byIcon(Icons.settings).first;
      await tester.tap(gearFinder);
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(
          const Duration(milliseconds: 100),
        ));
        await tester.pump();
      }

      // Post-fix: the handler falls back to the first available
      // workspace, shows a SnackBar explaining the mismatch, AND
      // opens settings for that fallback workspace.  Both an open
      // settings screen AND the explanatory SnackBar should be present.
      expect(find.byType(WorkspaceSettingsScreen), findsOneWidget,
          reason: 'falls back to first workspace + opens its settings');
      // Strengthen vs. PR #8 review feedback #5 — verify the screen
      // opened for the FALLBACK workspace, not just any settings.
      final settings = tester.widget<WorkspaceSettingsScreen>(
          find.byType(WorkspaceSettingsScreen));
      expect(settings.workspaceId, 1,
          reason: 'fallback target = first id in /me/workspaces (1)');
      expect(settings.workspaceName, 'admin',
          reason: 'fallback target name matches fixture');
      expect(
        find.textContaining('not in your list'),
        findsOneWidget,
        reason: 'SnackBar should explain the fallback',
      );
    },
  );
}
