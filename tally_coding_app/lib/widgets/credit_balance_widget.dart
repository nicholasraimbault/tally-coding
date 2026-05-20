import 'package:flutter/material.dart';

/// Sprint 46: shows credit balance + breakdown.
/// Inputs are denormalized; widget is stateless and pure-display.
class CreditBalanceWidget extends StatelessWidget {
  final String planLabel;
  final bool isBeta;
  final int usedCredits;
  final int includedCredits;
  final int prepaidCreditBalance;
  final double periodStart;

  const CreditBalanceWidget({
    super.key,
    required this.planLabel,
    required this.isBeta,
    required this.usedCredits,
    required this.includedCredits,
    required this.prepaidCreditBalance,
    required this.periodStart,
  });

  @override
  Widget build(BuildContext context) {
    final total = includedCredits + prepaidCreditBalance;
    final remainingIncluded = (includedCredits - usedCredits).clamp(0, includedCredits);
    final pct = total == 0 ? 0.0 : (usedCredits / total).clamp(0.0, 1.0);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(planLabel, style: Theme.of(context).textTheme.titleMedium),
                if (isBeta) ...[
                  const SizedBox(width: 8),
                  const Chip(label: Text('Beta — locked')),
                ],
              ],
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: pct,
              color: pct < 0.5 ? Colors.green : (pct < 0.8 ? Colors.orange : Colors.red),
              backgroundColor: Colors.grey.shade300,
            ),
            const SizedBox(height: 12),
            Text('$usedCredits / $total credits used'),
            const SizedBox(height: 4),
            Text(
              'Subscription pool: $remainingIncluded · Prepaid balance: $prepaidCreditBalance',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
