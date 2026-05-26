import 'package:flutter/material.dart';
import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/widgets/kanban/kanban_cards.dart';
import 'package:tally_coding_app/widgets/kanban/kanban_column.dart';
import 'package:tally_coding_app/widgets/kanban/task_status.dart';

const double _kColumnWidth = 234;
const double _kColumnGap = 12;
const double _kWideBreakpoint = 1100;

/// Top-level Kanban view. Stateless — parent feeds task list + callbacks.
///
/// Mobile (< 1100px): horizontal scroll, ~1.5 columns visible.
/// Desktop (>= 1100px): all 5 columns side-by-side, equal width.
///
/// [escalatedTaskIds]: set of task IDs with active escalation. Running cards
/// whose ID is in this set get coral chrome and "PAUSED · NEEDS YOU" footer.
class KanbanView extends StatelessWidget {
  final List<Task> tasks;
  final void Function(Task) onTaskTap;
  final VoidCallback onNewTask;
  final Set<String> escalatedTaskIds;

  const KanbanView({
    super.key,
    required this.tasks,
    required this.onTaskTap,
    required this.onNewTask,
    this.escalatedTaskIds = const {},
  });

  Map<TaskColumn, List<Task>> _grouped() {
    final groups = {for (final c in TaskColumn.values) c: <Task>[]};
    for (final t in tasks) {
      groups[mapTaskToColumn(t)]!.add(t);
    }
    return groups;
  }

  Widget _cardForTask(BuildContext context, Task task) {
    final column = mapTaskToColumn(task);
    void tap() => onTaskTap(task);
    final title = task.channelTitle;
    switch (column) {
      case TaskColumn.toDo:
        return TodoCard(title: title, queued: true, onTap: tap);
      case TaskColumn.planning:
        return PlanningCard(title: title, onTap: tap);
      case TaskColumn.running:
        // Agents not yet wired from backend; show empty for now.
        // Progress is null until backend exposes it — card shows no progress bar.
        return RunningTaskCard(
          title: title,
          agents: const [],
          progress: null,
          escalated: escalatedTaskIds.contains(task.id),
          onTap: tap,
        );
      case TaskColumn.awaiting:
        return AwaitingCard(title: title, action: 'Review', onTap: tap);
      case TaskColumn.done:
        return DoneCard(
          title: title,
          shippedAgo: '', // empty until B3 computes relative times
          failed: task.status == 'failed',
          onTap: tap,
        );
    }
  }

  List<Widget> _columns(BuildContext context) {
    final grouped = _grouped();
    return [
      for (final col in TaskColumn.values)
        KanbanColumn(
          label: _columnLabel(col),
          count: grouped[col]!.length,
          onNewTask: onNewTask,
          children: [for (final t in grouped[col]!) _cardForTask(context, t)],
        ),
    ];
  }

  String _columnLabel(TaskColumn col) {
    switch (col) {
      case TaskColumn.toDo:
        return 'To do';
      case TaskColumn.planning:
        return 'Planning';
      case TaskColumn.running:
        return 'Running';
      case TaskColumn.awaiting:
        return 'Awaiting';
      case TaskColumn.done:
        return 'Done';
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _kWideBreakpoint;
        if (wide) {
          // Desktop: 5 equal columns side-by-side.
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final col in _columns(context)) ...[
                  Expanded(child: col),
                  const SizedBox(width: _kColumnGap),
                ],
              ]..removeLast(),
            ),
          );
        }
        // Mobile: horizontal scroll with fixed-width columns.
        // Bottom padding matches the AmbientMiniDash collapsed height (~140px)
        // so the bottom cards are never hidden behind the bottom sheet.
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 140),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final col in _columns(context)) ...[
                SizedBox(width: _kColumnWidth, child: col),
                const SizedBox(width: _kColumnGap),
              ],
            ]..removeLast(),
          ),
        );
      },
    );
  }
}
