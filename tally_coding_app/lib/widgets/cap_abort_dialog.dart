import 'package:flutter/material.dart';

class CapAbortDialog extends StatelessWidget {
  final int costCredits;
  final int capCredits;
  final VoidCallback onRaiseCapAndRetry;
  final VoidCallback onViewPartial;
  const CapAbortDialog({
    super.key,
    required this.costCredits,
    required this.capCredits,
    required this.onRaiseCapAndRetry,
    required this.onViewPartial,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.block, color: Colors.red),
      title: const Text('Cost cap reached'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This task spent $costCredits credits, exceeding your '
            '$capCredits-credit per-task cap. Remaining agents were '
            'skipped to protect your balance.',
          ),
          const SizedBox(height: 12),
          const Text(
            'Partial artifacts are preserved. You can review what '
            'completed or raise your cap and retry.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: onViewPartial, child: const Text('View partial')),
        FilledButton(onPressed: onRaiseCapAndRetry, child: const Text('Raise cap & retry')),
      ],
    );
  }
}
