// tally_coding_app/lib/widgets/message_feed.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'message_bubble.dart';
import 'interactive_prompt_card.dart';
import 'team_proposal_card.dart';

class MessageFeed extends StatelessWidget {
  /// Messages in reverse chronological order (newest first).  The list is
  /// rendered with reverse:true so newest appears at the bottom (chat
  /// convention).
  final List<Map<String, dynamic>> messages;
  final void Function(int messageId, String answerValue) onAnswerPrompt;
  /// Sprint 48: callback when a team_proposal action is clicked.
  /// Receives (taskId, action) where action is 'approve' | 'edit' | 'cancel'.
  final void Function(String taskId, String action)? onTeamProposalAction;
  const MessageFeed({
    super.key,
    required this.messages,
    required this.onAnswerPrompt,
    this.onTeamProposalAction,
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
        if (kind == 'team_proposal') {
          return TeamProposalCard(
            message: m,
            onAction: (action) {
              if (onTeamProposalAction == null) return;
              try {
                final payload = jsonDecode(m['payload_json'] as String) as Map<String, dynamic>;
                final taskId = payload['task_id'] as String? ?? '';
                onTeamProposalAction!(taskId, action);
              } catch (_) {}
            },
          );
        }
        return MessageBubble(message: m);
      },
    );
  }
}
