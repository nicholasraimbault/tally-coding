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

  testWidgets('shows queue badge "1/N" when queueSize > 0', (tester) async {
    await tester.pumpWidget(_wrap(EscalationSheet(
      escalation: _esc, queueIndex: 0, queueSize: 3,
      taskTitle: 't', channelName: 'g',
      onReply: (_) {}, onSkip: () {}, onOpen: () {},
    )));
    // Compact "1/3" format per mockup (was "1 of 3").
    expect(find.text('1/3'), findsOneWidget);
  });

  testWidgets('renders one BrutalButton per option', (tester) async {
    await tester.pumpWidget(_wrap(EscalationSheet(
      escalation: _esc, queueIndex: 0, queueSize: 1,
      taskTitle: 't', channelName: 'g',
      onReply: (_) {}, onSkip: () {}, onOpen: () {},
    )));
    expect(find.text('2 DECIMALS'), findsOneWidget);
    expect(find.text('KEEP 4'), findsOneWidget);
  });

  testWidgets('tapping a quick reply calls onReply with the option', (tester) async {
    String? picked;
    await tester.pumpWidget(_wrap(EscalationSheet(
      escalation: _esc, queueIndex: 0, queueSize: 1,
      taskTitle: 't', channelName: 'g',
      onReply: (opt) => picked = opt, onSkip: () {}, onOpen: () {},
    )));
    await tester.tap(find.text('2 DECIMALS'));
    expect(picked, '2 decimals');
  });

  testWidgets('Open ghost button calls onOpen', (tester) async {
    int calls = 0;
    await tester.pumpWidget(_wrap(EscalationSheet(
      escalation: _esc, queueIndex: 0, queueSize: 1,
      taskTitle: 't', channelName: 'g',
      onReply: (_) {}, onSkip: () {}, onOpen: () => calls++,
    )));
    await tester.tap(find.text('OPEN #G'));
    expect(calls, 1);
  });

  testWidgets('Skip ghost button calls onSkip', (tester) async {
    int calls = 0;
    await tester.pumpWidget(_wrap(EscalationSheet(
      escalation: _esc, queueIndex: 0, queueSize: 2,
      taskTitle: 't', channelName: 'g',
      onReply: (_) {}, onSkip: () => calls++, onOpen: () {},
    )));
    await tester.tap(find.text('SKIP'));
    expect(calls, 1);
  });
}
