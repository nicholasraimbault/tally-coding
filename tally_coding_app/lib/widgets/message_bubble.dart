// tally_coding_app/lib/widgets/message_bubble.dart
import 'dart:convert';
import 'package:flutter/material.dart';

class MessageBubble extends StatelessWidget {
  final Map<String, dynamic> message;
  const MessageBubble({super.key, required this.message});

  String get _authorLabel {
    final kind = message['author_kind'] as String? ?? '';
    if (kind == 'tally') return 'Tally';
    if (kind == 'system') return 'System';
    final agentId = message['author_agent_id'];
    if (kind == 'agent' && agentId != null) {
      final payload = _payload();
      return (payload['role'] as String?) ?? 'Agent';
    }
    return (message['author_user_id'] as String?) ?? 'unknown';
  }

  Color get _authorColor {
    final kind = message['author_kind'] as String? ?? '';
    switch (kind) {
      case 'tally':  return const Color(0xFFF23F43);
      case 'agent':  return const Color(0xFF3BA55D);
      case 'system': return const Color(0xFF949BA4);
      default:       return const Color(0xFF5865F2);
    }
  }

  Map<String, dynamic> _payload() {
    try {
      return Map<String, dynamic>.from(jsonDecode(message['payload_json'] as String));
    } catch (_) {
      return const {};
    }
  }

  String _formatTime(num ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final payload = _payload();
    final text = (payload['text'] as String?) ?? '';
    final createdAt = (message['created_at'] as num?) ?? 0;
    final editedAt = message['edited_at'] as num?;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(_authorLabel, style: TextStyle(fontWeight: FontWeight.bold, color: _authorColor)),
              const SizedBox(width: 8),
              Text(_formatTime(createdAt),
                style: const TextStyle(fontSize: 11, color: Color(0xFF949BA4))),
              if (editedAt != null) ...[
                const SizedBox(width: 6),
                const Text('(edited)', style: TextStyle(fontSize: 11, color: Color(0xFF949BA4))),
              ],
            ],
          ),
          if (text.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: SelectableText(text, style: const TextStyle(fontSize: 14)),
            ),
        ],
      ),
    );
  }
}
