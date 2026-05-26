// tally_coding_app/test/escalation_notifier_test.dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/services/escalation_notifier.dart';
import 'package:tally_coding_app/services/notifications_ws.dart';

void main() {
  group('EscalationPushPayload', () {
    test('parses from JSON bytes correctly', () {
      final bytes = utf8.encode(jsonEncode({
        'type': 'escalation',
        'escalation_message_id': 42,
        'channel_id': 7,
        'question': 'Round to 2 or 4 decimals?',
        'quick_reply_options': ['2 decimals', 'Keep 4', 'Open'],
      }));

      final payload = EscalationPushPayload.fromBytes(bytes);
      expect(payload, isNotNull);
      expect(payload!.escalationMessageId, 42);
      expect(payload.channelId, 7);
      expect(payload.question, 'Round to 2 or 4 decimals?');
      expect(payload.quickReplyOptions, ['2 decimals', 'Keep 4', 'Open']);
    });

    test('returns null for non-escalation type', () {
      final bytes = utf8.encode(jsonEncode({'type': 'other', 'id': 1}));
      final payload = EscalationPushPayload.fromBytes(bytes);
      expect(payload, isNull);
    });

    test('returns null for malformed JSON', () {
      final payload = EscalationPushPayload.fromBytes(utf8.encode('not json'));
      expect(payload, isNull);
    });
  });

  group('NotificationsWsClient escalation routing', () {
    test('onNewEscalation is called for new_escalation WS frame', () async {
      // We can't spin up a real WebSocket in unit tests, so we test
      // _handleMessage directly via a test-accessible wrapper.
      // Verify the callback field exists on the class.
      final client = NotificationsWsClient(
        api: null,  // not used in this test (new_escalation handler doesn't call api)
        wsUrl: Uri.parse('ws://localhost'),
        bearerProvider: () async => null,
      );
      int? receivedChannel;
      int? receivedMsgId;
      client.onNewEscalation = (ch, mid) {
        receivedChannel = ch;
        receivedMsgId = mid;
      };

      // Simulate receiving a new_escalation frame.
      final frame = jsonEncode({
        'type': 'new_escalation',
        'channel_id': 7,
        'escalation_message_id': 42,
      });
      // Access _handleMessage via the public-for-test method.
      await client.handleMessageForTest(frame);

      expect(receivedChannel, 7);
      expect(receivedMsgId, 42);
    });
  });
}
