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
}
