import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/screens/workspace_settings.dart';
import 'package:tally_coding_app/theme/theme.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  TallyOrchClient _mockClient(MockClient mockHttp) =>
      TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mockHttp);

  Future<Widget> _wrap(Widget child) async {
    final controller = ThemeController();
    await controller.load();
    return ChangeNotifierProvider.value(
      value: controller,
      child: MaterialApp(
        theme: themeFromTokens(controller.activeEntry.tokens),
        home: child,
      ),
    );
  }

  testWidgets('renders branding section + member list', (tester) async {
    final mock = MockClient((req) async {
      if (req.url.path == '/workspaces/1/members') {
        return http.Response(
          '{"members":[{"user_id":"admin","member_kind":"human","role":"owner"},{"user_id":"bob","member_kind":"human","role":"member"}]}',
          200, headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 200, headers: {'content-type': 'application/json'});
    });
    await tester.pumpWidget(await _wrap(WorkspaceSettingsScreen(
      client: _mockClient(mock),
      workspaceId: 1,
      workspaceName: 'Test WS',
      callerRole: 'owner',
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('Branding'), findsOneWidget);
    expect(find.textContaining('admin'), findsOneWidget);
    expect(find.textContaining('bob'), findsOneWidget);
    expect(find.textContaining('Activity log'), findsOneWidget);
    // Scroll to reveal Danger zone (pushed below fold by the Appearance section)
    await tester.drag(find.byType(ListView), const Offset(0, -1200));
    await tester.pumpAndSettle();
    expect(find.textContaining('Danger zone'), findsOneWidget);
  });

  testWidgets('owner sees Delete workspace button', (tester) async {
    final mock = MockClient((req) async => http.Response('{"members":[]}', 200, headers: {'content-type':'application/json'}));
    await tester.pumpWidget(await _wrap(WorkspaceSettingsScreen(
      client: _mockClient(mock),
      workspaceId: 1,
      workspaceName: 'x',
      callerRole: 'owner',
    )));
    await tester.pumpAndSettle();
    // Scroll to reveal Delete workspace (pushed below fold by the Appearance section)
    await tester.drag(find.byType(ListView), const Offset(0, -1200));
    await tester.pumpAndSettle();
    expect(find.text('Delete workspace'), findsOneWidget);
  });

  testWidgets('non-owner sees Leave workspace button (not Delete)', (tester) async {
    final mock = MockClient((req) async => http.Response('{"members":[]}', 200, headers: {'content-type':'application/json'}));
    await tester.pumpWidget(await _wrap(WorkspaceSettingsScreen(
      client: _mockClient(mock),
      workspaceId: 1,
      workspaceName: 'x',
      callerRole: 'member',
    )));
    await tester.pumpAndSettle();
    expect(find.text('Leave workspace', skipOffstage: false), findsOneWidget);
    expect(find.text('Delete workspace', skipOffstage: false), findsNothing);
  });

  testWidgets('owner sees Transfer ownership button', (tester) async {
    final mock = MockClient((req) async => http.Response('{"members":[]}', 200, headers: {'content-type':'application/json'}));
    await tester.pumpWidget(await _wrap(WorkspaceSettingsScreen(
      client: _mockClient(mock),
      workspaceId: 1,
      workspaceName: 'x',
      callerRole: 'owner',
    )));
    await tester.pumpAndSettle();
    expect(find.text('Transfer ownership', skipOffstage: false), findsOneWidget);
  });

  testWidgets('renders Archived channels section with archived channels', (tester) async {
    final mock = MockClient((req) async {
      if (req.url.path == '/workspaces/1/members') {
        return http.Response('{"members":[]}', 200, headers: {'content-type':'application/json'});
      }
      if (req.url.path == '/channels') {
        return http.Response(
          '{"channels":[{"id":7,"workspace_id":1,"kind":"custom","name":"old-ops","archived_at":1700000000.0}]}',
          200, headers: {'content-type':'application/json'},
        );
      }
      return http.Response('{}', 200, headers: {'content-type':'application/json'});
    });
    await tester.pumpWidget(await _wrap(WorkspaceSettingsScreen(
      client: TallyOrchClient(baseUrl: Uri.parse('http://t'), provider: () async => 't', client: mock),
      workspaceId: 1,
      workspaceName: 'x',
      callerRole: 'owner',
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('Archived channels'), findsAtLeastNWidgets(1));
    expect(find.textContaining('old-ops'), findsOneWidget);
    expect(find.text('Unarchive'), findsOneWidget);
  });
}
