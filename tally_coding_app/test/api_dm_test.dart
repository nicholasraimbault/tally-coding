import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tally_coding_app/api.dart';

void main() {
  test('openDmChannel POSTs target', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/channels/dm');
      expect(req.method, 'POST');
      return http.Response('{"id":42,"kind":"dm","name":"admin-tally"}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.openDmChannel(targetKind: 'tally');
    expect(out['id'], 42);
    expect(out['kind'], 'dm');
  });
}
