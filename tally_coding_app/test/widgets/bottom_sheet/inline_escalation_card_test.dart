import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/escalation_model.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/inline_escalation_card.dart';

const _esc = EscalationModel(
  id: 'e1', question: 'Round to 2 decimals or keep 4?',
  options: ['2 decimals', 'Keep 4'],
  taskId: 't-42', channelId: 7,
);

Widget _wrap(Widget child) {
  final tokens = themeCatalog[defaultThemeSlug]!.tokens;
  return MaterialApp(theme: themeFromTokens(tokens), home: Scaffold(body: child));
}

void main() {
  testWidgets('renders question + options as buttons', (tester) async {
    await tester.pumpWidget(_wrap(InlineEscalationCard(
      escalation: _esc,
      taskTitle: 'Fix daily-deals',
      onReply: (_) {}, onOpenTask: () {},
    )));
    expect(find.text('Round to 2 decimals or keep 4?'), findsOneWidget);
    expect(find.text('2 DECIMALS'), findsOneWidget);
    expect(find.text('KEEP 4'), findsOneWidget);
  });

  testWidgets('renders Tally avatar + "Tally needs you" + task tag', (tester) async {
    await tester.pumpWidget(_wrap(InlineEscalationCard(
      escalation: _esc, taskTitle: 'Fix daily-deals',
      onReply: (_) {}, onOpenTask: () {},
    )));
    expect(find.text('T'), findsWidgets); // TallyAvatar monogram
    expect(find.textContaining('TALLY NEEDS YOU'), findsOneWidget);
    expect(find.text('Fix daily-deals'), findsOneWidget);
  });

  testWidgets('tapping option calls onReply', (tester) async {
    String? picked;
    await tester.pumpWidget(_wrap(InlineEscalationCard(
      escalation: _esc, taskTitle: 't',
      onReply: (o) => picked = o, onOpenTask: () {},
    )));
    await tester.tap(find.text('2 DECIMALS'));
    expect(picked, '2 decimals');
  });

  testWidgets('tapping Open task channel calls onOpenTask', (tester) async {
    int calls = 0;
    await tester.pumpWidget(_wrap(InlineEscalationCard(
      escalation: _esc, taskTitle: 't',
      onReply: (_) {}, onOpenTask: () => calls++,
    )));
    await tester.tap(find.text('OPEN TASK CHANNEL'));
    expect(calls, 1);
  });
}
