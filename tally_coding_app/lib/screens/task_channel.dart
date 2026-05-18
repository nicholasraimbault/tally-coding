/// Sprint 25: task channel — the main-pane view when a task is selected.
///
/// Same SSE stream + agent timeline + workspace tree as the old
/// TaskDetailScreen, but embedded as a panel (no AppBar) and themed for
/// the Discord shell. Each agent's events get a colored band so the
/// Planner → Coder → Reviewer flow is readable as a chat.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../agent_roles.dart';
import '../api.dart';
import '../widgets/channel_header.dart';
import 'file_tree.dart';

class TaskChannelScreen extends StatefulWidget {
  final TallyOrchClient client;
  final String taskId;
  const TaskChannelScreen({super.key, required this.client, required this.taskId});

  @override
  State<TaskChannelScreen> createState() => _TaskChannelScreenState();
}

class _TaskChannelScreenState extends State<TaskChannelScreen> {
  Task? _task;
  final List<Map<String, dynamic>> _events = [];
  int _lastSeq = -1;
  String? _error;
  StreamSubscription? _framesSub;
  List<Map<String, dynamic>>? _files;
  String? _filesError;
  bool _filesLoading = false;
  final _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _fetchInitial();
    _connectStream();
  }

  @override
  void dispose() {
    _framesSub?.cancel();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchInitial() async {
    try {
      final t = await widget.client.getTask(widget.taskId);
      if (!mounted) return;
      setState(() => _task = t);
      if (t.isTerminal && _files == null && !_filesLoading) _fetchFiles();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _fetchFiles() async {
    if (_filesLoading) return;
    setState(() => _filesLoading = true);
    try {
      final entries = await widget.client.listFiles(widget.taskId);
      if (!mounted) return;
      setState(() {
        _files = entries;
        _filesError = null;
        _filesLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _filesError = e.toString();
        _filesLoading = false;
      });
    }
  }

  void _connectStream() {
    _framesSub?.cancel();
    _framesSub = widget.client.streamFrames(widget.taskId, sinceSeq: _lastSeq).listen(
      (frame) {
        if (!mounted) return;
        setState(() {
          if (frame.name == 'task_event') {
            _events.add(frame.data);
            _lastSeq = frame.data['seq'] as int;
            // Auto-scroll to bottom when new event arrives (Discord shape).
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_scrollCtrl.hasClients) {
                _scrollCtrl.animateTo(
                  _scrollCtrl.position.maxScrollExtent,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                );
              }
            });
          } else if (frame.name == 'status_change') {
            final t = _task;
            final newStatus = frame.data['status'] as String;
            final ts = (frame.data['ts'] as num?)?.toDouble() ??
                DateTime.now().millisecondsSinceEpoch / 1000.0;
            if (t != null) {
              _task = Task(
                id: t.id,
                description: t.description,
                status: newStatus,
                result: t.result,
                error: t.error,
                createdAt: t.createdAt,
                updatedAt: ts,
                teamSpec: t.teamSpec,
              );
            }
            if (newStatus == 'completed' || newStatus == 'failed') {
              _fetchInitial();
            }
          }
          _error = null;
        });
      },
      onError: (e) {
        if (!mounted) return;
        setState(() => _error = 'stream: $e');
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) _connectStream();
        });
      },
      cancelOnError: true,
    );
  }

  Future<void> _openFileViewer(String path) async {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF313338),
        insetPadding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800, maxHeight: 600),
          child: _FileViewerDialog(
            client: widget.client,
            taskId: widget.taskId,
            path: path,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = _task;
    return Container(
      color: const Color(0xFF313338),
      child: Column(
        children: [
          ChannelHeader(
            glyph: '#',
            name: t?.id.substring(0, 8) ?? widget.taskId.substring(0, 8),
            description: t?.description ?? 'Loading…',
            trailing: t == null ? null : _HeaderTrailing(
              task: t,
              onSaveTemplate: () => _promptSaveTemplate(t),
            ),
          ),
          Expanded(child: _body(t)),
        ],
      ),
    );
  }

  Future<void> _promptSaveTemplate(Task t) async {
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => const _SaveTemplateDialog(),
    );
    if (result == null || !mounted) return;
    final parts = result.split('\n');
    final name = parts.first.trim();
    final note = parts.length > 1 ? parts.sublist(1).join('\n').trim() : null;
    try {
      await widget.client.saveTemplate(
        name: name,
        sourceTaskId: t.id,
        note: note?.isEmpty == true ? null : note,
      );
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
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Widget _body(Task? t) {
    if (t == null) {
      return Center(
        child: _error != null
            ? Text('Error: $_error', style: const TextStyle(color: Color(0xFF99AAB5)))
            : const CircularProgressIndicator(),
      );
    }
    return SingleChildScrollView(
      controller: _scrollCtrl,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SystemMessage(
            icon: Icons.task_alt,
            text: t.description,
            timestamp: t.createdAt,
          ),
          const SizedBox(height: 16),
          if (t.teamSpec != null) ...[
            _SystemMessage(
              icon: Icons.auto_awesome,
              text: () {
                final agents = (t.teamSpec!['agents'] as List).length;
                final flow = (t.teamSpec!['workflow'] as String?) ?? '(no workflow)';
                final template = t.teamSpec!['template_used'] as String?;
                final base = 'Tally picked $agents agent(s): $flow';
                return template != null && template.isNotEmpty
                    ? '$base · via template `$template`'
                    : base;
              }(),
              timestamp: t.createdAt,
            ),
            const SizedBox(height: 16),
          ],
          if (_events.isNotEmpty) ..._renderTimeline(t.status == 'running' || t.status == 'pending'),
          if (t.isTerminal && t.result != null) ...[
            const SizedBox(height: 16),
            _ResultCard(result: t.result!),
          ],
          if (t.isTerminal) ...[
            const SizedBox(height: 16),
            _WorkspaceCard(
              files: _files,
              filesError: _filesError,
              loading: _filesLoading,
              onRefresh: _fetchFiles,
              onFileTap: _openFileViewer,
            ),
          ],
          if (t.status == 'failed' && t.error != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFED4245).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFFED4245).withValues(alpha: 0.4)),
              ),
              child: SelectableText(
                t.error!,
                style: const TextStyle(color: Color(0xFFFFAAAA),
                    fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Group events by agent_idx (Sprint 22+ added this field to every event)
  /// and render each group with a colored band so multi-agent runs are
  /// readable. Events without agent_idx (Sprint 13 legacy) get a single
  /// unattributed band.
  ///
  /// Sprint 27.5 (open-items round): when team_spec.stages is set, insert
  /// a "Stage N" divider before the first agent of each stage so a
  /// reader of the chat scrollback can tell parallel stages apart from
  /// sequential ones.
  List<Widget> _renderTimeline(bool taskRunning) {
    final groups = <int?, List<Map<String, dynamic>>>{};
    for (final ev in _events) {
      final idx = ev['agent_idx'] as int?;
      groups.putIfAbsent(idx, () => []).add(ev);
    }
    final keys = groups.keys.toList()
      ..sort((a, b) => (a ?? -1).compareTo(b ?? -1));
    // Build a {agent_idx → stage_idx} lookup from team_spec.stages.
    final teamSpec = _task?.teamSpec;
    final stages = (teamSpec?['stages'] as List<dynamic>?) ?? const [];
    final stageByAgent = <int, int>{};
    for (var s = 0; s < stages.length; s++) {
      for (final i in (stages[s] as List<dynamic>)) {
        if (i is int) stageByAgent[i] = s;
      }
    }
    // Per-agent file list from result.agents[i].result.files_created.
    // Available the moment the agent finishes; missing for in-flight
    // agents and for legacy single-agent tasks.
    final filesByAgent = <int, List<String>>{};
    final resultAgents = (_task?.result?['agents'] as List<dynamic>?) ?? const [];
    for (final a in resultAgents) {
      if (a is! Map<String, dynamic>) continue;
      final idx = a['agent_idx'];
      final r = a['result'];
      if (idx is! int || r is! Map<String, dynamic>) continue;
      final fc = r['files_created'];
      if (fc is List) {
        filesByAgent[idx] = fc.whereType<String>().toList();
      }
    }
    final widgets = <Widget>[];
    int? prevStage;
    final seenPaths = <String>{};
    for (final k in keys) {
      final events = groups[k]!;
      final role = events.first['agent_role'] as String? ?? '?';
      final model = events.first['agent_model'] as String? ?? '';
      final isLastAgent = k == keys.last;
      final stageIdx = (k != null) ? stageByAgent[k] : null;
      // Emit a stage divider when we cross a stage boundary AND the
      // team actually has a multi-stage shape (stages.length > 1).
      if (stages.length > 1 && stageIdx != null && stageIdx != prevStage) {
        final agentsInStage = (stages[stageIdx] as List).length;
        widgets.add(_StageDivider(
          stageIdx: stageIdx,
          agentsInStage: agentsInStage,
        ));
        prevStage = stageIdx;
      }
      // Sprint 25.5 (open-items round): split the agent's file list
      // into "new" (paths not seen in a prior agent) and "touched"
      // (rewrote a prior file) so the user can tell where work was
      // *added* vs where it was *iterated on*.
      final allFiles = (k != null ? filesByAgent[k] : null) ?? const [];
      final newFiles = <String>[];
      final touchedFiles = <String>[];
      for (final p in allFiles) {
        if (seenPaths.contains(p)) {
          touchedFiles.add(p);
        } else {
          newFiles.add(p);
          seenPaths.add(p);
        }
      }
      widgets.add(_AgentBand(
        role: role,
        model: model,
        events: events,
        isLive: isLastAgent && taskRunning,
        newFiles: newFiles,
        touchedFiles: touchedFiles,
        onFileTap: _openFileViewer,
      ));
      widgets.add(const SizedBox(height: 12));
    }
    return widgets;
  }
}

class _StageDivider extends StatelessWidget {
  final int stageIdx;
  final int agentsInStage;
  const _StageDivider({required this.stageIdx, required this.agentsInStage});

  @override
  Widget build(BuildContext context) {
    final label = agentsInStage > 1
        ? 'Stage ${stageIdx + 1} · $agentsInStage agents in parallel'
        : 'Stage ${stageIdx + 1}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 12),
      child: Row(
        children: [
          Expanded(
            child: Container(height: 1, color: const Color(0xFF1E1F22)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF2B2D31),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF404249)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    agentsInStage > 1 ? Icons.call_split : Icons.linear_scale,
                    size: 12,
                    color: const Color(0xFF8E9297),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: const TextStyle(
                      color: Color(0xFFB9BBBE),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Container(height: 1, color: const Color(0xFF1E1F22)),
          ),
        ],
      ),
    );
  }
}

class _SystemMessage extends StatelessWidget {
  final IconData icon;
  final String text;
  final double timestamp;
  const _SystemMessage({required this.icon, required this.text, required this.timestamp});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: const Color(0xFF8E9297)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: Color(0xFFB9BBBE), fontSize: 13, height: 1.5),
          ),
        ),
      ],
    );
  }
}

class _AgentBand extends StatelessWidget {
  final String role;
  final String model;
  final List<Map<String, dynamic>> events;
  final bool isLive;
  final List<String> newFiles;
  final List<String> touchedFiles;
  final ValueChanged<String>? onFileTap;
  const _AgentBand({
    required this.role,
    required this.model,
    required this.events,
    required this.isLive,
    this.newFiles = const [],
    this.touchedFiles = const [],
    this.onFileTap,
  });

  @override
  Widget build(BuildContext context) {
    final r = agentRoleOf(role);
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF2B2D31),
        borderRadius: BorderRadius.circular(6),
        border: Border(
          left: BorderSide(color: r.tint, width: 4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: r.tint.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  alignment: Alignment.center,
                  child: Text(r.glyph, style: const TextStyle(fontSize: 14)),
                ),
                const SizedBox(width: 8),
                Text(
                  r.name,
                  style: TextStyle(
                    color: r.tint,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(width: 8),
                if (model.isNotEmpty)
                  Text(
                    model.split('/').last,
                    style: const TextStyle(color: Color(0xFF8E9297), fontSize: 11),
                  ),
                const Spacer(),
                if (isLive)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF5865F2).withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'working…',
                      style: TextStyle(color: Color(0xFF5865F2), fontSize: 10, fontWeight: FontWeight.w600),
                    ),
                  ),
              ],
            ),
          ),
          ...[
            for (final w in _renderEvents(context, events, isLive)) w,
          ],
          if (newFiles.isNotEmpty || touchedFiles.isNotEmpty)
            _AgentFilesPanel(
              tint: agentRoleOf(role).tint,
              newFiles: newFiles,
              touchedFiles: touchedFiles,
              onTap: onFileTap,
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  List<Widget> _renderEvents(BuildContext context, List<Map<String, dynamic>> events, bool isLive) {
    final widgets = <Widget>[];
    var i = 0;
    while (i < events.length) {
      final ev = events[i];
      if (ev['type'] == 'TokenBatch') {
        final run = <Map<String, dynamic>>[];
        while (i < events.length && events[i]['type'] == 'TokenBatch') {
          run.add(events[i]);
          i++;
        }
        final isLastInBand = i == events.length;
        widgets.add(_tokenBubble(context, run, isLive: isLive && isLastInBand));
      } else {
        widgets.add(_eventTile(context, ev));
        i++;
      }
    }
    return widgets;
  }

  Widget _eventTile(BuildContext context, Map<String, dynamic> ev) {
    final type = ev['type'] as String? ?? '?';
    final actionType = ev['action_type'] as String?;
    final obsType = ev['observation_type'] as String?;
    final body = ev['command'] ?? ev['path'] ?? ev['content'] ?? ev['output'] ?? ev['message'];
    String? bodyStr = body is String ? body : null;
    if (bodyStr != null && bodyStr.length > 200) bodyStr = '${bodyStr.substring(0, 200)}…';

    String label = type;
    if (actionType != null) label = '$type · $actionType';
    if (obsType != null) label = '$type · $obsType';

    final (icon, color) = switch (type) {
      'ActionEvent' => (Icons.play_arrow, Color(0xFF5865F2)),
      'ObservationEvent' => (Icons.visibility, Color(0xFFFEE75C)),
      'MessageEvent' => (Icons.message, Color(0xFFEB459E)),
      'AgentErrorEvent' => (Icons.error, Color(0xFFED4245)),
      _ => (Icons.circle_outlined, Color(0xFF8E9297)),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(color: Color(0xFFB9BBBE), fontSize: 11, fontWeight: FontWeight.w600),
                ),
                if (bodyStr != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      bodyStr,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFDCDDDE),
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Text(
            '#${ev['seq']}',
            style: const TextStyle(color: Color(0xFF8E9297), fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _tokenBubble(BuildContext context, List<Map<String, dynamic>> batches, {required bool isLive}) {
    final text = batches.map((b) => b['content'] as String? ?? '').join();
    final r = agentRoleOf(role);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: r.tint.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(4),
        ),
        child: RichText(
          text: TextSpan(
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              height: 1.4,
              color: Color(0xFFDCDDDE),
            ),
            children: [
              TextSpan(text: text),
              if (isLive)
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: _BlinkingCursor(color: r.tint),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AgentFilesPanel extends StatelessWidget {
  final Color tint;
  final List<String> newFiles;
  final List<String> touchedFiles;
  final ValueChanged<String>? onTap;
  const _AgentFilesPanel({
    required this.tint,
    required this.newFiles,
    required this.touchedFiles,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1F22).withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.folder_open, size: 12, color: tint),
                const SizedBox(width: 6),
                Text(
                  'files',
                  style: TextStyle(
                    color: tint,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(width: 8),
                if (newFiles.isNotEmpty)
                  Text(
                    '+${newFiles.length} new',
                    style: const TextStyle(color: Color(0xFF57F287), fontSize: 10),
                  ),
                if (newFiles.isNotEmpty && touchedFiles.isNotEmpty)
                  const Text(' · ', style: TextStyle(color: Color(0xFF8E9297), fontSize: 10)),
                if (touchedFiles.isNotEmpty)
                  Text(
                    '~${touchedFiles.length} touched',
                    style: const TextStyle(color: Color(0xFFFEE75C), fontSize: 10),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final p in newFiles)
                  _FileChip(path: p, color: const Color(0xFF57F287), onTap: onTap),
                for (final p in touchedFiles)
                  _FileChip(path: p, color: const Color(0xFFFEE75C), onTap: onTap),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FileChip extends StatelessWidget {
  final String path;
  final Color color;
  final ValueChanged<String>? onTap;
  const _FileChip({required this.path, required this.color, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap == null ? null : () => onTap!(path),
      borderRadius: BorderRadius.circular(3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          path,
          style: TextStyle(
            color: color,
            fontFamily: 'monospace',
            fontSize: 10.5,
          ),
        ),
      ),
    );
  }
}


class _BlinkingCursor extends StatefulWidget {
  final Color color;
  const _BlinkingCursor({required this.color});
  @override
  State<_BlinkingCursor> createState() => _BlinkingCursorState();
}

class _BlinkingCursorState extends State<_BlinkingCursor> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))..repeat(reverse: true);
  }
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _ctrl,
        child: Text('▌', style: TextStyle(color: widget.color, fontSize: 11)),
      );
}

/// Sprint 29: header trailing controls — status badge + "save this team"
/// bookmark for completed multi-agent tasks.
class _HeaderTrailing extends StatelessWidget {
  final Task task;
  final VoidCallback onSaveTemplate;
  const _HeaderTrailing({required this.task, required this.onSaveTemplate});

  @override
  Widget build(BuildContext context) {
    final canSave = task.isTerminal && task.teamSpec != null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (canSave)
          IconButton(
            tooltip: 'Save this team as a template',
            icon: const Icon(Icons.bookmark_add_outlined, size: 18,
                color: Color(0xFF8E9297)),
            onPressed: onSaveTemplate,
          ),
        _StatusBadge(status: task.status),
      ],
    );
  }
}

class _SaveTemplateDialog extends StatefulWidget {
  const _SaveTemplateDialog();
  @override
  State<_SaveTemplateDialog> createState() => _SaveTemplateDialogState();
}

class _SaveTemplateDialogState extends State<_SaveTemplateDialog> {
  final _nameCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();

  void _save() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop('$name\n${_noteCtrl.text}');
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF2B2D31),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Save this team as a template',
                style: TextStyle(color: Colors.white, fontSize: 16,
                    fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              const Text(
                "Tally will reuse this team verbatim when a future task is a "
                "clean match, otherwise it'll build fresh.",
                style: TextStyle(color: Color(0xFF8E9297), fontSize: 12, height: 1.4),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _nameCtrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Name',
                  labelStyle: TextStyle(color: Color(0xFF8E9297)),
                  hintText: 'e.g. fast-pytest, fullstack-fe-be',
                  hintStyle: TextStyle(color: Color(0xFF4F545C)),
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _noteCtrl,
                minLines: 1,
                maxLines: 3,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: const InputDecoration(
                  labelText: 'Note (optional)',
                  labelStyle: TextStyle(color: Color(0xFF8E9297)),
                  hintText: 'When does this team shine?',
                  hintStyle: TextStyle(color: Color(0xFF4F545C)),
                  border: OutlineInputBorder(),
                ),
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
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF7C5CFC),
                    ),
                    icon: const Icon(Icons.bookmark_add, size: 16),
                    label: const Text('Save'),
                    onPressed: _save,
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

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final (color, icon, label) = switch (status) {
      'completed' => (Color(0xFF57F287), Icons.check_circle, 'completed'),
      'failed' => (Color(0xFFED4245), Icons.error, 'failed'),
      'running' => (Color(0xFF5865F2), Icons.play_arrow, 'running'),
      'pending' => (Color(0xFFFEE75C), Icons.schedule, 'pending'),
      _ => (Color(0xFF8E9297), Icons.help, status),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  final Map<String, dynamic> result;
  const _ResultCard({required this.result});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2D31),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF1E1F22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Result',
            style: TextStyle(color: Color(0xFFC4C9CE), fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1.1),
          ),
          const SizedBox(height: 6),
          SelectableText(
            const JsonEncoder.withIndent('  ').convert(result),
            style: const TextStyle(color: Color(0xFFDCDDDE), fontFamily: 'monospace', fontSize: 11, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceCard extends StatelessWidget {
  final List<Map<String, dynamic>>? files;
  final String? filesError;
  final bool loading;
  final VoidCallback onRefresh;
  final ValueChanged<String> onFileTap;
  const _WorkspaceCard({
    required this.files,
    required this.filesError,
    required this.loading,
    required this.onRefresh,
    required this.onFileTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2D31),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF1E1F22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.folder, color: Color(0xFF8E9297), size: 16),
              const SizedBox(width: 6),
              const Text(
                'Workspace',
                style: TextStyle(color: Color(0xFFC4C9CE), fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1.1),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh, size: 16, color: Color(0xFF8E9297)),
                onPressed: loading ? null : onRefresh,
              ),
            ],
          ),
          if (loading && files == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (filesError != null && files == null)
            Text(filesError!, style: const TextStyle(color: Color(0xFFED4245), fontSize: 12))
          else if (files != null)
            FileTreeView(
              root: FileTreeNode.build(files!),
              onFileTap: onFileTap,
            ),
        ],
      ),
    );
  }
}

class _FileViewerDialog extends StatefulWidget {
  final TallyOrchClient client;
  final String taskId;
  final String path;
  const _FileViewerDialog({
    required this.client,
    required this.taskId,
    required this.path,
  });

  @override
  State<_FileViewerDialog> createState() => _FileViewerDialogState();
}

class _FileViewerDialogState extends State<_FileViewerDialog> {
  String? _content;
  int? _size;
  bool _truncated = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.client.readFile(widget.taskId, widget.path);
      if (!mounted) return;
      setState(() {
        _content = r.content;
        _size = r.size;
        _truncated = r.truncated;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.description, color: Color(0xFF8E9297), size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.path,
                  style: const TextStyle(
                    color: Colors.white,
                    fontFamily: 'monospace',
                    fontSize: 13,
                  ),
                ),
              ),
              if (_size != null)
                Text(
                  '$_size bytes${_truncated ? " (truncated)" : ""}',
                  style: const TextStyle(color: Color(0xFF8E9297), fontSize: 11),
                ),
              IconButton(
                icon: const Icon(Icons.close, color: Color(0xFF8E9297)),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const Divider(color: Color(0xFF1E1F22)),
          Expanded(
            child: _error != null
                ? Center(child: Text('Error: $_error', style: const TextStyle(color: Color(0xFFED4245))))
                : _content == null
                    ? const Center(child: CircularProgressIndicator())
                    : SingleChildScrollView(
                        child: SelectableText(
                          _content!,
                          style: const TextStyle(
                            color: Color(0xFFDCDDDE),
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}
