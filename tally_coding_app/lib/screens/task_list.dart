import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import 'task_detail.dart';
import 'task_submit.dart';

class TaskListScreen extends StatefulWidget {
  final TallyOrchClient client;
  const TaskListScreen({super.key, required this.client});

  @override
  State<TaskListScreen> createState() => _TaskListScreenState();
}

class _TaskListScreenState extends State<TaskListScreen> {
  List<Task> _tasks = const [];
  bool _loading = true;
  String? _error;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final tasks = await widget.client.listTasks();
      if (!mounted) return;
      setState(() {
        _tasks = tasks;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'pending':
        return Icons.schedule;
      case 'running':
        return Icons.play_arrow;
      case 'completed':
        return Icons.check_circle;
      case 'failed':
        return Icons.error;
      default:
        return Icons.help;
    }
  }

  Color _statusColor(String status, BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    switch (status) {
      case 'completed':
        return Colors.green;
      case 'failed':
        return cs.error;
      case 'running':
        return cs.primary;
      default:
        return cs.onSurfaceVariant;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tally Coding'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('New task'),
        onPressed: () async {
          final submitted = await Navigator.of(context).push<Task>(
            MaterialPageRoute(builder: (_) => TaskSubmitScreen(client: widget.client)),
          );
          if (submitted != null && mounted) {
            await _refresh();
          }
        },
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _tasks.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _tasks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cloud_off, size: 48),
              const SizedBox(height: 12),
              Text('Cannot reach orchestrator', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(_error!, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              FilledButton(onPressed: _refresh, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    if (_tasks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.task_outlined, size: 48),
              const SizedBox(height: 12),
              Text('No tasks yet', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              const Text('Tap "New task" to dispatch one to the TEE worker.'),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      itemCount: _tasks.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final t = _tasks[i];
        return ListTile(
          leading: Icon(_statusIcon(t.status), color: _statusColor(t.status, context)),
          title: Text(
            t.description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text('${t.status} · ${t.id.substring(0, 8)}'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => TaskDetailScreen(client: widget.client, taskId: t.id)),
          ),
        );
      },
    );
  }
}
