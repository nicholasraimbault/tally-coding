# Sub-Project B3b — Channels Sheet + Inline Escalation Card Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the mobile bottom-sheet UX layer started in B3a. Add (1) a `channelsExpanded` state to the existing bottom sheet — swipe up from `AmbientMiniDash` reveals a rich channel list (long-term channels only, with author-avatar snippets and need-attention highlighting); (2) an `InlineEscalationCard` widget that injects into long-term channel chats (Screen 5 pattern) so users can resolve escalations from within the channel without the takeover sheet; (3) channel highlighting wiring — channels with pending escalations get the amber accent treatment in the channels list. All UI; orchestrator-side escalation routing lands in B4.

**Architecture:** Extends B3a's `BottomSheetController` with `channelsExpanded` state + channel list state (`List<ChannelModel>`, fetched via existing `TallyOrchClient.listChannels()`). New `ChannelsSheet` widget renders the expanded variant. `InlineEscalationCard` is a standalone widget that `GeneralChannelScreen` (and other long-term channel screens) injects into its message stream when a message with `kind='escalation'` arrives. Same `EscalationModel` from B3a flows through both surfaces (inline + takeover). Channel highlighting comes from a derived flag in the controller — `hasEscalation: Set<int>` of channel IDs with pending escalations.

**Tech Stack:**
- Flutter SDK ^3.6.2 (existing)
- B1 Brutal primitives + B3a `BottomSheetController` + `EscalationModel`
- `provider` (existing)
- `TallyOrchClient.listChannels()` / `postMessage()` (existing)
- Standard `flutter_test`

**Scope boundary:** B3b finishes the mobile sheet UX. Does NOT include push notifs, narrator backend, desktop sidebar — those live in B4/B5. B3a must ship first (this plan extends B3a's controller + reuses its EscalationModel + EscalationSheet patterns).

---

## File Structure

### Create

| Path | Responsibility |
|---|---|
| `tally_coding_app/lib/widgets/bottom_sheet/channel_model.dart` | `ChannelModel` data class wrapping the loose `Map<String, dynamic>` from `listChannels()` |
| `tally_coding_app/lib/widgets/bottom_sheet/channels_sheet.dart` | `ChannelsSheet` widget: header + activity strip + rich rows + need-attention highlighting |
| `tally_coding_app/lib/widgets/bottom_sheet/channel_row.dart` | `CalmChannelRow` + `NeedsAttentionChannelRow` widgets |
| `tally_coding_app/lib/widgets/bottom_sheet/inline_escalation_card.dart` | `InlineEscalationCard` widget for embedding in long-term channel message streams |
| `tally_coding_app/test/widgets/bottom_sheet/channel_model_test.dart` | Model + fromJson tests |
| `tally_coding_app/test/widgets/bottom_sheet/channels_sheet_test.dart` | Sheet + rows + highlighting |
| `tally_coding_app/test/widgets/bottom_sheet/inline_escalation_card_test.dart` | Inline card rendering + tap → onReply |

### Modify

| Path | Why |
|---|---|
| `tally_coding_app/lib/widgets/bottom_sheet/bottom_sheet_controller.dart` | Add `channelsExpanded` SheetState variant + `loadChannels(client)` + `expandChannels()` / `collapseToAmbient()` methods + `hasEscalationInChannel(int channelId)` derived getter |
| `tally_coding_app/lib/widgets/bottom_sheet/bottom_sheet.dart` | Export the new files |
| `tally_coding_app/lib/screens/discord_shell.dart` | `_BoardBottomSheet` renders ChannelsSheet when `state == channelsExpanded`; gesture handling for swipe-up |
| `tally_coding_app/lib/screens/general_channel.dart` | Detect `kind='escalation'` messages in the stream and render InlineEscalationCard inline |

---

## Tasks

### Task 1: ChannelModel data class

**Files:**
- Create: `tally_coding_app/lib/widgets/bottom_sheet/channel_model.dart`
- Create: `tally_coding_app/test/widgets/bottom_sheet/channel_model_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/bottom_sheet/channel_model_test.dart`
Expected: FAIL.

- [ ] **Step 3: Implement ChannelModel**

```dart
import 'package:flutter/foundation.dart';

@immutable
class ChannelModel {
  final int id;
  final String name;
  final String kind;
  final String? lastMessageText;
  final String? lastMessageAuthor;
  final double? lastMessageAt;

  const ChannelModel({
    required this.id,
    required this.name,
    required this.kind,
    this.lastMessageText,
    this.lastMessageAuthor,
    this.lastMessageAt,
  });

  factory ChannelModel.fromJson(Map<String, dynamic> json) => ChannelModel(
        id: json['id'] as int,
        name: json['name'] as String,
        kind: json['kind'] as String,
        lastMessageText: json['last_message_text'] as String?,
        lastMessageAuthor: json['last_message_author'] as String?,
        lastMessageAt: (json['last_message_at'] as num?)?.toDouble(),
      );

  /// Long-term channels show in the channels sheet. Task channels do not.
  bool get isLongTerm => kind != 'task';

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is ChannelModel && other.id == id);

  @override
  int get hashCode => id.hashCode;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/bottom_sheet/channel_model_test.dart`
Expected: PASS — 3 tests.

- [ ] **Step 5: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/widgets/bottom_sheet/channel_model.dart tally_coding_app/test/widgets/bottom_sheet/channel_model_test.dart
git commit -m "[bsheet] ChannelModel data class"
```

---

### Task 2: Extend BottomSheetController with channelsExpanded state + channel list

**Files:**
- Modify: `tally_coding_app/lib/widgets/bottom_sheet/bottom_sheet_controller.dart`
- Modify: `tally_coding_app/test/widgets/bottom_sheet/bottom_sheet_controller_test.dart`

- [ ] **Step 1: Append failing tests**

```dart
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
```

Add imports to test file:
```dart
import 'package:tally_coding_app/widgets/bottom_sheet/channel_model.dart';
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/bottom_sheet/bottom_sheet_controller_test.dart`
Expected: FAIL.

- [ ] **Step 3: Extend BottomSheetController**

Modify `bottom_sheet_controller.dart`:

```dart
// Add to imports:
import 'package:tally_coding_app/widgets/bottom_sheet/channel_model.dart';

// Extend the enum:
enum SheetState { ambient, takeover, channelsExpanded, hidden }

// Add fields:
List<ChannelModel> _channels = [];

// Add public getter:
List<ChannelModel> get channels => List.unmodifiable(_channels);

// Add methods:
void setChannels(List<ChannelModel> channels) {
  _channels = List.of(channels);
  notifyListeners();
}

void expandChannels() {
  _state = SheetState.channelsExpanded;
  notifyListeners();
}

void collapseToAmbient() {
  _state = _queue.isEmpty ? SheetState.ambient : SheetState.takeover;
  notifyListeners();
}

bool hasEscalationInChannel(int channelId) =>
    _queue.any((e) => e.channelId == channelId);
```

Also update `show()` to handle the new state if needed (keep as-is — it returns to ambient/takeover, which is correct when un-hiding).

- [ ] **Step 4: Run tests**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/bottom_sheet/bottom_sheet_controller_test.dart`
Expected: PASS — 13 tests total (9 from B3a + 4 new).

- [ ] **Step 5: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/widgets/bottom_sheet/bottom_sheet_controller.dart tally_coding_app/test/widgets/bottom_sheet/bottom_sheet_controller_test.dart
git commit -m "[bsheet] BottomSheetController: channelsExpanded state + channel list + hasEscalationInChannel"
```

---

### Task 3: CalmChannelRow widget

**Files:**
- Create: `tally_coding_app/lib/widgets/bottom_sheet/channel_row.dart`
- Create: `tally_coding_app/test/widgets/bottom_sheet/channels_sheet_test.dart` (will accumulate tests for both row variants + the sheet)

- [ ] **Step 1: Write the failing tests**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/channel_model.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/channel_row.dart';

Widget _wrap(Widget child) {
  final tokens = themeCatalog[defaultThemeSlug]!.tokens;
  return MaterialApp(theme: themeFromTokens(tokens), home: Scaffold(body: child));
}

void main() {
  group('CalmChannelRow', () {
    testWidgets('renders # + name + last message snippet', (tester) async {
      await tester.pumpWidget(_wrap(CalmChannelRow(
        channel: const ChannelModel(
          id: 1, name: 'health', kind: 'custom',
          lastMessageText: 'p99 OK at 240ms', lastMessageAuthor: 'tally',
        ),
        onTap: () {},
      )));
      expect(find.text('#health'), findsOneWidget);
      expect(find.text('p99 OK at 240ms'), findsOneWidget);
    });

    testWidgets('invokes onTap when tapped', (tester) async {
      int taps = 0;
      await tester.pumpWidget(_wrap(CalmChannelRow(
        channel: const ChannelModel(id: 1, name: 'g', kind: 'custom'),
        onTap: () => taps++,
      )));
      await tester.tap(find.byType(CalmChannelRow));
      expect(taps, 1);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/bottom_sheet/channels_sheet_test.dart`
Expected: FAIL.

- [ ] **Step 3: Implement CalmChannelRow**

```dart
import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/channel_model.dart';

class CalmChannelRow extends StatelessWidget {
  final ChannelModel channel;
  final VoidCallback onTap;

  const CalmChannelRow({super.key, required this.channel, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tc.border, width: 1)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '#${channel.name}',
                    style: TextStyle(
                      color: tc.fg, fontSize: 14, fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (channel.lastMessageText != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      channel.lastMessageText!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: tc.fgDim, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

(`NeedsAttentionChannelRow` is added in the next task — kept separate for cleaner diffs.)

- [ ] **Step 4: Run tests**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/bottom_sheet/channels_sheet_test.dart`
Expected: PASS — 2 tests.

- [ ] **Step 5: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/widgets/bottom_sheet/channel_row.dart tally_coding_app/test/widgets/bottom_sheet/channels_sheet_test.dart
git commit -m "[bsheet] CalmChannelRow widget"
```

---

### Task 4: NeedsAttentionChannelRow widget (3px coral accent + amber wash)

**Files:**
- Modify: `tally_coding_app/lib/widgets/bottom_sheet/channel_row.dart`
- Modify: `tally_coding_app/test/widgets/bottom_sheet/channels_sheet_test.dart`

- [ ] **Step 1: Append the failing tests**

```dart
  group('NeedsAttentionChannelRow', () {
    testWidgets('renders # + name + "1 escalation" pill', (tester) async {
      await tester.pumpWidget(_wrap(NeedsAttentionChannelRow(
        channel: const ChannelModel(id: 1, name: 'general', kind: 'custom'),
        escalationCount: 1,
        onTap: () {},
      )));
      expect(find.text('#general'), findsOneWidget);
      expect(find.text('1 ESCALATION'), findsOneWidget);
    });

    testWidgets('pluralizes label when count > 1', (tester) async {
      await tester.pumpWidget(_wrap(NeedsAttentionChannelRow(
        channel: const ChannelModel(id: 1, name: 'g', kind: 'custom'),
        escalationCount: 3,
        onTap: () {},
      )));
      expect(find.text('3 ESCALATIONS'), findsOneWidget);
    });

    testWidgets('invokes onTap when tapped', (tester) async {
      int taps = 0;
      await tester.pumpWidget(_wrap(NeedsAttentionChannelRow(
        channel: const ChannelModel(id: 1, name: 'g', kind: 'custom'),
        escalationCount: 1,
        onTap: () => taps++,
      )));
      await tester.tap(find.byType(NeedsAttentionChannelRow));
      expect(taps, 1);
    });
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/bottom_sheet/channels_sheet_test.dart`
Expected: FAIL.

- [ ] **Step 3: Append NeedsAttentionChannelRow**

In `channel_row.dart`, append:

```dart
class NeedsAttentionChannelRow extends StatelessWidget {
  final ChannelModel channel;
  final int escalationCount;
  final VoidCallback onTap;

  const NeedsAttentionChannelRow({
    super.key,
    required this.channel,
    required this.escalationCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    final coral = tc.red;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: tc.red.withValues(alpha: 0.06), // amber-wash
          border: Border(
            left: BorderSide(color: coral, width: 3),
            bottom: BorderSide(color: tc.border, width: 1),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '#${channel.name}',
                style: TextStyle(
                  color: tc.fg, fontSize: 14, fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Inline BrutalPill-style chip for escalation count
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(border: Border.all(color: coral, width: 1)),
              child: Text(
                escalationCount == 1
                    ? '1 ESCALATION'
                    : '$escalationCount ESCALATIONS',
                style: TextStyle(
                  color: coral, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/bottom_sheet/channels_sheet_test.dart`
Expected: PASS — 5 tests total.

- [ ] **Step 5: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/widgets/bottom_sheet/channel_row.dart tally_coding_app/test/widgets/bottom_sheet/channels_sheet_test.dart
git commit -m "[bsheet] NeedsAttentionChannelRow widget (3px coral accent + amber wash + pill)"
```

---

### Task 5: ChannelsSheet widget

**Files:**
- Create: `tally_coding_app/lib/widgets/bottom_sheet/channels_sheet.dart`
- Modify: `tally_coding_app/test/widgets/bottom_sheet/channels_sheet_test.dart`

- [ ] **Step 1: Append failing tests**

```dart
  group('ChannelsSheet', () {
    testWidgets('renders header + activity strip + channel rows', (tester) async {
      await tester.pumpWidget(_wrap(ChannelsSheet(
        channels: const [
          ChannelModel(id: 1, name: 'general', kind: 'custom'),
          ChannelModel(id: 2, name: 'health', kind: 'custom'),
        ],
        needsAttention: const {},
        escalationCountByChannel: const {},
        onChannelTap: (_) {},
        onCollapse: () {},
      )));
      expect(find.text('CHANNELS'), findsOneWidget);
      expect(find.text('#general'), findsOneWidget);
      expect(find.text('#health'), findsOneWidget);
    });

    testWidgets('renders need-attention row for channels in needsAttention set', (tester) async {
      await tester.pumpWidget(_wrap(ChannelsSheet(
        channels: const [
          ChannelModel(id: 1, name: 'general', kind: 'custom'),
        ],
        needsAttention: const {1},
        escalationCountByChannel: const {1: 1},
        onChannelTap: (_) {},
        onCollapse: () {},
      )));
      expect(find.byType(NeedsAttentionChannelRow), findsOneWidget);
      expect(find.byType(CalmChannelRow), findsNothing);
    });

    testWidgets('skips non-long-term channels (e.g. task)', (tester) async {
      await tester.pumpWidget(_wrap(ChannelsSheet(
        channels: const [
          ChannelModel(id: 1, name: 'general', kind: 'custom'),
          ChannelModel(id: 2, name: 'feat/x', kind: 'task'),
        ],
        needsAttention: const {},
        escalationCountByChannel: const {},
        onChannelTap: (_) {},
        onCollapse: () {},
      )));
      expect(find.text('#general'), findsOneWidget);
      expect(find.text('#feat/x'), findsNothing);
    });

    testWidgets('tap on a row invokes onChannelTap', (tester) async {
      ChannelModel? tapped;
      await tester.pumpWidget(_wrap(ChannelsSheet(
        channels: const [ChannelModel(id: 5, name: 'g', kind: 'custom')],
        needsAttention: const {},
        escalationCountByChannel: const {},
        onChannelTap: (c) => tapped = c,
        onCollapse: () {},
      )));
      await tester.tap(find.text('#g'));
      expect(tapped?.id, 5);
    });
  });
```

Add to top imports:
```dart
import 'package:tally_coding_app/widgets/bottom_sheet/channels_sheet.dart';
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/bottom_sheet/channels_sheet_test.dart`
Expected: FAIL.

- [ ] **Step 3: Implement ChannelsSheet**

```dart
import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/channel_model.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/channel_row.dart';

class ChannelsSheet extends StatelessWidget {
  final List<ChannelModel> channels;
  final Set<int> needsAttention;
  final Map<int, int> escalationCountByChannel;
  final void Function(ChannelModel) onChannelTap;
  final VoidCallback onCollapse;

  const ChannelsSheet({
    super.key,
    required this.channels,
    required this.needsAttention,
    required this.escalationCountByChannel,
    required this.onChannelTap,
    required this.onCollapse,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    final longTerm = channels.where((c) => c.isLongTerm).toList();
    final attentionCount = longTerm.where((c) => needsAttention.contains(c.id)).length;

    return Container(
      decoration: BoxDecoration(
        color: tc.sheet,
        border: Border(top: BorderSide(color: tc.border, width: 1)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: GestureDetector(
              onTap: onCollapse,
              behavior: HitTestBehavior.opaque,
              child: Center(
                child: Container(
                  width: 36, height: 4,
                  decoration: BoxDecoration(color: tc.border, borderRadius: BorderRadius.circular(2)),
                ),
              ),
            ),
          ),
          // Header: "CHANNELS" label + count
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                Text(
                  'CHANNELS',
                  style: TextStyle(color: tc.fgDim, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.0),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(border: Border.all(color: tc.border, width: 1)),
                  child: Text(
                    '${longTerm.length}',
                    style: TextStyle(
                      color: tc.fgXdim, fontSize: 10, fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                if (attentionCount > 0) ...[
                  const Spacer(),
                  Text(
                    '$attentionCount NEED${attentionCount == 1 ? "S" : ""} YOU',
                    style: TextStyle(color: tc.red, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.8),
                  ),
                ],
              ],
            ),
          ),
          // Activity strip (dim) — placeholder for B4 when narrator counts surface
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '${longTerm.length} channels',
              style: TextStyle(color: tc.fgXdim, fontSize: 11),
            ),
          ),
          // Rows
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 480),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: longTerm.length,
              itemBuilder: (ctx, i) {
                final ch = longTerm[i];
                if (needsAttention.contains(ch.id)) {
                  return NeedsAttentionChannelRow(
                    channel: ch,
                    escalationCount: escalationCountByChannel[ch.id] ?? 1,
                    onTap: () => onChannelTap(ch),
                  );
                }
                return CalmChannelRow(channel: ch, onTap: () => onChannelTap(ch));
              },
            ),
          ),
          // iOS-style safe area for bottom
          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/bottom_sheet/channels_sheet_test.dart`
Expected: PASS — 9 tests total.

- [ ] **Step 5: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/widgets/bottom_sheet/channels_sheet.dart tally_coding_app/test/widgets/bottom_sheet/channels_sheet_test.dart
git commit -m "[bsheet] ChannelsSheet widget (header + count + activity strip + rows)"
```

---

### Task 6: InlineEscalationCard widget

**Files:**
- Create: `tally_coding_app/lib/widgets/bottom_sheet/inline_escalation_card.dart`
- Create: `tally_coding_app/test/widgets/bottom_sheet/inline_escalation_card_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/escalation_model.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/inline_escalation_card.dart';

const _esc = EscalationModel(
  id: 'e1', question: 'Round to 2 decimals or keep 4?',
  options: ['2 decimals', 'Keep 4'],
  taskId: 't-42', channelId: 7,
);

Widget _wrap(Widget child) {
  final tokens = themeCatalog[defaultThemeSlug]!.tokens;
  return MaterialApp(theme: themeFromTokens(tokens), home: Scaffold(body: child));
}

void main() {
  testWidgets('renders question + options as buttons', (tester) async {
    await tester.pumpWidget(_wrap(InlineEscalationCard(
      escalation: _esc,
      taskTitle: 'Fix daily-deals',
      onReply: (_) {}, onOpenTask: () {},
    )));
    expect(find.text('Round to 2 decimals or keep 4?'), findsOneWidget);
    expect(find.text('2 DECIMALS'), findsOneWidget);
    expect(find.text('KEEP 4'), findsOneWidget);
  });

  testWidgets('renders Tally avatar + "Tally needs you" + task tag', (tester) async {
    await tester.pumpWidget(_wrap(InlineEscalationCard(
      escalation: _esc, taskTitle: 'Fix daily-deals',
      onReply: (_) {}, onOpenTask: () {},
    )));
    expect(find.text('T'), findsWidgets); // TallyAvatar monogram
    expect(find.textContaining('TALLY NEEDS YOU'), findsOneWidget);
    expect(find.text('Fix daily-deals'), findsOneWidget);
  });

  testWidgets('tapping option calls onReply', (tester) async {
    String? picked;
    await tester.pumpWidget(_wrap(InlineEscalationCard(
      escalation: _esc, taskTitle: 't',
      onReply: (o) => picked = o, onOpenTask: () {},
    )));
    await tester.tap(find.text('2 DECIMALS'));
    expect(picked, '2 decimals');
  });

  testWidgets('tapping Open task channel calls onOpenTask', (tester) async {
    int calls = 0;
    await tester.pumpWidget(_wrap(InlineEscalationCard(
      escalation: _esc, taskTitle: 't',
      onReply: (_) {}, onOpenTask: () => calls++,
    )));
    await tester.tap(find.text('OPEN TASK CHANNEL'));
    expect(calls, 1);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/bottom_sheet/inline_escalation_card_test.dart`
Expected: FAIL.

- [ ] **Step 3: Implement InlineEscalationCard**

```dart
import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/escalation_model.dart';
import 'package:tally_coding_app/widgets/brutal/brutal.dart';

class InlineEscalationCard extends StatelessWidget {
  final EscalationModel escalation;
  final String taskTitle;
  final void Function(String option) onReply;
  final VoidCallback onOpenTask;

  const InlineEscalationCard({
    super.key,
    required this.escalation,
    required this.taskTitle,
    required this.onReply,
    required this.onOpenTask,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    final coral = tc.red;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tc.red.withValues(alpha: 0.06),
        border: Border.all(color: coral, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header row: Tally avatar + "TALLY NEEDS YOU" + task tag
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
                    Text(
                      'TALLY NEEDS YOU',
                      style: TextStyle(color: coral, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      taskTitle,
                      style: TextStyle(color: tc.fgDim, fontSize: 12, fontStyle: FontStyle.italic),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Question
          Text(
            escalation.question,
            style: TextStyle(color: tc.fg, fontSize: 13.5, height: 1.4),
          ),
          const SizedBox(height: 12),
          // Quick reply buttons (always stacked vertically in inline form for consistent thumb-tap)
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
          const SizedBox(height: 10),
          // Bottom ghost link: "OPEN TASK CHANNEL"
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: onOpenTask,
              style: TextButton.styleFrom(
                foregroundColor: tc.fgXdim,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
              ),
              child: const Text(
                'OPEN TASK CHANNEL',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test test/widgets/bottom_sheet/inline_escalation_card_test.dart`
Expected: PASS — 4 tests.

- [ ] **Step 5: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/widgets/bottom_sheet/inline_escalation_card.dart tally_coding_app/test/widgets/bottom_sheet/inline_escalation_card_test.dart
git commit -m "[bsheet] InlineEscalationCard widget (Screen 5 pattern)"
```

---

### Task 7: Update bottom_sheet barrel + main.dart import

**Files:**
- Modify: `tally_coding_app/lib/widgets/bottom_sheet/bottom_sheet.dart`

- [ ] **Step 1: Add exports**

```dart
export 'ambient_mini_dash.dart';
export 'bottom_sheet_controller.dart';
export 'channel_model.dart';
export 'channel_row.dart';
export 'channels_sheet.dart';
export 'escalation_model.dart';
export 'escalation_sheet.dart';
export 'inline_escalation_card.dart';
```

- [ ] **Step 2: Verify**

```bash
cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter analyze lib/widgets/bottom_sheet/bottom_sheet.dart
```
Expected: "No issues found!"

- [ ] **Step 3: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/widgets/bottom_sheet/bottom_sheet.dart
git commit -m "[bsheet] barrel: export channels sheet + inline escalation card"
```

---

### Task 8: Render ChannelsSheet in _BoardBottomSheet + swipe-up gesture

**Files:**
- Modify: `tally_coding_app/lib/screens/discord_shell.dart` (the `_BoardBottomSheet` widget from B3a)

- [ ] **Step 1: Extend the _BoardBottomSheet build()**

In `_BoardBottomSheet.build()` from B3a, add a third case for `SheetState.channelsExpanded`:

```dart
if (controller.state == SheetState.channelsExpanded) {
  return ChannelsSheet(
    channels: controller.channels,
    needsAttention: {
      for (final e in controller.queue) e.channelId,
    },
    escalationCountByChannel: {
      for (final e in controller.queue)
        e.channelId: controller.queue.where((q) => q.channelId == e.channelId).length,
    },
    onChannelTap: (ch) {
      controller.collapseToAmbient();
      onOpenChannel(ch.id, ch.name);
    },
    onCollapse: controller.collapseToAmbient,
  );
}
```

Place it before the existing `if (controller.state == SheetState.takeover ...)` check.

- [ ] **Step 2: Add swipe-up gesture on AmbientMiniDash drag handle**

Wrap the AmbientMiniDash return in a `GestureDetector`:

```dart
return GestureDetector(
  onVerticalDragEnd: (details) {
    if ((details.primaryVelocity ?? 0) < -200) {
      controller.expandChannels();
    }
  },
  child: AmbientMiniDash(...),
);
```

(Swipe-up gesture detection — negative velocity = upward swipe.)

- [ ] **Step 3: Run tests**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test 2>&1 | tail -5`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/screens/discord_shell.dart
git commit -m "[shell] render ChannelsSheet on swipe-up + collapse on tap"
```

---

### Task 9: Load channels into BottomSheetController on workspace switch

**Files:**
- Modify: `tally_coding_app/lib/screens/discord_shell.dart`

- [ ] **Step 1: Add channel-load helper**

Find where workspace context changes are handled (`didChangeDependencies` or `_fetchDirectChannels`). Add a call to load channels into the controller:

```dart
Future<void> _loadChannelsIntoController() async {
  final workspaceId = WorkspaceContext.activeIdOrDefault(context);
  try {
    final channelMaps = await widget.client.listChannels(workspaceId: workspaceId);
    if (!mounted) return;
    final channels = channelMaps.map(ChannelModel.fromJson).toList();
    context.read<BottomSheetController>().setChannels(channels);
  } catch (_) {
    // silent — empty channel list is fine fallback
  }
}
```

Call `_loadChannelsIntoController()` after each workspace change + on initial `_fetch()`. Be careful to chain it correctly with existing fetches.

Add to imports:
```dart
import 'package:tally_coding_app/widgets/bottom_sheet/channel_model.dart';
```

- [ ] **Step 2: Run tests**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test 2>&1 | tail -5`
Expected: all pass.

- [ ] **Step 3: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/screens/discord_shell.dart
git commit -m "[shell] populate BottomSheetController.channels on workspace load"
```

---

### Task 10: Inject InlineEscalationCard into GeneralChannelScreen message stream

**Files:**
- Modify: `tally_coding_app/lib/screens/general_channel.dart`

The general channel screen renders a message stream. When a message has `kind == 'escalation'` in its payload, render an `InlineEscalationCard` widget inline at that message's position instead of (or in addition to) the regular message bubble.

- [ ] **Step 1: Locate the message rendering in general_channel.dart**

```bash
cd tally_coding_app && grep -n 'kind\|message\|ListView\|builder' lib/screens/general_channel.dart | head -20
```

Find where each message becomes a rendered widget (likely a builder function or itemBuilder).

- [ ] **Step 2: Add the inline card render path**

Wherever a message's widget is constructed, check if `msg['payload']?['kind'] == 'escalation'`. If yes, construct an `EscalationModel` and render `InlineEscalationCard`:

```dart
import 'package:tally_coding_app/widgets/bottom_sheet/bottom_sheet.dart';

Widget _renderMessage(Map<String, dynamic> msg) {
  final payload = msg['payload'] as Map?;
  if (payload != null && payload['kind'] == 'escalation') {
    final esc = EscalationModel.fromJson({
      ...payload.cast<String, dynamic>(),
      'channel_id': msg['channel_id'] ?? payload['channel_id'],
    });
    final taskTitle = (payload['task_title'] as String?) ?? 'task';
    return InlineEscalationCard(
      escalation: esc,
      taskTitle: taskTitle,
      onReply: (option) async {
        await widget.client.postMessage(
          channelId: esc.channelId,
          text: option,
          kind: 'message',
          payload: {'in_response_to_escalation': esc.id},
        );
        // No state update needed — incoming WS event will refresh
      },
      onOpenTask: () {
        Navigator.of(context).pushNamed('/task', arguments: esc.taskId);
        // NOTE: actual routing depends on existing app navigation. If routes
        // not used, use Navigator.push(MaterialPageRoute(...)) with TaskChannelScreen.
      },
    );
  }
  // ... existing message rendering
}
```

(If the existing code uses a different style, adapt — the key change is adding the escalation branch before the default branch.)

- [ ] **Step 3: Run tests**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test 2>&1 | tail -5`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/lib/screens/general_channel.dart
git commit -m "[general] inject InlineEscalationCard for kind=escalation messages"
```

---

### Task 11: Smoke integration test for ChannelsSheet

**Files:**
- Create: `tally_coding_app/integration_test/channels_sheet_test.dart`

- [ ] **Step 1: Write the test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/bottom_sheet.dart';

void main() {
  testWidgets('expandChannels → ChannelsSheet renders with channels', (tester) async {
    final controller = BottomSheetController();
    controller.setChannels(const [
      ChannelModel(id: 1, name: 'general', kind: 'custom'),
      ChannelModel(id: 2, name: 'health', kind: 'custom'),
    ]);

    final themeCtrl = ThemeController();
    await themeCtrl.load();

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: themeCtrl),
        ChangeNotifierProvider.value(value: controller),
      ],
      child: MaterialApp(
        theme: themeFromTokens(themeCatalog[defaultThemeSlug]!.tokens),
        home: Scaffold(
          body: Consumer<BottomSheetController>(builder: (ctx, c, _) {
            if (c.state == SheetState.channelsExpanded) {
              return ChannelsSheet(
                channels: c.channels,
                needsAttention: const {1},
                escalationCountByChannel: const {1: 1},
                onChannelTap: (_) {},
                onCollapse: c.collapseToAmbient,
              );
            }
            return const Center(child: Text('ambient'));
          }),
        ),
      ),
    ));

    expect(find.text('ambient'), findsOneWidget);
    controller.expandChannels();
    await tester.pump();

    expect(find.text('CHANNELS'), findsOneWidget);
    expect(find.text('#general'), findsOneWidget);
    expect(find.text('#health'), findsOneWidget);
    expect(find.byType(NeedsAttentionChannelRow), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test**

Run: `cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test integration_test/channels_sheet_test.dart 2>&1 | tail -8`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add tally_coding_app/integration_test/channels_sheet_test.dart
git commit -m "[bsheet] integration test: expandChannels renders ChannelsSheet"
```

---

### Task 12: Final verification + spec acceptance

**Files:**
- Modify: `docs/superpowers/specs/2026-05-22-ux-operator-journey-design.md`

- [ ] **Step 1: Run full suite + analyzer**

```bash
cd tally_coding_app && PATH="/home/nick/.local/flutter/bin:$PATH" flutter test 2>&1 | tail -3
PATH="/home/nick/.local/flutter/bin:$PATH" flutter analyze 2>&1 | tail -5
```

Expected: all tests pass, no new analyzer issues.

- [ ] **Step 2: Update spec acceptance criteria**

Append to section 13 (after the B3a line):

```markdown
- [x] Sub-project B3b (channels sheet + inline escalation card) plan written: `docs/superpowers/plans/2026-05-25-sub-project-b3b-channels-sheet-inline-escalation.md`
- [x] Sub-project B3b implemented: ChannelsSheet (swipe-up from mini dash) shows long-term channels with author-avatar snippets + need-attention highlighting; InlineEscalationCard embedded in long-term channel chats; channel highlighting derives from BottomSheetController escalation queue.
- [x] Sub-project B3 (mini dash + escalation flow + channels sheet) COMPLETE via B3a + B3b sub-plans.
```

- [ ] **Step 3: Commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding && git add docs/superpowers/specs/2026-05-22-ux-operator-journey-design.md
git commit -m "[docs] mark B3b + B3 complete in spec acceptance criteria"
```

---

## Self-Review

**1. Spec coverage:**
- ✓ ChannelsSheet (swipe-up from mini dash) → Tasks 1-5, 8
- ✓ Long-term channels only (task channels filtered out) → Task 1 (isLongTerm) + Task 5 (filter in ChannelsSheet)
- ✓ Need-attention row treatment (amber wash + 3px coral) → Task 4
- ✓ Activity strip → Task 5 (currently "N channels" — B4 will replace with narrator counts)
- ✓ InlineEscalationCard in long-term channel chats → Tasks 6, 10
- ✓ Channel highlighting → Task 5 (needsAttention set) + Task 8 (derived from controller queue)
- ✓ Sheet state machine extension → Task 2 (channelsExpanded state + collapseToAmbient method)

**Out of B3 entirely (B4/B5):**
- Push notifications + Tally narrator backend (B4)
- Desktop sidebar variants of all this (B5)

**2. Placeholder scan:** No TBD / TODO in steps. The "B4 will replace activity strip with narrator counts" is a documented future intent in the activity strip's current text, which is acceptable per the YAGNI guidance.

**3. Type consistency:**
- `ChannelModel` used consistently across Tasks 1, 2, 3, 4, 5, 8, 9, 11
- `BottomSheetController.channels` / `.expandChannels()` / `.collapseToAmbient()` / `.hasEscalationInChannel()` consistent
- `EscalationModel` reused from B3a (Tasks 6, 10)
- `SheetState.channelsExpanded` added in Task 2, used in Tasks 8, 11

**4. Order dependencies:**
- Task 1 (ChannelModel) → Tasks 2-5 (consumers)
- Task 2 (controller extension) → Tasks 8-9, 11 (consumers of channelsExpanded)
- Tasks 3-4 (row widgets) → Task 5 (ChannelsSheet uses both)
- Task 5 (ChannelsSheet) → Task 8 (DiscordShellScreen integration)
- Task 6 (InlineEscalationCard) → Task 10 (general_channel integration)
- Task 7 (barrel) — independent, can land any time
- Tasks 8-10 (integrations) → Task 11 (integration test)
- Task 12 (verification) last

Clean dependency chain. **Hard dependency on B3a:** must ship first (controller + EscalationModel come from B3a).

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-25-sub-project-b3b-channels-sheet-inline-escalation.md`. Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task + two-stage review

**2. Inline Execution** — batched via executing-plans

Which approach?
