// Sprint 53+: Stage 2 — pump real Tally screens with mock clients
// under the real Linux desktop binding.
//
// Why this exists: the widget tests in test/ exercise the same widget
// tree but run with TestWidgetsFlutterBinding (a faked Skia + no real
// platform).  Moving the same pumpWidget assertions into
// integration_test/ confirms the screens render correctly on the real
// GTK + Mesa pipeline, real Flutter engine, real Dart isolate.  When
// these go red we know it's a Linux-desktop-specific rendering issue,
// not a generic widget-tree bug.
//
// Run:
//   ./scripts/run-it.sh integration_test/screens_smoke_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';

import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/screens/audit_log.dart';

TallyOrchClient _mockClient(MockClient mock) => TallyOrchClient(
      baseUrl: Uri.parse('http://t'),
      provider: () async => 't',
      client: mock,
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('AuditLogScreen renders entries on real Linux desktop', (tester) async {
    final mock = MockClient((req) async => http.Response(
          '{"entries":[{"id":1,"kind":"workspace_created","actor_user_id":"admin","payload":{"name":"My WS"},"created_at":1700000000.0}]}',
          200,
          headers: {'content-type': 'application/json'},
        ));
    await tester.pumpWidget(MaterialApp(
      home: AuditLogScreen(
        client: _mockClient(mock),
        workspaceId: 1,
        workspaceName: 'My WS',
      ),
    ));
    // Pump 3 frames over 1 s — enough for the initial fetch + entries
    // to render, but without pumpAndSettle (which hangs on indefinite
    // animations).
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.byType(AuditLogScreen), findsOneWidget);
    expect(find.textContaining('admin'), findsWidgets);
    expect(find.textContaining('workspace_created'), findsOneWidget);
  });

  testWidgets('AuditLogScreen renders empty state when no entries', (tester) async {
    final mock = MockClient((req) async => http.Response(
          '{"entries":[]}',
          200,
          headers: {'content-type': 'application/json'},
        ));
    await tester.pumpWidget(MaterialApp(
      home: AuditLogScreen(
        client: _mockClient(mock),
        workspaceId: 1,
        workspaceName: 'WS',
      ),
    ));
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.textContaining('No activity'), findsOneWidget);
  });
}
