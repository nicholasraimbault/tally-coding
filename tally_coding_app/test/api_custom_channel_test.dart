import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tally_coding_app/api.dart';

void main() {
  test('createCustomChannel POSTs', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/channels');
      expect(req.method, 'POST');
      return http.Response('{"id":42,"kind":"custom","name":"ops"}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.createCustomChannel(
      workspaceId: 1, name: 'ops',
      members: [{'kind': 'human', 'id': 'admin'}, {'kind': 'tally'}],
    );
    expect(out['id'], 42);
  });

  test('addChannelMember POSTs', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/channels/42/members');
      expect(req.method, 'POST');
      return http.Response('{"ok":true}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.addChannelMember(channelId: 42, memberKind: 'human', userId: 'bob');
    expect(out['ok'], true);
  });

  test('removeChannelMember DELETEs', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/channels/42/members/bob');
      expect(req.method, 'DELETE');
      return http.Response('{"ok":true}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    await api.removeChannelMember(channelId: 42, userId: 'bob');
  });
}
