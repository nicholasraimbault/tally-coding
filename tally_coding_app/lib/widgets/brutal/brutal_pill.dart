import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';

/// 1px-bordered, transparent-bg pill with uppercase mono text.
/// Defaults to red accent (escalation/alert); override via `accent`.
///
/// Example:
/// ```dart
/// BrutalPill(label: 'escalated')
/// BrutalPill(label: 'active', accent: tc.green)
/// ```
class BrutalPill extends StatelessWidget {
  final String label;
  final Color? accent;

  const BrutalPill({super.key, required this.label, this.accent});

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    final color = accent ?? tc.red;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: null,
        border: Border.all(color: color, width: 1),
        borderRadius: BorderRadius.zero,
      ),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: color,
          fontFamily: 'JetBrainsMono',
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
