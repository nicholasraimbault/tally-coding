import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/interactive_prompt_card.dart';

void main() {
  testWidgets('renders prompt text + action buttons', (tester) async {
    final msg = {
      'id': 10, 'channel_id': 1, 'author_kind': 'agent',
      'kind': 'interactive_prompt',
      'payload_json': jsonEncode({
        'role': 'Reviewer',
        'prompt': 'Found a duplicate-key bug. Block, or note only?',
        'options': [
          {'value': 'block', 'label': 'Block'},
          {'value': 'note', 'label': 'Note only'},
        ],
      }),
      'created_at': 1700000000.0,
    };
    String? clicked;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      InteractivePromptCard(message: msg, onAnswer: (v) => clicked = v),
    )));
    expect(find.textContaining('duplicate-key'), findsOneWidget);
    expect(find.text('Block'), findsOneWidget);
    expect(find.text('Note only'), findsOneWidget);
    await tester.tap(find.text('Block'));
    await tester.pumpAndSettle();
    expect(clicked, 'block');
  });
}
