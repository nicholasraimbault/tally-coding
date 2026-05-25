import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';

/// Square-cornered solid-fill progress bar. No gradient, no glow.
///
/// Example:
/// ```dart
/// BrutalProgressBar(value: 0.65) // 65% complete
/// ```
class BrutalProgressBar extends StatelessWidget {
  final double value;
  final double height;

  const BrutalProgressBar({
    super.key,
    required this.value,
    this.height = 3,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    final clamped = value.clamp(0.0, 1.0);
    return Container(
      height: height,
      decoration: BoxDecoration(color: tc.border),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: clamped,
          child: Container(
            decoration: BoxDecoration(color: tc.green),
          ),
        ),
      ),
    );
  }
}
