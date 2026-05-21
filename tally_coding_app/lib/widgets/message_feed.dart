// tally_coding_app/lib/widgets/message_feed.dart
import 'package:flutter/material.dart';
import 'message_bubble.dart';
import 'interactive_prompt_card.dart';

class MessageFeed extends StatelessWidget {
  /// Messages in reverse chronological order (newest first).  The list is
  /// rendered with reverse:true so newest appears at the bottom (chat
  /// convention).
  final List<Map<String, dynamic>> messages;
  final void Function(int messageId, String answerValue) onAnswerPrompt;
  const MessageFeed({
    super.key,
    required this.messages,
    required this.onAnswerPrompt,
  });

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No messages yet. Type below to start the conversation.',
            style: TextStyle(color: Color(0xFF949BA4))),
        ),
      );
    }
    return ListView.builder(
      reverse: true,
      itemCount: messages.length,
      itemBuilder: (ctx, i) {
        final m = messages[i];
        final kind = m['kind'] as String? ?? 'text';
        if (kind == 'interactive_prompt') {
          return InteractivePromptCard(
            message: m,
            onAnswer: (val) => onAnswerPrompt(m['id'] as int, val),
          );
        }
        return MessageBubble(message: m);
      },
    );
  }
}
