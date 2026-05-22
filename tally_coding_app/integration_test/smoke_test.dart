// Sprint 53+: integration_test scaffold.
//
// Goal of THIS file: prove the integration_test runner works on Linux
// desktop under Xvfb + dbus-run-session.  Once green, we'll add more
// tests that exercise the real Tally app.
//
// We deliberately do NOT boot lib/main.dart here.  The real app boots
// the Clerk SDK + opens a WebSocket on cold start, both of which read
// stale state from shared_preferences/credentials when present on the
// host machine — making the test pick up the developer's real signed-in
// session and fail with "websocket not upgraded" errors that have
// nothing to do with the test's actual assertions.
//
// Build-up plan:
//   1. (this file) Verify integration_test runner + Xvfb + dbus path works
//   2. Add a "render specific screen in isolation" test (pumpWidget with
//      mocked dependencies — like Sprint 52's widget tests, but in
//      integration_test so we exercise real platform channels)
//   3. Add an auth bypass (admin token via dart-define) for tests that
//      need a logged-in shell without going through Clerk
//   4. Add the channel-sync regression test (covers the bug we found
//      where channels created via API don't propagate to clients
//      without a manual refresh)
//
// Run:
//   ./scripts/run-it.sh
// or:
//   ./scripts/run-it.sh integration_test/smoke_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'integration_test runner works (minimal MaterialApp)',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: Text('integration_test ok')),
          ),
        ),
      );
      expect(find.text('integration_test ok'), findsOneWidget);
    },
  );
}
