import 'package:flutter/material.dart';

import '../api.dart';
import 'task_detail.dart';

class TaskSubmitScreen extends StatefulWidget {
  final TallyOrchClient client;
  const TaskSubmitScreen({super.key, required this.client});

  @override
  State<TaskSubmitScreen> createState() => _TaskSubmitScreenState();
}

class _TaskSubmitScreenState extends State<TaskSubmitScreen> {
  final _controller = TextEditingController();
  bool _submitting = false;
  String? _error;

  Future<void> _submit() async {
    final desc = _controller.text.trim();
    if (desc.isEmpty) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final task = await widget.client.submitTask(desc);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => TaskDetailScreen(client: widget.client, taskId: task.id),
        ),
      );
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
    return Scaffold(
      appBar: AppBar(title: const Text('New task')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Describe what the TEE agent should build:',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              minLines: 4,
              maxLines: 12,
              autofocus: true,
              decoration: const InputDecoration(
                hintText:
                    'e.g. Create primes.py with is_prime(n). Add pytest covering primes up to 50. Run the tests.',
                border: OutlineInputBorder(),
              ),
              enabled: !_submitting,
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: _submitting
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              label: Text(_submitting ? 'Submitting…' : 'Dispatch to worker'),
              onPressed: _submitting ? null : _submit,
            ),
          ],
        ),
      ),
    );
  }
}
