import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';
import 'package:tally_coding_app/widgets/brutal/brutal.dart';

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
                borderRadius: BorderRadius.circular(999),
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
              Text('│', style: TextStyle(color: tc.fgDimmer, fontFamily: 'JetBrainsMono', fontSize: 14)),
              const SizedBox(width: 10),
              _StatNumber(value: doneCount),
              const SizedBox(width: 6),
              _StatLabel(text: 'done today'),
            ],
          ),
          // Per-task rows (added in Task 4)
          ...taskRows,
          // Narrator bubble
          if (narratorText != null) ...[
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const TallyAvatar(size: 28, online: false),
                const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.transparent,
                      border: Border.all(color: tc.border, width: 1),
                    ),
                    child: Text(
                      narratorText!,
                      style: TextStyle(
                        color: tc.fgDim,
                        fontFamily: 'JetBrainsMono',
                        fontSize: 12.5,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
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
        fontFamily: 'JetBrainsMono',
        fontSize: 18,
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
      text.toUpperCase(),
      style: TextStyle(
        color: tc.fgXdim,
        fontFamily: 'JetBrainsMono',
        fontSize: 10.5,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.6,
      ),
    );
  }
}

class MiniTaskRow extends StatelessWidget {
  final String title;
  final double progress;
  final List<AgentRole> agents;

  const MiniTaskRow({
    super.key,
    required this.title,
    required this.progress,
    this.agents = const [],
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    final clamped = progress.clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          if (agents.isNotEmpty) ...[
            Wrap(
              spacing: 2,
              children: [
                for (final role in agents)
                  AgentAvatar(role: role, size: 18, active: false),
              ],
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: tc.fgDim, fontFamily: 'JetBrainsMono', fontSize: 13),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 60,
            height: 3,
            child: Container(
              color: tc.border,
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: clamped,
                  child: Container(color: tc.green),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${(clamped * 100).round()}%',
            style: TextStyle(
              color: tc.fgXdim,
              fontFamily: 'JetBrainsMono',
              fontSize: 11,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
