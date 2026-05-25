import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/widgets/kanban/task_status.dart';

Task _task({
  String status = 'pending',
  Map<String, dynamic>? teamSpec,
}) {
  return Task.fromJson({
    'id': 't1',
    'description': 'sample',
    'status': status,
    'created_at': 0.0,
    'updated_at': 0.0,
    if (teamSpec != null) 'team_spec': teamSpec,
  });
}

void main() {
  group('mapTaskToColumn', () {
    test('pending without teamSpec maps to toDo', () {
      expect(mapTaskToColumn(_task(status: 'pending')), TaskColumn.toDo);
    });

    test('pending WITH teamSpec maps to planning', () {
      expect(
        mapTaskToColumn(_task(status: 'pending', teamSpec: {'agents': []})),
        TaskColumn.planning,
      );
    });

    test('running maps to running', () {
      expect(mapTaskToColumn(_task(status: 'running')), TaskColumn.running);
    });

    test('recovering maps to awaiting', () {
      expect(mapTaskToColumn(_task(status: 'recovering')), TaskColumn.awaiting);
    });

    test('completed maps to done', () {
      expect(mapTaskToColumn(_task(status: 'completed')), TaskColumn.done);
    });

    test('failed maps to done', () {
      expect(mapTaskToColumn(_task(status: 'failed')), TaskColumn.done);
    });

    test('unknown status falls back to toDo', () {
      expect(mapTaskToColumn(_task(status: 'mystery')), TaskColumn.toDo);
    });
  });

  group('TaskColumn enum', () {
    test('has exactly 5 columns in left-to-right state-flow order', () {
      expect(TaskColumn.values, [
        TaskColumn.toDo,
        TaskColumn.planning,
        TaskColumn.running,
        TaskColumn.awaiting,
        TaskColumn.done,
      ]);
    });
  });
}
