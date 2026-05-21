import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tally_coding_app/api.dart';

void main() {
  test('createWorkspace POSTs and returns row', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/workspaces');
      expect(req.method, 'POST');
      return http.Response('{"id":7,"name":"My WS","role":"owner"}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.createWorkspace(name: 'My WS');
    expect(out['id'], 7);
    expect(out['role'], 'owner');
  });

  test('listMyWorkspaces returns list', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/me/workspaces');
      return http.Response('{"workspaces":[{"id":1,"name":"a","role":"owner"}]}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.listMyWorkspaces();
    expect(out.length, 1);
  });

  test('updateWorkspace PATCHes', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/workspaces/5');
      expect(req.method, 'PATCH');
      return http.Response('{"id":5}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.updateWorkspace(id: 5, patch: {'name': 'new'});
    expect(out['id'], 5);
  });
}
