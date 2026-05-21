import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tally_coding_app/api.dart';

void main() {
  test('deleteWorkspace DELETEs', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/workspaces/5');
      expect(req.method, 'DELETE');
      return http.Response('{"ok":true}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://t'), provider: () async => 't', client: mock);
    await api.deleteWorkspace(id: 5);
  });

  test('leaveWorkspace POSTs /workspaces/{id}/leave', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/workspaces/5/leave');
      expect(req.method, 'POST');
      return http.Response('{"ok":true}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://t'), provider: () async => 't', client: mock);
    await api.leaveWorkspace(id: 5);
  });
}
