import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tally_coding_app/api.dart';

void main() {
  test('listAuditLog GETs without before_id', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/workspaces/1/audit-log');
      expect(req.url.queryParameters['limit'], '50');
      expect(req.url.queryParameters['before_id'], null);
      return http.Response(
        '{"entries":[{"id":7,"kind":"workspace_created","actor_user_id":"admin","payload":{}}]}',
        200, headers: {'content-type':'application/json'},
      );
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://t'), provider: () async => 't', client: mock);
    final entries = await api.listAuditLog(workspaceId: 1, limit: 50);
    expect(entries.length, 1);
    expect(entries[0]['kind'], 'workspace_created');
  });

  test('listAuditLog GETs with before_id', () async {
    final mock = MockClient((req) async {
      expect(req.url.queryParameters['before_id'], '42');
      return http.Response('{"entries":[]}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://t'), provider: () async => 't', client: mock);
    final entries = await api.listAuditLog(workspaceId: 1, beforeId: 42);
    expect(entries, isEmpty);
  });
}
