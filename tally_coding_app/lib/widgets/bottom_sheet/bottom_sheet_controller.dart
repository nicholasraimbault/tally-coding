import 'package:flutter/foundation.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/escalation_model.dart';

enum SheetState { ambient, takeover, hidden }

class BottomSheetController extends ChangeNotifier {
  SheetState _state = SheetState.ambient;
  final List<EscalationModel> _queue = [];

  SheetState get state => _state;
  List<EscalationModel> get queue => List.unmodifiable(_queue);
  EscalationModel? get activeEscalation =>
      _queue.isEmpty ? null : _queue.first;
  int get queueSize => _queue.length;

  /// Adds [e] to the queue (deduplicated by id).
  /// If the sheet is ambient, flips to takeover so the escalation is visible.
  void enqueueEscalation(EscalationModel e) {
    if (_queue.any((q) => q.id == e.id)) return; // dedupe
    _queue.add(e);
    if (_state == SheetState.ambient) {
      _state = SheetState.takeover;
    }
    notifyListeners();
  }

  /// Removes the head of the queue (the active escalation).
  /// Returns to ambient when the queue becomes empty.
  void resolveActive() {
    if (_queue.isEmpty) return;
    _queue.removeAt(0);
    if (_queue.isEmpty) {
      _state = SheetState.ambient;
    }
    notifyListeners();
  }

  /// Cycles the head to the tail without resolving it.
  /// No-op when queue size < 2 (nothing to cycle to).
  void skip() {
    if (_queue.length < 2) return;
    _queue.add(_queue.removeAt(0));
    notifyListeners();
  }

  /// Hides the sheet regardless of queue state.
  void hide() {
    _state = SheetState.hidden;
    notifyListeners();
  }

  /// Shows the sheet, resuming ambient or takeover based on queue contents.
  void show() {
    _state = _queue.isEmpty ? SheetState.ambient : SheetState.takeover;
    notifyListeners();
  }
}
