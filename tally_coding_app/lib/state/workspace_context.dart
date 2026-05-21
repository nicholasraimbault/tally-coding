// tally_coding_app/lib/state/workspace_context.dart
//
// Sprint 50: active-workspace provider.  Set by main.dart after Clerk
// auth.  Read from screens that need the current workspace_id.
// Persistence: shared_preferences key 'active_workspace_id'.
import 'package:flutter/widgets.dart';

class WorkspaceContext extends InheritedWidget {
  final int activeWorkspaceId;
  final ValueChanged<int> onChange;
  const WorkspaceContext({
    super.key,
    required this.activeWorkspaceId,
    required this.onChange,
    required super.child,
  });

  static WorkspaceContext of(BuildContext context) {
    final ctx = context.dependOnInheritedWidgetOfExactType<WorkspaceContext>();
    assert(ctx != null, 'No WorkspaceContext in tree');
    return ctx!;
  }

  /// Sprint 50: convenience for screens that may run outside the
  /// WorkspaceContext tree (e.g. transient modals).  Returns 1 (admin's
  /// backfilled workspace) as a safe fallback so the UI doesn't crash.
  static int activeIdOrDefault(BuildContext context) {
    final ctx = context.dependOnInheritedWidgetOfExactType<WorkspaceContext>();
    return ctx?.activeWorkspaceId ?? 1;
  }

  @override
  bool updateShouldNotify(WorkspaceContext old) =>
      old.activeWorkspaceId != activeWorkspaceId;
}
