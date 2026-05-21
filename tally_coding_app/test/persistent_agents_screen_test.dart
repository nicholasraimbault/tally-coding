import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/screens/persistent_agents.dart';

void main() {
  TallyOrchClient _mockClient(MockClient mockHttp) {
    return TallyOrchClient(
      baseUrl: Uri.parse('http://test'),
      provider: () async => 't',
      client: mockHttp,
    );
  }

  testWidgets('renders agents from listPersistentAgents', (tester) async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/persistent_agents');
      return http.Response(
        '{"persistent_agents":[{"id":1,"name":"nightly","cron_schedule":"0 21 * * *","enabled":true},{"id":2,"name":"reviewer","cron_schedule":null,"enabled":false}]}',
        200, headers: {'content-type': 'application/json'},
      );
    });
    await tester.pumpWidget(MaterialApp(home: PersistentAgentsScreen(client: _mockClient(mock), workspaceId: 1)));
    await tester.pumpAndSettle();
    expect(find.text('nightly'), findsOneWidget);
    expect(find.text('reviewer'), findsOneWidget);
    expect(find.textContaining('0 21 * * *'), findsOneWidget);
  });

  testWidgets('empty state when no agents', (tester) async {
    final mock = MockClient((req) async => http.Response('{"persistent_agents":[]}', 200, headers: {'content-type': 'application/json'}));
    await tester.pumpWidget(MaterialApp(home: PersistentAgentsScreen(client: _mockClient(mock), workspaceId: 1)));
    await tester.pumpAndSettle();
    expect(find.textContaining('No persistent agents'), findsOneWidget);
  });
}
