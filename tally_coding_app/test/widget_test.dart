import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/screens/discord_shell.dart';

void main() {
  testWidgets('DiscordShellScreen renders the four-column layout', (WidgetTester tester) async {
    final client = TallyOrchClient.fromToken(
      baseUrl: Uri.parse('http://127.0.0.1:65535'),
      token: 'fake',
    );
    await tester.pumpWidget(MaterialApp(home: DiscordShellScreen(client: client)));
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
