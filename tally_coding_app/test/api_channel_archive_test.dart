import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tally_coding_app/api.dart';

void main() {
  test('archiveChannel POSTs /channels/{id}/archive', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/channels/7/archive');
      expect(req.method, 'POST');
      return http.Response('{"ok":true}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://t'), provider: () async => 't', client: mock);
    await api.archiveChannel(channelId: 7);
  });

  test('unarchiveChannel POSTs /channels/{id}/unarchive', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/channels/7/unarchive');
      return http.Response('{"ok":true}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://t'), provider: () async => 't', client: mock);
    await api.unarchiveChannel(channelId: 7);
  });
}
