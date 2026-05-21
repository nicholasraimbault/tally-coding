import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tally_coding_app/api.dart';

void main() {
  group('transferOwnership', () {
    test('POSTs the correct body and returns server payload', () async {
      late http.Request capturedReq;
      final mock = MockClient((req) async {
        capturedReq = req as http.Request;
        return http.Response('{"ok":true,"new_owner":"user_bob"}', 200,
            headers: {'content-type': 'application/json'});
      });
      final client = TallyOrchClient(
        baseUrl: Uri.parse('http://x.test'),
        provider: () async => 'tok',
        client: mock,
      );
      final result = await client.transferOwnership(workspaceId: 7, newOwnerUserId: 'user_bob');
      expect(capturedReq.method, 'POST');
      expect(capturedReq.url.toString(), 'http://x.test/workspaces/7/transfer-ownership');
      expect(jsonDecode(capturedReq.body), {'new_owner_user_id': 'user_bob'});
      expect(result['new_owner'], 'user_bob');
    });

    test('non-200 throws', () async {
      final mock = MockClient((req) async => http.Response('forbidden', 403));
      final client = TallyOrchClient(
        baseUrl: Uri.parse('http://x.test'),
        provider: () async => 'tok',
        client: mock,
      );
      expect(
        () => client.transferOwnership(workspaceId: 7, newOwnerUserId: 'user_bob'),
        throwsA(isA<Exception>()),
      );
    });
  });
}
