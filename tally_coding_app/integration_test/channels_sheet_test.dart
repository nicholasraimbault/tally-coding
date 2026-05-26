import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/bottom_sheet.dart';

void main() {
  testWidgets('expandChannels → ChannelsSheet renders with channels', (tester) async {
    final controller = BottomSheetController();
    controller.setChannels(const [
      ChannelModel(id: 1, name: 'general', kind: 'custom'),
      ChannelModel(id: 2, name: 'health', kind: 'custom'),
    ]);

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: ThemeController()..load()),
        ChangeNotifierProvider.value(value: controller),
      ],
      child: MaterialApp(
        theme: themeFromTokens(themeCatalog[defaultThemeSlug]!.tokens),
        home: Scaffold(
          body: Consumer<BottomSheetController>(builder: (ctx, c, _) {
            if (c.state == SheetState.channelsExpanded) {
              return ChannelsSheet(
                channels: c.channels,
                needsAttention: const {1},
                escalationCountByChannel: const {1: 1},
                onChannelTap: (_) {},
                onCollapse: c.collapseToAmbient,
              );
            }
            return const Center(child: Text('ambient'));
          }),
        ),
      ),
    ));
    await tester.pump();

    // Initial state: ambient placeholder
    expect(find.text('ambient'), findsOneWidget);

    // Trigger state change
    controller.expandChannels();
    await tester.pump();

    // Sheet header + both channel rows
    expect(find.text('CHANNELS'), findsOneWidget);
    expect(find.text('#general'), findsOneWidget);
    expect(find.text('#health'), findsOneWidget);
    // Channel 1 is in needsAttention → NeedsAttentionChannelRow
    expect(find.byType(NeedsAttentionChannelRow), findsOneWidget);
  });
}
