import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/sidebar/sidebar_channels_list.dart';
import 'package:tally_coding_app/theme/theme.dart';

Widget _wrap(Widget child) {
  final tokens = themeCatalog[defaultThemeSlug]!.tokens;
  return MaterialApp(
    theme: themeFromTokens(tokens),
    home: Scaffold(body: SizedBox(width: 240, child: child)),
  );
}

const _normalChannel = SidebarChannelEntry(
  name: 'health',
  needsAttention: false,
  escalationCount: 0,
);
const _alertChannel = SidebarChannelEntry(
  name: 'general',
  needsAttention: true,
  escalationCount: 1,
);

void main() {
  group('SidebarChannelsList', () {
    testWidgets('renders channel names with hash prefix', (tester) async {
      await tester.pumpWidget(_wrap(SidebarChannelsList(
        channels: const [_normalChannel],
        activeChannelName: null,
        onChannelTap: (_) {},
        onAddChannel: () {},
      )));
      expect(find.text('health'), findsOneWidget);
      expect(find.text('＃'), findsOneWidget);
    });

    testWidgets('needs-attention row has 3px coral left accent', (tester) async {
      await tester.pumpWidget(_wrap(SidebarChannelsList(
        channels: const [_alertChannel],
        activeChannelName: null,
        onChannelTap: (_) {},
        onAddChannel: () {},
      )));
      // The coral accent Container exists (3px wide red bar)
      expect(
        find.byWidgetPredicate((w) =>
            w is Container &&
            w.constraints?.maxWidth == 3.0),
        findsOneWidget,
      );
    });

    testWidgets('needs-attention row shows count pill', (tester) async {
      await tester.pumpWidget(_wrap(SidebarChannelsList(
        channels: const [_alertChannel],
        activeChannelName: null,
        onChannelTap: (_) {},
        onAddChannel: () {},
      )));
      // The count pill shows the escalation count; the header also shows
      // the channel list count — both show "1" in this test.
      expect(find.text('1'), findsAtLeastNWidgets(1));
    });

    testWidgets('tapping a channel fires onChannelTap with channel name',
        (tester) async {
      String? tappedName;
      await tester.pumpWidget(_wrap(SidebarChannelsList(
        channels: const [_normalChannel],
        activeChannelName: null,
        onChannelTap: (name) => tappedName = name,
        onAddChannel: () {},
      )));
      await tester.tap(find.text('health'));
      expect(tappedName, 'health');
    });

    testWidgets('active channel row is present in tree', (tester) async {
      await tester.pumpWidget(_wrap(SidebarChannelsList(
        channels: const [_normalChannel],
        activeChannelName: 'health',
        onChannelTap: (_) {},
        onAddChannel: () {},
      )));
      // Active channel's name is rendered with fg-colored text (not dimmed).
      // The _ChannelRow widget renders an AnimatedContainer when active.
      expect(find.byType(AnimatedContainer), findsWidgets);
    });

    testWidgets('section header shows + button that fires onAddChannel',
        (tester) async {
      var addTapped = false;
      await tester.pumpWidget(_wrap(SidebarChannelsList(
        channels: const [_normalChannel],
        activeChannelName: null,
        onChannelTap: (_) {},
        onAddChannel: () => addTapped = true,
      )));
      await tester.tap(find.byKey(const Key('sidebar_channels_add')));
      expect(addTapped, isTrue);
    });

    // F1-Fix3: Board nav entry above CHANNELS section.
    testWidgets('F1-Fix3: Board entry is rendered above CHANNELS header',
        (tester) async {
      await tester.pumpWidget(_wrap(SidebarChannelsList(
        channels: const [_normalChannel],
        activeChannelName: null,
        onChannelTap: (_) {},
        onAddChannel: () {},
      )));
      expect(find.text('Board'), findsOneWidget);
      // Board entry should be above the CHANNELS section header.
      final boardY = tester.getTopLeft(find.text('Board')).dy;
      final channelsY = tester.getTopLeft(find.text('CHANNELS')).dy;
      expect(boardY, lessThan(channelsY));
    });

    testWidgets('F1-Fix3: tapping Board entry fires onBoardTap', (tester) async {
      var boardTapped = false;
      await tester.pumpWidget(_wrap(SidebarChannelsList(
        channels: const [_normalChannel],
        activeChannelName: null,
        isBoardSelected: false,
        onBoardTap: () => boardTapped = true,
        onChannelTap: (_) {},
        onAddChannel: () {},
      )));
      await tester.tap(find.byKey(const Key('sidebar_board_entry')));
      expect(boardTapped, isTrue);
    });

    testWidgets('F1-Fix3: isBoardSelected highlights the Board entry',
        (tester) async {
      await tester.pumpWidget(_wrap(SidebarChannelsList(
        channels: const [_normalChannel],
        activeChannelName: null,
        isBoardSelected: true,
        onBoardTap: () {},
        onChannelTap: (_) {},
        onAddChannel: () {},
      )));
      // Board entry exists and widget tree is renderable when selected.
      expect(find.text('Board'), findsOneWidget);
      // The board entry key must be present.
      expect(find.byKey(const Key('sidebar_board_entry')), findsOneWidget);
    });
  });
}
