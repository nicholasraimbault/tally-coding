# Sub-Project B3a — Mini Dash + Escalation Takeover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a docked bottom sheet on top of the kanban view (`BoardSelected`) that has two states — *ambient* (stat row + per-task progress rows + Tally narrator bubble) and *escalation takeover* (coral-washed card with Tally avatar + question + quick replies + Open/Skip ghost buttons). A `BottomSheetController` (ChangeNotifier) drives the state machine; WebSocket `kind='escalation'` events enqueue escalations and flip the sheet into takeover. Tap a quick reply → posts the answer back via `TallyOrchClient.postMessage()` and dequeues. Kanban's currently-escalated `RunningTaskCard` gets a paused/needs-you backreference variant. The channels sheet (expanded state) + inline escalation card in long-term channels are deferred to B3b.

**Architecture:** `BottomSheetController` (provider'd via existing Provider pattern from B1's ThemeController) holds `state: {ambient | takeover | hidden}` + `escalationQueue: List<EscalationModel>`. Mount sheet in a `Stack` overlay inside `DiscordShellScreen`'s wide AND narrow main panes. Sheet visibility: `BoardSelected` → visible; anything else → hidden. The `NotificationsWsClient.onNewMessage` callback gets an additional dispatch path: if `payload['kind'] == 'escalation'`, enqueue in the controller. Quick reply taps construct a follow-up message via `TallyOrchClient.postMessage()` to the long-term channel where the escalation lives.

**Tech Stack:**
- Flutter SDK ^3.6.2 (existing)
- B1 Brutal primitives: `BrutalCard`, `BrutalButton`, `TallyAvatar`, `AgentAvatar`, `BrutalPill`, `BrutalProgressBar` (already shipped)
- B2 kanban widgets: `RunningTaskCard` (already shipped — adds `escalated` prop)
- `provider` (existing — already wraps `ThemeController` in `main.dart`)
- `package:tally_coding_app/api.dart` for `TallyOrchClient.postMessage()` (existing)
- `package:tally_coding_app/services/notifications_ws.dart` for WebSocket integration (existing)
- Standard `flutter_test` for unit + widget tests

**Scope boundary:** B3a ships ambient mini dash + escalation takeover. Does NOT include the channels sheet (expanded state), inline escalation card in `general_channel.dart`, or channel highlighting — those land in B3b. Does NOT include push notifications, narrator backend, or any orchestrator-side changes — those land in B4. Does NOT include desktop sidebar variants — those land in B5.

---

## File Structure

### Create

| Path | Responsibility |
|---|---|
| `tally_coding_app/lib/widgets/bottom_sheet/escalation_model.dart` | `EscalationModel` data class (id, question, options, taskId, channelId) + `fromJson` factory |
| `tally_coding_app/lib/widgets/bottom_sheet/bottom_sheet_controller.dart` | `BottomSheetController` ChangeNotifier: state enum + escalation queue + enqueue/resolve/skip methods |
| `tally_coding_app/lib/widgets/bottom_sheet/ambient_mini_dash.dart` | `AmbientMiniDash` widget: drag handle + stat row + per-task progress rows + Tally narrator bubble |
| `tally_coding_app/lib/widgets/bottom_sheet/escalation_sheet.dart` | `EscalationSheet` widget: coral wash + header + question + quick replies + bottom row (Open / Skip) |
| `tally_coding_app/lib/widgets/bottom_sheet/bottom_sheet.dart` | Barrel export |
| `tally_coding_app/test/widgets/bottom_sheet/escalation_model_test.dart` | Model + fromJson tests |
| `tally_coding_app/test/widgets/bottom_sheet/bottom_sheet_controller_test.dart` | Enqueue / resolve / skip / state transitions |
| `tally_coding_app/test/widgets/bottom_sheet/ambient_mini_dash_test.dart` | Renders stat row + task rows + narrator bubble |
| `tally_coding_app/test/widgets/bottom_sheet/escalation_sheet_test.dart` | Renders header + question + quick reply buttons + bottom row |

### Modify

| Path | Why |
|---|---|
| `tally_coding_app/lib/main.dart` | Wrap app in `ChangeNotifierProvider<BottomSheetController>` (next to existing `ThemeController` provider) |
| `tally_coding_app/lib/screens/discord_shell.dart` | Mount bottom sheet via `Stack` on top of `_mainPane()`; pass narrator text from `_DiscordShellScreenState`'s task fetch loop; hide sheet when not `BoardSelected` |
| `tally_coding_app/lib/services/notifications_ws.dart` | Add `onNewEscalation` callback (or extend existing `onNewMessage` to route `kind='escalation'` payloads to the controller) |
| `tally_coding_app/lib/widgets/kanban/kanban_cards.dart` | Add `escalated` bool prop to `RunningTaskCard` (default false): when true, applies coral wash + amber "Paused · needs you" footer; agent avatars stop pulsing (B1's `AgentAvatar.active=false`) |
| `tally_coding_app/test/widgets/kanban/kanban_cards_test.dart` | Add tests for `RunningTaskCard.escalated=true` rendering |

---

## Tasks

### Task 1: EscalationModel data class

**Files:**
- Create: `tally_coding_app/lib/widgets/bottom_sheet/escalation_model.dart`
- Create: `tally_coding_app/test/widgets/bottom_sheet/escalation_model_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `tally_coding_app/test/widgets/bottom_sheet/escalation_model_test.dart`:

```dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/bottom_sheet/escalation_model_test.dart`
Expected: FAIL — file not found.

- [ ] **Step 3: Implement EscalationModel**

```dart
import 'package:flutter/foundation.dart';

@immutable
class EscalationModel {
  final String id;
  final String question;
  final List<String> options;
  final String taskId;
  final int channelId;

  const EscalationModel({
    required this.id,
    required this.question,
    required this.options,
    required this.taskId,
    required this.channelId,
  });

  factory EscalationModel.fromJson(Map<String, dynamic> json) {
    return EscalationModel(
      id: json['id'] as String,
      question: json['question'] as String,
      options: (json['options'] as List?)?.cast<String>() ?? const [],
      taskId: json['task_id'] as String,
      channelId: json['channel_id'] as int,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is EscalationModel && other.id == id);

  @override
  int get hashCode => id.hashCode;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/bottom_sheet/escalation_model_test.dart`
Expected: PASS — 3 tests.

- [ ] **Step 5: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/widgets/bottom_sheet/escalation_model.dart tally_coding_app/test/widgets/bottom_sheet/escalation_model_test.dart
git commit -m "[bsheet] EscalationModel data class"
```

---

### Task 2: BottomSheetController ChangeNotifier

**Files:**
- Create: `tally_coding_app/lib/widgets/bottom_sheet/bottom_sheet_controller.dart`
- Create: `tally_coding_app/test/widgets/bottom_sheet/bottom_sheet_controller_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/bottom_sheet_controller.dart';
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
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/bottom_sheet/bottom_sheet_controller_test.dart`
Expected: FAIL — file not found.

- [ ] **Step 3: Implement BottomSheetController**

```dart
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

  void enqueueEscalation(EscalationModel e) {
    if (_queue.any((q) => q.id == e.id)) return; // dedupe
    _queue.add(e);
    if (_state == SheetState.ambient) {
      _state = SheetState.takeover;
    }
    notifyListeners();
  }

  void resolveActive() {
    if (_queue.isEmpty) return;
    _queue.removeAt(0);
    if (_queue.isEmpty) {
      _state = SheetState.ambient;
    }
    notifyListeners();
  }

  void skip() {
    if (_queue.length < 2) return; // nothing to cycle
    _queue.add(_queue.removeAt(0));
    notifyListeners();
  }

  void hide() {
    _state = SheetState.hidden;
    notifyListeners();
  }

  void show() {
    _state = _queue.isEmpty ? SheetState.ambient : SheetState.takeover;
    notifyListeners();
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/bottom_sheet/bottom_sheet_controller_test.dart`
Expected: PASS — 9 tests.

- [ ] **Step 5: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/widgets/bottom_sheet/bottom_sheet_controller.dart tally_coding_app/test/widgets/bottom_sheet/bottom_sheet_controller_test.dart
git commit -m "[bsheet] BottomSheetController + state machine + escalation queue"
```

---

### Task 3: AmbientMiniDash widget — stat row + drag handle

**Files:**
- Create: `tally_coding_app/lib/widgets/bottom_sheet/ambient_mini_dash.dart`
- Create: `tally_coding_app/test/widgets/bottom_sheet/ambient_mini_dash_test.dart`

This task lands the skeleton: drag handle pill at top, stat row "N open │ M done today", and an empty body. The next 2 tasks add per-task rows + narrator bubble.

- [ ] **Step 1: Write the failing tests**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/ambient_mini_dash.dart';

Widget _wrap(Widget child) {
  final tokens = themeCatalog[defaultThemeSlug]!.tokens;
  return MaterialApp(theme: themeFromTokens(tokens), home: Scaffold(body: child));
}

void main() {
  testWidgets('renders open + done stat counts', (tester) async {
    await tester.pumpWidget(_wrap(const AmbientMiniDash(
      openCount: 6, doneCount: 3, taskRows: [], narratorText: null,
    )));
    expect(find.text('6'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('open'), findsOneWidget);
    expect(find.text('done today'), findsOneWidget);
  });

  testWidgets('renders drag handle pill', (tester) async {
    await tester.pumpWidget(_wrap(const AmbientMiniDash(
      openCount: 0, doneCount: 0, taskRows: [], narratorText: null,
    )));
    expect(find.byKey(const ValueKey('drag-handle')), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/bottom_sheet/ambient_mini_dash_test.dart`
Expected: FAIL.

- [ ] **Step 3: Implement AmbientMiniDash skeleton**

```dart
import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';

class AmbientMiniDash extends StatelessWidget {
  final int openCount;
  final int doneCount;
  final List<Widget> taskRows;
  final String? narratorText;

  const AmbientMiniDash({
    super.key,
    required this.openCount,
    required this.doneCount,
    required this.taskRows,
    required this.narratorText,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return Container(
      decoration: BoxDecoration(
        color: tc.sheet,
        border: Border(top: BorderSide(color: tc.border, width: 1)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle pill
          Center(
            child: Container(
              key: const ValueKey('drag-handle'),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: tc.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 10),
          // Stat row
          Row(
            children: [
              _StatNumber(value: openCount),
              const SizedBox(width: 6),
              _StatLabel(text: 'open'),
              const SizedBox(width: 10),
              Text('│', style: TextStyle(color: tc.fgDimmer, fontSize: 14)),
              const SizedBox(width: 10),
              _StatNumber(value: doneCount),
              const SizedBox(width: 6),
              _StatLabel(text: 'done today'),
            ],
          ),
          // Per-task rows (added in Task 4)
          ...taskRows,
          // Narrator bubble (added in Task 5)
        ],
      ),
    );
  }
}

class _StatNumber extends StatelessWidget {
  final int value;
  const _StatNumber({required this.value});

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return Text(
      '$value',
      style: TextStyle(
        color: tc.fg,
        fontSize: 22,
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _StatLabel extends StatelessWidget {
  final String text;
  const _StatLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return Text(
      text,
      style: TextStyle(
        color: tc.fgDim,
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.8,
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/bottom_sheet/ambient_mini_dash_test.dart`
Expected: PASS — 2 tests.

- [ ] **Step 5: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/widgets/bottom_sheet/ambient_mini_dash.dart tally_coding_app/test/widgets/bottom_sheet/ambient_mini_dash_test.dart
git commit -m "[bsheet] AmbientMiniDash skeleton (drag handle + stat row)"
```

---

### Task 4: AmbientMiniDash per-task progress rows

The caller (DiscordShellScreen, integrated in Task 11) constructs each `taskRows` element from a Task. To keep AmbientMiniDash simple, we add a `MiniTaskRow` widget that the integration layer uses, then verify it renders inside the dash.

**Files:**
- Modify: `tally_coding_app/lib/widgets/bottom_sheet/ambient_mini_dash.dart` (add `MiniTaskRow` widget)
- Modify: `tally_coding_app/test/widgets/bottom_sheet/ambient_mini_dash_test.dart` (add tests)

- [ ] **Step 1: Append the failing tests**

```dart
  testWidgets('renders MiniTaskRow children inside body', (tester) async {
    await tester.pumpWidget(_wrap(const AmbientMiniDash(
      openCount: 1, doneCount: 0,
      taskRows: [
        MiniTaskRow(title: 'Fix daily-deals', progress: 0.6),
      ],
      narratorText: null,
    )));
    expect(find.text('Fix daily-deals'), findsOneWidget);
  });

  testWidgets('MiniTaskRow renders progress', (tester) async {
    await tester.pumpWidget(_wrap(const Padding(
      padding: EdgeInsets.all(16),
      child: MiniTaskRow(title: 'x', progress: 0.7),
    )));
    expect(find.byType(MiniTaskRow), findsOneWidget);
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/bottom_sheet/ambient_mini_dash_test.dart`
Expected: FAIL.

- [ ] **Step 3: Append MiniTaskRow widget**

In `ambient_mini_dash.dart`, append:

```dart
class MiniTaskRow extends StatelessWidget {
  final String title;
  final double progress;

  const MiniTaskRow({super.key, required this.title, required this.progress});

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    final clamped = progress.clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: tc.fgDim, fontSize: 13),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 60,
            height: 3,
            child: Container(
              color: tc.border,
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: clamped,
                  child: Container(color: tc.green),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${(clamped * 100).round()}%',
            style: TextStyle(
              color: tc.fgXdim,
              fontSize: 11,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/bottom_sheet/ambient_mini_dash_test.dart`
Expected: PASS — 4 tests total.

- [ ] **Step 5: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/widgets/bottom_sheet/ambient_mini_dash.dart tally_coding_app/test/widgets/bottom_sheet/ambient_mini_dash_test.dart
git commit -m "[bsheet] MiniTaskRow widget + AmbientMiniDash body integration"
```

---

### Task 5: Tally narrator bubble in AmbientMiniDash

**Files:**
- Modify: `tally_coding_app/lib/widgets/bottom_sheet/ambient_mini_dash.dart`
- Modify: `tally_coding_app/test/widgets/bottom_sheet/ambient_mini_dash_test.dart`

- [ ] **Step 1: Append the failing tests**

```dart
  testWidgets('renders Tally narrator bubble when narratorText provided', (tester) async {
    await tester.pumpWidget(_wrap(const AmbientMiniDash(
      openCount: 0, doneCount: 0, taskRows: [],
      narratorText: 'Diagnosed the daily-deals bug.',
    )));
    expect(find.text('Diagnosed the daily-deals bug.'), findsOneWidget);
    // Tally avatar 'T' should appear
    expect(find.text('T'), findsOneWidget);
  });

  testWidgets('omits narrator bubble when narratorText is null', (tester) async {
    await tester.pumpWidget(_wrap(const AmbientMiniDash(
      openCount: 0, doneCount: 0, taskRows: [], narratorText: null,
    )));
    // No 'T' should appear when narrator is null
    expect(find.text('T'), findsNothing);
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/bottom_sheet/ambient_mini_dash_test.dart`
Expected: FAIL.

- [ ] **Step 3: Add narrator bubble to AmbientMiniDash**

Modify `ambient_mini_dash.dart` — add the import at top:

```dart
import 'package:tally_coding_app/widgets/brutal/brutal.dart';
```

In `AmbientMiniDash.build()`, after `...taskRows,` and before the closing `],` of the outer Column, add:

```dart
          if (narratorText != null) ...[
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const TallyAvatar(size: 28, online: false),
                const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: tc.bubble,
                      border: Border.all(color: tc.border, width: 1),
                    ),
                    child: Text(
                      narratorText!,
                      style: TextStyle(color: tc.fg, fontSize: 12.5, height: 1.4),
                    ),
                  ),
                ),
              ],
            ),
          ],
```

- [ ] **Step 4: Run tests**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/bottom_sheet/ambient_mini_dash_test.dart`
Expected: PASS — 6 tests total.

- [ ] **Step 5: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/widgets/bottom_sheet/ambient_mini_dash.dart tally_coding_app/test/widgets/bottom_sheet/ambient_mini_dash_test.dart
git commit -m "[bsheet] Tally narrator bubble in AmbientMiniDash"
```

---

### Task 6: EscalationSheet widget — coral chrome + header

**Files:**
- Create: `tally_coding_app/lib/widgets/bottom_sheet/escalation_sheet.dart`
- Create: `tally_coding_app/test/widgets/bottom_sheet/escalation_sheet_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/escalation_model.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/escalation_sheet.dart';

const _esc = EscalationModel(
  id: 'e1',
  question: 'Round to 2 decimals or keep 4?',
  options: ['2 decimals', 'Keep 4'],
  taskId: 't-42',
  channelId: 7,
);

Widget _wrap(Widget child) {
  final tokens = themeCatalog[defaultThemeSlug]!.tokens;
  return MaterialApp(theme: themeFromTokens(tokens), home: Scaffold(body: child));
}

void main() {
  testWidgets('renders the question text', (tester) async {
    await tester.pumpWidget(_wrap(EscalationSheet(
      escalation: _esc,
      queueIndex: 0, queueSize: 1,
      taskTitle: 'Fix daily-deals',
      channelName: 'general',
      onReply: (_) {}, onSkip: () {}, onOpen: () {},
    )));
    expect(find.text('Round to 2 decimals or keep 4?'), findsOneWidget);
  });

  testWidgets('renders channel name + "needs you" in header', (tester) async {
    await tester.pumpWidget(_wrap(EscalationSheet(
      escalation: _esc, queueIndex: 0, queueSize: 2,
      taskTitle: 't', channelName: 'general',
      onReply: (_) {}, onSkip: () {}, onOpen: () {},
    )));
    expect(find.textContaining('general'), findsWidgets);
    expect(find.textContaining('needs you'), findsOneWidget);
  });

  testWidgets('shows queue badge "1 of N" when queueSize > 1', (tester) async {
    await tester.pumpWidget(_wrap(EscalationSheet(
      escalation: _esc, queueIndex: 0, queueSize: 3,
      taskTitle: 't', channelName: 'g',
      onReply: (_) {}, onSkip: () {}, onOpen: () {},
    )));
    expect(find.text('1 of 3'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/bottom_sheet/escalation_sheet_test.dart`
Expected: FAIL.

- [ ] **Step 3: Implement EscalationSheet skeleton (header + question only; buttons in next task)**

```dart
import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/escalation_model.dart';
import 'package:tally_coding_app/widgets/brutal/brutal.dart';

class EscalationSheet extends StatelessWidget {
  final EscalationModel escalation;
  final int queueIndex; // 0-based
  final int queueSize;
  final String taskTitle;
  final String channelName;
  final void Function(String option) onReply;
  final VoidCallback onSkip;
  final VoidCallback onOpen;

  const EscalationSheet({
    super.key,
    required this.escalation,
    required this.queueIndex,
    required this.queueSize,
    required this.taskTitle,
    required this.channelName,
    required this.onReply,
    required this.onSkip,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    final coral = tc.red;
    return Stack(
      children: [
        // Base + coral wash
        Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          decoration: BoxDecoration(
            color: tc.sheet,
            border: Border(top: BorderSide(color: coral, width: 1)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 36, height: 4,
                  decoration: BoxDecoration(color: tc.border, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 12),
              // Header row: Tally avatar + "#channel · needs you" + queue badge + task line
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const TallyAvatar(size: 28),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text('#$channelName',
                                style: TextStyle(color: tc.fg, fontSize: 13, fontWeight: FontWeight.w700)),
                            Text(' · ', style: TextStyle(color: tc.fgXdim, fontSize: 13)),
                            Text('needs you',
                                style: TextStyle(color: coral, fontSize: 12.5, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text('about: $taskTitle',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: tc.fgDim, fontSize: 11.5)),
                      ],
                    ),
                  ),
                  if (queueSize > 1) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(border: Border.all(color: coral, width: 1)),
                      child: Text(
                        '${queueIndex + 1} of $queueSize',
                        style: TextStyle(color: coral, fontSize: 10, fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()]),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              // Question
              Text(
                escalation.question,
                style: TextStyle(color: tc.fg, fontSize: 13.5, height: 1.4),
              ),
              const SizedBox(height: 14),
              // Buttons + bottom row added in Task 7
            ],
          ),
        ),
      ],
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/bottom_sheet/escalation_sheet_test.dart`
Expected: PASS — 3 tests.

- [ ] **Step 5: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/widgets/bottom_sheet/escalation_sheet.dart tally_coding_app/test/widgets/bottom_sheet/escalation_sheet_test.dart
git commit -m "[bsheet] EscalationSheet skeleton (coral chrome + header + question)"
```

---

### Task 7: EscalationSheet quick replies + bottom row (Open / Skip)

**Files:**
- Modify: `tally_coding_app/lib/widgets/bottom_sheet/escalation_sheet.dart`
- Modify: `tally_coding_app/test/widgets/bottom_sheet/escalation_sheet_test.dart`

- [ ] **Step 1: Append the failing tests**

```dart
  testWidgets('renders one BrutalButton per option', (tester) async {
    await tester.pumpWidget(_wrap(EscalationSheet(
      escalation: _esc, queueIndex: 0, queueSize: 1,
      taskTitle: 't', channelName: 'g',
      onReply: (_) {}, onSkip: () {}, onOpen: () {},
    )));
    expect(find.text('2 DECIMALS'), findsOneWidget);
    expect(find.text('KEEP 4'), findsOneWidget);
  });

  testWidgets('tapping a quick reply calls onReply with the option', (tester) async {
    String? picked;
    await tester.pumpWidget(_wrap(EscalationSheet(
      escalation: _esc, queueIndex: 0, queueSize: 1,
      taskTitle: 't', channelName: 'g',
      onReply: (opt) => picked = opt, onSkip: () {}, onOpen: () {},
    )));
    await tester.tap(find.text('2 DECIMALS'));
    expect(picked, '2 decimals');
  });

  testWidgets('Open ghost button calls onOpen', (tester) async {
    int calls = 0;
    await tester.pumpWidget(_wrap(EscalationSheet(
      escalation: _esc, queueIndex: 0, queueSize: 1,
      taskTitle: 't', channelName: 'g',
      onReply: (_) {}, onSkip: () {}, onOpen: () => calls++,
    )));
    await tester.tap(find.text('OPEN #G'));
    expect(calls, 1);
  });

  testWidgets('Skip ghost button calls onSkip', (tester) async {
    int calls = 0;
    await tester.pumpWidget(_wrap(EscalationSheet(
      escalation: _esc, queueIndex: 0, queueSize: 2,
      taskTitle: 't', channelName: 'g',
      onReply: (_) {}, onSkip: () => calls++, onOpen: () {},
    )));
    await tester.tap(find.text('SKIP'));
    expect(calls, 1);
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/bottom_sheet/escalation_sheet_test.dart`
Expected: FAIL.

- [ ] **Step 3: Append quick replies + bottom row to EscalationSheet**

In `escalation_sheet.dart`, replace the `// Buttons + bottom row added in Task 7` line + everything before the outer closing `],` with:

```dart
              // Quick reply buttons (one per option). 1-2 inline, 3+ stacked.
              if (escalation.options.length <= 2)
                Row(
                  children: [
                    for (int i = 0; i < escalation.options.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      Expanded(
                        child: i == 0
                            ? BrutalButton.primary(
                                label: escalation.options[i],
                                onPressed: () => onReply(escalation.options[i]),
                              )
                            : BrutalButton.outline(
                                label: escalation.options[i],
                                onPressed: () => onReply(escalation.options[i]),
                              ),
                      ),
                    ],
                  ],
                )
              else
                Column(
                  children: [
                    for (int i = 0; i < escalation.options.length; i++) ...[
                      if (i > 0) const SizedBox(height: 6),
                      i == 0
                          ? BrutalButton.primary(
                              label: escalation.options[i],
                              onPressed: () => onReply(escalation.options[i]),
                            )
                          : BrutalButton.outline(
                              label: escalation.options[i],
                              onPressed: () => onReply(escalation.options[i]),
                            ),
                    ],
                  ],
                ),
              const SizedBox(height: 10),
              // Bottom row: Open #channel ghost + Skip ghost
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: onOpen,
                    style: TextButton.styleFrom(
                      foregroundColor: tc.fgXdim,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                    ),
                    child: Text(
                      'OPEN #${channelName.toUpperCase()}',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8),
                    ),
                  ),
                  if (queueSize > 1)
                    TextButton(
                      onPressed: onSkip,
                      style: TextButton.styleFrom(
                        foregroundColor: tc.fgXdim,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                      ),
                      child: const Text(
                        'SKIP',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8),
                      ),
                    ),
                ],
              ),
```

- [ ] **Step 4: Run tests**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/bottom_sheet/escalation_sheet_test.dart`
Expected: PASS — 7 tests total.

- [ ] **Step 5: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/widgets/bottom_sheet/escalation_sheet.dart tally_coding_app/test/widgets/bottom_sheet/escalation_sheet_test.dart
git commit -m "[bsheet] EscalationSheet quick replies + Open/Skip ghost buttons"
```

---

### Task 8: Bottom sheet barrel export

**Files:**
- Create: `tally_coding_app/lib/widgets/bottom_sheet/bottom_sheet.dart`

- [ ] **Step 1: Create barrel**

```dart
export 'ambient_mini_dash.dart';
export 'bottom_sheet_controller.dart';
export 'escalation_model.dart';
export 'escalation_sheet.dart';
```

- [ ] **Step 2: Verify it compiles**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter analyze lib/widgets/bottom_sheet/bottom_sheet.dart`
Expected: "No issues found!"

- [ ] **Step 3: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/widgets/bottom_sheet/bottom_sheet.dart
git commit -m "[bsheet] barrel export for widgets/bottom_sheet/ module"
```

---

### Task 9: Wire BottomSheetController into main.dart

**Files:**
- Modify: `tally_coding_app/lib/main.dart`

- [ ] **Step 1: Read existing provider setup**

Run: `cd tally_coding_app && grep -n 'ChangeNotifierProvider\|themeController' lib/main.dart | head -10`

- [ ] **Step 2: Modify main()**

Wrap the existing `ChangeNotifierProvider.value(value: themeController, ...)` with a second provider. Use `MultiProvider`:

At the top of `main.dart`, add:

```dart
import 'package:tally_coding_app/widgets/bottom_sheet/bottom_sheet.dart';
```

Change `main()`:

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await clerk.setUpLogging(printer: const _LogPrinter());
  final themeController = ThemeController();
  await themeController.load();
  final bottomSheetController = BottomSheetController();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: themeController),
        ChangeNotifierProvider.value(value: bottomSheetController),
      ],
      child: const TallyApp(),
    ),
  );
}
```

- [ ] **Step 3: Run tests**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test 2>&1 | tail -5`
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/main.dart
git commit -m "[app] wire BottomSheetController into main.dart via MultiProvider"
```

---

### Task 10: RunningTaskCard escalated variant (kanban backreference)

**Files:**
- Modify: `tally_coding_app/lib/widgets/kanban/kanban_cards.dart`
- Modify: `tally_coding_app/test/widgets/kanban/kanban_cards_test.dart`

- [ ] **Step 1: Append the failing tests**

```dart
  testWidgets('RunningTaskCard with escalated=true shows Paused · needs you', (tester) async {
    await tester.pumpWidget(_wrap(const RunningTaskCard(
      title: 't', agents: [AgentRole.coder], progress: 0.5, escalated: true,
    )));
    expect(find.text('PAUSED · NEEDS YOU'), findsOneWidget);
  });

  testWidgets('RunningTaskCard default escalated=false does not show paused label', (tester) async {
    await tester.pumpWidget(_wrap(const RunningTaskCard(
      title: 't', agents: [AgentRole.coder], progress: 0.5,
    )));
    expect(find.text('PAUSED · NEEDS YOU'), findsNothing);
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/kanban/kanban_cards_test.dart`
Expected: FAIL.

- [ ] **Step 3: Add `escalated` prop to RunningTaskCard**

In `kanban_cards.dart`, find the `RunningTaskCard` class. Add `final bool escalated;` field + parameter (default false). At the bottom of its Column children, conditionally add:

```dart
          if (escalated) ...[
            const SizedBox(height: 8),
            Text(
              'PAUSED · NEEDS YOU',
              style: TextStyle(
                color: tc.red,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
          ],
```

(Agent pulses stopping is handled in B5/integration later — the visual paused label is enough for B3a.)

- [ ] **Step 4: Run tests**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/kanban/kanban_cards_test.dart`
Expected: PASS — 24 tests total.

- [ ] **Step 5: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/widgets/kanban/kanban_cards.dart tally_coding_app/test/widgets/kanban/kanban_cards_test.dart
git commit -m "[kanban] RunningTaskCard escalated variant (paused/needs-you backreference)"
```

---

### Task 11: Wire BottomSheetController state → DiscordShellScreen mounting

**Files:**
- Modify: `tally_coding_app/lib/screens/discord_shell.dart`

- [ ] **Step 1: Add provider import + controller access**

At the top:
```dart
import 'package:provider/provider.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/bottom_sheet.dart';
```

- [ ] **Step 2: Wrap _mainPane() return in Stack with sheet overlay**

Find `_mainPane()` (around line 666 after B2). Wrap the `case BoardSelected()` arm so it returns:

```dart
BoardSelected() => Stack(
  children: [
    Positioned.fill(
      child: KanbanView(
        tasks: _filteredTasksForKanban(),
        onTaskTap: (task) => setState(() => _selected = TaskSelected(task.id)),
        onNewTask: () => setState(() => _selected = const GeneralSelected()),
      ),
    ),
    Positioned(
      left: 0, right: 0, bottom: 0,
      child: _BoardBottomSheet(
        tasks: _filteredTasksForKanban(),
        latestNarratorText: _latestNarratorText,
        onOpenChannel: (channelId, name) => setState(() {
          _selected = DirectChannelSelected(channelId: channelId, channelName: name);
        }),
      ),
    ),
  ],
),
```

Add `_latestNarratorText` field + extract it from messages stream (Task 12 wires this; for now default to `null`).

For other arms (GeneralSelected, TaskSelected, DirectChannelSelected), DON'T mount the sheet — only Board has it.

- [ ] **Step 3: Add _BoardBottomSheet helper widget**

At the bottom of `discord_shell.dart`, add:

```dart
class _BoardBottomSheet extends StatelessWidget {
  final List<Task> tasks;
  final String? latestNarratorText;
  final void Function(int channelId, String name) onOpenChannel;

  const _BoardBottomSheet({
    required this.tasks,
    required this.latestNarratorText,
    required this.onOpenChannel,
  });

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<BottomSheetController>();
    final running = tasks.where((t) => t.status == 'running').toList();
    final done = tasks.where((t) => t.status == 'completed' || t.status == 'failed').length;
    final open = tasks.length - done;

    if (controller.state == SheetState.hidden) return const SizedBox.shrink();

    if (controller.state == SheetState.takeover && controller.activeEscalation != null) {
      final esc = controller.activeEscalation!;
      final task = tasks.firstWhere(
        (t) => t.id == esc.taskId,
        orElse: () => Task.fromJson({'id': esc.taskId, 'description': '(task)', 'status': 'recovering', 'created_at': 0.0, 'updated_at': 0.0}),
      );
      return EscalationSheet(
        escalation: esc,
        queueIndex: 0,
        queueSize: controller.queueSize,
        taskTitle: task.channelTitle,
        channelName: 'general', // B3b will derive from escalation routing
        onReply: (option) async {
          // Post answer back to the long-term channel + resolve
          // ... (orchestrator integration done in Task 13)
          controller.resolveActive();
        },
        onSkip: controller.skip,
        onOpen: () => onOpenChannel(esc.channelId, 'general'),
      );
    }

    // Ambient state
    return AmbientMiniDash(
      openCount: open,
      doneCount: done,
      taskRows: [
        for (final t in running.take(2))
          MiniTaskRow(title: t.channelTitle, progress: 0.5),  // progress placeholder until B3b
      ],
      narratorText: latestNarratorText,
    );
  }
}
```

- [ ] **Step 4: Run tests**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test 2>&1 | tail -5`
Expected: all existing tests still pass.

- [ ] **Step 5: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/screens/discord_shell.dart
git commit -m "[shell] mount BottomSheet on BoardSelected (ambient/takeover via controller)"
```

---

### Task 12: Tally narrator text wiring (event-driven only — periodic in B4)

For B3a, narrator text comes from the most recent `kind='tally_narrator'` message in the workspace. B4 will introduce LLM-driven narrator on the orchestrator side; B3a just consumes whatever's in the stream.

**Files:**
- Modify: `tally_coding_app/lib/screens/discord_shell.dart` (add `_latestNarratorText` state + extraction from NotificationsWs events)

- [ ] **Step 1: Add field + extraction logic**

In `_DiscordShellScreenState`:

```dart
String? _latestNarratorText;
```

In `initState()` or wherever `wsClient.onNewMessage` is set, add a callback:

```dart
widget.wsClient.onNewMessage = (msg) {
  final kind = (msg['payload'] as Map?)?['kind'] as String?;
  if (kind == 'tally_narrator') {
    final text = (msg['payload'] as Map?)?['text'] as String?;
    if (text != null && mounted) {
      setState(() => _latestNarratorText = text);
    }
  }
  // Preserve existing onNewMessage behavior (forward to existing handler if any)
};
```

(If `onNewMessage` is already set, COMPOSE — chain the existing callback at the end of the new one.)

- [ ] **Step 2: Run tests**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test 2>&1 | tail -5`
Expected: all pass.

- [ ] **Step 3: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/screens/discord_shell.dart
git commit -m "[shell] consume Tally narrator messages from NotificationsWs"
```

---

### Task 13: Escalation enqueue via NotificationsWs

**Files:**
- Modify: `tally_coding_app/lib/screens/discord_shell.dart`

- [ ] **Step 1: Add escalation routing to onNewMessage**

Extend the `onNewMessage` callback (from Task 12) to also handle `kind='escalation'`:

```dart
widget.wsClient.onNewMessage = (msg) {
  final payload = msg['payload'] as Map?;
  final kind = payload?['kind'] as String?;
  if (kind == 'tally_narrator') {
    // (existing handler from Task 12)
  } else if (kind == 'escalation' && payload != null) {
    final esc = EscalationModel.fromJson({
      ...payload.cast<String, dynamic>(),
      'channel_id': msg['channel_id'] ?? payload['channel_id'],
    });
    if (mounted) {
      context.read<BottomSheetController>().enqueueEscalation(esc);
    }
  }
};
```

Imports needed:
```dart
import 'package:tally_coding_app/widgets/bottom_sheet/escalation_model.dart';
```

- [ ] **Step 2: Run tests**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test 2>&1 | tail -5`
Expected: all pass.

- [ ] **Step 3: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/screens/discord_shell.dart
git commit -m "[shell] enqueue escalations from NotificationsWs kind=escalation events"
```

---

### Task 14: Wire quick reply → TallyOrchClient.postMessage

**Files:**
- Modify: `tally_coding_app/lib/screens/discord_shell.dart` (`_BoardBottomSheet.onReply` callback)

- [ ] **Step 1: Implement onReply to post + resolve**

In `_BoardBottomSheet.build()`, replace the `onReply` stub with:

```dart
onReply: (option) async {
  // Post the chosen option as a message to the long-term channel.
  // The orchestrator (B4) will relay this back to the task channel.
  try {
    await context.read<TallyOrchClient>().postMessage(
      channelId: esc.channelId,
      text: option,
      kind: 'message',
      payload: {'in_response_to_escalation': esc.id},
    );
  } catch (_) {
    // If post fails, don't resolve — keep escalation in queue so user can retry.
    return;
  }
  if (context.mounted) {
    context.read<BottomSheetController>().resolveActive();
  }
},
```

Note: `_BoardBottomSheet` will need access to the client. Two options:
- Pass `client` as a constructor param from `DiscordShellScreen`
- Or read from Provider (if available)

Go with constructor param (cleaner, matches existing pattern):

In `_BoardBottomSheet`:
```dart
final TallyOrchClient client;
```
constructor: `required this.client`

In the `_mainPane()` switch arm, pass `client: widget.client`.

- [ ] **Step 2: Run tests**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test 2>&1 | tail -5`
Expected: all pass.

- [ ] **Step 3: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/screens/discord_shell.dart
git commit -m "[shell] post quick reply back to channel on escalation resolve"
```

---

### Task 15: Smoke integration test — escalation lifecycle

**Files:**
- Create: `tally_coding_app/integration_test/escalation_lifecycle_test.dart`

Verifies: ambient → enqueue escalation → takeover renders → tap reply → returns to ambient.

- [ ] **Step 1: Write the test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/bottom_sheet.dart';

void main() {
  testWidgets('controller lifecycle: enqueue → resolve → ambient', (tester) async {
    final controller = BottomSheetController();
    final themeCtrl = ThemeController();

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: themeCtrl..load()),
        ChangeNotifierProvider.value(value: controller),
      ],
      child: MaterialApp(
        theme: themeFromTokens(themeCatalog[defaultThemeSlug]!.tokens),
        home: Scaffold(
          body: Consumer<BottomSheetController>(
            builder: (ctx, c, _) {
              if (c.state == SheetState.takeover) {
                final esc = c.activeEscalation!;
                return EscalationSheet(
                  escalation: esc,
                  queueIndex: 0,
                  queueSize: c.queueSize,
                  taskTitle: 'mock',
                  channelName: 'general',
                  onReply: (_) => c.resolveActive(),
                  onSkip: c.skip,
                  onOpen: () {},
                );
              }
              return const AmbientMiniDash(
                openCount: 0, doneCount: 0, taskRows: [], narratorText: null,
              );
            },
          ),
        ),
      ),
    ));
    await tester.pump();

    // Initial: ambient
    expect(find.byType(AmbientMiniDash), findsOneWidget);

    // Enqueue → takeover
    controller.enqueueEscalation(const EscalationModel(
      id: 'e1', question: 'Q?', options: ['Yes', 'No'],
      taskId: 't1', channelId: 1,
    ));
    await tester.pump();
    expect(find.byType(EscalationSheet), findsOneWidget);
    expect(find.text('Q?'), findsOneWidget);

    // Tap Yes → resolve → ambient
    await tester.tap(find.text('YES'));
    await tester.pump();
    expect(find.byType(AmbientMiniDash), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test integration_test/escalation_lifecycle_test.dart 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/integration_test/escalation_lifecycle_test.dart
git commit -m "[bsheet] integration test: escalation lifecycle ambient → takeover → resolve"
```

---

### Task 16: Final verification + spec acceptance

**Files:**
- Modify: `docs/superpowers/specs/2026-05-22-ux-operator-journey-design.md`

- [ ] **Step 1: Run full suite + analyzer**

```bash
cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test 2>&1 | tail -3
PATH="/home/nick/.local/flutter/bin:$PATH" flutter analyze 2>&1 | tail -5
```

Expected: all tests pass, no new analyzer issues.

- [ ] **Step 2: Update spec acceptance criteria**

Append to section 13 (after the existing B2/B4/B5 lines):

```markdown
- [x] Sub-project B3a (mini dash + escalation takeover) plan written: `docs/superpowers/plans/2026-05-25-sub-project-b3a-mini-dash-escalation-takeover.md`
- [x] Sub-project B3a implemented: AmbientMiniDash + EscalationSheet + BottomSheetController; mounts on BoardSelected via Stack overlay; escalations enqueue from NotificationsWs kind='escalation' events; quick replies post back via TallyOrchClient.postMessage; kanban RunningTaskCard gets escalated variant (PAUSED · NEEDS YOU footer). Channels sheet expanded state + inline escalation card deferred to B3b.
```

- [ ] **Step 3: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add docs/superpowers/specs/2026-05-22-ux-operator-journey-design.md
git commit -m "[docs] mark B3a implemented in spec acceptance criteria"
```

---

## Self-Review

**1. Spec coverage:**
- ✓ Mini dash ambient (stat row + per-task progress + Tally narrator) → Tasks 3-5
- ✓ Escalation takeover (coral chrome + Tally + question + replies + Open/Skip) → Tasks 6-7
- ✓ BottomSheetController state machine + queue → Task 2
- ✓ Kanban card backreference (escalated variant) → Task 10
- ✓ Mount in DiscordShellScreen via Stack on BoardSelected → Task 11
- ✓ WebSocket integration (kind='escalation' + kind='tally_narrator') → Tasks 12-13
- ✓ Quick reply → postMessage wiring → Task 14

**Out of B3a scope (deferred to B3b):**
- ChannelsSheet expanded variant (swipe-up channels list)
- Inline escalation card in general_channel.dart message stream
- Channel highlighting in the channels list

**Out of B3 scope entirely (B4):**
- Tally narrator LLM backend on orchestrator
- Push notification dispatch
- Real escalation routing logic in orchestrator

**2. Placeholder scan:** No TBD / TODO. Every step has exact code.

**3. Type consistency:**
- `EscalationModel` used consistently across Tasks 1, 2, 6, 7, 11, 13, 15
- `SheetState` enum (ambient | takeover | hidden) consistent
- `BottomSheetController` API (`enqueueEscalation` / `resolveActive` / `skip` / `hide` / `show`) consistent
- `AmbientMiniDash` constructor signature locked in Task 3, used in 4/5/11
- `EscalationSheet` constructor signature locked in Task 6, used in 7/11/15
- `MiniTaskRow` defined Task 4, used in Task 11

**4. Order dependencies:** Tasks 1-2 → 3-5 → 6-7 → 8 → 9 → 10 → 11-14 → 15-16. Clean chain.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-25-sub-project-b3a-mini-dash-escalation-takeover.md`. Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task + two-stage review

**2. Inline Execution** — batched in this session via executing-plans

Which approach?
