/// Sprint 25: #general — chat-style entry point.
///
/// Each row is a "message": user describes a task, Tally responds with
/// the team it picked + reasoning. Submitting redirects to the new
/// task channel (handled by the shell via onTaskSubmitted).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../agent_roles.dart';
import '../api.dart';
import '../state/workspace_context.dart';
import '../widgets/channel_header.dart';
import '../widgets/cost_estimate_banner.dart';
import '../widgets/team_proposal_card.dart';
import 'workflow_editor.dart';

class GeneralChannelScreen extends StatefulWidget {
  final TallyOrchClient client;
  final List<Task> recentTasks;
  final ValueChanged<Task> onTaskSubmitted;
  /// Sprint 37: when set, the composer submits tasks into this project
  /// so the first agent inherits HEAD artifacts.  Surfaced as a small
  /// "Submitting into: <project>" indicator above the composer so the
  /// user can see what context the next task will inherit.
  final String? activeProjectId;
  const GeneralChannelScreen({
    super.key,
    required this.client,
    required this.recentTasks,
    required this.onTaskSubmitted,
    this.activeProjectId,
  });

  @override
  State<GeneralChannelScreen> createState() => _GeneralChannelScreenState();
}

class _GeneralChannelScreenState extends State<GeneralChannelScreen> {
  final _ctrl = TextEditingController();
  bool _submitting = false;
  String? _error;
  int _availableCredits = 0;
  int _perTaskCap = 100;

  int? _generalChannelId;
  List<Map<String, dynamic>> _proposals = [];

  @override
  void initState() {
    super.initState();
    unawaited(_refreshCreditState());
    unawaited(_loadProposals());
  }

  Future<void> _loadProposals() async {
    try {
      if (_generalChannelId == null) {
        // Resolve #general channel id once
        final channels = await widget.client.listChannels(
          workspaceId: WorkspaceContext.activeIdOrDefault(context),
        );
        final general = channels.firstWhere(
          (c) => c['kind'] == 'general',
          orElse: () => const {},
        );
        if (general.isEmpty) return;
        _generalChannelId = general['id'] as int;
      }
      final msgs = await widget.client.getMessages(channelId: _generalChannelId!);
      if (!mounted) return;
      setState(() {
        _proposals = msgs
            .where((m) => m['kind'] == 'team_proposal')
            .toList();
      });
    } catch (_) {
      // Silent — proposal UI is additive; no UX impact if it fails
    }
  }

  Map<String, dynamic>? _findProposalPayload(String taskId) {
    for (final m in _proposals) {
      try {
        final p = jsonDecode(m['payload_json'] as String) as Map<String, dynamic>;
        if (p['task_id'] == taskId) return p;
      } catch (_) {}
    }
    return null;
  }

  Future<void> _onProposalAction(String taskId, String action) async {
    // Capture context-dependent objects before any await to satisfy
    // use_build_context_synchronously lint rule.
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      switch (action) {
        case 'approve':
          await widget.client.approveTask(taskId: taskId);
          if (mounted) {
            await _loadProposals();
            messenger.showSnackBar(
              const SnackBar(content: Text('Approved — task dispatched')),
            );
          }
          break;
        case 'edit':
          final payload = _findProposalPayload(taskId);
          if (payload == null) return;
          await navigator.push(
            MaterialPageRoute(
              builder: (_) => WorkflowEditorScreen(
                client: widget.client,
                taskId: taskId,
                initialTeamSpec:
                    Map<String, dynamic>.from(payload['team_spec'] as Map),
              ),
            ),
          );
          if (mounted) await _loadProposals();
          break;
        case 'cancel':
          await widget.client.cancelTask(taskId: taskId);
          if (mounted) await _loadProposals();
          break;
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('$action failed: $e')),
        );
      }
    }
  }

  Future<void> _refreshCreditState() async {
    try {
      final results = await Future.wait([
        widget.client.getCreditsBalance(),
        widget.client.getCaps(),
      ]);
      if (!mounted) return;
      setState(() {
        _availableCredits = results[0]['available_credits'] as int;
        _perTaskCap = results[1]['per_task_cap_credits'] as int;
      });
    } catch (_) {
      // banner stays at defaults; no UX impact
    }
  }

  Future<void> _submit({String? overrideDescription, Map<String, dynamic>? teamSpec}) async {
    final desc = (overrideDescription ?? _ctrl.text).trim();
    if (desc.isEmpty || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final t = await widget.client.submitTask(
        desc,
        teamSpec: teamSpec,
        projectId: widget.activeProjectId,
      );
      if (overrideDescription == null) _ctrl.clear();
      if (!mounted) return;
      setState(() => _submitting = false);
      unawaited(_loadProposals());
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
          if (_proposals.isNotEmpty)
            Container(
              constraints: const BoxConstraints(maxHeight: 240),
              color: const Color(0xFF2B2D31),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _proposals.length,
                itemBuilder: (_, i) => TeamProposalCard(
                  message: _proposals[i],
                  onAction: (action) {
                    try {
                      final payload = jsonDecode(
                              _proposals[i]['payload_json'] as String)
                          as Map<String, dynamic>;
                      final taskId =
                          payload['task_id'] as String? ?? '';
                      _onProposalAction(taskId, action);
                    } catch (_) {}
                  },
                ),
              ),
            ),
          Expanded(
            child: _GeneralFeed(
              recentTasks: widget.recentTasks,
              submitting: _submitting,
              onTryExample: (e) => _submit(
                overrideDescription: e.description,
                teamSpec: e.teamSpec,
              ),
            ),
          ),
          if (widget.activeProjectId != null)
            _ActiveProjectStrip(projectId: widget.activeProjectId!),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _ctrl,
            builder: (context, value, _) {
              final est = estimateCreditsClientSide(value.text);
              return CostEstimateBanner(
                estimatedCredits: est,
                availableCredits: _availableCredits,
                perTaskCapCredits: _perTaskCap,
              );
            },
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

/// Sprint 37: small banner just above the composer that reminds the
/// user their next task will land inside an active project (and
/// therefore inherit the project's HEAD artifact set).  Hidden when
/// no project is active — the composer is the default surface for
/// one-off tasks.
class _ActiveProjectStrip extends StatelessWidget {
  final String projectId;
  const _ActiveProjectStrip({required this.projectId});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF7C5CFC).withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            const Icon(Icons.folder, size: 14, color: Color(0xFF7C5CFC)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                "Submitting into project — first agent inherits HEAD artifacts.",
                style: const TextStyle(
                  color: Color(0xFFDCDDDE),
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Sprint 36: example task a new user can try with one tap.  Each
/// example carries a hand-picked team_spec so the user gets to see a
/// successful end-to-end run without having to write a prompt
/// themselves.  Cards only show when the user has zero prior tasks.
class _Example {
  final String emoji;
  final String title;
  final String subtitle;
  final String description;
  final Map<String, dynamic> teamSpec;
  const _Example({
    required this.emoji,
    required this.title,
    required this.subtitle,
    required this.description,
    required this.teamSpec,
  });
}

const _examples = <_Example>[
  _Example(
    emoji: '👋',
    title: 'Hello world (Python)',
    subtitle: '1 agent · ~30 s · the gentlest possible smoke test',
    description:
        'Write hello.py that prints "hello, world" and verify it runs.',
    teamSpec: {
      'agents': [
        {'role': 'Coder', 'model': 'meta-llama/llama-3.3-70b-instruct'},
      ],
      'workflow': 'Coder',
      'reasoning':
          'Tiny self-contained task — one Coder is plenty. Picked as a free-tier '
              'onboarding example so you can see the agent timeline end-to-end '
              'without burning quota.',
    },
  ),
  _Example(
    emoji: '✅',
    title: 'React TODO list',
    subtitle: '2 agents · ~3 min · code + review',
    description:
        'Build a single-file React TODO list component with add, mark-complete, '
        'and delete. Use functional components + useState. Include a quick '
        'render-test to confirm it builds.',
    teamSpec: {
      'agents': [
        {'role': 'Coder', 'model': 'meta-llama/llama-3.3-70b-instruct'},
        {'role': 'Reviewer', 'model': 'meta-llama/llama-3.3-70b-instruct'},
      ],
      'workflow': 'Coder -> Reviewer',
      'reasoning':
          'Coder writes the component; Reviewer catches missing keys, accessibility '
              'issues, and obvious React anti-patterns before the artifact lands.',
    },
  ),
  _Example(
    emoji: '📋',
    title: 'Document a small codebase',
    subtitle: '2 agents · ~4 min · planner + docs',
    description:
        'Write a small Python utility that reads a directory of markdown files '
        'and prints a flat index, then produce README.md describing how the '
        'tool works and how to extend it.',
    teamSpec: {
      'agents': [
        {'role': 'Planner', 'model': 'meta-llama/llama-3.3-70b-instruct'},
        {'role': 'DocWriter', 'model': 'meta-llama/llama-3.3-70b-instruct'},
      ],
      'workflow': 'Planner -> DocWriter',
      'reasoning':
          'Planner outlines the tool + the README structure; DocWriter writes both. '
              "Mirrors the workflow you'd reach for on a real internal-doc task.",
    },
  ),
];

/// Renders recent tasks as Tally's responses. Oldest first (chat scroll),
/// keeps the welcome message at the top. Sprint 36: when the user has
/// zero tasks, shows three "Try this" example cards beneath the welcome.
class _GeneralFeed extends StatelessWidget {
  final List<Task> recentTasks;
  final bool submitting;
  final void Function(_Example) onTryExample;
  const _GeneralFeed({
    required this.recentTasks,
    required this.submitting,
    required this.onTryExample,
  });

  /// Dev affordance: `--dart-define=TALLY_FORCE_ONBOARDING=true` shows the
  /// example cards even when the user has prior tasks.  Useful for taking
  /// screenshots, verifying layout, and demoing the onboarding flow to a
  /// non-fresh account.  No effect on production builds (defaults false).
  static const bool _forceOnboarding =
      bool.fromEnvironment('TALLY_FORCE_ONBOARDING', defaultValue: false);

  @override
  Widget build(BuildContext context) {
    // Reverse-chrono in the list, but display chronologically so the newest
    // message is at the bottom (Discord-style).
    final chronological = [...recentTasks]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final isFirstTime = _forceOnboarding || recentTasks.isEmpty;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      children: [
        const _WelcomeMessage(),
        if (isFirstTime) ...[
          const SizedBox(height: 16),
          _OnboardingExamples(
            examples: _examples,
            submitting: submitting,
            onTry: onTryExample,
          ),
        ],
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

class _OnboardingExamples extends StatelessWidget {
  final List<_Example> examples;
  final bool submitting;
  final void Function(_Example) onTry;
  const _OnboardingExamples({
    required this.examples,
    required this.submitting,
    required this.onTry,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            'Try one of these to see a real multi-agent run:',
            style: TextStyle(
              color: Color(0xFFB9BBBE),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        for (final e in examples) ...[
          _ExampleCard(example: e, submitting: submitting, onTap: () => onTry(e)),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _ExampleCard extends StatelessWidget {
  final _Example example;
  final bool submitting;
  final VoidCallback onTap;
  const _ExampleCard({
    required this.example,
    required this.submitting,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: submitting ? null : onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF2B2D31),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF1E1F22)),
        ),
        child: Row(
          children: [
            Text(example.emoji, style: const TextStyle(fontSize: 28)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    example.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    example.subtitle,
                    style: const TextStyle(color: Color(0xFF99AAB5), fontSize: 11),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    example.description,
                    style: const TextStyle(
                      color: Color(0xFFC4C9CE),
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: submitting ? null : onTap,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF7C5CFC),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
              child: const Text('Try this'),
            ),
          ],
        ),
      ),
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
