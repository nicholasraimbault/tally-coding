import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/screens/discord_shell.dart';
import 'package:tally_coding_app/services/notifications_ws.dart';
import 'package:tally_coding_app/state/workspace_context.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/sidebar/sidebar_shell.dart';
import 'package:tally_coding_app/widgets/server_rail.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/bottom_sheet_controller.dart';

TallyOrchClient _makeClient() {
  final mock = MockClient((req) async {
    // Workspace list
    if (req.url.path.contains('/me/workspaces')) {
      return http.Response(
        '{"workspaces":[{"id":1,"name":"test","role":"admin"}]}',
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    // Tasks
    if (req.url.path.contains('/tasks')) {
      return http.Response('[]', 200,
          headers: {'content-type': 'application/json'});
    }
    // Channels
    if (req.url.path.contains('/channels')) {
      return http.Response('{"channels":[]}', 200,
          headers: {'content-type': 'application/json'});
    }
    // Health
    if (req.url.path.contains('/health')) {
      return http.Response(
        '{"pool_ready":true,"pool_target":0,"pool_joined":0}',
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response('{}', 404,
        headers: {'content-type': 'application/json'});
  });
  return TallyOrchClient(
    baseUrl: Uri.parse('http://localhost'),
    provider: () async => 'test-token',
    client: mock,
  );
}

NotificationsWsClient _makeWsClient(TallyOrchClient client) {
  return NotificationsWsClient(
    api: client,
    wsUrl: Uri.parse('ws://localhost/ws/notifications'),
    bearerProvider: () async => 'test-token',
  );
}

Widget _wideApp() {
  SharedPreferences.setMockInitialValues({});
  final tokens = themeCatalog[defaultThemeSlug]!.tokens;
  final client = _makeClient();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => BottomSheetController()),
    ],
    child: WorkspaceContext(
      activeWorkspaceId: 1,
      onChange: (_) {},
      child: MaterialApp(
        theme: themeFromTokens(tokens),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(1440, 900)),
          // SizedBox ensures LayoutBuilder in DiscordShellScreen gets 1440px width
          child: SizedBox(
            width: 1440,
            height: 900,
            child: DiscordShellScreen(
              client: client,
              wsClient: _makeWsClient(client),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('DiscordShellScreen wide layout', () {
    testWidgets('shows SidebarShell, not ServerRail', (tester) async {
      // Set the test surface to 1440×900 so LayoutBuilder sees a wide constraint.
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_wideApp());
      await tester.pump(); // let initState complete
      expect(find.byType(SidebarShell), findsOneWidget);
      expect(find.byType(ServerRail), findsNothing);
    });

    testWidgets('sidebar shows loaded workspace name after async load',
        (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_wideApp());
      await tester.pump();
      // Allow async _loadActiveWorkspaceName() to complete
      await tester.pumpAndSettle();
      expect(find.text('test'), findsOneWidget);
    });
  });
}
