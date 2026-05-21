import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tally_coding_app/api.dart';

void main() {
  test('approveTask POSTs /tasks/{id}/approve', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/tasks/abc/approve');
      expect(req.method, 'POST');
      return http.Response('{"id":"abc","status":"pending"}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.approveTask(taskId: 'abc');
    expect(out['status'], 'pending');
  });

  test('updateTaskTeamSpec PATCHes /tasks/{id}/team_spec', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/tasks/abc/team_spec');
      expect(req.method, 'PATCH');
      return http.Response('{"id":"abc","status":"proposed","team_spec":{"nodes":[],"edges":[]}}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.updateTaskTeamSpec(taskId: 'abc', teamSpec: {'nodes':[],'edges':[]});
    expect(out['status'], 'proposed');
  });

  test('cancelTask POSTs /tasks/{id}/cancel', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/tasks/abc/cancel');
      expect(req.method, 'POST');
      return http.Response('{"id":"abc","status":"cancelled"}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.cancelTask(taskId: 'abc');
    expect(out['status'], 'cancelled');
  });
}
