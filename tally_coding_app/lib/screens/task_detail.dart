import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../api.dart';

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
  Timer? _statusTimer;
  StreamSubscription<Map<String, dynamic>>? _eventsSub;

  @override
  void initState() {
    super.initState();
    _pollStatus();
    // Status changes slowly (pending → running → terminal); a slow poll is fine.
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_task?.isTerminal == true) {
        _statusTimer?.cancel();
        return;
      }
      _pollStatus();
    });
    _connectEventStream();
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _eventsSub?.cancel();
    super.dispose();
  }

  void _connectEventStream() {
    _eventsSub?.cancel();
    _eventsSub = widget.client.streamEvents(widget.taskId, sinceSeq: _lastSeq).listen(
      (ev) {
        if (!mounted) return;
        setState(() {
          _events.add(ev);
          _lastSeq = ev['seq'] as int;
        });
      },
      onError: (e) {
        if (!mounted) return;
        setState(() => _error = 'event stream: $e');
        // Reconnect after a short pause.
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) _connectEventStream();
        });
      },
      cancelOnError: true,
    );
  }

  Future<void> _pollStatus() async {
    try {
      final t = await widget.client.getTask(widget.taskId);
      if (!mounted) return;
      setState(() {
        _task = t;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
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
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _pollStatus)],
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
                    if (t.result?['files_created'] is List) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Files created (${(t.result!['files_created'] as List).length})',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: (t.result!['files_created'] as List)
                            .map((f) => Chip(label: Text(f.toString(), style: const TextStyle(fontSize: 12))))
                            .toList(),
                      ),
                    ],
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
