import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/channel_model.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/channel_row.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/channels_sheet.dart';

Widget _wrap(Widget child) {
  final tokens = themeCatalog[defaultThemeSlug]!.tokens;
  return MaterialApp(theme: themeFromTokens(tokens), home: Scaffold(body: child));
}

void main() {
  group('CalmChannelRow', () {
    testWidgets('renders # + name + last message snippet', (tester) async {
      await tester.pumpWidget(_wrap(CalmChannelRow(
        channel: const ChannelModel(
          id: 1, name: 'health', kind: 'custom',
          lastMessageText: 'p99 OK at 240ms', lastMessageAuthor: 'tally',
        ),
        onTap: () {},
      )));
      expect(find.text('#health'), findsOneWidget);
      expect(find.text('p99 OK at 240ms'), findsOneWidget);
    });

    testWidgets('invokes onTap when tapped', (tester) async {
      int taps = 0;
      await tester.pumpWidget(_wrap(CalmChannelRow(
        channel: const ChannelModel(id: 1, name: 'g', kind: 'custom'),
        onTap: () => taps++,
      )));
      await tester.tap(find.byType(CalmChannelRow));
      expect(taps, 1);
    });
  });

  group('NeedsAttentionChannelRow', () {
    testWidgets('renders # + name + "1 escalation" pill', (tester) async {
      await tester.pumpWidget(_wrap(NeedsAttentionChannelRow(
        channel: const ChannelModel(id: 1, name: 'general', kind: 'custom'),
        escalationCount: 1,
        onTap: () {},
      )));
      expect(find.text('#general'), findsOneWidget);
      expect(find.text('1 ESCALATION'), findsOneWidget);
    });

    testWidgets('pluralizes label when count > 1', (tester) async {
      await tester.pumpWidget(_wrap(NeedsAttentionChannelRow(
        channel: const ChannelModel(id: 1, name: 'g', kind: 'custom'),
        escalationCount: 3,
        onTap: () {},
      )));
      expect(find.text('3 ESCALATIONS'), findsOneWidget);
    });

    testWidgets('invokes onTap when tapped', (tester) async {
      int taps = 0;
      await tester.pumpWidget(_wrap(NeedsAttentionChannelRow(
        channel: const ChannelModel(id: 1, name: 'g', kind: 'custom'),
        escalationCount: 1,
        onTap: () => taps++,
      )));
      await tester.tap(find.byType(NeedsAttentionChannelRow));
      expect(taps, 1);
    });
  });

  group('ChannelsSheet', () {
    testWidgets('renders header + activity strip + channel rows', (tester) async {
      await tester.pumpWidget(_wrap(ChannelsSheet(
        channels: const [
          ChannelModel(id: 1, name: 'general', kind: 'custom'),
          ChannelModel(id: 2, name: 'health', kind: 'custom'),
        ],
        needsAttention: const {},
        escalationCountByChannel: const {},
        onChannelTap: (_) {},
        onCollapse: () {},
      )));
      expect(find.text('CHANNELS'), findsOneWidget);
      expect(find.text('#general'), findsOneWidget);
      expect(find.text('#health'), findsOneWidget);
    });

    testWidgets('renders need-attention row for channels in needsAttention set', (tester) async {
      await tester.pumpWidget(_wrap(ChannelsSheet(
        channels: const [
          ChannelModel(id: 1, name: 'general', kind: 'custom'),
        ],
        needsAttention: const {1},
        escalationCountByChannel: const {1: 1},
        onChannelTap: (_) {},
        onCollapse: () {},
      )));
      expect(find.byType(NeedsAttentionChannelRow), findsOneWidget);
      expect(find.byType(CalmChannelRow), findsNothing);
    });

    testWidgets('skips non-long-term channels (e.g. task)', (tester) async {
      await tester.pumpWidget(_wrap(ChannelsSheet(
        channels: const [
          ChannelModel(id: 1, name: 'general', kind: 'custom'),
          ChannelModel(id: 2, name: 'feat/x', kind: 'task'),
        ],
        needsAttention: const {},
        escalationCountByChannel: const {},
        onChannelTap: (_) {},
        onCollapse: () {},
      )));
      expect(find.text('#general'), findsOneWidget);
      expect(find.text('#feat/x'), findsNothing);
    });

    testWidgets('tap on a row invokes onChannelTap', (tester) async {
      ChannelModel? tapped;
      await tester.pumpWidget(_wrap(ChannelsSheet(
        channels: const [ChannelModel(id: 5, name: 'g', kind: 'custom')],
        needsAttention: const {},
        escalationCountByChannel: const {},
        onChannelTap: (c) => tapped = c,
        onCollapse: () {},
      )));
      await tester.tap(find.text('#g'));
      expect(tapped?.id, 5);
    });
  });
}
