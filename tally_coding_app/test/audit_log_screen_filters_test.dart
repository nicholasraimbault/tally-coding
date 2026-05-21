import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/screens/audit_log.dart';

void main() {
  testWidgets('selecting kind filter and applying reloads with kind param', (tester) async {
    String? receivedKind;
    int callCount = 0;
    final mock = MockClient((req) async {
      callCount++;
      receivedKind = req.url.queryParameters['kind'];
      return http.Response('{"entries":[]}', 200,
        headers: {'content-type': 'application/json'});
    });
    final client = TallyOrchClient(
      baseUrl: Uri.parse('http://x.test'),
      provider: () async => 'tok',
      client: mock,
    );

    await tester.pumpWidget(MaterialApp(
      home: AuditLogScreen(client: client, workspaceId: 1, workspaceName: 'Test WS'),
    ));
    await tester.pumpAndSettle();
    expect(callCount, 1);  // initial load
    expect(receivedKind, isNull);  // no filter yet

    // Expand the Filters tile
    await tester.tap(find.text('Filters'));
    await tester.pumpAndSettle();

    // Open the kind dropdown
    await tester.tap(find.byType(DropdownButtonFormField<String?>));
    await tester.pumpAndSettle();

    // Pick channel_created — scroll into view first because the list is long
    final channelCreatedFinder = find.text('channel_created').last;
    await tester.ensureVisible(channelCreatedFinder);
    await tester.pumpAndSettle();
    await tester.tap(channelCreatedFinder, warnIfMissed: false);
    await tester.pumpAndSettle();

    // Apply
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(callCount, 2);
    expect(receivedKind, 'channel_created');
  });
}
