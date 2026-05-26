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
import 'package:tally_coding_app/widgets/bottom_sheet/bottom_sheet_controller.dart';

TallyOrchClient _makeClient() {
  final mock = MockClient((req) async {
    if (req.url.path.contains('/me/workspaces')) {
      return http.Response(
        '{"workspaces":[{"id":1,"name":"test","role":"admin"}]}',
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (req.url.path.contains('/tasks')) {
      return http.Response('[]', 200,
          headers: {'content-type': 'application/json'});
    }
    if (req.url.path.contains('/channels')) {
      return http.Response('{"channels":[]}', 200,
          headers: {'content-type': 'application/json'});
    }
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

Widget _app({required double width}) {
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
        home: DiscordShellScreen(
          client: client,
          wsClient: _makeWsClient(client),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('DiscordShellScreen responsive', () {
    testWidgets('wide (1440 px) shows SidebarShell', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_app(width: 1440));
      await tester.pump();
      expect(find.byType(SidebarShell), findsOneWidget);
    });

    testWidgets('narrow (375 px) does NOT show SidebarShell', (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_app(width: 375));
      await tester.pump();
      expect(find.byType(SidebarShell), findsNothing);
    });

    testWidgets('at breakpoint boundary (1099 px) is narrow', (tester) async {
      tester.view.physicalSize = const Size(1099, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_app(width: 1099));
      await tester.pump();
      expect(find.byType(SidebarShell), findsNothing);
    });

    testWidgets('at breakpoint boundary (1100 px) is wide', (tester) async {
      tester.view.physicalSize = const Size(1100, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_app(width: 1100));
      await tester.pump();
      expect(find.byType(SidebarShell), findsOneWidget);
    });
  });
}
