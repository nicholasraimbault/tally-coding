import 'dart:async';
import 'package:flutter/material.dart';
import '../api.dart';

class TaskCostTicker extends StatefulWidget {
  final TallyOrchClient client;
  final String taskId;
  final int perTaskCapCredits;
  final String taskStatus;
  const TaskCostTicker({
    super.key,
    required this.client,
    required this.taskId,
    required this.perTaskCapCredits,
    required this.taskStatus,
  });
  @override
  State<TaskCostTicker> createState() => _TaskCostTickerState();
}

class _TaskCostTickerState extends State<TaskCostTicker> {
  int _credits = 0;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _poll();
    if (widget.taskStatus == 'running' || widget.taskStatus == 'pending') {
      _t = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
    }
  }

  @override
  void didUpdateWidget(covariant TaskCostTicker old) {
    super.didUpdateWidget(old);
    final shouldRun = widget.taskStatus == 'running' || widget.taskStatus == 'pending';
    if (shouldRun && _t == null) {
      _t = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
    } else if (!shouldRun && _t != null) {
      _t!.cancel();
      _t = null;
    }
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    try {
      final out = await widget.client.getTaskCost(widget.taskId);
      final micro = (out['total_micro_usd'] as num).toInt();
      final credits = (micro + 9999) ~/ 10000; // round up like server
      if (!mounted) return;
      setState(() => _credits = credits);
    } catch (_) {/* silent — don't crash UI on transient errors */}
  }

  Color _color() {
    if (_credits > widget.perTaskCapCredits) return Colors.red;
    if (_credits > widget.perTaskCapCredits * 0.8) return Colors.orange;
    return Colors.green;
  }

  @override
  Widget build(BuildContext context) {
    final usd = _credits * 0.02;
    return Chip(
      avatar: Icon(Icons.attach_money, size: 16, color: _color()),
      label: Text('$_credits credits  \$${usd.toStringAsFixed(2)}'),
      backgroundColor: _color().withValues(alpha: 0.12),
    );
  }
}
