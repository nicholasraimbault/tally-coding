import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/message_bubble.dart';

void main() {
  testWidgets('renders human text message', (tester) async {
    final msg = {
      'id': 1,
      'channel_id': 1,
      'author_kind': 'human',
      'author_user_id': 'admin',
      'kind': 'text',
      'payload_json': jsonEncode({'text': 'hello world'}),
      'created_at': 1700000000.0,
      'edited_at': null,
    };
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageBubble(message: msg))));
    expect(find.textContaining('hello world'), findsOneWidget);
    expect(find.textContaining('admin'), findsOneWidget);
  });

  testWidgets('renders agent message with role-color', (tester) async {
    final msg = {
      'id': 2, 'channel_id': 1, 'author_kind': 'agent',
      'author_agent_id': 5, 'kind': 'text',
      'payload_json': jsonEncode({'text': 'on it', 'role': 'Coder'}),
      'created_at': 1700000001.0,
    };
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageBubble(message: msg))));
    expect(find.textContaining('on it'), findsOneWidget);
  });

  testWidgets('shows (edited) indicator when edited_at is set', (tester) async {
    final msg = {
      'id': 3, 'channel_id': 1, 'author_kind': 'human',
      'author_user_id': 'admin', 'kind': 'text',
      'payload_json': jsonEncode({'text': 'fixed typo'}),
      'created_at': 1700000000.0, 'edited_at': 1700000060.0,
    };
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageBubble(message: msg))));
    expect(find.textContaining('edited'), findsOneWidget);
  });
}
