import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/kanban/quick_add_task_modal.dart';

// Minimal Task JSON the mock server returns.
Map<String, dynamic> _taskJson(String description) => {
      'id': 'test-id-1',
      'description': description,
      'status': 'pending',
      'created_at': 0.0,
      'updated_at': 0.0,
    };

Widget _wrap(Widget child) {
  final tokens = themeCatalog[defaultThemeSlug]!.tokens;
  return MaterialApp(
    theme: themeFromTokens(tokens),
    home: Scaffold(body: child),
  );
}

/// Build a [TallyOrchClient] backed by [MockClient].
TallyOrchClient _client(MockClient mock) => TallyOrchClient(
      baseUrl: Uri.parse('http://test'),
      provider: () async => 'token',
      client: mock,
    );

void main() {
  group('QuickAddTaskModal', () {
    testWidgets('renders text field + Cancel + Add buttons', (tester) async {
      final mock = MockClient((_) async => http.Response('{}', 500));
      await tester.pumpWidget(_wrap(QuickAddTaskModal(
        client: _client(mock),
        onCreated: (_) {},
      )));
      expect(find.byType(TextField), findsOneWidget);
      // BrutalButton renders uppercase labels
      expect(find.text('CANCEL'), findsOneWidget);
      expect(find.text('ADD TO BOARD'), findsOneWidget);
    });

    testWidgets('renders NEW TASK label', (tester) async {
      final mock = MockClient((_) async => http.Response('{}', 500));
      await tester.pumpWidget(_wrap(QuickAddTaskModal(
        client: _client(mock),
        onCreated: (_) {},
      )));
      expect(find.text('NEW TASK'), findsOneWidget);
    });

    testWidgets('empty text → tapping Add is a no-op (no HTTP call)', (tester) async {
      var called = false;
      final mock = MockClient((_) async {
        called = true;
        return http.Response('{}', 200);
      });
      await tester.pumpWidget(_wrap(QuickAddTaskModal(
        client: _client(mock),
        onCreated: (_) {},
      )));
      await tester.tap(find.text('ADD TO BOARD'));
      await tester.pump();
      expect(called, isFalse);
    });

    testWidgets('submit calls client.submitTask with text and projectId',
        (tester) async {
      String? capturedDesc;
      String? capturedProjectId;
      final mock = MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        capturedDesc = body['description'] as String?;
        capturedProjectId = body['project_id'] as String?;
        return http.Response(
            jsonEncode(_taskJson(capturedDesc ?? '')), 200,
            headers: {'content-type': 'application/json'});
      });
      await tester.pumpWidget(_wrap(QuickAddTaskModal(
        client: _client(mock),
        projectId: 'proj-42',
        onCreated: (_) {},
      )));
      await tester.enterText(find.byType(TextField), 'ship the deal export');
      await tester.tap(find.text('ADD TO BOARD'));
      await tester.pump(); // start async
      await tester.pump(); // settle
      expect(capturedDesc, 'ship the deal export');
      expect(capturedProjectId, 'proj-42');
    });

    testWidgets('onCreated callback fires with returned Task on success',
        (tester) async {
      Task? created;
      final mock = MockClient((_) async => http.Response(
          jsonEncode(_taskJson('build the thing')), 200,
          headers: {'content-type': 'application/json'}));
      await tester.pumpWidget(_wrap(QuickAddTaskModal(
        client: _client(mock),
        onCreated: (t) => created = t,
      )));
      await tester.enterText(find.byType(TextField), 'build the thing');
      await tester.tap(find.text('ADD TO BOARD'));
      await tester.pump();
      await tester.pump();
      expect(created?.id, 'test-id-1');
      expect(created?.description, 'build the thing');
    });

    testWidgets('shows inline error and does not dismiss on submit failure',
        (tester) async {
      final mock = MockClient((_) async =>
          http.Response('server error', 500));
      await tester.pumpWidget(_wrap(QuickAddTaskModal(
        client: _client(mock),
        onCreated: (_) {},
      )));
      await tester.enterText(find.byType(TextField), 'failing task');
      await tester.tap(find.text('ADD TO BOARD'));
      await tester.pump();
      await tester.pump();
      // Modal is still visible (not dismissed) and shows error text.
      expect(find.textContaining('Could not submit'), findsOneWidget);
      expect(find.text('ADD TO BOARD'), findsOneWidget); // still showing
    });
  });
}
