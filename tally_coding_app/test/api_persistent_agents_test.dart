import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tally_coding_app/api.dart';

void main() {
  test('createPersistentAgent POSTs and returns row', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/persistent_agents');
      expect(req.method, 'POST');
      return http.Response(
        '{"id":7,"name":"nightly","role_name":"Tester","cron_schedule":"0 21 * * *","enabled":true}',
        200, headers: {'content-type':'application/json'},
      );
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.createPersistentAgent(
      workspaceId: 1, name: 'nightly', roleName: 'Tester',
      teamSpec: {'nodes': [], 'edges': []},
      cronSchedule: '0 21 * * *',
    );
    expect(out['id'], 7);
  });

  test('listPersistentAgents returns list', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/persistent_agents');
      expect(req.url.queryParameters['workspace_id'], '1');
      return http.Response('{"persistent_agents":[{"id":1,"name":"a"}]}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.listPersistentAgents(workspaceId: 1);
    expect(out.length, 1);
  });

  test('updatePersistentAgent PATCHes', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/persistent_agents/5');
      expect(req.method, 'PATCH');
      return http.Response('{"id":5,"name":"new"}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.updatePersistentAgent(id: 5, patch: {'name': 'new'});
    expect(out['name'], 'new');
  });

  test('runPersistentAgentNow POSTs to /run_now', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/persistent_agents/5/run_now');
      return http.Response('{"ok":true,"task_id":"abc"}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.runPersistentAgentNow(id: 5);
    expect(out['task_id'], 'abc');
  });

  test('deletePersistentAgent DELETEs', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/persistent_agents/5');
      expect(req.method, 'DELETE');
      return http.Response('{"ok":true}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    await api.deletePersistentAgent(id: 5);
  });
}
