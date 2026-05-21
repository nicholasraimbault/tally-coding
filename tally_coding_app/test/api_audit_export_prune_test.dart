import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tally_coding_app/api.dart';

void main() {
  group('exportAuditLogCsv', () {
    test('GETs the export URL and returns raw CSV text', () async {
      late Uri capturedUrl;
      final mock = MockClient((req) async {
        capturedUrl = req.url;
        return http.Response('"id"\n"1"\n', 200,
            headers: {'content-type': 'text/csv'});
      });
      final client = TallyOrchClient(
        baseUrl: Uri.parse('http://x.test'),
        provider: () async => 'tok',
        client: mock,
      );
      final csv = await client.exportAuditLogCsv(workspaceId: 7, kind: 'member_removed');
      expect(capturedUrl.path, '/workspaces/7/audit-log/export');
      expect(capturedUrl.queryParameters['kind'], 'member_removed');
      expect(csv, '"id"\n"1"\n');
    });

    test('no filters → no query string', () async {
      late Uri capturedUrl;
      final mock = MockClient((req) async {
        capturedUrl = req.url;
        return http.Response('"id"\n', 200);
      });
      final client = TallyOrchClient(
        baseUrl: Uri.parse('http://x.test'),
        provider: () async => 'tok',
        client: mock,
      );
      await client.exportAuditLogCsv(workspaceId: 7);
      expect(capturedUrl.toString(), 'http://x.test/workspaces/7/audit-log/export');
      expect(capturedUrl.hasQuery, isFalse);
    });
  });

  group('pruneAuditLog', () {
    test('POSTs older_than_days and returns deleted count', () async {
      late http.Request capturedReq;
      final mock = MockClient((req) async {
        capturedReq = req as http.Request;
        return http.Response('{"ok":true,"deleted":42}', 200,
            headers: {'content-type': 'application/json'});
      });
      final client = TallyOrchClient(
        baseUrl: Uri.parse('http://x.test'),
        provider: () async => 'tok',
        client: mock,
      );
      final result = await client.pruneAuditLog(workspaceId: 7, olderThanDays: 90);
      expect(capturedReq.method, 'POST');
      expect(capturedReq.url.path, '/workspaces/7/audit-log/prune');
      expect(jsonDecode(capturedReq.body), {'older_than_days': 90});
      expect(result['deleted'], 42);
    });
  });
}
