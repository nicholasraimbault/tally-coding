# Sub-Project B2 — Kanban Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `TASKS` section of the Discord-style channel rail with a 5-column Kanban view (`To do · Planning · Running · Awaiting · Done`) rendered in the main pane. Cards = task channels; tap a card to open its task channel. Inline `+ New task` ghost row at the bottom of each column forwards to the existing task-submission path. Keep the rest of the rail (`#general`, CHANNELS, SCHEDULED, DMs) untouched — B3 will retire those when the channels sheet ships.

**Architecture:** No new state-management framework. `KanbanView` is a stateless widget that takes `List<Task> tasks`, `void Function(Task) onTaskTap`, `VoidCallback onNewTask`. `DiscordShellScreen`'s existing `_fetch()` polling loop continues to drive the task list — we just feed it to the kanban instead of the rail's TASKS section. A pure-function `mapTaskToColumn(Task)` enumerates 5 statuses; `KanbanView` groups the list and hands each subset to a `KanbanColumn`, which renders the appropriate card variant per row. Mobile = horizontal scroll, desktop = side-by-side; we use `LayoutBuilder` to switch based on container width.

**Tech Stack:**
- Flutter SDK ^3.6.2 (existing)
- B1 Brutal Terminal primitives: `BrutalCard`, `BrutalProgressBar`, `BrutalPill`, `TallyAvatar`, `AgentAvatar`, `CursorBlink` (already shipped at `lib/widgets/brutal/`)
- `Task` data class from `lib/api.dart` (existing — no schema changes)
- `TallyOrchClient.listTasks()` for the existing polling loop (no new endpoints)
- `ChannelSelection` sealed class in `discord_shell.dart` (existing — adds new `BoardSelected` variant)
- Standard `flutter_test` for unit + widget tests

**Scope boundary:** B2 ships the kanban as the new default landing view. The rail keeps its non-task sections so users don't lose access to DMs / scheduled agents / custom channels (B3 retires the rail when the channels sheet is ready). No mini dash, no escalation flow, no push notifs (B3/B4). No desktop sidebar variant (B5). No drag-to-change-status (deferred — Brutal Terminal aesthetic doesn't include drag affordances anyway). No auto-archive (backend behavior, deferred).

---

## File Structure

### Create

| Path | Responsibility |
|---|---|
| `tally_coding_app/lib/widgets/kanban/task_status.dart` | `TaskColumn` enum + `mapTaskToColumn(Task)` pure function |
| `tally_coding_app/lib/widgets/kanban/kanban_cards.dart` | 5 card widgets (TodoCard, PlanningCard, RunningTaskCard, AwaitingCard, DoneCard) + NewTaskRow |
| `tally_coding_app/lib/widgets/kanban/kanban_column.dart` | `KanbanColumn` widget: header (icon + name + count) + Stack of cards + NewTaskRow at bottom |
| `tally_coding_app/lib/widgets/kanban/kanban_view.dart` | `KanbanView` widget: responsive layout, mobile = horizontal scroll, desktop = side-by-side |
| `tally_coding_app/lib/widgets/kanban/kanban.dart` | Barrel export |
| `tally_coding_app/test/widgets/kanban/task_status_test.dart` | Status mapping tests (8 cases) |
| `tally_coding_app/test/widgets/kanban/kanban_cards_test.dart` | Each card variant renders + props (6 widgets) |
| `tally_coding_app/test/widgets/kanban/kanban_column_test.dart` | Column header + card stack + NewTaskRow at bottom |
| `tally_coding_app/test/widgets/kanban/kanban_view_test.dart` | View groups tasks correctly + scrolls horizontally on narrow + side-by-side on wide |

### Modify

| Path | Why |
|---|---|
| `tally_coding_app/lib/screens/discord_shell.dart` | Add `BoardSelected` variant to `ChannelSelection`; add "Board" entry to rail; render `KanbanView` in main pane when selected; remove the TASKS section from `_ChannelList`; default `_selected` to `BoardSelected` on first launch |
| `tally_coding_app/test/integration/kanban_navigation_test.dart` | New: smoke test verifying tap-card-to-open works end-to-end |

---

## Tasks

### Task 1: TaskColumn enum + mapTaskToColumn pure function

**Files:**
- Create: `tally_coding_app/lib/widgets/kanban/task_status.dart`
- Create: `tally_coding_app/test/widgets/kanban/task_status_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `tally_coding_app/test/widgets/kanban/task_status_test.dart`:

```dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/kanban/task_status_test.dart`
Expected: FAIL — `task_status.dart` not found.

- [ ] **Step 3: Implement TaskColumn + mapTaskToColumn**

Create `tally_coding_app/lib/widgets/kanban/task_status.dart`:

```dart
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/kanban/task_status_test.dart`
Expected: PASS — 8 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/widgets/kanban/task_status.dart tally_coding_app/test/widgets/kanban/task_status_test.dart
git commit -m "[kanban] TaskColumn enum + mapTaskToColumn pure function"
```

---

### Task 2: TodoCard + NewTaskRow widgets

**Files:**
- Create: `tally_coding_app/lib/widgets/kanban/kanban_cards.dart` (initially with TodoCard + NewTaskRow only; later tasks add the other 4 card variants)
- Create: `tally_coding_app/test/widgets/kanban/kanban_cards_test.dart` (initially testing TodoCard + NewTaskRow)

- [ ] **Step 1: Write the failing tests**

Create `tally_coding_app/test/widgets/kanban/kanban_cards_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/kanban/kanban_cards.dart';

Widget _wrap(Widget child) {
  final tokens = themeCatalog[defaultThemeSlug]!.tokens;
  return MaterialApp(
    theme: themeFromTokens(tokens),
    home: Scaffold(body: child),
  );
}

void main() {
  group('TodoCard', () {
    testWidgets('renders title', (tester) async {
      await tester.pumpWidget(_wrap(
        const TodoCard(title: 'Sync inventory across Shopify locations'),
      ));
      expect(find.text('Sync inventory across Shopify locations'), findsOneWidget);
    });

    testWidgets('shows QUEUED label when queued=true', (tester) async {
      await tester.pumpWidget(_wrap(const TodoCard(title: 't', queued: true)));
      expect(find.text('QUEUED'), findsOneWidget);
    });

    testWidgets('hides QUEUED label when queued=false', (tester) async {
      await tester.pumpWidget(_wrap(const TodoCard(title: 't')));
      expect(find.text('QUEUED'), findsNothing);
    });

    testWidgets('invokes onTap when tapped', (tester) async {
      int taps = 0;
      await tester.pumpWidget(_wrap(
        TodoCard(title: 't', onTap: () => taps++),
      ));
      await tester.tap(find.byType(TodoCard));
      expect(taps, 1);
    });
  });

  group('NewTaskRow', () {
    testWidgets('renders + glyph + "New task" label', (tester) async {
      await tester.pumpWidget(_wrap(NewTaskRow(onTap: () {})));
      expect(find.text('+ New task'), findsOneWidget);
    });

    testWidgets('invokes onTap when tapped', (tester) async {
      int taps = 0;
      await tester.pumpWidget(_wrap(NewTaskRow(onTap: () => taps++)));
      await tester.tap(find.byType(NewTaskRow));
      expect(taps, 1);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/kanban/kanban_cards_test.dart`
Expected: FAIL — `kanban_cards.dart` not found.

- [ ] **Step 3: Implement TodoCard + NewTaskRow**

Create `tally_coding_app/lib/widgets/kanban/kanban_cards.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';
import 'package:tally_coding_app/widgets/brutal/brutal.dart';

/// Card for tasks queued but not yet picked up by the architect.
class TodoCard extends StatelessWidget {
  final String title;
  final bool queued;
  final VoidCallback? onTap;

  const TodoCard({
    super.key,
    required this.title,
    this.queued = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return BrutalCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: TextStyle(
              color: tc.fg,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              height: 1.3,
            ),
          ),
          if (queued) ...[
            const SizedBox(height: 8),
            Text(
              'QUEUED',
              style: TextStyle(
                color: tc.fgXdim,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Inline ghost row at the bottom of every kanban column.
/// Notion mobile pattern: transparent bg, square corners, "+ New task" label.
class NewTaskRow extends StatefulWidget {
  final VoidCallback onTap;

  const NewTaskRow({super.key, required this.onTap});

  @override
  State<NewTaskRow> createState() => _NewTaskRowState();
}

class _NewTaskRowState extends State<NewTaskRow> {
  bool _hov = false;

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return MouseRegion(
      onEnter: (_) => setState(() => _hov = true),
      onExit: (_) => setState(() => _hov = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 10),
          alignment: Alignment.center,
          color: _hov ? tc.card : Colors.transparent,
          child: Text(
            '+ New task',
            style: TextStyle(
              color: _hov ? tc.fgDim : tc.fgXdim,
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/kanban/kanban_cards_test.dart`
Expected: PASS — 6 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/widgets/kanban/kanban_cards.dart tally_coding_app/test/widgets/kanban/kanban_cards_test.dart
git commit -m "[kanban] TodoCard + NewTaskRow widgets"
```

---

### Task 3: PlanningCard widget

**Files:**
- Modify: `tally_coding_app/lib/widgets/kanban/kanban_cards.dart` (append PlanningCard)
- Modify: `tally_coding_app/test/widgets/kanban/kanban_cards_test.dart` (append PlanningCard tests)

- [ ] **Step 1: Append the failing tests**

Append to the existing `group(...)`s in `kanban_cards_test.dart` (before the closing `}` of `main`):

```dart
  group('PlanningCard', () {
    testWidgets('renders title', (tester) async {
      await tester.pumpWidget(_wrap(
        const PlanningCard(title: 'Wire up Stripe webhooks'),
      ));
      expect(find.text('Wire up Stripe webhooks'), findsOneWidget);
    });

    testWidgets('renders architect avatar', (tester) async {
      await tester.pumpWidget(_wrap(const PlanningCard(title: 't')));
      // Architect monogram is "A"
      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('renders PLANNING label', (tester) async {
      await tester.pumpWidget(_wrap(const PlanningCard(title: 't')));
      expect(find.text('PLANNING'), findsOneWidget);
    });

    testWidgets('invokes onTap when tapped', (tester) async {
      int taps = 0;
      await tester.pumpWidget(_wrap(
        PlanningCard(title: 't', onTap: () => taps++),
      ));
      await tester.tap(find.byType(PlanningCard));
      expect(taps, 1);
    });
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/kanban/kanban_cards_test.dart`
Expected: FAIL — `PlanningCard` is not defined.

- [ ] **Step 3: Append PlanningCard**

Append to `kanban_cards.dart`:

```dart

/// Card for tasks the architect is breaking down (pending + teamSpec != null).
class PlanningCard extends StatelessWidget {
  final String title;
  final VoidCallback? onTap;

  const PlanningCard({
    super.key,
    required this.title,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return BrutalCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: TextStyle(
              color: tc.fg,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const AgentAvatar(role: AgentRole.architect, size: 20),
              Text(
                'PLANNING',
                style: TextStyle(
                  color: tc.fgXdim,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/kanban/kanban_cards_test.dart`
Expected: PASS — 10 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/widgets/kanban/kanban_cards.dart tally_coding_app/test/widgets/kanban/kanban_cards_test.dart
git commit -m "[kanban] PlanningCard widget"
```

---

### Task 4: RunningTaskCard widget

**Files:**
- Modify: `tally_coding_app/lib/widgets/kanban/kanban_cards.dart` (append RunningTaskCard)
- Modify: `tally_coding_app/test/widgets/kanban/kanban_cards_test.dart` (append RunningTaskCard tests)

This is the most visually complex card: agent avatar row + progress bar + ETA text.

- [ ] **Step 1: Append the failing tests**

```dart
  group('RunningTaskCard', () {
    testWidgets('renders title', (tester) async {
      await tester.pumpWidget(_wrap(
        const RunningTaskCard(
          title: 'Build email digest worker',
          agents: [AgentRole.coder],
          progress: 0.3,
        ),
      ));
      expect(find.text('Build email digest worker'), findsOneWidget);
    });

    testWidgets('renders agent avatars (coder + tester)', (tester) async {
      await tester.pumpWidget(_wrap(
        const RunningTaskCard(
          title: 't',
          agents: [AgentRole.coder, AgentRole.tester],
          progress: 0.5,
        ),
      ));
      expect(find.text('C'), findsOneWidget); // coder monogram
      expect(find.text('T'), findsOneWidget); // tester monogram
    });

    testWidgets('renders progress bar', (tester) async {
      await tester.pumpWidget(_wrap(
        const RunningTaskCard(
          title: 't',
          agents: [AgentRole.coder],
          progress: 0.6,
        ),
      ));
      expect(find.byType(BrutalProgressBar), findsOneWidget);
      final bar = tester.widget<BrutalProgressBar>(find.byType(BrutalProgressBar));
      expect(bar.value, 0.6);
    });

    testWidgets('renders eta text if provided', (tester) async {
      await tester.pumpWidget(_wrap(
        const RunningTaskCard(
          title: 't',
          agents: [AgentRole.coder],
          progress: 0.5,
          eta: '~5m',
        ),
      ));
      expect(find.text('~5m'), findsOneWidget);
    });

    testWidgets('invokes onTap when tapped', (tester) async {
      int taps = 0;
      await tester.pumpWidget(_wrap(
        RunningTaskCard(
          title: 't',
          agents: const [AgentRole.coder],
          progress: 0.5,
          onTap: () => taps++,
        ),
      ));
      await tester.tap(find.byType(RunningTaskCard));
      expect(taps, 1);
    });
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/kanban/kanban_cards_test.dart`
Expected: FAIL — `RunningTaskCard` is not defined.

- [ ] **Step 3: Append RunningTaskCard**

Append to `kanban_cards.dart`:

```dart

/// Card for tasks workers are actively executing.
/// Shows agent avatars + ETA + progress bar.
class RunningTaskCard extends StatelessWidget {
  final String title;
  final List<AgentRole> agents;
  final double progress;
  final String? eta;
  final VoidCallback? onTap;

  const RunningTaskCard({
    super.key,
    required this.title,
    required this.agents,
    required this.progress,
    this.eta,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return BrutalCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: TextStyle(
              color: tc.fg,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Wrap(
                spacing: 4,
                children: [
                  for (final role in agents) AgentAvatar(role: role, size: 20),
                ],
              ),
              if (eta != null)
                Text(
                  eta!,
                  style: TextStyle(
                    color: tc.fgDim,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          BrutalProgressBar(value: progress),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/kanban/kanban_cards_test.dart`
Expected: PASS — 15 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/widgets/kanban/kanban_cards.dart tally_coding_app/test/widgets/kanban/kanban_cards_test.dart
git commit -m "[kanban] RunningTaskCard widget (agents + progress + eta)"
```

---

### Task 5: AwaitingCard widget

**Files:**
- Modify: `tally_coding_app/lib/widgets/kanban/kanban_cards.dart`
- Modify: `tally_coding_app/test/widgets/kanban/kanban_cards_test.dart`

- [ ] **Step 1: Append the failing tests**

```dart
  group('AwaitingCard', () {
    testWidgets('renders title', (tester) async {
      await tester.pumpWidget(_wrap(
        const AwaitingCard(
          title: 'Wire up Stripe webhooks',
          action: 'Review PR',
        ),
      ));
      expect(find.text('Wire up Stripe webhooks'), findsOneWidget);
    });

    testWidgets('renders action pill', (tester) async {
      await tester.pumpWidget(_wrap(
        const AwaitingCard(title: 't', action: 'Review PR'),
      ));
      expect(find.text('REVIEW PR'), findsOneWidget); // BrutalPill uppercase
    });

    testWidgets('invokes onTap when tapped', (tester) async {
      int taps = 0;
      await tester.pumpWidget(_wrap(
        AwaitingCard(
          title: 't',
          action: 'review',
          onTap: () => taps++,
        ),
      ));
      await tester.tap(find.byType(AwaitingCard));
      expect(taps, 1);
    });
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/kanban/kanban_cards_test.dart`
Expected: FAIL — `AwaitingCard` is not defined.

- [ ] **Step 3: Append AwaitingCard**

Append to `kanban_cards.dart`:

```dart

/// Card for tasks waiting on user input (paused agents).
/// Amber-tinted via tc.red token + action pill.
class AwaitingCard extends StatelessWidget {
  final String title;
  final String action;
  final VoidCallback? onTap;

  const AwaitingCard({
    super.key,
    required this.title,
    required this.action,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return BrutalCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: TextStyle(
              color: tc.fg,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 10),
          BrutalPill(label: action), // default red accent (escalation/needs-you color)
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/kanban/kanban_cards_test.dart`
Expected: PASS — 18 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/widgets/kanban/kanban_cards.dart tally_coding_app/test/widgets/kanban/kanban_cards_test.dart
git commit -m "[kanban] AwaitingCard widget (amber pill, needs-user)"
```

---

### Task 6: DoneCard widget

**Files:**
- Modify: `tally_coding_app/lib/widgets/kanban/kanban_cards.dart`
- Modify: `tally_coding_app/test/widgets/kanban/kanban_cards_test.dart`

- [ ] **Step 1: Append the failing tests**

```dart
  group('DoneCard', () {
    testWidgets('renders title', (tester) async {
      await tester.pumpWidget(_wrap(
        const DoneCard(title: 'Add refunds CSV export', shippedAgo: '2h ago'),
      ));
      expect(find.text('Add refunds CSV export'), findsOneWidget);
    });

    testWidgets('renders SHIPPED + relative timestamp', (tester) async {
      await tester.pumpWidget(_wrap(
        const DoneCard(title: 't', shippedAgo: '2h ago'),
      ));
      expect(find.text('SHIPPED'), findsOneWidget);
      expect(find.text('2h ago'), findsOneWidget);
    });

    testWidgets('shows FAILED label when failed=true', (tester) async {
      await tester.pumpWidget(_wrap(
        const DoneCard(title: 't', shippedAgo: '5m ago', failed: true),
      ));
      expect(find.text('FAILED'), findsOneWidget);
      expect(find.text('SHIPPED'), findsNothing);
    });

    testWidgets('invokes onTap when tapped', (tester) async {
      int taps = 0;
      await tester.pumpWidget(_wrap(
        DoneCard(title: 't', shippedAgo: '1m', onTap: () => taps++),
      ));
      await tester.tap(find.byType(DoneCard));
      expect(taps, 1);
    });
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/kanban/kanban_cards_test.dart`
Expected: FAIL — `DoneCard` is not defined.

- [ ] **Step 3: Append DoneCard**

Append to `kanban_cards.dart`:

```dart

/// Card for completed tasks (or failed — distinguishes via the failed flag).
class DoneCard extends StatelessWidget {
  final String title;
  final String shippedAgo;
  final bool failed;
  final VoidCallback? onTap;

  const DoneCard({
    super.key,
    required this.title,
    required this.shippedAgo,
    this.failed = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    final accentColor = failed ? tc.red : tc.green;
    final label = failed ? 'FAILED' : 'SHIPPED';
    return BrutalCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: TextStyle(
              color: tc.fgDim, // dim — done is less salient than active work
              fontSize: 14,
              fontWeight: FontWeight.w700,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: accentColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
              Text(
                shippedAgo,
                style: TextStyle(
                  color: tc.fgXdim,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/kanban/kanban_cards_test.dart`
Expected: PASS — 22 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/widgets/kanban/kanban_cards.dart tally_coding_app/test/widgets/kanban/kanban_cards_test.dart
git commit -m "[kanban] DoneCard widget (shipped/failed + relative time)"
```

---

### Task 7: KanbanColumn widget

**Files:**
- Create: `tally_coding_app/lib/widgets/kanban/kanban_column.dart`
- Create: `tally_coding_app/test/widgets/kanban/kanban_column_test.dart`

KanbanColumn renders: header (icon + name + count pill) + Stack of child widgets + NewTaskRow at bottom. It does NOT know about Task data — the parent passes pre-built widgets as `children`. This keeps the column dumb and reusable.

- [ ] **Step 1: Write the failing tests**

Create `tally_coding_app/test/widgets/kanban/kanban_column_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/kanban/kanban_column.dart';

Widget _wrap(Widget child) {
  final tokens = themeCatalog[defaultThemeSlug]!.tokens;
  return MaterialApp(
    theme: themeFromTokens(tokens),
    home: Scaffold(body: SizedBox(width: 240, child: child)),
  );
}

void main() {
  testWidgets('renders header label uppercase', (tester) async {
    await tester.pumpWidget(_wrap(KanbanColumn(
      label: 'Running',
      count: 2,
      children: const [Text('card1'), Text('card2')],
      onNewTask: () {},
    )));
    expect(find.text('RUNNING'), findsOneWidget);
  });

  testWidgets('renders count pill', (tester) async {
    await tester.pumpWidget(_wrap(KanbanColumn(
      label: 'Running',
      count: 7,
      children: const [],
      onNewTask: () {},
    )));
    expect(find.text('7'), findsOneWidget);
  });

  testWidgets('renders each child card', (tester) async {
    await tester.pumpWidget(_wrap(KanbanColumn(
      label: 'x',
      count: 2,
      children: const [Text('alpha'), Text('beta')],
      onNewTask: () {},
    )));
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);
  });

  testWidgets('renders NewTaskRow at the bottom', (tester) async {
    await tester.pumpWidget(_wrap(KanbanColumn(
      label: 'x',
      count: 0,
      children: const [],
      onNewTask: () {},
    )));
    expect(find.text('+ New task'), findsOneWidget);
  });

  testWidgets('invokes onNewTask when NewTaskRow tapped', (tester) async {
    int newTaps = 0;
    await tester.pumpWidget(_wrap(KanbanColumn(
      label: 'x',
      count: 0,
      children: const [],
      onNewTask: () => newTaps++,
    )));
    await tester.tap(find.text('+ New task'));
    expect(newTaps, 1);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/kanban/kanban_column_test.dart`
Expected: FAIL — `kanban_column.dart` not found.

- [ ] **Step 3: Implement KanbanColumn**

Create `tally_coding_app/lib/widgets/kanban/kanban_column.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';
import 'package:tally_coding_app/widgets/kanban/kanban_cards.dart';

/// A single column in the Kanban view: header + scrollable card stack +
/// inline NewTaskRow at the bottom. Dumb — parent provides pre-built children.
class KanbanColumn extends StatelessWidget {
  final String label;
  final int count;
  final List<Widget> children;
  final VoidCallback onNewTask;

  const KanbanColumn({
    super.key,
    required this.label,
    required this.count,
    required this.children,
    required this.onNewTask,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Header: LABEL + count pill
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  color: tc.fgDim,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  border: Border.all(color: tc.border, width: 1),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    color: tc.fgXdim,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ),
        // Card stack
        for (final child in children) ...[
          child,
          const SizedBox(height: 8),
        ],
        // Inline +New task row
        NewTaskRow(onTap: onNewTask),
      ],
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/kanban/kanban_column_test.dart`
Expected: PASS — 5 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/widgets/kanban/kanban_column.dart tally_coding_app/test/widgets/kanban/kanban_column_test.dart
git commit -m "[kanban] KanbanColumn widget (header + stack + NewTaskRow)"
```

---

### Task 8: KanbanView widget (responsive layout)

**Files:**
- Create: `tally_coding_app/lib/widgets/kanban/kanban_view.dart`
- Create: `tally_coding_app/test/widgets/kanban/kanban_view_test.dart`

KanbanView is the top-level widget. Takes `List<Task> tasks`, `void Function(Task) onTaskTap`, `VoidCallback onNewTask`. Uses `mapTaskToColumn` to group tasks. Renders 5 KanbanColumns, each with the right card variant per task. Responsive: mobile = horizontal scroll, desktop (width >= 1100) = side-by-side equal-width columns.

- [ ] **Step 1: Write the failing tests**

Create `tally_coding_app/test/widgets/kanban/kanban_view_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/kanban/kanban_column.dart';
import 'package:tally_coding_app/widgets/kanban/kanban_view.dart';

Task _t({String id = 't', String status = 'running', String desc = 'task',
         Map<String, dynamic>? teamSpec, double updatedAt = 0}) {
  return Task.fromJson({
    'id': id,
    'description': desc,
    'status': status,
    'created_at': 0.0,
    'updated_at': updatedAt,
    if (teamSpec != null) 'team_spec': teamSpec,
  });
}

Widget _wrap(Widget child, {double width = 400}) {
  final tokens = themeCatalog[defaultThemeSlug]!.tokens;
  return MaterialApp(
    theme: themeFromTokens(tokens),
    home: Scaffold(body: SizedBox(width: width, child: child)),
  );
}

void main() {
  testWidgets('renders 5 columns with correct labels', (tester) async {
    await tester.pumpWidget(_wrap(
      KanbanView(tasks: const [], onTaskTap: (_) {}, onNewTask: () {}),
    ));
    expect(find.text('TO DO'), findsOneWidget);
    expect(find.text('PLANNING'), findsOneWidget);
    expect(find.text('RUNNING'), findsOneWidget);
    expect(find.text('AWAITING'), findsOneWidget);
    expect(find.text('DONE'), findsOneWidget);
  });

  testWidgets('groups tasks into correct columns', (tester) async {
    final tasks = [
      _t(id: '1', status: 'pending', desc: 'todo task'),
      _t(id: '2', status: 'pending', teamSpec: {'agents': []}, desc: 'planning task'),
      _t(id: '3', status: 'running', desc: 'running task'),
      _t(id: '4', status: 'recovering', desc: 'awaiting task'),
      _t(id: '5', status: 'completed', desc: 'done task'),
    ];
    await tester.pumpWidget(_wrap(
      KanbanView(tasks: tasks, onTaskTap: (_) {}, onNewTask: () {}),
      width: 1400,
    ));
    expect(find.text('todo task'), findsOneWidget);
    expect(find.text('planning task'), findsOneWidget);
    expect(find.text('running task'), findsOneWidget);
    expect(find.text('awaiting task'), findsOneWidget);
    expect(find.text('done task'), findsOneWidget);
  });

  testWidgets('count pills reflect column populations', (tester) async {
    final tasks = [
      _t(id: '1', status: 'running'),
      _t(id: '2', status: 'running'),
      _t(id: '3', status: 'completed'),
    ];
    await tester.pumpWidget(_wrap(
      KanbanView(tasks: tasks, onTaskTap: (_) {}, onNewTask: () {}),
      width: 1400,
    ));
    // Expect a column with count '2' (running) and one with '1' (done).
    expect(find.text('2'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('tap on task card invokes onTaskTap with the task', (tester) async {
    Task? tapped;
    final task = _t(id: 'x', status: 'running', desc: 'tap me');
    await tester.pumpWidget(_wrap(
      KanbanView(
        tasks: [task],
        onTaskTap: (t) => tapped = t,
        onNewTask: () {},
      ),
      width: 1400,
    ));
    await tester.tap(find.text('tap me'));
    expect(tapped?.id, 'x');
  });

  testWidgets('horizontal scroll on narrow viewport', (tester) async {
    await tester.pumpWidget(_wrap(
      KanbanView(tasks: const [], onTaskTap: (_) {}, onNewTask: () {}),
      width: 400,
    ));
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    final scroll = tester.widget<SingleChildScrollView>(find.byType(SingleChildScrollView));
    expect(scroll.scrollDirection, Axis.horizontal);
  });

  testWidgets('side-by-side on wide viewport (no horizontal scroll)', (tester) async {
    await tester.pumpWidget(_wrap(
      KanbanView(tasks: const [], onTaskTap: (_) {}, onNewTask: () {}),
      width: 1400,
    ));
    expect(find.byType(SingleChildScrollView), findsNothing);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/kanban/kanban_view_test.dart`
Expected: FAIL — `kanban_view.dart` not found.

- [ ] **Step 3: Implement KanbanView**

Create `tally_coding_app/lib/widgets/kanban/kanban_view.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';
import 'package:tally_coding_app/widgets/brutal/brutal.dart';
import 'package:tally_coding_app/widgets/kanban/kanban_cards.dart';
import 'package:tally_coding_app/widgets/kanban/kanban_column.dart';
import 'package:tally_coding_app/widgets/kanban/task_status.dart';

const double _kColumnWidth = 280;
const double _kColumnGap = 12;
const double _kWideBreakpoint = 1100;

/// Top-level Kanban view. Stateless — parent feeds task list + callbacks.
///
/// Mobile (< 1100px): horizontal scroll, ~1.5 columns visible.
/// Desktop (>= 1100px): all 5 columns side-by-side, equal width.
class KanbanView extends StatelessWidget {
  final List<Task> tasks;
  final void Function(Task) onTaskTap;
  final VoidCallback onNewTask;

  const KanbanView({
    super.key,
    required this.tasks,
    required this.onTaskTap,
    required this.onNewTask,
  });

  Map<TaskColumn, List<Task>> _grouped() {
    final groups = {for (final c in TaskColumn.values) c: <Task>[]};
    for (final t in tasks) {
      groups[mapTaskToColumn(t)]!.add(t);
    }
    return groups;
  }

  Widget _cardForTask(BuildContext context, Task task) {
    final column = mapTaskToColumn(task);
    final tap = () => onTaskTap(task);
    final title = task.channelTitle;
    switch (column) {
      case TaskColumn.toDo:
        return TodoCard(title: title, queued: true, onTap: tap);
      case TaskColumn.planning:
        return PlanningCard(title: title, onTap: tap);
      case TaskColumn.running:
        // Agents not yet wired from backend; show empty for now.
        // B3 will introduce escalation backreference + agent state on cards.
        return RunningTaskCard(
          title: title,
          agents: const [],
          progress: 0.5, // backend doesn't expose progress yet — placeholder
          onTap: tap,
        );
      case TaskColumn.awaiting:
        return AwaitingCard(title: title, action: 'Review', onTap: tap);
      case TaskColumn.done:
        return DoneCard(
          title: title,
          shippedAgo: '', // empty until B3 computes relative times
          failed: task.status == 'failed',
          onTap: tap,
        );
    }
  }

  List<Widget> _columns(BuildContext context) {
    final grouped = _grouped();
    return [
      for (final col in TaskColumn.values)
        KanbanColumn(
          label: _columnLabel(col),
          count: grouped[col]!.length,
          children: [for (final t in grouped[col]!) _cardForTask(context, t)],
          onNewTask: onNewTask,
        ),
    ];
  }

  String _columnLabel(TaskColumn col) {
    switch (col) {
      case TaskColumn.toDo:
        return 'To do';
      case TaskColumn.planning:
        return 'Planning';
      case TaskColumn.running:
        return 'Running';
      case TaskColumn.awaiting:
        return 'Awaiting';
      case TaskColumn.done:
        return 'Done';
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _kWideBreakpoint;
        if (wide) {
          // Desktop: 5 equal columns side-by-side.
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final col in _columns(context)) ...[
                  Expanded(child: col),
                  const SizedBox(width: _kColumnGap),
                ],
              ]..removeLast(),
            ),
          );
        }
        // Mobile: horizontal scroll with fixed-width columns.
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final col in _columns(context)) ...[
                SizedBox(width: _kColumnWidth, child: col),
                const SizedBox(width: _kColumnGap),
              ],
            ]..removeLast(),
          ),
        );
      },
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/kanban/kanban_view_test.dart`
Expected: PASS — 6 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/widgets/kanban/kanban_view.dart tally_coding_app/test/widgets/kanban/kanban_view_test.dart
git commit -m "[kanban] KanbanView responsive widget (mobile scroll, desktop side-by-side)"
```

---

### Task 9: Kanban barrel export

**Files:**
- Create: `tally_coding_app/lib/widgets/kanban/kanban.dart`

- [ ] **Step 1: Create barrel**

```dart
export 'kanban_cards.dart';
export 'kanban_column.dart';
export 'kanban_view.dart';
export 'task_status.dart';
```

- [ ] **Step 2: Verify it compiles**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter analyze lib/widgets/kanban/kanban.dart`
Expected: "No issues found!"

- [ ] **Step 3: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/widgets/kanban/kanban.dart
git commit -m "[kanban] barrel export for widgets/kanban/ module"
```

---

### Task 10: Add BoardSelected variant to ChannelSelection

**Files:**
- Modify: `tally_coding_app/lib/screens/discord_shell.dart` (the `ChannelSelection` sealed class at ~line 41)

- [ ] **Step 1: Read the existing ChannelSelection definition**

Run: `cd tally_coding_app && sed -n '38,62p' lib/screens/discord_shell.dart`

Expected: see the sealed class with `GeneralSelected`, `TaskSelected`, `DirectChannelSelected` variants.

- [ ] **Step 2: Add BoardSelected variant**

In the `ChannelSelection` sealed class block, append:

```dart
final class BoardSelected extends ChannelSelection {
  const BoardSelected();
}
```

Update the `==` and `hashCode` getters at the bottom of the class if present.

- [ ] **Step 3: Run existing tests to confirm no regressions**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/screens/ test/integration/ 2>&1 | tail -10`

Expected: existing tests still pass.

- [ ] **Step 4: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/screens/discord_shell.dart
git commit -m "[shell] add BoardSelected variant to ChannelSelection"
```

---

### Task 11: Add "Board" entry to rail, default to BoardSelected on launch

**Files:**
- Modify: `tally_coding_app/lib/screens/discord_shell.dart` (the `_ChannelList` widget at ~line 757 + the `_initialSelection` getter or constructor default near line 90)

- [ ] **Step 1: Read the rail's top section + initial selection logic**

Run: `cd tally_coding_app && sed -n '85,110p;757,810p' lib/screens/discord_shell.dart`

Look for: where `#general` is rendered as a tile at the top of the rail; where `_selected` is initialized in `initState`.

- [ ] **Step 2: Add "Board" rail entry above "#general"**

Inside `_ChannelList.build()`, prepend a tile for Board. Use the existing `_ChannelTile` widget pattern (matching the rest of the rail's styling). The label is "Board", icon is `▤` or `Icons.view_kanban`, and tapping sets `_selected = const BoardSelected()`.

Find the existing tile for general and add right above it:

```dart
_ChannelTile(
  selected: selected is BoardSelected,
  label: 'Board',
  icon: Icons.view_kanban,
  onTap: () => onSelect(const BoardSelected()),
),
```

- [ ] **Step 3: Change initial selection from GeneralSelected to BoardSelected**

In `_DiscordShellScreenState.initState`, find where `_selected` is initialized. Change the default from `const GeneralSelected()` to `const BoardSelected()`. Preserve the `widget.initialTaskId` short-circuit (deep-link override stays).

- [ ] **Step 4: Run existing tests + integration test**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/ integration_test/ 2>&1 | tail -10`

Expected: existing tests pass (some integration tests may need a quick update if they assumed `GeneralSelected` was the default — fix them by tapping the "#general" rail tile to navigate there).

- [ ] **Step 5: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/screens/discord_shell.dart tally_coding_app/integration_test/
git commit -m "[shell] add Board rail entry, default new sessions to Board view"
```

---

### Task 12: Render KanbanView when BoardSelected

**Files:**
- Modify: `tally_coding_app/lib/screens/discord_shell.dart` (the `_mainPane()` switch at ~line 666)

- [ ] **Step 1: Read the current _mainPane switch**

Run: `cd tally_coding_app && sed -n '660,700p' lib/screens/discord_shell.dart`

- [ ] **Step 2: Add a case for BoardSelected**

Add a switch arm in `_mainPane()`:

```dart
BoardSelected() => KanbanView(
  tasks: _filteredTasksForKanban(),
  onTaskTap: (task) {
    setState(() => _selected = TaskSelected(task.id));
  },
  onNewTask: () {
    setState(() => _selected = const GeneralSelected());
    // GeneralChannelScreen has the existing architect chat input;
    // tapping +New takes the user there to enter a new goal.
    // Sub-project A will replace this with a dedicated quick-add modal.
  },
),
```

Add the import at the top of `discord_shell.dart`:

```dart
import 'package:tally_coding_app/widgets/kanban/kanban.dart';
```

- [ ] **Step 3: Add _filteredTasksForKanban helper**

In `_DiscordShellScreenState`, add:

```dart
List<Task> _filteredTasksForKanban() {
  // Respect the active project filter the existing rail uses (Sprint 37).
  if (_activeProjectId == null) return _tasks;
  return _tasks.where((t) => t.projectId == _activeProjectId).toList();
}
```

- [ ] **Step 4: Run tests**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/ 2>&1 | tail -5`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/screens/discord_shell.dart
git commit -m "[shell] render KanbanView when BoardSelected (mainPane integration)"
```

---

### Task 13: Remove the TASKS section from the rail

The rail currently lists tasks in a dedicated section between CHANNELS and SCHEDULED. With B2 shipping the kanban, that section is redundant — tasks live in the kanban view from now on.

**Files:**
- Modify: `tally_coding_app/lib/screens/discord_shell.dart` (the `_ChannelList` widget body)

- [ ] **Step 1: Locate the TASKS section in _ChannelList**

Run: `cd tally_coding_app && grep -n "TASKS\|_TaskTile\|_tasks" lib/screens/discord_shell.dart | head -20`

Identify the lines that render the TASKS section header + the loop that renders each task tile.

- [ ] **Step 2: Delete the TASKS section block**

Remove the section header label ("TASKS") and the `for (final task in tasks) ...` loop that renders task tiles in the rail. Keep `#general`, the "Board" entry, CHANNELS, SCHEDULED, and DIRECT MESSAGES sections.

- [ ] **Step 3: Verify the rail still renders for non-task selections**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test integration_test/discord_shell_test.dart 2>&1 | tail -5`

Expected: still passes (the integration test checks for rail rendering, not specifically the TASKS section).

- [ ] **Step 4: Run full suite**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test 2>&1 | tail -5`

Expected: all tests pass. If any test specifically asserts the TASKS rail section exists, update it to assert on the kanban view instead.

- [ ] **Step 5: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/screens/discord_shell.dart tally_coding_app/test/
git commit -m "[shell] remove TASKS section from rail (now lives in kanban view)"
```

---

### Task 14: Smoke integration test for tap-card-to-open

**Files:**
- Create: `tally_coding_app/integration_test/kanban_navigation_test.dart`

End-to-end: pump DiscordShellScreen with a mock client returning 1 running task. Verify kanban renders, tap the task card, verify TaskChannelScreen appears.

- [ ] **Step 1: Write the failing test**

Create `tally_coding_app/integration_test/kanban_navigation_test.dart`:

```dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/screens/discord_shell.dart';
import 'package:tally_coding_app/screens/task_channel.dart';
import 'package:tally_coding_app/services/notifications_ws.dart';
import 'package:tally_coding_app/state/workspace_context.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/kanban/kanban.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('tapping a kanban card opens the task channel', (tester) async {
    // Mock orchestrator: return 1 running task on listTasks; empty for everything else.
    final mock = MockClient((req) async {
      if (req.url.path.endsWith('/tasks') && req.method == 'GET') {
        return http.Response(
          jsonEncode([
            {
              'id': 'task-42',
              'description': 'Fix daily-deals price formatting',
              'status': 'running',
              'created_at': 0.0,
              'updated_at': 0.0,
            }
          ]),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (req.url.path.endsWith('/channels')) {
        return http.Response('[]', 200, headers: {'content-type': 'application/json'});
      }
      if (req.url.path.contains('/health')) {
        return http.Response('{"ready":true,"target":1,"joined":1}', 200);
      }
      // Default: empty
      return http.Response('[]', 200, headers: {'content-type': 'application/json'});
    });

    final client = TallyOrchClient(baseUrl: 'http://test', bearer: 't', client: mock);
    final wsClient = NotificationsWsClient(orchUrl: 'http://test', bearer: 't');
    final themeCtrl = ThemeController();
    await themeCtrl.load();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: themeCtrl,
        child: MaterialApp(
          theme: themeFromTokens(themeCtrl.activeEntry.tokens),
          home: WorkspaceContext(
            activeWorkspaceId: 1,
            onChange: (_) {},
            child: DiscordShellScreen(client: client, wsClient: wsClient),
          ),
        ),
      ),
    );
    // Let initial _fetch() complete.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    // Kanban is the default selection — the task card should appear.
    expect(find.byType(KanbanView), findsOneWidget);
    expect(find.text('Fix daily-deals price formatting'), findsOneWidget);

    // Tap the card.
    await tester.tap(find.text('Fix daily-deals price formatting'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Task channel screen should now render.
    expect(find.byType(TaskChannelScreen), findsOneWidget);

    // Clean up timers.
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
```

- [ ] **Step 2: Run the test**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test integration_test/kanban_navigation_test.dart 2>&1 | tail -10`

Expected: PASS.

If it fails because the `width: 400` default in tester pumps mobile layout and the card scrolls off-screen, wrap the test app in a `SizedBox(width: 1400, height: 900, child: ...)` so desktop layout is used.

- [ ] **Step 3: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/integration_test/kanban_navigation_test.dart
git commit -m "[shell] integration test: tap kanban card opens task channel"
```

---

### Task 15: Final verification + spec acceptance update

**Files:**
- Modify: `docs/superpowers/specs/2026-05-22-ux-operator-journey-design.md`

- [ ] **Step 1: Run the full test suite**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test 2>&1 | tail -5`
Expected: ALL tests pass.

- [ ] **Step 2: Run analyzer**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter analyze 2>&1 | tail -10`
Expected: no new issues (only pre-existing lint info from B1 era).

- [ ] **Step 3: Manual smoke test (Linux)**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter run -d linux`

In the app:
1. App boots into the Board view (kanban).
2. Tasks (if any) appear in the right columns based on their backend status.
3. Tap a card → task channel opens.
4. Tap "Board" in the rail → kanban returns.
5. Tap "#general" in the rail → general channel still works.
6. Tap "+ New task" in any column → general channel opens (so the user can type a new goal in the architect chat).

Skip if no Linux GUI available. Tests are the gate.

- [ ] **Step 4: Update spec acceptance criteria**

Append to the `## 13. Acceptance criteria for this spec` section, after the existing B1 lines:

```markdown
- [x] Sub-project B2 (kanban refactor) plan written: `docs/superpowers/plans/2026-05-25-sub-project-b2-kanban-refactor.md`
- [x] Sub-project B2 implemented: KanbanView replaces the rail's TASKS section; 5 columns (To do · Planning · Running · Awaiting · Done) with mobile horizontal scroll + desktop side-by-side; inline +New task forwards to #general for goal entry; tap-card-to-open-task-channel works. Rail's other sections (#general, CHANNELS, SCHEDULED, DMs) stay until B3 retires the rail.
```

- [ ] **Step 5: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add docs/superpowers/specs/2026-05-22-ux-operator-journey-design.md
git commit -m "[docs] mark B2 implemented in spec acceptance criteria"
```

---

## Self-Review

**1. Spec coverage:**
- ✓ "5-column kanban (replaces rail)" → Tasks 1-9 (widgets) + Tasks 10-13 (shell integration)
- ✓ "Inline +New task per column" → Task 2 (NewTaskRow) + Task 7 (KanbanColumn places it at bottom)
- ✓ "Tap-card-to-open-task-channel transition" → Task 12 (KanbanView onTaskTap → TaskSelected) + Task 14 (integration test)
- ✓ "Mobile horizontal scroll + desktop side-by-side" → Task 8 (responsive LayoutBuilder)
- ✓ ANSI agent identity, square corners, no gradients → inherited from B1's Brutal primitives

**Known gaps documented in the plan (NOT spec violations — intentional B2 deferrals):**
- RunningTaskCard's `agents` list is empty + `progress` is placeholder `0.5` (backend doesn't expose these yet; B3 wires them when escalation routing lands).
- DoneCard's `shippedAgo` is empty string (no relative-time computation in B2; B3 adds it).
- AwaitingCard's `action` is hardcoded "Review"; B3 will derive from escalation context.
- Inline +New forwards to `#general` instead of a rich quick-add modal (deferred to sub-project A explicitly per spec section 8.1).

**2. Placeholder scan:** No "TBD" / "TODO" / "fill in details" in any task. Every step has exact code.

**3. Type consistency:**
- `TaskColumn` enum used consistently across Tasks 1, 8.
- `Task` data class from `lib/api.dart` (existing — no schema changes).
- `AgentRole` enum from B1's `agent_avatar.dart` used consistently in PlanningCard + RunningTaskCard.
- `ChannelSelection` sealed class extended with `BoardSelected` (Task 10), referenced in Task 12.
- `BrutalCard`, `BrutalProgressBar`, `BrutalPill`, `AgentAvatar` from B1's `brutal.dart` barrel.

**4. Order dependencies:**
- Tasks 1 → 2 → 3 → 4 → 5 → 6 → 7 (cards stack on previous; column needs cards)
- Task 7 → 8 (view needs columns)
- Task 8 → 9 (barrel needs all widgets)
- Tasks 10 → 11 → 12 (shell integration depends on BoardSelected variant)
- Task 12 → 13 (remove rail TASKS only after kanban renders)
- Task 13 → 14 (integration test asserts on the final state)
- Task 14 → 15 (final verification last)

Clean dependency chain.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-25-sub-project-b2-kanban-refactor.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
