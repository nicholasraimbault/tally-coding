import 'package:flutter/material.dart';

class CostEstimateBanner extends StatelessWidget {
  final int estimatedCredits;
  final int availableCredits;
  final int perTaskCapCredits;
  const CostEstimateBanner({
    super.key,
    required this.estimatedCredits,
    required this.availableCredits,
    required this.perTaskCapCredits,
  });

  Color _color() {
    if (estimatedCredits > availableCredits) return Colors.red;
    if (estimatedCredits > perTaskCapCredits) return Colors.orange;
    if (estimatedCredits > availableCredits ~/ 2) return Colors.amber;
    return Colors.green;
  }

  @override
  Widget build(BuildContext context) {
    // 1 credit = $0.01 user-facing (matches the server's accounting unit).
    final usd = estimatedCredits * 0.02;
    final color = _color();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: color.withValues(alpha: 0.12),
      child: Row(
        children: [
          Icon(Icons.bolt, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Estimated cost: $estimatedCredits credits (\$${usd.toStringAsFixed(2)}) · '
              '$availableCredits remaining this period',
              style: TextStyle(fontSize: 12, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// Sprint 46: client-side cost estimate.  Heuristic only — server
/// authoritatively rejects at the credit gate.
///
/// 1 credit = $0.01 of COGS (matches server semantics).  Real agent
/// runs cost 50-100+ credits because of system prompts; this client
/// hint only accounts for the description-driven tokens, so it
/// underestimates by design and is best used to feel cost SHAPE
/// (small/medium/huge), not exact spend.
int estimateCreditsClientSide(String description) {
  if (description.isEmpty) return 0;
  // 4 chars ≈ 1 prompt token; llama-3.3 70b: $0.59/M prompt + $0.79/M completion
  // assume completion ≈ 0.2× prompt.
  final tokens = (description.length / 4).round();
  final usdProm = tokens * 0.59 / 1000000;
  final usdComp = tokens * 0.2 * 0.79 / 1000000;
  final usdTotal = usdProm + usdComp;
  // Convert USD → credits at $0.01/credit, round up so small spend
  // shows as ≥1 credit.
  return (usdTotal * 100).ceil();
}
