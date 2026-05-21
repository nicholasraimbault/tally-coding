// tally_coding_app/lib/widgets/interactive_prompt_card.dart
import 'dart:convert';
import 'package:flutter/material.dart';

class InteractivePromptCard extends StatelessWidget {
  final Map<String, dynamic> message;
  final void Function(String value) onAnswer;
  const InteractivePromptCard({super.key, required this.message, required this.onAnswer});

  Map<String, dynamic> _payload() {
    try {
      return Map<String, dynamic>.from(jsonDecode(message['payload_json'] as String));
    } catch (_) { return const {}; }
  }

  @override
  Widget build(BuildContext context) {
    final payload = _payload();
    final role = (payload['role'] as String?) ?? 'Agent';
    final prompt = (payload['prompt'] as String?) ?? '';
    final options = (payload['options'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF3B2F1F),
        border: const Border(left: BorderSide(color: Color(0xFFF0B232), width: 3)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$role needs you', style: const TextStyle(color: Color(0xFFF0B232), fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(prompt, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final opt in options)
                ElevatedButton(
                  onPressed: () => onAnswer(opt['value'] as String),
                  child: Text(opt['label'] as String),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
