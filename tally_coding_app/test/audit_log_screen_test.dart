import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/screens/audit_log.dart';

void main() {
  TallyOrchClient _mock(MockClient http) =>
      TallyOrchClient(baseUrl: Uri.parse('http://t'), provider: () async => 't', client: http);

  testWidgets('renders entries with humanized summaries', (tester) async {
    final mock = MockClient((req) async {
      return http.Response(
        '{"entries":[{"id":3,"kind":"workspace_created","actor_user_id":"admin","payload":{"name":"My WS"},"created_at":1700000000.0},'
        '{"id":2,"kind":"member_invited","actor_user_id":"admin","payload":{"user_id":"bob","role":"member"},"created_at":1700000001.0},'
        '{"id":1,"kind":"channel_created","actor_user_id":"admin","payload":{"channel_id":5,"kind":"custom","name":"ops"},"created_at":1700000002.0}]}',
        200, headers: {'content-type':'application/json'},
      );
    });
    await tester.pumpWidget(MaterialApp(home: AuditLogScreen(
      client: _mock(mock), workspaceId: 1, workspaceName: 'My WS',
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('admin'), findsWidgets);
    expect(find.textContaining('workspace_created'), findsOneWidget);
    expect(find.textContaining('bob'), findsOneWidget);
    expect(find.textContaining('ops'), findsOneWidget);
  });

  testWidgets('empty state when no entries', (tester) async {
    final mock = MockClient((req) async {
      return http.Response('{"entries":[]}', 200, headers: {'content-type':'application/json'});
    });
    await tester.pumpWidget(MaterialApp(home: AuditLogScreen(
      client: _mock(mock), workspaceId: 1, workspaceName: 'WS',
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('No activity'), findsOneWidget);
  });

  testWidgets('renders Load more tile when first page is full', (tester) async {
    // Page size 50; return exactly 50 entries so the "Load more" tile appears
    final mock = MockClient((req) async {
      final entries = [
        for (int i = 50; i > 0; i--)
          '{"id":$i,"kind":"member_invited","actor_user_id":"admin","payload":{"user_id":"u$i","role":"member"},"created_at":1700000000.0}',
      ].join(',');
      return http.Response('{"entries":[$entries]}', 200, headers: {'content-type':'application/json'});
    });
    await tester.pumpWidget(MaterialApp(home: AuditLogScreen(
      client: _mock(mock), workspaceId: 1, workspaceName: 'WS',
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('Load more'), findsOneWidget);
  });
}
