import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/screens/workspace_settings.dart';

void main() {
  TallyOrchClient _mockClient(MockClient mockHttp) =>
      TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mockHttp);

  testWidgets('renders branding section + member list', (tester) async {
    final mock = MockClient((req) async {
      if (req.url.path == '/workspaces/1/members') {
        return http.Response(
          '{"members":[{"user_id":"admin","member_kind":"human","role":"owner"},{"user_id":"bob","member_kind":"human","role":"member"}]}',
          200, headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 200, headers: {'content-type': 'application/json'});
    });
    await tester.pumpWidget(MaterialApp(home: WorkspaceSettingsScreen(
      client: _mockClient(mock),
      workspaceId: 1,
      workspaceName: 'Test WS',
      callerRole: 'owner',
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('Branding'), findsOneWidget);
    expect(find.textContaining('admin'), findsOneWidget);
    expect(find.textContaining('bob'), findsOneWidget);
    expect(find.textContaining('Danger zone'), findsOneWidget);
  });

  testWidgets('owner sees Delete workspace button', (tester) async {
    final mock = MockClient((req) async => http.Response('{"members":[]}', 200, headers: {'content-type':'application/json'}));
    await tester.pumpWidget(MaterialApp(home: WorkspaceSettingsScreen(
      client: _mockClient(mock),
      workspaceId: 1,
      workspaceName: 'x',
      callerRole: 'owner',
    )));
    await tester.pumpAndSettle();
    expect(find.text('Delete workspace'), findsOneWidget);
  });

  testWidgets('non-owner sees Leave workspace button (not Delete)', (tester) async {
    final mock = MockClient((req) async => http.Response('{"members":[]}', 200, headers: {'content-type':'application/json'}));
    await tester.pumpWidget(MaterialApp(home: WorkspaceSettingsScreen(
      client: _mockClient(mock),
      workspaceId: 1,
      workspaceName: 'x',
      callerRole: 'member',
    )));
    await tester.pumpAndSettle();
    expect(find.text('Leave workspace'), findsOneWidget);
    expect(find.text('Delete workspace'), findsNothing);
  });
}
