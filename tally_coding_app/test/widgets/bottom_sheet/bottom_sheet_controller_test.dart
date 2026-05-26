import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/bottom_sheet_controller.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/channel_model.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/escalation_model.dart';

const _e1 = EscalationModel(id: 'e1', question: 'q1', options: ['a','b'], taskId: 't1', channelId: 1);
const _e2 = EscalationModel(id: 'e2', question: 'q2', options: ['x'], taskId: 't2', channelId: 1);

void main() {
  group('BottomSheetController', () {
    test('initial state is ambient with empty queue', () {
      final c = BottomSheetController();
      expect(c.state, SheetState.ambient);
      expect(c.queue, isEmpty);
      expect(c.activeEscalation, isNull);
    });

    test('enqueue first escalation flips state to takeover', () {
      final c = BottomSheetController();
      c.enqueueEscalation(_e1);
      expect(c.state, SheetState.takeover);
      expect(c.activeEscalation, _e1);
      expect(c.queue.length, 1);
    });

    test('enqueue second escalation appends to queue, state stays takeover', () {
      final c = BottomSheetController()..enqueueEscalation(_e1);
      c.enqueueEscalation(_e2);
      expect(c.state, SheetState.takeover);
      expect(c.queue, [_e1, _e2]);
      expect(c.activeEscalation, _e1);
    });

    test('resolveActive removes head, flips back to ambient when empty', () {
      final c = BottomSheetController()..enqueueEscalation(_e1);
      c.resolveActive();
      expect(c.state, SheetState.ambient);
      expect(c.queue, isEmpty);
    });

    test('resolveActive with multiple in queue moves to next', () {
      final c = BottomSheetController()
        ..enqueueEscalation(_e1)
        ..enqueueEscalation(_e2);
      c.resolveActive();
      expect(c.state, SheetState.takeover);
      expect(c.activeEscalation, _e2);
    });

    test('skip cycles head to tail without resolving', () {
      final c = BottomSheetController()
        ..enqueueEscalation(_e1)
        ..enqueueEscalation(_e2);
      c.skip();
      expect(c.queue, [_e2, _e1]);
      expect(c.activeEscalation, _e2);
      expect(c.state, SheetState.takeover);
    });

    test('hide() sets state to hidden regardless of queue', () {
      final c = BottomSheetController()..enqueueEscalation(_e1);
      c.hide();
      expect(c.state, SheetState.hidden);
    });

    test('show() returns to ambient or takeover based on queue', () {
      final c = BottomSheetController()..hide();
      c.show();
      expect(c.state, SheetState.ambient);

      c.enqueueEscalation(_e1);
      c.hide();
      c.show();
      expect(c.state, SheetState.takeover);
    });

    test('enqueueEscalation notifies listeners', () {
      final c = BottomSheetController();
      var calls = 0;
      c.addListener(() => calls++);
      c.enqueueEscalation(_e1);
      expect(calls, 1);
    });

    test('expandChannels flips state to channelsExpanded', () {
      final c = BottomSheetController();
      c.expandChannels();
      expect(c.state, SheetState.channelsExpanded);
    });

    test('collapseToAmbient returns to ambient (or takeover if queue non-empty)', () {
      final c = BottomSheetController()..expandChannels();
      c.collapseToAmbient();
      expect(c.state, SheetState.ambient);

      c.enqueueEscalation(const EscalationModel(id: 'e1', question: 'q', options: [], taskId: 't', channelId: 7));
      c.expandChannels();
      c.collapseToAmbient();
      expect(c.state, SheetState.takeover); // queue non-empty → back to takeover
    });

    test('hasEscalationInChannel returns true if any escalation in queue matches', () {
      final c = BottomSheetController();
      c.enqueueEscalation(const EscalationModel(id: 'e1', question: 'q', options: [], taskId: 't', channelId: 7));
      expect(c.hasEscalationInChannel(7), isTrue);
      expect(c.hasEscalationInChannel(99), isFalse);
    });

    test('setChannels updates channels list + notifies', () {
      final c = BottomSheetController();
      var calls = 0;
      c.addListener(() => calls++);
      c.setChannels([
        const ChannelModel(id: 1, name: 'general', kind: 'custom'),
      ]);
      expect(c.channels, hasLength(1));
      expect(calls, 1);
    });
  });
}
