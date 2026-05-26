import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/channel_model.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/channel_row.dart';

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
}
