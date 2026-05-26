// tally_coding_app/lib/widgets/message_feed.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'bottom_sheet/bottom_sheet.dart';
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
  /// B3b Task 10: callbacks for inline escalation cards.
  /// [onEscalationReply] receives (escalation, selectedOption).
  /// [onOpenTask] receives the taskId string.
  final void Function(EscalationModel esc, String option)? onEscalationReply;
  final void Function(String taskId)? onOpenTask;
  const MessageFeed({
    super.key,
    required this.messages,
    required this.onAnswerPrompt,
    this.onTeamProposalAction,
    this.onEscalationReply,
    this.onOpenTask,
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
        // B3b Task 10: escalation messages render as InlineEscalationCard.
        // The payload is stored as payload_json (JSON string) or as a Map
        // depending on the API response shape.  Try both.
        if (kind == 'escalation') {
          try {
            final Map<String, dynamic> payload;
            final raw = m['payload_json'];
            if (raw is String) {
              payload = jsonDecode(raw) as Map<String, dynamic>;
            } else if (m['payload'] is Map) {
              payload = (m['payload'] as Map).cast<String, dynamic>();
            } else {
              payload = const {};
            }
            // channel_id comes from the message envelope; fall back to payload.
            final channelId =
                (m['channel_id'] as num?)?.toInt() ??
                (payload['channel_id'] as num?)?.toInt() ??
                0;
            final esc = EscalationModel.fromJson({
              ...payload,
              'channel_id': channelId,
            });
            final taskTitle =
                (payload['task_title'] as String?) ?? 'task';
            return InlineEscalationCard(
              escalation: esc,
              taskTitle: taskTitle,
              onReply: (option) => onEscalationReply?.call(esc, option),
              onOpenTask: () => onOpenTask?.call(esc.taskId),
            );
          } catch (_) {
            // Malformed escalation payload — fall through to default bubble.
          }
        }
        return MessageBubble(message: m);
      },
    );
  }
}
