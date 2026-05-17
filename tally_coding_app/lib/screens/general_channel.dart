/// Sprint 25: #general — chat-style entry point.
///
/// Each row is a "message": user describes a task, Tally responds with
/// the team it picked + reasoning. Submitting redirects to the new
/// task channel (handled by the shell via onTaskSubmitted).
library;

import 'package:flutter/material.dart';

import '../agent_roles.dart';
import '../api.dart';
import '../widgets/channel_header.dart';

class GeneralChannelScreen extends StatefulWidget {
  final TallyOrchClient client;
  final List<Task> recentTasks;
  final ValueChanged<Task> onTaskSubmitted;
  const GeneralChannelScreen({
    super.key,
    required this.client,
    required this.recentTasks,
    required this.onTaskSubmitted,
  });

  @override
  State<GeneralChannelScreen> createState() => _GeneralChannelScreenState();
}

class _GeneralChannelScreenState extends State<GeneralChannelScreen> {
  final _ctrl = TextEditingController();
  bool _submitting = false;
  String? _error;

  Future<void> _submit() async {
    final desc = _ctrl.text.trim();
    if (desc.isEmpty || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final t = await widget.client.submitTask(desc);
      _ctrl.clear();
      if (!mounted) return;
      setState(() => _submitting = false);
      widget.onTaskSubmitted(t);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF313338),
      child: Column(
        children: [
          const ChannelHeader(
            glyph: '✨',
            name: 'general',
            description: 'Describe what to build. Tally picks the team.',
          ),
          Expanded(
            child: _GeneralFeed(recentTasks: widget.recentTasks),
          ),
          _Composer(
            controller: _ctrl,
            submitting: _submitting,
            error: _error,
            onSubmit: _submit,
          ),
        ],
      ),
    );
  }
}

/// Renders recent tasks as Tally's responses. Oldest first (chat scroll),
/// keeps the welcome message at the top.
class _GeneralFeed extends StatelessWidget {
  final List<Task> recentTasks;
  const _GeneralFeed({required this.recentTasks});

  @override
  Widget build(BuildContext context) {
    // Reverse-chrono in the list, but display chronologically so the newest
    // message is at the bottom (Discord-style).
    final chronological = [...recentTasks]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      children: [
        const _WelcomeMessage(),
        const SizedBox(height: 24),
        for (final t in chronological) ...[
          _UserSubmission(task: t),
          if (t.teamSpec != null) ...[
            const SizedBox(height: 4),
            _TallyResponse(task: t),
          ],
          const SizedBox(height: 16),
        ],
      ],
    );
  }
}

class _WelcomeMessage extends StatelessWidget {
  const _WelcomeMessage();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2D31),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF1E1F22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '✨ Welcome to #general',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Describe what you want built. Tally reads your message, '
            'picks a custom team of agents, and dispatches them to '
            'TEE-attested workers. New tasks appear as channels in the '
            'left sidebar.',
            style: TextStyle(color: Color(0xFFC4C9CE), fontSize: 13, height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _UserSubmission extends StatelessWidget {
  final Task task;
  const _UserSubmission({required this.task});

  @override
  Widget build(BuildContext context) {
    return _MessageRow(
      avatar: const _CircleAvatar(
        bg: Color(0xFF4E5058),
        glyph: Icons.person,
      ),
      author: 'You',
      authorColor: Colors.white,
      timestamp: _formatTimestamp(task.createdAt),
      body: SelectableText(
        task.description,
        style: const TextStyle(color: Color(0xFFDCDDDE), fontSize: 14, height: 1.4),
      ),
    );
  }
}

class _TallyResponse extends StatelessWidget {
  final Task task;
  const _TallyResponse({required this.task});

  @override
  Widget build(BuildContext context) {
    final spec = task.teamSpec!;
    final reasoning = spec['reasoning'] as String? ?? '';
    final workflow = spec['workflow'] as String? ?? '';
    final agents = (spec['agents'] as List<dynamic>?) ?? const [];

    return _MessageRow(
      avatar: const _CircleAvatar(
        bg: Color(0xFF7C5CFC),
        text: '✨',
      ),
      author: 'Tally',
      authorColor: const Color(0xFF7C5CFC),
      timestamp: _formatTimestamp(task.updatedAt),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (reasoning.isNotEmpty)
            SelectableText(
              reasoning,
              style: const TextStyle(color: Color(0xFFDCDDDE), fontSize: 14, height: 1.4),
            ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF2B2D31),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF1E1F22)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (workflow.isNotEmpty) ...[
                  Row(
                    children: [
                      const Icon(Icons.account_tree, size: 14, color: Color(0xFF8E9297)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: SelectableText(
                          workflow,
                          style: const TextStyle(
                            color: Color(0xFFB9BBBE),
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final a in agents)
                      _AgentChip(
                        role: agentRoleOf((a as Map<String, dynamic>)['role'] as String? ?? '?'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '#${task.id.substring(0, 8)} · ${task.status}',
            style: const TextStyle(color: Color(0xFF8E9297), fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _AgentChip extends StatelessWidget {
  final AgentRole role;
  const _AgentChip({required this.role});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: role.tint.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(role.glyph, style: const TextStyle(fontSize: 12)),
          const SizedBox(width: 4),
          Text(
            role.name,
            style: TextStyle(color: role.tint, fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _MessageRow extends StatelessWidget {
  final Widget avatar;
  final String author;
  final Color authorColor;
  final String timestamp;
  final Widget body;
  const _MessageRow({
    required this.avatar,
    required this.author,
    required this.authorColor,
    required this.timestamp,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        avatar,
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    author,
                    style: TextStyle(color: authorColor, fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                  const SizedBox(width: 8),
                  Text(timestamp, style: const TextStyle(color: Color(0xFF8E9297), fontSize: 11)),
                ],
              ),
              const SizedBox(height: 2),
              body,
            ],
          ),
        ),
      ],
    );
  }
}

class _CircleAvatar extends StatelessWidget {
  final Color bg;
  final IconData? glyph;
  final String? text;
  const _CircleAvatar({required this.bg, this.glyph, this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(18),
      ),
      alignment: Alignment.center,
      child: glyph != null
          ? Icon(glyph, color: Colors.white, size: 18)
          : Text(text ?? '?', style: const TextStyle(fontSize: 18)),
    );
  }
}

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final bool submitting;
  final String? error;
  final VoidCallback onSubmit;
  const _Composer({
    required this.controller,
    required this.submitting,
    required this.error,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (error != null) ...[
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
            ),
            const SizedBox(height: 6),
          ],
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF383A40),
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 6,
                    enabled: !submitting,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: const InputDecoration(
                      hintText: 'Message #general — describe a task',
                      hintStyle: TextStyle(color: Color(0xFF8E9297)),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    onSubmitted: (_) => onSubmit(),
                    textInputAction: TextInputAction.send,
                  ),
                ),
                IconButton(
                  tooltip: 'Send',
                  icon: submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send, color: Color(0xFF7C5CFC)),
                  onPressed: submitting ? null : onSubmit,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _formatTimestamp(double secondsSinceEpoch) {
  final dt = DateTime.fromMillisecondsSinceEpoch((secondsSinceEpoch * 1000).round());
  final now = DateTime.now();
  if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
    return 'Today at ${_two(dt.hour)}:${_two(dt.minute)}';
  }
  return '${dt.year}-${_two(dt.month)}-${_two(dt.day)} ${_two(dt.hour)}:${_two(dt.minute)}';
}

String _two(int n) => n.toString().padLeft(2, '0');
