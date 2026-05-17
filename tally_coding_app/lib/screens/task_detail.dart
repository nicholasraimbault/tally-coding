import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../api.dart';

class TaskDetailScreen extends StatefulWidget {
  final TallyOrchClient client;
  final String taskId;
  const TaskDetailScreen({super.key, required this.client, required this.taskId});

  @override
  State<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends State<TaskDetailScreen> {
  Task? _task;
  String? _error;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _poll();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_task?.isTerminal == true) {
        _pollTimer?.cancel();
        return;
      }
      _poll();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
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

  @override
  Widget build(BuildContext context) {
    final t = _task;
    return Scaffold(
      appBar: AppBar(
        title: Text('Task ${widget.taskId.substring(0, 8)}'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _poll)],
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
