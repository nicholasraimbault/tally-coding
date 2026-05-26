import 'package:flutter/material.dart';
import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';
import 'package:tally_coding_app/widgets/brutal/brutal.dart';

/// Quick-add task modal — minimal v1: just goal text + submit.
///
/// Fast path: tap + → type one line ("ship the deal export") → enter →
/// task lands in To do, Tally observes, architect breaks it down async.
/// No chat, no plan preview, no team-spec UI — just goal text → submit.
///
/// Presentation:
/// - Mobile (< 1100 px): bottom sheet, rises above the software keyboard.
/// - Desktop (>= 1100 px): centered modal dialog.
///
/// Example:
/// ```dart
/// final task = await QuickAddTaskModal.show(
///   context,
///   client: orchClient,
///   projectId: _activeProjectId,
/// );
/// if (task != null) _refreshBoard();
/// ```
class QuickAddTaskModal extends StatefulWidget {
  final TallyOrchClient client;
  final String? projectId;
  final void Function(Task created)? onCreated;

  const QuickAddTaskModal({
    super.key,
    required this.client,
    this.projectId,
    this.onCreated,
  });

  /// Show the modal and return the created [Task] on success, or null if the
  /// user dismissed without submitting.
  ///
  /// Uses a bottom sheet on narrow viewports (< 1100 px) and a centered
  /// dialog on desktop.
  static Future<Task?> show(
    BuildContext context, {
    required TallyOrchClient client,
    String? projectId,
  }) {
    final isNarrow = MediaQuery.of(context).size.width < 1100;
    if (isNarrow) {
      return showModalBottomSheet<Task>(
        context: context,
        backgroundColor: Theme.of(context).extension<TCTokens>()!.sheet,
        isScrollControlled: true,
        builder: (ctx) => Padding(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: QuickAddTaskModal(
            client: client,
            projectId: projectId,
            onCreated: (t) => Navigator.of(ctx).pop(t),
          ),
        ),
      );
    }
    return showDialog<Task>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        backgroundColor: Theme.of(ctx).extension<TCTokens>()!.sheet,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        child: SizedBox(
          width: 480,
          child: QuickAddTaskModal(
            client: client,
            projectId: projectId,
            onCreated: (t) => Navigator.of(ctx).pop(t),
          ),
        ),
      ),
    );
  }

  @override
  State<QuickAddTaskModal> createState() => _QuickAddTaskModalState();
}

class _QuickAddTaskModalState extends State<QuickAddTaskModal> {
  final _ctrl = TextEditingController();
  bool _submitting = false;
  String? _error;

  Future<void> _submit() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final task = await widget.client.submitTask(
        text,
        projectId: widget.projectId,
      );
      widget.onCreated?.call(task);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not submit: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'NEW TASK',
            style: TextStyle(
              color: tc.fgDim,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              fontFamily: 'JetBrainsMono',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            autofocus: true,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            style: TextStyle(
              color: tc.fg,
              fontFamily: 'JetBrainsMono',
              fontSize: 14,
            ),
            decoration: InputDecoration(
              hintText: 'Ship the deal export…',
              hintStyle: TextStyle(
                color: tc.fgXdim,
                fontFamily: 'JetBrainsMono',
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.zero,
                borderSide: BorderSide(color: tc.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.zero,
                borderSide: BorderSide(color: tc.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.zero,
                borderSide: BorderSide(color: tc.borderStr),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
            // onSubmitted fires on every newline — not useful for multiline;
            // submission is via the Add button or programmatic _submit().
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: tc.red, fontSize: 12),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: BrutalButton.outline(
                  label: 'Cancel',
                  onPressed:
                      _submitting ? null : () => Navigator.of(context).pop(),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: BrutalButton.primary(
                  label: _submitting ? 'Adding…' : 'Add to board',
                  onPressed: _submitting ? null : _submit,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
