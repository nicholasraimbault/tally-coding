/// Sprint 30: visual team builder.
///
/// Kanban-style canvas: stages are columns, agents are cards inside a
/// column.  Agents in the same column run concurrently; stages run
/// strictly in order.  Same JSON engine as the architect — what you
/// build here is exactly what Tally would emit.
///
/// Entry: the ⚙ tile on the server rail.  Exit: save as a template
/// (POST /templates) and/or run a task with this team_spec preset.
library;

import 'package:flutter/material.dart';

import '../agent_roles.dart';
import '../api.dart';

const _validAffinities = ['any', 'tee', 'local', 'local_if_available'];

/// One agent in the builder's draft team_spec. Internal-only; the
/// public surface is the team_spec JSON returned by `_toTeamSpec`.
class _AgentDraft {
  String role;
  String? model;
  String spec;
  String workerAffinity;
  _AgentDraft({
    required this.role,
    this.model,
    this.spec = '',
    this.workerAffinity = 'any',
  });

  Map<String, dynamic> toJson() => {
        'role': role,
        if (model != null && model!.isNotEmpty) 'model': model,
        'spec': spec,
        if (workerAffinity != 'any') 'worker_affinity': workerAffinity,
      };
}

class TeamBuilderScreen extends StatefulWidget {
  final TallyOrchClient client;
  const TeamBuilderScreen({super.key, required this.client});

  @override
  State<TeamBuilderScreen> createState() => _TeamBuilderScreenState();
}

class _TeamBuilderScreenState extends State<TeamBuilderScreen> {
  List<List<_AgentDraft>> _stages = [
    [_AgentDraft(role: 'Planner', spec: 'Plan the task.')],
  ];
  List<Map<String, dynamic>> _palette = const [];
  bool _loading = true;
  String? _error;
  final _taskDescCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadPalette();
  }

  Future<void> _loadPalette() async {
    try {
      final roles = await widget.client.listAgentRoles();
      if (!mounted) return;
      setState(() {
        _palette = roles;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Flatten the stages-of-drafts into a JSON team_spec ready for the
  /// orchestrator. agent_idx is implicit (its position in `agents`).
  Map<String, dynamic> _toTeamSpec() {
    final agents = <Map<String, dynamic>>[];
    final stages = <List<int>>[];
    for (final stage in _stages) {
      final stageIdxs = <int>[];
      for (final a in stage) {
        stageIdxs.add(agents.length);
        agents.add(a.toJson());
      }
      stages.add(stageIdxs);
    }
    final workflow = _stages
        .map((stage) {
          if (stage.length == 1) return stage.first.role;
          return '(${stage.map((a) => a.role).join(' || ')})';
        })
        .join(' -> ');
    return {
      'agents': agents,
      'stages': stages,
      'workflow': workflow,
      'reasoning': 'Hand-built via Sprint 30 visual builder.',
    };
  }

  void _addAgent(int stageIdx) {
    setState(() {
      _stages[stageIdx].add(_AgentDraft(role: 'Coder'));
    });
  }

  void _removeAgent(int stageIdx, int agentIdx) {
    setState(() {
      _stages[stageIdx].removeAt(agentIdx);
      if (_stages[stageIdx].isEmpty && _stages.length > 1) {
        _stages.removeAt(stageIdx);
      }
    });
  }

  void _addStage() {
    setState(() {
      _stages.add([_AgentDraft(role: 'Reviewer')]);
    });
  }

  void _removeStage(int stageIdx) {
    if (_stages.length <= 1) return;
    setState(() {
      _stages.removeAt(stageIdx);
    });
  }

  Future<void> _saveAsTemplate() async {
    if (!_validate()) return;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => const _BuilderSaveDialog(),
    );
    if (result == null || !mounted) return;
    final name = result.trim();
    if (name.isEmpty) return;
    try {
      await widget.client.saveTemplate(name: name, teamSpec: _toTeamSpec());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Saved team as `$name`'),
          backgroundColor: const Color(0xFF57F287),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Save failed: $e'),
          backgroundColor: const Color(0xFFED4245),
        ),
      );
    }
  }

  Future<void> _runAsTask() async {
    if (!_validate()) return;
    final desc = _taskDescCtrl.text.trim();
    if (desc.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Add a task description below the canvas before running.'),
          backgroundColor: Color(0xFFFEE75C),
        ),
      );
      return;
    }
    try {
      final task = await widget.client.submitTask(desc, teamSpec: _toTeamSpec());
      if (!mounted) return;
      Navigator.of(context).pop(task);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Run failed: $e'),
          backgroundColor: const Color(0xFFED4245),
        ),
      );
    }
  }

  bool _validate() {
    final agentCount = _stages.fold<int>(0, (sum, s) => sum + s.length);
    if (agentCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Team is empty — add at least one agent.'),
          backgroundColor: Color(0xFFED4245),
        ),
      );
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1F22),
      appBar: AppBar(
        backgroundColor: const Color(0xFF2B2D31),
        title: const Text('Team builder'),
        actions: [
          if (!_loading) ...[
            TextButton.icon(
              icon: const Icon(Icons.bookmark_add_outlined,
                  color: Color(0xFF8E9297), size: 18),
              label: const Text('Save as template',
                  style: TextStyle(color: Color(0xFFC4C9CE))),
              onPressed: _saveAsTemplate,
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF7C5CFC),
              ),
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('Run'),
              onPressed: _runAsTask,
            ),
            const SizedBox(width: 12),
          ],
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('Error: $_error',
                  style: const TextStyle(color: Color(0xFFED4245))))
              : Column(
                  children: [
                    Expanded(child: _buildCanvas()),
                    _buildTaskInput(),
                  ],
                ),
    );
  }

  Widget _buildCanvas() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (int i = 0; i < _stages.length; i++) ...[
              _StageColumn(
                stageIdx: i,
                stage: _stages[i],
                palette: _palette,
                onAddAgent: () => _addAgent(i),
                onRemoveAgent: (j) => _removeAgent(i, j),
                onRemoveStage: () => _removeStage(i),
                onAgentChanged: () => setState(() {}),
                canRemoveStage: _stages.length > 1,
              ),
              if (i < _stages.length - 1)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 60),
                  child: Icon(Icons.arrow_forward,
                      color: Color(0xFF8E9297), size: 28),
                ),
            ],
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 60),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add stage'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF8E9297),
                  side: const BorderSide(color: Color(0xFF404249)),
                ),
                onPressed: _addStage,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTaskInput() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      decoration: const BoxDecoration(
        color: Color(0xFF2B2D31),
        border: Border(top: BorderSide(color: Color(0xFF1E1F22), width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Task description (for Run)',
            style: TextStyle(color: Color(0xFF8E9297), fontSize: 11,
                fontWeight: FontWeight.w600, letterSpacing: 0.8),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _taskDescCtrl,
            minLines: 1,
            maxLines: 3,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: const InputDecoration(
              hintText: 'What should this team do?',
              hintStyle: TextStyle(color: Color(0xFF4F545C)),
              filled: true,
              fillColor: Color(0xFF383A40),
              border: OutlineInputBorder(borderSide: BorderSide.none),
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              isDense: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _StageColumn extends StatelessWidget {
  final int stageIdx;
  final List<_AgentDraft> stage;
  final List<Map<String, dynamic>> palette;
  final VoidCallback onAddAgent;
  final ValueChanged<int> onRemoveAgent;
  final VoidCallback onRemoveStage;
  final VoidCallback onAgentChanged;
  final bool canRemoveStage;
  const _StageColumn({
    required this.stageIdx,
    required this.stage,
    required this.palette,
    required this.onAddAgent,
    required this.onRemoveAgent,
    required this.onRemoveStage,
    required this.onAgentChanged,
    required this.canRemoveStage,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: const Color(0xFF2B2D31),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF1E1F22)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 6, 6),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFF1E1F22))),
            ),
            child: Row(
              children: [
                Icon(
                  stage.length > 1 ? Icons.call_split : Icons.linear_scale,
                  size: 14,
                  color: const Color(0xFF8E9297),
                ),
                const SizedBox(width: 6),
                Text(
                  stage.length > 1
                      ? 'Stage ${stageIdx + 1} · ${stage.length} parallel'
                      : 'Stage ${stageIdx + 1}',
                  style: const TextStyle(
                    color: Color(0xFFB9BBBE),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
                const Spacer(),
                if (canRemoveStage)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 16,
                        color: Color(0xFF8E9297)),
                    onPressed: onRemoveStage,
                    tooltip: 'Remove stage',
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                for (int i = 0; i < stage.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _AgentCard(
                      draft: stage[i],
                      palette: palette,
                      onChanged: onAgentChanged,
                      onRemove: () => onRemoveAgent(i),
                    ),
                  ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add agent'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF8E9297),
                    side: const BorderSide(color: Color(0xFF404249)),
                    minimumSize: const Size.fromHeight(36),
                  ),
                  onPressed: onAddAgent,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AgentCard extends StatelessWidget {
  final _AgentDraft draft;
  final List<Map<String, dynamic>> palette;
  final VoidCallback onChanged;
  final VoidCallback onRemove;
  const _AgentCard({
    required this.draft,
    required this.palette,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final role = agentRoleOf(draft.role);
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF313338),
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(color: role.tint, width: 3)),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(role.glyph, style: const TextStyle(fontSize: 14)),
              const SizedBox(width: 6),
              Expanded(
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: draft.role,
                    isDense: true,
                    dropdownColor: const Color(0xFF313338),
                    style: TextStyle(color: role.tint, fontSize: 13,
                        fontWeight: FontWeight.w600),
                    iconEnabledColor: const Color(0xFF8E9297),
                    iconSize: 16,
                    items: [
                      for (final r in palette)
                        DropdownMenuItem(
                          value: r['name'] as String,
                          child: Text(
                            r['name'] as String,
                            style: TextStyle(
                              color: agentRoleOf(r['name'] as String).tint,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                    onChanged: (v) {
                      if (v != null) {
                        draft.role = v;
                        // Reset model to the new role's default.
                        final r = palette.firstWhere(
                          (e) => e['name'] == v,
                          orElse: () => const {},
                        );
                        if (r.isNotEmpty) {
                          draft.model = r['default_model'] as String?;
                        }
                        onChanged();
                      }
                    },
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 14,
                    color: Color(0xFF8E9297)),
                onPressed: onRemove,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                tooltip: 'Remove agent',
              ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: TextEditingController(text: draft.spec),
            minLines: 1,
            maxLines: 4,
            style: const TextStyle(color: Color(0xFFDCDDDE), fontSize: 12),
            decoration: const InputDecoration(
              hintText: 'What should this agent do?',
              hintStyle: TextStyle(color: Color(0xFF4F545C), fontSize: 12),
              isDense: true,
              filled: true,
              fillColor: Color(0xFF2B2D31),
              border: OutlineInputBorder(borderSide: BorderSide.none),
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            ),
            onChanged: (v) {
              draft.spec = v;
            },
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.computer, size: 12, color: Color(0xFF8E9297)),
              const SizedBox(width: 4),
              Text('runs on', style: TextStyle(
                  color: const Color(0xFF8E9297), fontSize: 10)),
              const SizedBox(width: 4),
              DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: draft.workerAffinity,
                  isDense: true,
                  dropdownColor: const Color(0xFF313338),
                  style: const TextStyle(color: Color(0xFFC4C9CE), fontSize: 11),
                  iconEnabledColor: const Color(0xFF8E9297),
                  iconSize: 14,
                  items: [
                    for (final a in _validAffinities)
                      DropdownMenuItem(value: a, child: Text(a)),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      draft.workerAffinity = v;
                      onChanged();
                    }
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BuilderSaveDialog extends StatefulWidget {
  const _BuilderSaveDialog();
  @override
  State<_BuilderSaveDialog> createState() => _BuilderSaveDialogState();
}

class _BuilderSaveDialogState extends State<_BuilderSaveDialog> {
  final _nameCtrl = TextEditingController();
  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF2B2D31),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Save built team as template',
                  style: TextStyle(color: Colors.white, fontSize: 16,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
              TextField(
                controller: _nameCtrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Name',
                  labelStyle: TextStyle(color: Color(0xFF8E9297)),
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => Navigator.of(context).pop(_nameCtrl.text),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel',
                        style: TextStyle(color: Color(0xFF8E9297))),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF7C5CFC),
                    ),
                    onPressed: () => Navigator.of(context).pop(_nameCtrl.text),
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
