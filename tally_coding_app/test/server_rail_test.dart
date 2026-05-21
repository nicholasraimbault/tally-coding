import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/widgets/server_rail.dart';

void main() {
  testWidgets('ServerRail renders workspace icons from listMyWorkspaces', (tester) async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/me/workspaces');
      return http.Response(
        '{"workspaces":[{"id":1,"name":"Personal","role":"owner"},{"id":2,"name":"Team","role":"member"}]}',
        200, headers: {'content-type':'application/json'},
      );
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://t'), provider: () async => 't', client: mock);
    final selectedIds = <int>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      Row(children: [
        ServerRail(client: api, activeWorkspaceId: 1, onSelect: selectedIds.add),
        const Expanded(child: SizedBox()),
      ]),
    )));
    await tester.pumpAndSettle();
    expect(find.text('P'), findsOneWidget);
    expect(find.text('T'), findsOneWidget);
  });
}
