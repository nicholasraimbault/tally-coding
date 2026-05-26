import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/escalation_model.dart';

void main() {
  group('EscalationModel', () {
    test('fromJson parses required fields', () {
      final json = {
        'id': 'esc-1',
        'question': 'Round to 2 decimals or keep 4?',
        'options': ['2 decimals', 'Keep 4'],
        'task_id': 'task-42',
        'channel_id': 7,
      };
      final m = EscalationModel.fromJson(json);
      expect(m.id, 'esc-1');
      expect(m.question, 'Round to 2 decimals or keep 4?');
      expect(m.options, ['2 decimals', 'Keep 4']);
      expect(m.taskId, 'task-42');
      expect(m.channelId, 7);
    });

    test('fromJson with empty options defaults to empty list', () {
      final m = EscalationModel.fromJson({
        'id': 'e',
        'question': 'q',
        'task_id': 't',
        'channel_id': 1,
      });
      expect(m.options, isEmpty);
    });

    test('equality based on id', () {
      final a = const EscalationModel(id: 'x', question: 'q', options: [], taskId: 't', channelId: 1);
      final b = const EscalationModel(id: 'x', question: 'different', options: ['a'], taskId: 'other', channelId: 99);
      expect(a, b);
    });
  });
}
