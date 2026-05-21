import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/message_feed.dart';

void main() {
  testWidgets('renders multiple messages in reverse chronological order', (tester) async {
    final messages = [
      {
        'id': 3, 'channel_id': 1, 'author_kind': 'human',
        'author_user_id': 'admin', 'kind': 'text',
        'payload_json': jsonEncode({'text': 'third'}),
        'created_at': 1700000003.0,
      },
      {
        'id': 2, 'channel_id': 1, 'author_kind': 'agent',
        'kind': 'text',
        'payload_json': jsonEncode({'text': 'second', 'role': 'Coder'}),
        'created_at': 1700000002.0,
      },
      {
        'id': 1, 'channel_id': 1, 'author_kind': 'human',
        'author_user_id': 'admin', 'kind': 'text',
        'payload_json': jsonEncode({'text': 'first'}),
        'created_at': 1700000001.0,
      },
    ];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      MessageFeed(messages: messages, onAnswerPrompt: (mid, val) {}),
    )));
    expect(find.textContaining('first'), findsOneWidget);
    expect(find.textContaining('second'), findsOneWidget);
    expect(find.textContaining('third'), findsOneWidget);
  });

  testWidgets('renders empty state when no messages', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      MessageFeed(messages: const [], onAnswerPrompt: (m, v) {}),
    )));
    expect(find.textContaining('No messages yet'), findsOneWidget);
  });

  // Sprint 49 B8: verify escalation interactive_prompt wiring (cross-check Sprint 47 B3)
  testWidgets('escalation interactive_prompt fires onAnswerPrompt with correct args', (tester) async {
    // Persistent-agent escalation posts a kind='interactive_prompt' with
    // pause/resume/cancel buttons in the agent's scheduled_agent channel.
    final messages = [
      {
        'id': 42, 'channel_id': 9, 'author_kind': 'agent',
        'kind': 'interactive_prompt',
        'payload_json': jsonEncode({
          'role': 'Tester',
          'prompt': 'Test suite is failing intermittently. What should I do?',
          'options': [
            {'value': 'pause', 'label': 'Pause'},
            {'value': 'resume', 'label': 'Resume'},
            {'value': 'cancel', 'label': 'Cancel'},
          ],
        }),
        'created_at': 1700000000.0,
      },
    ];
    int? lastMsgId;
    String? lastAnswer;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      MessageFeed(
        messages: messages,
        onAnswerPrompt: (mid, v) { lastMsgId = mid; lastAnswer = v; },
      ),
    )));
    expect(find.text('Pause'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    await tester.tap(find.text('Pause'));
    await tester.pumpAndSettle();
    expect(lastMsgId, 42);
    expect(lastAnswer, 'pause');
  });

  testWidgets('renders team_proposal message via TeamProposalCard', (tester) async {
    final messages = [
      {
        'id': 1, 'channel_id': 1, 'author_kind': 'tally',
        'kind': 'team_proposal',
        'payload_json': jsonEncode({
          'task_id': 'abc', 'description': 'build it',
          'team_spec': {'nodes': [{'id':'n1','kind':'agent','role':'Coder'}], 'edges':[]},
          'options': [{'value':'approve','label':'Approve'}, {'value':'edit','label':'Edit'}, {'value':'cancel','label':'Cancel'}],
        }),
        'created_at': 1700000000.0,
      },
    ];
    String? clicked;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      MessageFeed(
        messages: messages,
        onAnswerPrompt: (_, __) {},
        onTeamProposalAction: (taskId, action) => clicked = '$taskId:$action',
      ),
    )));
    expect(find.textContaining('build it'), findsOneWidget);
    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();
    expect(clicked, 'abc:approve');
  });
}
