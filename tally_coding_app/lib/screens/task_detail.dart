import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../api.dart';
import 'file_tree.dart';

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
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _ctrl,
        child: Text('▌', style: TextStyle(color: widget.color, fontSize: 14)),
      );
}

class TaskDetailScreen extends StatefulWidget {
  final TallyOrchClient client;
  final String taskId;
  const TaskDetailScreen({super.key, required this.client, required this.taskId});

  @override
  State<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends State<TaskDetailScreen> {
  Task? _task;
  final List<Map<String, dynamic>> _events = [];
  int _lastSeq = -1;
  String? _error;
  StreamSubscription? _framesSub;
  // Workspace tree state — fetched once after the task reaches terminal.
  List<Map<String, dynamic>>? _files;
  String? _filesError;
  bool _filesLoading = false;

  @override
  void initState() {
    super.initState();
    // One-shot initial fetch so we have description + initial status to render
    // before the SSE stream connects.
    _fetchInitial();
    _connectStream();
    // Optional deep-link: open a file viewer on first frame (dev / screenshot use).
    const autoOpenFile = String.fromEnvironment('TALLY_AUTO_OPEN_FILE');
    if (autoOpenFile.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openFileViewer(autoOpenFile);
      });
    }
  }

  @override
  void dispose() {
    _framesSub?.cancel();
    super.dispose();
  }

  Future<void> _fetchInitial() async {
    try {
      final t = await widget.client.getTask(widget.taskId);
      if (!mounted) return;
      setState(() => _task = t);
      // If the task is already terminal (page open after completion) and we
      // haven't fetched the workspace yet, kick that off now too.
      if (t.isTerminal && _files == null && !_filesLoading) {
        _fetchFiles();
      }
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
          } else if (frame.name == 'status_change') {
            // Splice the new status into our local Task. The server's first
            // post-connect status_change is a snapshot so we always converge.
            final t = _task;
            final newStatus = frame.data['status'] as String;
            final ts = (frame.data['ts'] as num?)?.toDouble() ?? DateTime.now().millisecondsSinceEpoch / 1000.0;
            if (t != null) {
              _task = Task(
                id: t.id,
                description: t.description,
                status: newStatus,
                result: t.result,
                error: t.error,
                createdAt: t.createdAt,
                updatedAt: ts,
              );
            }
            // If transitioning to terminal, refetch once to pick up result/error.
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
        insetPadding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800, maxHeight: 600),
          child: _FileViewerDialog(client: widget.client, taskId: widget.taskId, path: path),
        ),
      ),
    );
  }

  Widget _statusChip(Task t) {
    final cs = Theme.of(context).colorScheme;
    final (color, icon) = switch (t.status) {
      'completed' => (Colors.green, Icons.check_circle),
      'failed' => (cs.error, Icons.error),
      'running' => (cs.primary, Icons.play_arrow),
      _ => (cs.onSurfaceVariant, Icons.schedule),
    };
    return Chip(
      avatar: Icon(icon, color: color, size: 18),
      label: Text(t.status),
      backgroundColor: color.withValues(alpha: 0.1),
    );
  }

  Widget _eventTile(Map<String, dynamic> ev) {
    final type = ev['type'] as String? ?? '?';
    final actionType = ev['action_type'] as String?;
    final obsType = ev['observation_type'] as String?;
    final command = ev['command'] as String?;
    final path = ev['path'] as String?;
    final content = ev['content'] as String?;
    final output = ev['output'] as String?;
    final message = ev['message'] as String?;

    String label = type;
    if (actionType != null) label = '$type · $actionType';
    if (obsType != null) label = '$type · $obsType';

    String? body = command ?? path ?? content ?? output ?? message;
    if (body != null && body.length > 200) body = '${body.substring(0, 200)}…';

    final (icon, color) = switch (type) {
      'ActionEvent' => (Icons.play_arrow, Theme.of(context).colorScheme.primary),
      'ObservationEvent' => (Icons.visibility, Theme.of(context).colorScheme.secondary),
      'MessageEvent' => (Icons.message, Theme.of(context).colorScheme.tertiary),
      'AgentErrorEvent' => (Icons.error, Theme.of(context).colorScheme.error),
      _ => (Icons.circle_outlined, Theme.of(context).colorScheme.onSurfaceVariant),
    };

    return ListTile(
      dense: true,
      leading: Icon(icon, color: color, size: 18),
      title: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
      subtitle: body != null
          ? Text(body, style: const TextStyle(fontFamily: 'monospace', fontSize: 11), maxLines: 4, overflow: TextOverflow.ellipsis)
          : null,
      trailing: Text('#${ev['seq']}', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11)),
    );
  }

  /// Renders a contiguous run of TokenBatch events as one growing "streaming
  /// thought" bubble. Shows a typing cursor while the run is still live (i.e.,
  /// it's the last group of events and the task is still running).
  Widget _tokenBubble(List<Map<String, dynamic>> batches, {required bool isLive}) {
    final text = batches.map((b) => b['content'] as String? ?? '').join();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.psychology, size: 18, color: Theme.of(context).colorScheme.tertiary),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.tertiaryContainer.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Theme.of(context).colorScheme.tertiary.withValues(alpha: 0.3)),
              ),
              child: RichText(
                text: TextSpan(
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4),
                  children: [
                    TextSpan(
                      text: text,
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
                    ),
                    if (isLive)
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: _BlinkingCursor(color: Theme.of(context).colorScheme.tertiary),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Text(
            '${batches.length} batch${batches.length == 1 ? '' : 'es'}',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 10),
          ),
        ],
      ),
    );
  }

  List<Widget> _renderTimeline(bool taskRunning) {
    final widgets = <Widget>[];
    var i = 0;
    while (i < _events.length) {
      final ev = _events[i];
      if (ev['type'] == 'TokenBatch') {
        // Collect this contiguous run of TokenBatch events.
        final run = <Map<String, dynamic>>[];
        while (i < _events.length && _events[i]['type'] == 'TokenBatch') {
          run.add(_events[i]);
          i++;
        }
        final isLastRun = i == _events.length;
        widgets.add(_tokenBubble(run, isLive: isLastRun && taskRunning));
      } else {
        widgets.add(_eventTile(ev));
        i++;
      }
    }
    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    final t = _task;
    return Scaffold(
      appBar: AppBar(
        title: Text('Task ${widget.taskId.substring(0, 8)}'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _fetchInitial)],
      ),
      body: t == null
          ? Center(
              child: _error != null
                  ? Text('Error: $_error')
                  : const CircularProgressIndicator(),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [_statusChip(t)]),
                  const SizedBox(height: 16),
                  Text('Description', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(t.description),
                  const SizedBox(height: 24),
                  if (t.status == 'pending' || t.status == 'running') ...[
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    Text(
                      t.status == 'pending'
                          ? 'Queued; processor will pick this up next.'
                          : 'Running in TEE worker via MLS-encrypted wake…',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (_events.isNotEmpty) ...[
                    Row(
                      children: [
                        Text('Agent activity', style: Theme.of(context).textTheme.titleSmall),
                        const SizedBox(width: 8),
                        Text('(${_events.length})', style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Card(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: _renderTimeline(t.status == 'running' || t.status == 'pending'),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                  if (t.status == 'completed' && t.result != null) ...[
                    Text('Result', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: SelectableText(
                          const JsonEncoder.withIndent('  ').convert(t.result),
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Text('Workspace', style: Theme.of(context).textTheme.titleSmall),
                        const SizedBox(width: 8),
                        if (_files != null)
                          Text('(${_files!.where((e) => e['is_dir'] != true).length} files)',
                              style: Theme.of(context).textTheme.bodySmall),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.refresh, size: 18),
                          tooltip: 'Refresh workspace',
                          onPressed: _filesLoading ? null : _fetchFiles,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (_filesLoading && _files == null)
                      const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
                    else if (_filesError != null && _files == null)
                      Card(
                        color: Theme.of(context).colorScheme.errorContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: SelectableText(_filesError!),
                        ),
                      )
                    else if (_files != null)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: FileTreeView(
                            root: FileTreeNode.build(_files!),
                            onFileTap: _openFileViewer,
                          ),
                        ),
                      ),
                  ],
                  if (t.status == 'failed' && t.error != null) ...[
                    Text('Error', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: SelectableText(t.error!),
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}

class _FileViewerDialog extends StatefulWidget {
  final TallyOrchClient client;
  final String taskId;
  final String path;
  const _FileViewerDialog({required this.client, required this.taskId, required this.path});

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
              const Icon(Icons.description, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(widget.path, style: const TextStyle(fontFamily: 'monospace')),
              ),
              if (_size != null)
                Text('$_size bytes${_truncated ? " (truncated)" : ""}',
                    style: Theme.of(context).textTheme.bodySmall),
              IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
            ],
          ),
          const Divider(),
          Expanded(
            child: _error != null
                ? Center(child: Text('Error: $_error'))
                : _content == null
                    ? const Center(child: CircularProgressIndicator())
                    : SingleChildScrollView(
                        child: SelectableText(
                          _content!,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4),
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}
