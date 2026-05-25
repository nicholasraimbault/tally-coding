import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';
import 'package:tally_coding_app/widgets/kanban/kanban_cards.dart';

/// A single column in the Kanban view: header + scrollable card stack +
/// inline NewTaskRow at the bottom. Dumb — parent provides pre-built children.
class KanbanColumn extends StatelessWidget {
  final String label;
  final int count;
  final List<Widget> children;
  final VoidCallback onNewTask;

  const KanbanColumn({
    super.key,
    required this.label,
    required this.count,
    required this.children,
    required this.onNewTask,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Header: LABEL (uppercase, fgDim, 11/700/tracking 1.0) + count pill (1px tc.border, tabular figures)
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  color: tc.fgDim,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  border: Border.all(color: tc.border, width: 1),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    color: tc.fgXdim,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ),
        // Card stack: each child separated by 8px gap
        for (final child in children) ...[
          child,
          const SizedBox(height: 8),
        ],
        // Inline + New task row at the bottom
        NewTaskRow(onTap: onNewTask),
      ],
    );
  }
}
