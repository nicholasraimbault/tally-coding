import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/escalation_model.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/escalation_sheet.dart';

const _esc = EscalationModel(
  id: 'e1',
  question: 'Round to 2 decimals or keep 4?',
  options: ['2 decimals', 'Keep 4'],
  taskId: 't-42',
  channelId: 7,
);

Widget _wrap(Widget child) {
  final tokens = themeCatalog[defaultThemeSlug]!.tokens;
  return MaterialApp(theme: themeFromTokens(tokens), home: Scaffold(body: child));
}

void main() {
  testWidgets('renders the question text', (tester) async {
    await tester.pumpWidget(_wrap(EscalationSheet(
      escalation: _esc,
      queueIndex: 0, queueSize: 1,
      taskTitle: 'Fix daily-deals',
      channelName: 'general',
      onReply: (_) {}, onSkip: () {}, onOpen: () {},
    )));
    expect(find.text('Round to 2 decimals or keep 4?'), findsOneWidget);
  });

  testWidgets('renders channel name + "needs you" in header', (tester) async {
    await tester.pumpWidget(_wrap(EscalationSheet(
      escalation: _esc, queueIndex: 0, queueSize: 2,
      taskTitle: 't', channelName: 'general',
      onReply: (_) {}, onSkip: () {}, onOpen: () {},
    )));
    expect(find.textContaining('general'), findsWidgets);
    expect(find.textContaining('needs you'), findsOneWidget);
  });

  testWidgets('shows queue badge "1 of N" when queueSize > 1', (tester) async {
    await tester.pumpWidget(_wrap(EscalationSheet(
      escalation: _esc, queueIndex: 0, queueSize: 3,
      taskTitle: 't', channelName: 'g',
      onReply: (_) {}, onSkip: () {}, onOpen: () {},
    )));
    expect(find.text('1 of 3'), findsOneWidget);
  });
}
