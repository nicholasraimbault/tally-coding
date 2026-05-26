import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';

class AmbientMiniDash extends StatelessWidget {
  final int openCount;
  final int doneCount;
  final List<Widget> taskRows;
  final String? narratorText;

  const AmbientMiniDash({
    super.key,
    required this.openCount,
    required this.doneCount,
    required this.taskRows,
    required this.narratorText,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return Container(
      decoration: BoxDecoration(
        color: tc.sheet,
        border: Border(top: BorderSide(color: tc.border, width: 1)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle pill
          Center(
            child: Container(
              key: const ValueKey('drag-handle'),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: tc.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 10),
          // Stat row
          Row(
            children: [
              _StatNumber(value: openCount),
              const SizedBox(width: 6),
              _StatLabel(text: 'open'),
              const SizedBox(width: 10),
              Text('│', style: TextStyle(color: tc.fgDimmer, fontSize: 14)),
              const SizedBox(width: 10),
              _StatNumber(value: doneCount),
              const SizedBox(width: 6),
              _StatLabel(text: 'done today'),
            ],
          ),
          // Per-task rows (added in Task 4)
          ...taskRows,
          // Narrator bubble (added in Task 5)
        ],
      ),
    );
  }
}

class _StatNumber extends StatelessWidget {
  final int value;
  const _StatNumber({required this.value});

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return Text(
      '$value',
      style: TextStyle(
        color: tc.fg,
        fontSize: 22,
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _StatLabel extends StatelessWidget {
  final String text;
  const _StatLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return Text(
      text,
      style: TextStyle(
        color: tc.fgDim,
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.8,
      ),
    );
  }
}
