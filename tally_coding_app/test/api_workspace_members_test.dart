import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tally_coding_app/api.dart';

void main() {
  test('listWorkspaceMembers GETs', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/workspaces/1/members');
      return http.Response('{"members":[{"user_id":"admin","member_kind":"human","role":"owner"}]}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.listWorkspaceMembers(workspaceId: 1);
    expect(out.length, 1);
  });

  test('inviteWorkspaceMember POSTs', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/workspaces/1/members');
      expect(req.method, 'POST');
      return http.Response('{"ok":true,"user_id":"bob","role":"member"}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.inviteWorkspaceMember(workspaceId: 1, userId: 'bob', role: 'member');
    expect(out['ok'], true);
  });

  test('removeWorkspaceMember DELETEs', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/workspaces/1/members/bob');
      expect(req.method, 'DELETE');
      return http.Response('{"ok":true}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    await api.removeWorkspaceMember(workspaceId: 1, userId: 'bob');
  });

  test('updateWorkspaceMemberRole PATCHes', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/workspaces/1/members/bob');
      expect(req.method, 'PATCH');
      return http.Response('{"ok":true,"role":"admin"}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.updateWorkspaceMemberRole(workspaceId: 1, userId: 'bob', role: 'admin');
    expect(out['role'], 'admin');
  });
}
