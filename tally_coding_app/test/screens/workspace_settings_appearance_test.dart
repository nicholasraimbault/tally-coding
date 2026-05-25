import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/screens/theme_picker_screen.dart';
import 'package:tally_coding_app/screens/workspace_settings.dart';
import 'package:tally_coding_app/theme/theme.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  TallyOrchClient _mockClient() {
    final mock = MockClient((req) async =>
        http.Response('{"members":[],"channels":[]}', 200,
            headers: {'content-type': 'application/json'}));
    return TallyOrchClient(
        baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
  }

  Future<void> pumpSettings(WidgetTester tester) async {
    final controller = ThemeController();
    await controller.load();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          theme: themeFromTokens(controller.activeEntry.tokens),
          home: WorkspaceSettingsScreen(
            client: _mockClient(),
            workspaceId: 1,
            workspaceName: 'Test WS',
            callerRole: 'owner',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Appearance section is present in workspace settings', (tester) async {
    await pumpSettings(tester);
    // Drag to reveal content below the fold
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.text('Appearance'), findsAtLeastNWidgets(1));
  });

  testWidgets('Tapping "Open theme picker" navigates to ThemePickerScreen',
      (tester) async {
    await pumpSettings(tester);
    // Drag to reveal the Appearance section and button
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    // BrutalButton renders label uppercased
    await tester.tap(find.text('OPEN THEME PICKER'));
    await tester.pumpAndSettle();
    expect(find.byType(ThemePickerScreen), findsOneWidget);
  });
}
