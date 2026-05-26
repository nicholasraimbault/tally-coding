import 'package:tally_coding_app/api.dart';

/// The five Kanban columns, in left-to-right state-flow order.
enum TaskColumn { toDo, planning, running, awaiting, done }

/// Map a Task to its Kanban column.
///
/// Backend status field is one of: 'pending', 'running', 'recovering',
/// 'completed', 'failed'. There's no 'planning' status — we discriminate
/// pending tasks with vs without teamSpec (architect has run vs hasn't).
///
/// 'recovering' currently routes to awaiting; B3 will introduce a real
/// 'awaiting_user' status when escalation routing lands.
TaskColumn mapTaskToColumn(Task task) {
  switch (task.status) {
    case 'pending':
      return task.teamSpec != null ? TaskColumn.planning : TaskColumn.toDo;
    case 'running':
      return TaskColumn.running;
    case 'recovering':
      return TaskColumn.awaiting;
    case 'completed':
    case 'failed':
      return TaskColumn.done;
    default:
      return TaskColumn.toDo;
  }
}
