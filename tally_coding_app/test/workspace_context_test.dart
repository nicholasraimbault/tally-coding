import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/state/workspace_context.dart';

void main() {
  testWidgets('WorkspaceContext.of returns the active workspace_id', (tester) async {
    int? activeId;
    await tester.pumpWidget(WorkspaceContext(
      activeWorkspaceId: 42,
      onChange: (_) {},
      child: Builder(builder: (ctx) {
        activeId = WorkspaceContext.of(ctx).activeWorkspaceId;
        return const SizedBox();
      }),
    ));
    expect(activeId, 42);
  });

  testWidgets('updateShouldNotify returns true when id changes', (tester) async {
    final notifications = <int>[];
    Widget tree(int id) => WorkspaceContext(
      activeWorkspaceId: id,
      onChange: (_) {},
      child: Builder(builder: (ctx) {
        notifications.add(WorkspaceContext.of(ctx).activeWorkspaceId);
        return const SizedBox();
      }),
    );
    await tester.pumpWidget(tree(1));
    await tester.pumpWidget(tree(2));
    expect(notifications, [1, 2]);
  });
}
