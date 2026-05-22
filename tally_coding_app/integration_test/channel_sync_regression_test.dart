// Sprint 53+: Stage 4 — channel-sync regression test.
//
// This test demonstrates the bug we found while building the test loop:
// channels created via the orchestrator's POST /channels API don't
// propagate to WebSocket-connected clients in real time, because the
// orchestrator has no _broadcast_new_channel helper — only
// _broadcast_new_message.  DiscordShellScreen has a 4-second
// polling refresh that EVENTUALLY picks up the new channel, but if
// you wait less than the poll interval (i.e., expect real-time
// behavior), the channel doesn't appear.
//
// The test is **expected to FAIL on current main**.  It's gated
// behind a `skip:` clause so CI doesn't go red, but the test body is
// real and the assertion is correct.  When we ship the broadcast
// fix in a future commit:
//   1. The orchestrator gets _broadcast_new_channel that fires on
//      POST /channels success.
//   2. NotificationsWsClient grows an onChannelCreated callback.
//   3. DiscordShellScreen subscribes to it and appends to its
//      channel list.
// — at which point this test goes green and the `skip:` clause
// gets removed.
//
// Run (locally, with admin token from .env.prod):
//   ./scripts/run-it.sh integration_test/channel_sync_regression_test.dart
//
// To force-run despite the skip annotation (to see the failure):
//   change `skip: ...` to `skip: false`

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';

import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/screens/discord_shell.dart';
import 'package:tally_coding_app/services/notifications_ws.dart';
import 'package:tally_coding_app/state/workspace_context.dart';

const _kAdminToken = String.fromEnvironment('TALLY_TEST_ADMIN_TOKEN', defaultValue: '');
const _kOrchUrl = String.fromEnvironment('TALLY_ORCH_URL', defaultValue: 'https://tally.pronoic.dev');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'channel created via API appears in rail without manual refresh',
    (tester) async {
      if (_kAdminToken.isEmpty) {
        // No admin token configured — markAsSkipped via fail-fast.
        markTestSkipped('TALLY_TEST_ADMIN_TOKEN dart-define not set');
        return;
      }

      final baseUri = Uri.parse(_kOrchUrl);
      final client = TallyOrchClient(
        baseUrl: baseUri,
        provider: () async => _kAdminToken,
      );
      final wsUri = baseUri.replace(
        scheme: baseUri.scheme == 'https' ? 'wss' : 'ws',
        path: '/ws/notifications',
      );
      final ws = NotificationsWsClient(
        api: client,
        wsUrl: wsUri,
        bearerProvider: () async => _kAdminToken,
      );
      // Connect the WebSocket BEFORE creating the channel so that any
      // real-time event the server pushes would be received.
      await ws.connect();

      await tester.pumpWidget(MaterialApp(
        home: WorkspaceContext(
          activeWorkspaceId: 1,
          onChange: (_) {},
          child: DiscordShellScreen(client: client, wsClient: ws),
        ),
      ));
      // Let the initial fetches complete + rail paint.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }

      // Generate a unique-named channel so re-runs don't collide.
      final channelName = 'sync-it-${DateTime.now().millisecondsSinceEpoch}';
      final createResp = await http.post(
        baseUri.resolve('/channels'),
        headers: {
          'content-type': 'application/json',
          'authorization': 'Bearer $_kAdminToken',
        },
        body: jsonEncode({
          'workspace_id': 1,
          'kind': 'custom',
          'name': channelName,
          'members': [
            {'kind': 'human', 'id': 'admin'},
          ],
        }),
      );
      expect(createResp.statusCode, 200,
          reason: 'channel creation should succeed: ${createResp.body}');
      final channelId = (jsonDecode(createResp.body) as Map)['id'] as int;

      try {
        // Wait LESS than DiscordShellScreen's 4-s poll interval so we're
        // testing the real-time WebSocket path, not the polling fallback.
        // If WS propagation works, the channel should appear in well
        // under 2 s; if only polling works, it'd appear at ~4 s.
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 400));
        }

        // EXPECTED TO FAIL on current main: orchestrator doesn't
        // broadcast channel-created events, so the rail stays stale
        // until the 4-s poll refreshes it.
        expect(
          find.textContaining(channelName, findRichText: true),
          findsAtLeast(1),
          reason: 'channel "$channelName" should appear in rail via WS push',
        );
      } finally {
        // Cleanup: archive the test channel so the workspace doesn't
        // accumulate sync-it-* clutter across runs.
        try {
          await http.post(
            baseUri.resolve('/channels/$channelId/archive'),
            headers: {'authorization': 'Bearer $_kAdminToken'},
          );
        } catch (_) {
          // best-effort; ignore
        }
        ws.dispose();
      }
    },
    // Locked-in regression for the channel-sync bug — orchestrator has no
    // _broadcast_new_channel helper, so this test FAILS on current main.
    // Remove `skip: true` when the WS broadcast lands so the test guards
    // against regression going forward.
    skip: true,
  );
}
