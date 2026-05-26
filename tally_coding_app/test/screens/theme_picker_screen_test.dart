import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tally_coding_app/screens/theme_picker_screen.dart';
import 'package:tally_coding_app/theme/theme.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpPicker(WidgetTester tester) async {
    final controller = ThemeController();
    await controller.load();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          theme: themeFromTokens(controller.activeEntry.tokens),
          home: const ThemePickerScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders all 28 theme tiles', (tester) async {
    await pumpPicker(tester);
    expect(find.byType(ThemeTile), findsNWidgets(28));
  });

  testWidgets('filter input narrows the list', (tester) async {
    await pumpPicker(tester);
    await tester.enterText(find.byType(TextField), 'catppuccin');
    await tester.pump();
    // Catppuccin has 3 variants: Mocha, Macchiato, Frappé (plus Latte light = 4)
    expect(find.byType(ThemeTile), findsNWidgets(4));
  });

  testWidgets('tapping a tile updates the active theme', (tester) async {
    await pumpPicker(tester);
    final controller = tester
        .element(find.byType(ThemePickerScreen))
        .read<ThemeController>();
    await tester.tap(find.text('Dracula'));
    await tester.pump();
    expect(controller.activeSlug, 'dracula');
  });

  testWidgets('preview pane renders sample widgets', (tester) async {
    await pumpPicker(tester);
    expect(find.text('Sample · preview reflects active theme'), findsOneWidget);
  });
}
