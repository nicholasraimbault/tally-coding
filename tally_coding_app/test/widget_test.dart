import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/screens/discord_shell.dart';
import 'package:tally_coding_app/services/notifications_ws.dart';
import 'package:tally_coding_app/state/workspace_context.dart';

void main() {
  testWidgets('DiscordShellScreen renders the four-column layout', (WidgetTester tester) async {
    final client = TallyOrchClient.fromToken(
      baseUrl: Uri.parse('http://127.0.0.1:65535'),
      token: 'fake',
    );
    // Sprint 47 B7: wsClient is now required; pass a disconnected stub.
    final wsClient = NotificationsWsClient(
      api: client,
      wsUrl: Uri.parse('ws://127.0.0.1:65535/ws/notifications'),
      bearerProvider: () async => 'fake',
    );
    // Sprint 50 B3: DiscordShellScreen now reads WorkspaceContext.
    await tester.pumpWidget(WorkspaceContext(
      activeWorkspaceId: 1,
      onChange: (_) {},
      child: MaterialApp(
        home: DiscordShellScreen(client: client, wsClient: wsClient),
      ),
    ));
    // Server rail label
    expect(find.text('T'), findsOneWidget);
    // Channel list header
    expect(find.text('My Team'), findsOneWidget);
    // #general channel
    expect(find.text('general'), findsOneWidget);
    // Tally as a member on #general
    expect(find.text('Tally'), findsOneWidget);
  });
}
