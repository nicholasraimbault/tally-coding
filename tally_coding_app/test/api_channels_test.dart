import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tally_coding_app/api.dart';

void main() {
  test('listChannels returns channels list', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/channels');
      expect(req.url.queryParameters['workspace_id'], '1');
      return http.Response(
        '{"channels":[{"id":1,"workspace_id":1,"kind":"general","name":"general","task_id":null,"persistent_agent_id":null,"auto_jump_in_for_tally":false,"created_at":0,"archived_at":null}]}',
        200, headers: {'content-type':'application/json'},
      );
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.listChannels(workspaceId: 1);
    expect(out.length, 1);
    expect(out[0]['kind'], 'general');
  });

  test('postMessage sends text + returns server row', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/channels/5/messages');
      expect(req.method, 'POST');
      return http.Response(
        '{"id":42,"channel_id":5,"author_kind":"human","author_user_id":"admin","author_agent_id":null,"kind":"text","payload_json":"{\\"text\\":\\"hi\\"}","reply_to_id":null,"created_at":1,"edited_at":null}',
        200, headers: {'content-type':'application/json'},
      );
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.postMessage(channelId: 5, text: 'hi');
    expect(out['id'], 42);
    expect(out['kind'], 'text');
  });

  test('getMessages with since_id passes through query', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/channels/5/messages');
      expect(req.url.queryParameters['since_id'], '100');
      return http.Response(
        '{"channel_id":5,"messages":[]}',
        200, headers: {'content-type':'application/json'},
      );
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.getMessages(channelId: 5, sinceId: 100);
    expect(out.length, 0);
  });
}
