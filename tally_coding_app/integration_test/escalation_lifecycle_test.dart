import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/bottom_sheet.dart';

void main() {
  testWidgets('controller lifecycle: enqueue → resolve → ambient', (tester) async {
    final controller = BottomSheetController();
    final themeCtrl = ThemeController();

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: themeCtrl..load()),
        ChangeNotifierProvider.value(value: controller),
      ],
      child: MaterialApp(
        theme: themeFromTokens(themeCatalog[defaultThemeSlug]!.tokens),
        home: Scaffold(
          body: Consumer<BottomSheetController>(
            builder: (ctx, c, _) {
              if (c.state == SheetState.takeover) {
                final esc = c.activeEscalation!;
                return EscalationSheet(
                  escalation: esc,
                  queueIndex: 0,
                  queueSize: c.queueSize,
                  taskTitle: 'mock',
                  channelName: 'general',
                  onReply: (_) => c.resolveActive(),
                  onSkip: c.skip,
                  onOpen: () {},
                );
              }
              return const AmbientMiniDash(
                openCount: 0, doneCount: 0, taskRows: [], narratorText: null,
              );
            },
          ),
        ),
      ),
    ));
    await tester.pump();

    // Initial: ambient
    expect(find.byType(AmbientMiniDash), findsOneWidget);

    // Enqueue → takeover
    controller.enqueueEscalation(const EscalationModel(
      id: 'e1', question: 'Q?', options: ['Yes', 'No'],
      taskId: 't1', channelId: 1,
    ));
    await tester.pump();
    expect(find.byType(EscalationSheet), findsOneWidget);
    expect(find.text('Q?'), findsOneWidget);

    // Tap Yes → resolve → ambient
    await tester.tap(find.text('YES'));
    await tester.pump();
    expect(find.byType(AmbientMiniDash), findsOneWidget);
  });
}
