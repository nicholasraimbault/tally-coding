import 'package:flutter/material.dart';

/// Sprint 46 + follow-up: shows after a task is aborted because of a
/// cost cap.  Branches on `reason`:
/// - `"per_task_cap"` — task exceeded the per-task cap; offer to raise it
/// - `"period_cap"`  — account credit balance exhausted; offer to buy credits
class CapAbortDialog extends StatelessWidget {
  final String reason; // "per_task_cap" | "period_cap"
  final int costCredits;
  final int capCredits;
  final VoidCallback onRaiseCapAndRetry;
  final VoidCallback onViewPartial;

  const CapAbortDialog({
    super.key,
    required this.reason,
    required this.costCredits,
    required this.capCredits,
    required this.onRaiseCapAndRetry,
    required this.onViewPartial,
  });

  bool get _isPeriodCap => reason == 'period_cap';

  String get _bodyText {
    if (_isPeriodCap) {
      return 'This task was aborted because your account credit balance '
          'is exhausted. The task spent $costCredits credits before '
          'stopping. Buy more credits or wait for your next period to '
          'reset.';
    }
    return 'This task spent $costCredits credits, exceeding your '
        '$capCredits-credit per-task cap. Remaining agents were '
        'skipped to protect your balance.';
  }

  String get _primaryActionLabel {
    return _isPeriodCap ? 'Buy credits' : 'Raise cap & retry';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.block, color: Colors.red),
      title: Text(_isPeriodCap ? 'Credit balance exhausted' : 'Cost cap reached'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_bodyText),
          const SizedBox(height: 12),
          const Text(
            'Partial artifacts are preserved. You can review what '
            'completed or take action below.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: onViewPartial, child: const Text('View partial')),
        FilledButton(onPressed: onRaiseCapAndRetry, child: Text(_primaryActionLabel)),
      ],
    );
  }
}
