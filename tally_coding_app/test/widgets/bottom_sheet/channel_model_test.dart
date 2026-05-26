import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/channel_model.dart';

void main() {
  group('ChannelModel', () {
    test('fromJson parses standard fields', () {
      final json = {
        'id': 7,
        'name': 'general',
        'kind': 'custom',
        'last_message_text': 'p99 OK at 240ms',
        'last_message_author': 'tally',
        'last_message_at': 1700000000.0,
      };
      final m = ChannelModel.fromJson(json);
      expect(m.id, 7);
      expect(m.name, 'general');
      expect(m.kind, 'custom');
      expect(m.lastMessageText, 'p99 OK at 240ms');
      expect(m.lastMessageAuthor, 'tally');
    });

    test('fromJson tolerates missing optional fields', () {
      final m = ChannelModel.fromJson({'id': 1, 'name': 'g', 'kind': 'custom'});
      expect(m.lastMessageText, isNull);
      expect(m.lastMessageAuthor, isNull);
      expect(m.lastMessageAt, isNull);
    });

    test('isLongTerm returns true for custom + dm + scheduled, false for task', () {
      expect(ChannelModel.fromJson({'id': 1, 'name': 'g', 'kind': 'custom'}).isLongTerm, isTrue);
      expect(ChannelModel.fromJson({'id': 1, 'name': 'g', 'kind': 'dm'}).isLongTerm, isTrue);
      expect(ChannelModel.fromJson({'id': 1, 'name': 'g', 'kind': 'scheduled_agent'}).isLongTerm, isTrue);
      expect(ChannelModel.fromJson({'id': 1, 'name': 'g', 'kind': 'task'}).isLongTerm, isFalse);
    });
  });
}
