import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tally_coding_app/api.dart';

void main() {
  group('listAuditLog filters', () {
    test('passes kind+actor as query params', () async {
      String? capturedKind;
      String? capturedActor;
      final mock = MockClient((req) async {
        capturedKind = req.url.queryParameters['kind'];
        capturedActor = req.url.queryParameters['actor_user_id'];
        return http.Response('{"entries":[]}', 200,
            headers: {'content-type': 'application/json'});
      });
      final client = TallyOrchClient(
        baseUrl: Uri.parse('http://x.test'),
        provider: () async => 'tok',
        client: mock,
      );
      await client.listAuditLog(
        workspaceId: 7,
        kind: 'channel_created',
        actorUserId: 'user_alice',
      );
      expect(capturedKind, 'channel_created');
      expect(capturedActor, 'user_alice');
    });

    test('passes since+until as query params', () async {
      String? capturedSince;
      String? capturedUntil;
      final mock = MockClient((req) async {
        capturedSince = req.url.queryParameters['since'];
        capturedUntil = req.url.queryParameters['until'];
        return http.Response('{"entries":[]}', 200,
            headers: {'content-type': 'application/json'});
      });
      final client = TallyOrchClient(
        baseUrl: Uri.parse('http://x.test'),
        provider: () async => 'tok',
        client: mock,
      );
      await client.listAuditLog(workspaceId: 7, since: 1700000000, until: 1700100000);
      expect(capturedSince, '1700000000.0');
      expect(capturedUntil, '1700100000.0');
    });
  });
}
