// tally_coding_app/lib/widgets/team_proposal_card.dart
import 'dart:convert';
import 'package:flutter/material.dart';

class TeamProposalCard extends StatelessWidget {
  final Map<String, dynamic> message;
  final void Function(String action) onAction;
  const TeamProposalCard({super.key, required this.message, required this.onAction});

  Map<String, dynamic> _payload() {
    try {
      return Map<String, dynamic>.from(jsonDecode(message['payload_json'] as String));
    } catch (_) { return const {}; }
  }

  String _teamSummary(Map<String, dynamic> teamSpec) {
    final nodes = (teamSpec['nodes'] as List?) ?? const [];
    final roles = nodes
      .where((n) => n is Map && n['kind'] == 'agent')
      .map((n) => (n as Map)['role']?.toString() ?? 'Agent')
      .toList();
    if (roles.isEmpty) return 'No agents';
    return roles.join(' → ');
  }

  @override
  Widget build(BuildContext context) {
    final payload = _payload();
    final description = (payload['description'] as String?) ?? '';
    final teamSpec = Map<String, dynamic>.from(payload['team_spec'] ?? {});
    final options = (payload['options'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    final cancelled = (payload['cancelled'] as bool?) ?? false;
    final approved = (payload['approved'] as bool?) ?? false;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E3A2F),
        border: const Border(left: BorderSide(color: Color(0xFF3BA55D), width: 3)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Tally proposes a team', style: TextStyle(color: Color(0xFF3BA55D), fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(description, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          Text('Team: ${_teamSummary(teamSpec)}', style: const TextStyle(fontSize: 12, color: Color(0xFF949BA4))),
          const SizedBox(height: 10),
          if (cancelled)
            const Text('cancelled', style: TextStyle(color: Color(0xFF949BA4), fontStyle: FontStyle.italic))
          else if (approved)
            const Text('approved', style: TextStyle(color: Color(0xFF3BA55D), fontStyle: FontStyle.italic))
          else
            Wrap(
              spacing: 8,
              children: [
                for (final opt in options)
                  ElevatedButton(
                    onPressed: () => onAction(opt['value'] as String),
                    child: Text(opt['label'] as String),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
