import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/widgets/new_channel_modal.dart';

void main() {
  testWidgets('NewChannelModal renders name field + chip groups', (tester) async {
    final mock = MockClient((req) async {
      // listWorkspaceMembers + listPersistentAgents both called on init
      if (req.url.path == '/workspaces/1/members') {
        return http.Response('{"members":[{"user_id":"admin","member_kind":"human","role":"owner"}]}', 200, headers: {'content-type':'application/json'});
      }
      if (req.url.path == '/persistent_agents') {
        return http.Response('{"persistent_agents":[]}', 200, headers: {'content-type':'application/json'});
      }
      return http.Response('{}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      Builder(builder: (ctx) => ElevatedButton(
        onPressed: () => showDialog(context: ctx, builder: (_) => NewChannelModal(client: api, workspaceId: 1)),
        child: const Text('open'),
      )),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('New channel'), findsOneWidget);
    expect(find.textContaining('Humans'), findsOneWidget);
    // "Tally" appears as a section header AND as chip label "Include Tally"
    expect(find.textContaining('Tally'), findsAtLeastNWidgets(1));
    expect(find.textContaining('Persistent agents'), findsOneWidget);
  });
}
