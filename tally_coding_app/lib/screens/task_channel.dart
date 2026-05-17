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
            trailing: t == null ? null : _StatusBadge(status: t.status),
          ),
          Expanded(child: _body(t)),
        ],
      ),
    );
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
              text: 'Tally picked '
                  '${(t.teamSpec!['agents'] as List).length} agent(s): '
                  '${(t.teamSpec!['workflow'] as String?) ?? "(no workflow)"}',
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
  List<Widget> _renderTimeline(bool taskRunning) {
    final groups = <int?, List<Map<String, dynamic>>>{};
    for (final ev in _events) {
      final idx = ev['agent_idx'] as int?;
      groups.putIfAbsent(idx, () => []).add(ev);
    }
    // Sort: null first (legacy), then numeric agent_idx.
    final keys = groups.keys.toList()
      ..sort((a, b) => (a ?? -1).compareTo(b ?? -1));
    final widgets = <Widget>[];
    for (final k in keys) {
      final events = groups[k]!;
      final role = events.first['agent_role'] as String? ?? '?';
      final model = events.first['agent_model'] as String? ?? '';
      final isLastAgent = k == keys.last;
      widgets.add(_AgentBand(
        role: role,
        model: model,
        events: events,
        isLive: isLastAgent && taskRunning,
      ));
      widgets.add(const SizedBox(height: 12));
    }
    return widgets;
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
  const _AgentBand({
    required this.role,
    required this.model,
    required this.events,
    required this.isLive,
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
