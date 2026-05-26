/// Verifies that the narrow layout uses context.tc.* tokens so the theme
/// picker actually affects mobile rendering. Validates against Catppuccin
/// Mocha whose values differ from the old Discord hardcodes on every surface.
library;

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
import 'package:tally_coding_app/widgets/bottom_sheet/bottom_sheet.dart';
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

/// Pumps the app at narrow (375 px) width with the given theme tokens.
Future<void> _pumpNarrow(WidgetTester tester, String themeSlug) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(375, 812);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final tokens = themeCatalog[themeSlug]!.tokens;
  final client = _makeClient();
  await tester.pumpWidget(
    MultiProvider(
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
            wsClient: NotificationsWsClient(
              api: client,
              wsUrl: Uri.parse('ws://localhost/ws/notifications'),
              bearerProvider: () async => 'test-token',
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('narrow layout re-theme (F2)', () {
    /// Catppuccin Mocha bg = 0xFF1E1E2E — distinct from Discord 0xFF313338.
    testWidgets('Scaffold bg matches Catppuccin Mocha tc.bg', (tester) async {
      await _pumpNarrow(tester, 'catppuccin-mocha');
      final tokens = themeCatalog['catppuccin-mocha']!.tokens;

      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(
        scaffold.backgroundColor,
        tokens.bg,
        reason: 'Scaffold.backgroundColor must come from tc.bg, not a hardcoded hex',
      );
    });

    /// Catppuccin Mocha elev = 0xFF272838 — distinct from Discord 0xFF1E1F22.
    testWidgets('AppBar bg matches Catppuccin Mocha tc.elev', (tester) async {
      await _pumpNarrow(tester, 'catppuccin-mocha');
      final tokens = themeCatalog['catppuccin-mocha']!.tokens;

      final appBar = tester.widget<AppBar>(find.byType(AppBar).first);
      expect(
        appBar.backgroundColor,
        tokens.elev,
        reason: 'AppBar.backgroundColor must come from tc.elev, not a hardcoded hex',
      );
    });

    /// Verify token values differ across themes so the test is meaningful.
    testWidgets('Tokyo Night and Catppuccin Mocha tokens have distinct bg values',
        (tester) async {
      final tokyoTokens = themeCatalog['tokyo-night']!.tokens;
      final mochaTokens = themeCatalog['catppuccin-mocha']!.tokens;

      // These themes must have different bg tokens for the re-theme to matter.
      expect(
        tokyoTokens.bg,
        isNot(equals(mochaTokens.bg)),
        reason: 'Tokyo Night and Catppuccin Mocha must have different tc.bg values',
      );

      // Verify Catppuccin Mocha bg = 0xFF1E1E2E (distinct from old hardcoded 0xFF313338).
      expect(
        mochaTokens.bg,
        const Color(0xFF1E1E2E),
        reason: 'Catppuccin Mocha tc.bg is expected to be 0xFF1E1E2E',
      );

      // Verify the old Discord hardcode 0xFF313338 is not present in Mocha or Tokyo.
      const discordBg = Color(0xFF313338);
      expect(
        mochaTokens.bg,
        isNot(equals(discordBg)),
        reason: 'Catppuccin Mocha tc.bg must not equal the old hardcoded Discord bg',
      );
      expect(
        tokyoTokens.bg,
        isNot(equals(discordBg)),
        reason: 'Tokyo Night tc.bg must not equal the old hardcoded Discord bg',
      );
    });
  });
}
