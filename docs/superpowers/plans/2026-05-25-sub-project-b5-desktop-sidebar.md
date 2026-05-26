# Sub-Project B5 — Desktop Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current `ServerRail` (60 px) + `_ChannelList` (240 px) split in `DiscordShellScreen`'s wide layout with a single 240 px `SidebarShell` that integrates the workspace switcher row, a compact channels list, and a docked `SidebarMiniDash` — the desktop-chrome variant of B3's ambient mini-dash and escalation takeover.

**Architecture:** B5 builds three new widget files that wrap B3's content widgets (`EscalationContentBlock`, `NarratorBubble`, `MiniDashStatRow`, `MiniDashTaskRow` — all defined in B3) in desktop-appropriate chrome (no drag handle, narrower 212 px content area, stacked quick-reply buttons). `SidebarShell` is a `StatelessWidget` that reads a shared `MiniDashController` (defined in B3) passed down from `DiscordShellScreen`. `DiscordShellScreen._buildWide` is surgically updated to swap `ServerRail + _ChannelList` for `SidebarShell`; `_buildNarrow` is unchanged (keeps B3's bottom-sheet pattern). `LayoutBuilder` at the 1100 px breakpoint (already in the codebase) drives the switch.

**Tech Stack:**
- Flutter SDK ^3.6.2 (existing)
- B1 Brutal Terminal primitives: `BrutalButton`, `BrutalPill`, `TallyAvatar`, `AgentAvatar`, `CursorBlink`, `BrutalProgressBar` (already shipped at `lib/widgets/brutal/`)
- B3 controller + content widgets: `MiniDashController` (ChangeNotifier), `EscalationContentBlock`, `NarratorBubble`, `MiniDashStatRow`, `MiniDashTaskRow` (B3-defined — assumed available)
- `TCTokens` / `context.tc` accessor from B1 (`lib/theme/tc_tokens.dart`)
- `ChannelSelection` sealed class (existing, `discord_shell.dart`)
- `TallyOrchClient` (existing `api.dart`)
- `WorkspaceContext` (existing `state/workspace_context.dart`)
- Standard `flutter_test` for widget tests

**Hard dependency:** B3 must ship before B5 executes. The widgets B5 wraps (`MiniDashController`, `EscalationContentBlock`, `NarratorBubble`, `MiniDashStatRow`, `MiniDashTaskRow`) are defined in B3. This plan can be read and reviewed in parallel with B3's plan but must not be executed until B3 is merged.

**Scope boundary:** B5 is desktop-only chrome. It does NOT include mobile bottom-sheet work (B3), push notifications (B4), or multi-window APIs (post-MVP roadmap, spec section 9.8). The members panel (`_MembersPanel`) is removed from the wide layout in this plan — its content (agent roster) is not part of the Brutal Terminal sidebar design (Screens 6 + 7 show no members panel).

---

## Architecture decisions locked in this plan

| Decision | Choice | Rationale |
|---|---|---|
| State ownership | `SidebarShell` consumes `MiniDashController` from B3 via constructor injection (same instance as mobile sheet) | Single source of truth; desktop sidebar and mobile bottom sheet always show the same escalation queue |
| Workspace switcher popover | Defer — `WorkspaceRow` chevron tap opens the existing `ServerRail` workspace-list as a `DropdownMenu` overlay | Keeps parity with existing switcher behavior; B5 absorbs `ServerRail`'s load logic, not its workspace-creation flow |
| Compact channel row | 1-line: `#` icon + channel name + optional needs-attention treatment. No last-message preview (spec section 5.2 Layer 2 explicitly says "compact 1-line rows") | Desktop sidebar has limited vertical space; rich rows are a mobile-sheet pattern |
| Active channel highlight | `rgba(tc.fg, 0.04)` background tint + `tc.fg` color for channel name — same as B3's channel rows but without the mobile padding | Brutal Terminal: no fill, just a near-invisible tint on `tc.bg` |
| Members panel | Removed from wide layout in B5 | Screens 6 + 7 have no members panel; saves 240 px for the kanban at 1440 width |

---

## File Structure

### Create

| Path | Responsibility |
|---|---|
| `tally_coding_app/lib/widgets/sidebar/workspace_row.dart` | `WorkspaceRow` — top row of sidebar: 24 px green badge + workspace name + chevron + search icon + workspace switcher popover |
| `tally_coding_app/lib/widgets/sidebar/sidebar_channels_list.dart` | `SidebarChannelsList` — scrollable list of compact 1-line channel rows for desktop |
| `tally_coding_app/lib/widgets/sidebar/sidebar_mini_dash.dart` | `SidebarMiniDash` — docked footer: ambient state (stat row + task rows + narrator bubble) + escalation takeover (coral wash + question + stacked quick replies); no drag handle |
| `tally_coding_app/lib/widgets/sidebar/sidebar_shell.dart` | `SidebarShell` — 240 px column: `WorkspaceRow` + scrollable `SidebarChannelsList` + docked `SidebarMiniDash` |
| `tally_coding_app/lib/widgets/sidebar/sidebar.dart` | Barrel export |
| `tally_coding_app/test/widgets/sidebar/workspace_row_test.dart` | WorkspaceRow renders badge + name + search icon; badge tap triggers callback |
| `tally_coding_app/test/widgets/sidebar/sidebar_channels_list_test.dart` | Normal rows render; needs-attention row renders coral accent + pill + chevron; tap triggers onSelect |
| `tally_coding_app/test/widgets/sidebar/sidebar_mini_dash_test.dart` | Ambient state renders stat row + tasks + narrator; escalation state renders coral wash + question + stacked buttons; Skip callback; primary button callback |
| `tally_coding_app/test/widgets/sidebar/sidebar_shell_test.dart` | Shell renders WorkspaceRow at top, MiniDash docked at bottom, channels list fills middle |

### Modify

| Path | Why |
|---|---|
| `tally_coding_app/lib/screens/discord_shell.dart` | `_buildWide`: replace `ServerRail` + `_ChannelList` + `_MembersPanel` with `SidebarShell`; thread `MiniDashController` from B3 |
| `tally_coding_app/test/screens/discord_shell_wide_test.dart` | New: smoke test that wide layout renders `SidebarShell` and not `ServerRail` |

---

## Tasks

### Task 1: WorkspaceRow widget

**Files:**
- Create: `tally_coding_app/lib/widgets/sidebar/workspace_row.dart`
- Create: `tally_coding_app/test/widgets/sidebar/workspace_row_test.dart`

- [ ] **Step 1: Write failing tests**

Create `tally_coding_app/test/widgets/sidebar/workspace_row_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/sidebar/workspace_row.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/theme/theme_catalog.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: themeFromTokens(themeCatalog['tokyo-night']!),
  home: Scaffold(body: child),
);

void main() {
  group('WorkspaceRow', () {
    testWidgets('renders badge letter from workspaceName', (tester) async {
      await tester.pumpWidget(_wrap(WorkspaceRow(
        workspaceName: 'pronoic',
        onSwitcherTap: () {},
        onSearchTap: () {},
      )));
      // Badge shows first letter uppercase
      expect(find.text('P'), findsOneWidget);
      // Name appears
      expect(find.text('pronoic'), findsOneWidget);
    });

    testWidgets('chevron tap fires onSwitcherTap', (tester) async {
      var tapped = false;
      await tester.pumpWidget(_wrap(WorkspaceRow(
        workspaceName: 'acme',
        onSwitcherTap: () => tapped = true,
        onSearchTap: () {},
      )));
      // Tap the row area (badge + name + chevron are one GestureDetector)
      await tester.tap(find.byType(WorkspaceRow));
      expect(tapped, isTrue);
    });

    testWidgets('search icon tap fires onSearchTap', (tester) async {
      var searched = false;
      await tester.pumpWidget(_wrap(WorkspaceRow(
        workspaceName: 'acme',
        onSwitcherTap: () {},
        onSearchTap: () => searched = true,
      )));
      await tester.tap(find.byKey(const Key('workspace_row_search')));
      expect(searched, isTrue);
    });

    testWidgets('bottom hairline border is present', (tester) async {
      await tester.pumpWidget(_wrap(WorkspaceRow(
        workspaceName: 'acme',
        onSwitcherTap: () {},
        onSearchTap: () {},
      )));
      // Container with bottom border wraps the row
      expect(
        find.byWidgetPredicate((w) =>
          w is Container &&
          (w.decoration as BoxDecoration?)?.border?.bottom.width == 1.0),
        findsOneWidget,
      );
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app
flutter test test/widgets/sidebar/workspace_row_test.dart
```

Expected: compilation errors — `workspace_row.dart` does not exist.

- [ ] **Step 3: Implement WorkspaceRow**

Create `tally_coding_app/lib/widgets/sidebar/workspace_row.dart`:

```dart
import 'package:flutter/material.dart';
import '../../theme/tc_tokens.dart';

/// Top row of the desktop sidebar.
///
/// Shows:
/// - 24×24 green badge with the first letter of [workspaceName] (uppercase)
/// - [workspaceName] in TC.fg bold
/// - Chevron-down SVG (tapping the row area fires [onSwitcherTap])
/// - Search icon button (fires [onSearchTap])
///
/// Example:
/// ```dart
/// WorkspaceRow(
///   workspaceName: 'pronoic',
///   onSwitcherTap: () => _showWorkspacePicker(context),
///   onSearchTap: () => _openSearch(context),
/// )
/// ```
class WorkspaceRow extends StatelessWidget {
  final String workspaceName;
  final VoidCallback onSwitcherTap;
  final VoidCallback onSearchTap;

  const WorkspaceRow({
    super.key,
    required this.workspaceName,
    required this.onSwitcherTap,
    required this.onSearchTap,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    final letter = workspaceName.trim().isEmpty
        ? '?'
        : workspaceName.trim()[0].toUpperCase();

    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tc.border, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: Row(
        children: [
          // Workspace badge (green block, first letter)
          GestureDetector(
            onTap: onSwitcherTap,
            child: Row(
              children: [
                Container(
                  width: 24, height: 24,
                  color: tc.green,
                  alignment: Alignment.center,
                  child: Text(
                    letter,
                    style: TextStyle(
                      color: tc.bg,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'JetBrainsMono',
                      height: 1,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    workspaceName,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: tc.fg,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'JetBrainsMono',
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // Chevron-down (square linecap, no fill)
                SizedBox(
                  width: 10, height: 10,
                  child: CustomPaint(painter: _ChevronPainter(color: tc.fgXdim)),
                ),
              ],
            ),
          ),
          const Spacer(),
          // Search icon button
          GestureDetector(
            key: const Key('workspace_row_search'),
            onTap: onSearchTap,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: SizedBox(
                width: 26, height: 26,
                child: Center(
                  child: SizedBox(
                    width: 14, height: 14,
                    child: CustomPaint(painter: _SearchPainter(color: tc.fgXdim)),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Draws a chevron-down with square line caps.
class _ChevronPainter extends CustomPainter {
  final Color color;
  _ChevronPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.square
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(size.width * 0.15, size.height * 0.35)
      ..lineTo(size.width * 0.5, size.height * 0.7)
      ..lineTo(size.width * 0.85, size.height * 0.35);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_ChevronPainter old) => old.color != color;
}

/// Draws a search (circle + line) icon with square line caps.
class _SearchPainter extends CustomPainter {
  final Color color;
  _SearchPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.square
      ..style = PaintingStyle.stroke;
    // Circle
    canvas.drawCircle(
      Offset(size.width * 0.44, size.height * 0.44),
      size.width * 0.3,
      paint,
    );
    // Handle line
    final lPaint = Paint()
      ..color = color
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.square;
    canvas.drawLine(
      Offset(size.width * 0.66, size.height * 0.66),
      Offset(size.width * 0.92, size.height * 0.92),
      lPaint,
    );
  }

  @override
  bool shouldRepaint(_SearchPainter old) => old.color != color;
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app
flutter test test/widgets/sidebar/workspace_row_test.dart
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/widgets/sidebar/workspace_row.dart \
        tally_coding_app/test/widgets/sidebar/workspace_row_test.dart
git commit -m "feat(sidebar): add WorkspaceRow widget for desktop sidebar top row"
```

---

### Task 2: SidebarChannelsList widget

**Files:**
- Create: `tally_coding_app/lib/widgets/sidebar/sidebar_channels_list.dart`
- Create: `tally_coding_app/test/widgets/sidebar/sidebar_channels_list_test.dart`

- [ ] **Step 1: Write failing tests**

Create `tally_coding_app/test/widgets/sidebar/sidebar_channels_list_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/sidebar/sidebar_channels_list.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/theme/theme_catalog.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: themeFromTokens(themeCatalog['tokyo-night']!),
  home: Scaffold(body: SizedBox(width: 240, child: child)),
);

const _normalChannel = SidebarChannelEntry(
  name: 'health',
  needsAttention: false,
  escalationCount: 0,
);
const _alertChannel = SidebarChannelEntry(
  name: 'general',
  needsAttention: true,
  escalationCount: 1,
);

void main() {
  group('SidebarChannelsList', () {
    testWidgets('renders channel names with hash prefix', (tester) async {
      await tester.pumpWidget(_wrap(SidebarChannelsList(
        channels: const [_normalChannel],
        activeChannelName: null,
        onChannelTap: (_) {},
        onAddChannel: () {},
      )));
      expect(find.text('health'), findsOneWidget);
      expect(find.text('＃'), findsOneWidget);
    });

    testWidgets('needs-attention row has 3px coral left accent', (tester) async {
      await tester.pumpWidget(_wrap(SidebarChannelsList(
        channels: const [_alertChannel],
        activeChannelName: null,
        onChannelTap: (_) {},
        onAddChannel: () {},
      )));
      // The coral accent Container exists
      expect(
        find.byWidgetPredicate((w) =>
          w is Container &&
          (w.color?.value == const Color(0xFFF7768E).value ||
           (w.decoration as BoxDecoration?)?.color?.value ==
               const Color(0xFFF7768E).value)),
        findsOneWidget,
      );
    });

    testWidgets('needs-attention row shows count pill', (tester) async {
      await tester.pumpWidget(_wrap(SidebarChannelsList(
        channels: const [_alertChannel],
        activeChannelName: null,
        onChannelTap: (_) {},
        onAddChannel: () {},
      )));
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('tapping a channel fires onChannelTap with channel name', (tester) async {
      String? tappedName;
      await tester.pumpWidget(_wrap(SidebarChannelsList(
        channels: const [_normalChannel],
        activeChannelName: null,
        onChannelTap: (name) => tappedName = name,
        onAddChannel: () {},
      )));
      await tester.tap(find.text('health'));
      expect(tappedName, 'health');
    });

    testWidgets('active channel has subtle background tint', (tester) async {
      await tester.pumpWidget(_wrap(SidebarChannelsList(
        channels: const [_normalChannel],
        activeChannelName: 'health',
        onChannelTap: (_) {},
        onAddChannel: () {},
      )));
      // Active row has a non-transparent background container
      expect(
        find.byWidgetPredicate((w) =>
          w is Container &&
          w.color != null &&
          w.color != Colors.transparent),
        findsWidgets, // at least one tinted container
      );
    });

    testWidgets('section header shows + button that fires onAddChannel', (tester) async {
      var addTapped = false;
      await tester.pumpWidget(_wrap(SidebarChannelsList(
        channels: const [_normalChannel],
        activeChannelName: null,
        onChannelTap: (_) {},
        onAddChannel: () => addTapped = true,
      )));
      await tester.tap(find.byKey(const Key('sidebar_channels_add')));
      expect(addTapped, isTrue);
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app
flutter test test/widgets/sidebar/sidebar_channels_list_test.dart
```

Expected: compilation errors — `sidebar_channels_list.dart` does not exist.

- [ ] **Step 3: Implement SidebarChannelsList**

Create `tally_coding_app/lib/widgets/sidebar/sidebar_channels_list.dart`:

```dart
import 'package:flutter/material.dart';
import '../../theme/tc_tokens.dart';

/// A single long-term channel entry for the desktop sidebar.
///
/// [needsAttention] = escalation pending. [escalationCount] drives the pill.
@immutable
class SidebarChannelEntry {
  final String name;
  final bool needsAttention;
  final int escalationCount;
  const SidebarChannelEntry({
    required this.name,
    required this.needsAttention,
    required this.escalationCount,
  });
}

/// Compact 1-line channel list for the desktop sidebar.
///
/// Shows:
/// - Section header "CHANNELS" + count + `+` adder button
/// - One row per [SidebarChannelEntry]: `＃` icon + name (+ needs-attention
///   treatment: 3 px coral left accent + coral row tint + count pill + chevron)
///
/// Active channel (matching [activeChannelName]) gets a subtle `rgba(tc.fg, 0.04)`
/// background tint.
///
/// Example:
/// ```dart
/// SidebarChannelsList(
///   channels: channels,
///   activeChannelName: 'general',
///   onChannelTap: (name) => setState(() => _activeChannel = name),
///   onAddChannel: () => _showNewChannelModal(context),
/// )
/// ```
class SidebarChannelsList extends StatelessWidget {
  final List<SidebarChannelEntry> channels;
  final String? activeChannelName;
  final void Function(String name) onChannelTap;
  final VoidCallback onAddChannel;

  const SidebarChannelsList({
    super.key,
    required this.channels,
    required this.activeChannelName,
    required this.onChannelTap,
    required this.onAddChannel,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(
          tc: tc,
          count: channels.length,
          onAdd: onAddChannel,
        ),
        for (final ch in channels)
          _ChannelRow(
            entry: ch,
            isActive: ch.name == activeChannelName,
            tc: tc,
            onTap: () => onChannelTap(ch.name),
          ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final TCTokens tc;
  final int count;
  final VoidCallback onAdd;
  const _SectionHeader({required this.tc, required this.count, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
      child: Row(
        children: [
          Text(
            'CHANNELS',
            style: TextStyle(
              color: tc.fgXdim, fontSize: 10.5, fontWeight: FontWeight.w700,
              letterSpacing: 1.0, fontFamily: 'JetBrainsMono',
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              border: Border.all(color: tc.border, width: 1),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                color: tc.fgXdim, fontSize: 10.5, fontWeight: FontWeight.w700,
                fontFamily: 'JetBrainsMono',
              ),
            ),
          ),
          const Spacer(),
          GestureDetector(
            key: const Key('sidebar_channels_add'),
            onTap: onAdd,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: SizedBox(
                width: 22, height: 22,
                child: Center(
                  child: Text(
                    '+',
                    style: TextStyle(
                      color: tc.fgXdim, fontSize: 14, fontWeight: FontWeight.w700,
                      fontFamily: 'JetBrainsMono', height: 1,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChannelRow extends StatefulWidget {
  final SidebarChannelEntry entry;
  final bool isActive;
  final TCTokens tc;
  final VoidCallback onTap;
  const _ChannelRow({
    required this.entry, required this.isActive,
    required this.tc, required this.onTap,
  });

  @override
  State<_ChannelRow> createState() => _ChannelRowState();
}

class _ChannelRowState extends State<_ChannelRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tc = widget.tc;
    final ch = widget.entry;

    if (ch.needsAttention) {
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Stack(
            children: [
              // Row background (coral tint)
              AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                color: _hovered
                    ? const Color(0x14F7768E) // rgba(247,118,142,0.08)
                    : const Color(0x0DF7768E), // rgba(247,118,142,0.05)
                padding: const EdgeInsets.fromLTRB(17, 7, 14, 7),
                child: Row(
                  children: [
                    Text(
                      '＃',
                      style: TextStyle(
                        color: tc.red, fontSize: 13, height: 1,
                        fontFamily: 'JetBrainsMono',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        ch.name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: tc.fg, fontSize: 13, fontWeight: FontWeight.w700,
                          fontFamily: 'JetBrainsMono',
                        ),
                      ),
                    ),
                    if (ch.escalationCount > 0) ...[
                      const SizedBox(width: 4),
                      Container(
                        constraints: const BoxConstraints(minWidth: 18),
                        height: 18,
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        decoration: BoxDecoration(
                          border: Border.all(color: tc.red, width: 1),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '${ch.escalationCount}',
                          style: TextStyle(
                            color: tc.red, fontSize: 10, fontWeight: FontWeight.w700,
                            fontFamily: 'JetBrainsMono',
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: 4),
                    // Chevron-right in coral
                    SizedBox(
                      width: 10, height: 10,
                      child: CustomPaint(painter: _ChevronRightPainter(color: tc.red)),
                    ),
                  ],
                ),
              ),
              // 3 px coral left accent bar
              Positioned(
                left: 0, top: 0, bottom: 0,
                child: Container(width: 3, color: tc.red),
              ),
            ],
          ),
        ),
      );
    }

    // Normal channel row
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          color: widget.isActive
              ? Color.fromRGBO(
                  tc.fg.red, tc.fg.green, tc.fg.blue, 0.06)
              : (_hovered
                  ? Color.fromRGBO(tc.fg.red, tc.fg.green, tc.fg.blue, 0.04)
                  : Colors.transparent),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Row(
            children: [
              Text(
                '＃',
                style: TextStyle(
                  color: tc.fgXdim, fontSize: 13, height: 1,
                  fontFamily: 'JetBrainsMono',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  ch.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _hovered || widget.isActive ? tc.fg : tc.fgDim,
                    fontSize: 13, fontWeight: FontWeight.w700,
                    fontFamily: 'JetBrainsMono',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChevronRightPainter extends CustomPainter {
  final Color color;
  _ChevronRightPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.square
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(size.width * 0.25, size.height * 0.1)
      ..lineTo(size.width * 0.75, size.height * 0.5)
      ..lineTo(size.width * 0.25, size.height * 0.9);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_ChevronRightPainter old) => old.color != color;
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app
flutter test test/widgets/sidebar/sidebar_channels_list_test.dart
```

Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/widgets/sidebar/sidebar_channels_list.dart \
        tally_coding_app/test/widgets/sidebar/sidebar_channels_list_test.dart
git commit -m "feat(sidebar): add SidebarChannelsList — compact 1-line desktop channel rows"
```

---

### Task 3: SidebarMiniDash — ambient state

**Files:**
- Create: `tally_coding_app/lib/widgets/sidebar/sidebar_mini_dash.dart` (ambient state only; escalation added in Task 4)
- Create: `tally_coding_app/test/widgets/sidebar/sidebar_mini_dash_test.dart` (ambient tests only)

B5 wraps B3's `MiniDashStatRow`, `MiniDashTaskRow`, and `NarratorBubble` content widgets in desktop chrome. The API contracts below assume B3 has shipped those widgets with these signatures:

```dart
// B3-defined (assumed available):
class MiniDashStatRow extends StatelessWidget {
  final int openCount;
  final int doneToday;
  // ...
}
class MiniDashTaskRow extends StatelessWidget {
  final String taskTitle;
  final List<String> agentRoles; // e.g. ['architect', 'coder']
  final int progressPct;
  // ...
}
class NarratorBubble extends StatelessWidget {
  final String text;        // max 160 chars
  final List<String> emphasizedPhrases; // bolded phrases in TC.fg 700
  // ...
}
```

- [ ] **Step 1: Write failing ambient-state tests**

Create `tally_coding_app/test/widgets/sidebar/sidebar_mini_dash_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/sidebar/sidebar_mini_dash.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/theme/theme_catalog.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: themeFromTokens(themeCatalog['tokyo-night']!),
  home: Scaffold(body: SizedBox(width: 240, child: child)),
);

// Minimal stub escalation item — matches B3's EscalationItem model.
// Replace with the real import once B3 ships.
class _FakeEscalation {
  final String channelName;
  final String taskName;
  final String question;
  final List<String> quickReplies;
  final List<String> emphasizedTerms;
  const _FakeEscalation({
    required this.channelName,
    required this.taskName,
    required this.question,
    required this.quickReplies,
    required this.emphasizedTerms,
  });
}

void main() {
  group('SidebarMiniDash — ambient', () {
    testWidgets('renders stat row with open and done counts', (tester) async {
      await tester.pumpWidget(_wrap(SidebarMiniDash(
        openCount: 6,
        doneToday: 3,
        tasks: const [
          SidebarMiniTaskData(
            title: 'Fix daily-deals',
            agentRoles: ['architect', 'coder'],
            progressPct: 60,
          ),
        ],
        narratorText: 'Coder is patching — PR in ~5 min.',
        narratorEmphasis: ['Coder is patching'],
        escalations: const [],
        onQuickReply: (_) {},
        onSkipEscalation: () {},
        onOpenChannel: () {},
      )));
      expect(find.text('6'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('renders task row with title', (tester) async {
      await tester.pumpWidget(_wrap(SidebarMiniDash(
        openCount: 1,
        doneToday: 0,
        tasks: const [
          SidebarMiniTaskData(
            title: 'Fix daily-deals',
            agentRoles: ['coder'],
            progressPct: 30,
          ),
        ],
        narratorText: 'All good.',
        narratorEmphasis: const [],
        escalations: const [],
        onQuickReply: (_) {},
        onSkipEscalation: () {},
        onOpenChannel: () {},
      )));
      expect(find.textContaining('Fix daily-deals'), findsOneWidget);
    });

    testWidgets('renders narrator bubble text', (tester) async {
      await tester.pumpWidget(_wrap(SidebarMiniDash(
        openCount: 1,
        doneToday: 0,
        tasks: const [],
        narratorText: 'All good.',
        narratorEmphasis: const [],
        escalations: const [],
        onQuickReply: (_) {},
        onSkipEscalation: () {},
        onOpenChannel: () {},
      )));
      expect(find.text('All good.'), findsOneWidget);
    });

    testWidgets('has TC.sheet background + 1px top border + no drag handle', (tester) async {
      await tester.pumpWidget(_wrap(SidebarMiniDash(
        openCount: 0,
        doneToday: 0,
        tasks: const [],
        narratorText: 'Idle.',
        narratorEmphasis: const [],
        escalations: const [],
        onQuickReply: (_) {},
        onSkipEscalation: () {},
        onOpenChannel: () {},
      )));
      // Drag handle must NOT be present (no DraggableScrollableSheet, no pill)
      expect(find.byKey(const Key('drag_handle')), findsNothing);
      // Top border container
      expect(
        find.byWidgetPredicate((w) =>
          w is Container &&
          (w.decoration as BoxDecoration?)?.border?.top.width == 1.0),
        findsOneWidget,
      );
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app
flutter test test/widgets/sidebar/sidebar_mini_dash_test.dart
```

Expected: compilation errors.

- [ ] **Step 3: Implement SidebarMiniDash (ambient state only)**

Create `tally_coding_app/lib/widgets/sidebar/sidebar_mini_dash.dart`:

```dart
import 'package:flutter/material.dart';
import '../../theme/tc_tokens.dart';
import '../../widgets/brutal/tally_avatar.dart';
import '../../widgets/brutal/agent_avatar.dart';
import '../../widgets/brutal/brutal_progress_bar.dart';

/// Data for a single running task shown in the sidebar mini-dash.
@immutable
class SidebarMiniTaskData {
  final String title;
  final List<String> agentRoles; // e.g. ['architect', 'coder']
  final int progressPct;         // 0–100
  const SidebarMiniTaskData({
    required this.title,
    required this.agentRoles,
    required this.progressPct,
  });
}

/// Data for a single escalation item.
///
/// Mirrors B3's EscalationItem shape; imported from B3 once it ships.
/// Defined here temporarily so B5 compiles independently during development.
@immutable
class SidebarEscalationData {
  final String channelName;
  final String taskName;
  final String question;
  final List<String> quickReplies;     // first = primary; rest = outline
  final List<String> emphasizedTerms;  // bold in TC.fg weight-700
  const SidebarEscalationData({
    required this.channelName,
    required this.taskName,
    required this.question,
    required this.quickReplies,
    required this.emphasizedTerms,
  });
}

/// Desktop variant of the mini-dash, docked at the bottom of the sidebar.
///
/// Two states:
/// - **Ambient** (escalations is empty): stat row + per-task rows + narrator bubble.
/// - **Takeover** (escalations is non-empty): coral wash + question + stacked buttons.
///
/// No drag handle — this is a static docked footer, not a draggable sheet.
///
/// Content area is 212 px wide (240 sidebar − 14 px padding × 2).
///
/// Example (ambient):
/// ```dart
/// SidebarMiniDash(
///   openCount: 6,
///   doneToday: 3,
///   tasks: [...],
///   narratorText: 'Coder is patching — PR in ~5 min.',
///   narratorEmphasis: ['Coder is patching'],
///   escalations: const [],
///   onQuickReply: (_) {},
///   onSkipEscalation: () {},
///   onOpenChannel: () {},
/// )
/// ```
class SidebarMiniDash extends StatelessWidget {
  // Ambient state
  final int openCount;
  final int doneToday;
  final List<SidebarMiniTaskData> tasks;
  final String narratorText;
  final List<String> narratorEmphasis;
  // Escalation state
  final List<SidebarEscalationData> escalations;
  final void Function(String reply) onQuickReply;
  final VoidCallback onSkipEscalation;
  final VoidCallback onOpenChannel;
  // Index into escalations currently shown (0-based)
  final int activeEscalationIndex;

  const SidebarMiniDash({
    super.key,
    required this.openCount,
    required this.doneToday,
    required this.tasks,
    required this.narratorText,
    required this.narratorEmphasis,
    required this.escalations,
    required this.onQuickReply,
    required this.onSkipEscalation,
    required this.onOpenChannel,
    this.activeEscalationIndex = 0,
  });

  bool get _isEscalation => escalations.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return _isEscalation
        ? _buildEscalation(context, tc)
        : _buildAmbient(context, tc);
  }

  Widget _buildAmbient(BuildContext context, TCTokens tc) {
    return Container(
      decoration: BoxDecoration(
        color: tc.sheet,
        border: Border(top: BorderSide(color: tc.border, width: 1)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Stat row: "6 open | 3 done today"
          _StatRow(openCount: openCount, doneToday: doneToday, tc: tc),
          if (tasks.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(height: 1, color: tc.border),
            const SizedBox(height: 2),
            for (int i = 0; i < tasks.length; i++) ...[
              _TaskRow(data: tasks[i], tc: tc),
              if (i < tasks.length - 1) Container(height: 1, color: tc.border),
            ],
          ],
          const SizedBox(height: 8),
          _NarratorBubbleInline(
            text: narratorText,
            emphasis: narratorEmphasis,
            tc: tc,
          ),
        ],
      ),
    );
  }

  Widget _buildEscalation(BuildContext context, TCTokens tc) {
    // Escalation takeover — implemented in Task 4.
    // Returns an empty box as a placeholder until Task 4 adds this.
    return const SizedBox.shrink();
  }
}

// ─── Ambient sub-widgets ──────────────────────────────────────────────────

class _StatRow extends StatelessWidget {
  final int openCount;
  final int doneToday;
  final TCTokens tc;
  const _StatRow({required this.openCount, required this.doneToday, required this.tc});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          '$openCount',
          style: TextStyle(
            color: tc.fg, fontSize: 16, fontWeight: FontWeight.w700,
            fontFamily: 'JetBrainsMono', height: 1,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          'OPEN',
          style: TextStyle(
            color: tc.fgXdim, fontSize: 10, fontWeight: FontWeight.w700,
            letterSpacing: 0.6, fontFamily: 'JetBrainsMono',
          ),
        ),
        const SizedBox(width: 4),
        Text(
          '│',
          style: TextStyle(color: tc.fgDimmer, fontSize: 11),
        ),
        const SizedBox(width: 4),
        Text(
          '$doneToday',
          style: TextStyle(
            color: tc.fg, fontSize: 16, fontWeight: FontWeight.w700,
            fontFamily: 'JetBrainsMono', height: 1,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          'DONE TODAY',
          style: TextStyle(
            color: tc.fgXdim, fontSize: 10, fontWeight: FontWeight.w700,
            letterSpacing: 0.6, fontFamily: 'JetBrainsMono',
          ),
        ),
      ],
    );
  }
}

class _TaskRow extends StatelessWidget {
  final SidebarMiniTaskData data;
  final TCTokens tc;
  const _TaskRow({required this.data, required this.tc});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          // Agent micro-avatars (16 px)
          for (int i = 0; i < data.agentRoles.length; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            AgentAvatar(role: data.agentRoles[i], size: 16, pulse: i == 0),
          ],
          const SizedBox(width: 7),
          // Task title (truncated)
          Expanded(
            child: Text(
              data.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: tc.fgDim, fontSize: 11.5, fontWeight: FontWeight.w500,
                fontFamily: 'JetBrainsMono',
              ),
            ),
          ),
          const SizedBox(width: 4),
          // Progress bar (42 px wide, 3 px tall)
          SizedBox(
            width: 42,
            child: BrutalProgressBar(value: data.progressPct / 100.0, height: 3),
          ),
          const SizedBox(width: 4),
          // Progress percentage
          SizedBox(
            width: 24,
            child: Text(
              '${data.progressPct}%',
              textAlign: TextAlign.right,
              style: TextStyle(
                color: tc.fgXdim, fontSize: 10, fontWeight: FontWeight.w700,
                fontFamily: 'JetBrainsMono',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NarratorBubbleInline extends StatelessWidget {
  final String text;
  final List<String> emphasis;
  final TCTokens tc;
  const _NarratorBubbleInline({required this.text, required this.emphasis, required this.tc});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        TallyAvatar(size: 22),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: tc.border, width: 1),
              color: Colors.transparent,
            ),
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
            child: _buildRichText(context),
          ),
        ),
      ],
    );
  }

  Widget _buildRichText(BuildContext context) {
    final tc = context.tc;
    if (emphasis.isEmpty) {
      return Text(
        text,
        style: TextStyle(
          color: tc.fgDim, fontSize: 11.5, height: 1.45,
          fontFamily: 'JetBrainsMono',
        ),
      );
    }
    // Split text at emphasis spans and build RichText
    final spans = <TextSpan>[];
    var remaining = text;
    for (final phrase in emphasis) {
      final idx = remaining.indexOf(phrase);
      if (idx == -1) continue;
      if (idx > 0) {
        spans.add(TextSpan(
          text: remaining.substring(0, idx),
          style: TextStyle(color: tc.fgDim, fontSize: 11.5, height: 1.45),
        ));
      }
      spans.add(TextSpan(
        text: phrase,
        style: TextStyle(
          color: tc.fg, fontSize: 11.5, fontWeight: FontWeight.w700, height: 1.45,
        ),
      ));
      remaining = remaining.substring(idx + phrase.length);
    }
    if (remaining.isNotEmpty) {
      spans.add(TextSpan(
        text: remaining,
        style: TextStyle(color: tc.fgDim, fontSize: 11.5, height: 1.45),
      ));
    }
    return RichText(
      text: TextSpan(
        style: TextStyle(fontFamily: 'JetBrainsMono'),
        children: spans,
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app
flutter test test/widgets/sidebar/sidebar_mini_dash_test.dart
```

Expected: 4 ambient-state tests pass.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/widgets/sidebar/sidebar_mini_dash.dart \
        tally_coding_app/test/widgets/sidebar/sidebar_mini_dash_test.dart
git commit -m "feat(sidebar): add SidebarMiniDash ambient state"
```

---

### Task 4: SidebarMiniDash — escalation takeover state

**Files:**
- Modify: `tally_coding_app/lib/widgets/sidebar/sidebar_mini_dash.dart` (fill in `_buildEscalation`)
- Modify: `tally_coding_app/test/widgets/sidebar/sidebar_mini_dash_test.dart` (add escalation tests)

- [ ] **Step 1: Write failing escalation tests**

Append these test groups to `tally_coding_app/test/widgets/sidebar/sidebar_mini_dash_test.dart`:

```dart
  group('SidebarMiniDash — escalation takeover', () {
    final escalation = SidebarEscalationData(
      channelName: 'general',
      taskName: 'Fix daily-deals',
      question: 'Round to 2 decimals or keep 4?',
      quickReplies: ['2 decimals', 'Keep 4'],
      emphasizedTerms: ['2 decimals', '4'],
    );

    testWidgets('shows channel context header', (tester) async {
      await tester.pumpWidget(_wrap(SidebarMiniDash(
        openCount: 6,
        doneToday: 3,
        tasks: const [],
        narratorText: '',
        narratorEmphasis: const [],
        escalations: [escalation],
        onQuickReply: (_) {},
        onSkipEscalation: () {},
        onOpenChannel: () {},
      )));
      expect(find.textContaining('general'), findsOneWidget);
      expect(find.textContaining('needs you'), findsOneWidget);
    });

    testWidgets('shows question text', (tester) async {
      await tester.pumpWidget(_wrap(SidebarMiniDash(
        openCount: 0,
        doneToday: 0,
        tasks: const [],
        narratorText: '',
        narratorEmphasis: const [],
        escalations: [escalation],
        onQuickReply: (_) {},
        onSkipEscalation: () {},
        onOpenChannel: () {},
      )));
      expect(find.textContaining('Round to'), findsOneWidget);
    });

    testWidgets('primary quick-reply button fires onQuickReply', (tester) async {
      String? reply;
      await tester.pumpWidget(_wrap(SidebarMiniDash(
        openCount: 0,
        doneToday: 0,
        tasks: const [],
        narratorText: '',
        narratorEmphasis: const [],
        escalations: [escalation],
        onQuickReply: (r) => reply = r,
        onSkipEscalation: () {},
        onOpenChannel: () {},
      )));
      await tester.tap(find.text('2 DECIMALS')); // uppercase via button
      expect(reply, '2 decimals');
    });

    testWidgets('outline quick-reply button fires onQuickReply', (tester) async {
      String? reply;
      await tester.pumpWidget(_wrap(SidebarMiniDash(
        openCount: 0,
        doneToday: 0,
        tasks: const [],
        narratorText: '',
        narratorEmphasis: const [],
        escalations: [escalation],
        onQuickReply: (r) => reply = r,
        onSkipEscalation: () {},
        onOpenChannel: () {},
      )));
      await tester.tap(find.text('KEEP 4')); // uppercase via button
      expect(reply, 'Keep 4');
    });

    testWidgets('Skip button fires onSkipEscalation', (tester) async {
      var skipped = false;
      await tester.pumpWidget(_wrap(SidebarMiniDash(
        openCount: 0,
        doneToday: 0,
        tasks: const [],
        narratorText: '',
        narratorEmphasis: const [],
        escalations: [escalation],
        onQuickReply: (_) {},
        onSkipEscalation: () => skipped = true,
        onOpenChannel: () {},
      )));
      await tester.tap(find.byKey(const Key('sidebar_escalation_skip')));
      expect(skipped, isTrue);
    });

    testWidgets('multi-escalation shows 1/N pill', (tester) async {
      await tester.pumpWidget(_wrap(SidebarMiniDash(
        openCount: 0,
        doneToday: 0,
        tasks: const [],
        narratorText: '',
        narratorEmphasis: const [],
        escalations: [escalation, escalation],
        onQuickReply: (_) {},
        onSkipEscalation: () {},
        onOpenChannel: () {},
      )));
      expect(find.text('1/2'), findsOneWidget);
    });

    testWidgets('has coral wash overlay in escalation state', (tester) async {
      await tester.pumpWidget(_wrap(SidebarMiniDash(
        openCount: 0,
        doneToday: 0,
        tasks: const [],
        narratorText: '',
        narratorEmphasis: const [],
        escalations: [escalation],
        onQuickReply: (_) {},
        onSkipEscalation: () {},
        onOpenChannel: () {},
      )));
      // Coral wash = rgba(247,118,142,0.06)
      expect(
        find.byWidgetPredicate((w) =>
          w is Container &&
          w.color?.value == const Color(0x0FF7768E).value),
        findsOneWidget,
      );
    });
  });
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app
flutter test test/widgets/sidebar/sidebar_mini_dash_test.dart --name "escalation"
```

Expected: the escalation-group tests fail (primary returns `SizedBox.shrink`).

- [ ] **Step 3: Implement `_buildEscalation` in SidebarMiniDash**

In `tally_coding_app/lib/widgets/sidebar/sidebar_mini_dash.dart`, replace the `_buildEscalation` stub:

```dart
  Widget _buildEscalation(BuildContext context, TCTokens tc) {
    final item = escalations[activeEscalationIndex];
    final total = escalations.length;
    final isMulti = total > 1;

    return Stack(
      children: [
        // Base container with coral top border + sheet bg
        Container(
          decoration: BoxDecoration(
            color: tc.sheet,
            border: Border(
              top: BorderSide(
                // coral at 45% opacity: rgba(247,118,142,0.45)
                color: const Color(0x73F7768E),
                width: 1,
              ),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row: TallyAvatar + channel context + 1/N pill
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TallyAvatar(size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // "#general · NEEDS YOU"
                        Row(
                          children: [
                            Text(
                              '＃${item.channelName}',
                              style: TextStyle(
                                color: tc.fg, fontSize: 12, fontWeight: FontWeight.w700,
                                fontFamily: 'JetBrainsMono',
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text('│', style: TextStyle(color: tc.fgDimmer, fontSize: 10)),
                            const SizedBox(width: 4),
                            Text(
                              'NEEDS YOU',
                              style: TextStyle(
                                color: tc.red, fontSize: 10, fontWeight: FontWeight.w700,
                                letterSpacing: 0.6, fontFamily: 'JetBrainsMono',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        // "about: <task name>"
                        Text(
                          'about: ${item.taskName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: tc.fgXdim, fontSize: 10.5,
                            fontFamily: 'JetBrainsMono',
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isMulti) ...[
                    const SizedBox(width: 6),
                    // "1/N" pill: 1px coral border, no fill, coral text
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        border: Border.all(color: tc.red, width: 1),
                      ),
                      child: Text(
                        '${activeEscalationIndex + 1}/$total',
                        style: TextStyle(
                          color: tc.red, fontSize: 9.5, fontWeight: FontWeight.w700,
                          letterSpacing: 0.4, fontFamily: 'JetBrainsMono',
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              // Question text with emphasized terms
              _buildQuestionText(context, tc, item),
              const SizedBox(height: 12),
              // Quick replies — stacked vertically (sidebar is too narrow for inline)
              _buildQuickReplies(tc, item),
              const SizedBox(height: 8),
              // Bottom row: "Open #channel" ghost + "Skip →" ghost
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _GhostButton(
                    label: '💬 Open #${item.channelName}',
                    onTap: onOpenChannel,
                    tc: tc,
                  ),
                  _GhostButton(
                    key: const Key('sidebar_escalation_skip'),
                    label: 'Skip →',
                    onTap: onSkipEscalation,
                    tc: tc,
                  ),
                ],
              ),
            ],
          ),
        ),
        // Coral wash overlay
        Positioned.fill(
          child: IgnorePointer(
            child: Container(
              // rgba(247,118,142,0.06)
              color: const Color(0x0FF7768E),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildQuestionText(BuildContext context, TCTokens tc, SidebarEscalationData item) {
    if (item.emphasizedTerms.isEmpty) {
      return Text(
        item.question,
        style: TextStyle(
          color: tc.fgDim, fontSize: 12, height: 1.45,
          fontFamily: 'JetBrainsMono',
        ),
      );
    }
    final spans = <TextSpan>[];
    var remaining = item.question;
    for (final term in item.emphasizedTerms) {
      final idx = remaining.indexOf(term);
      if (idx == -1) continue;
      if (idx > 0) {
        spans.add(TextSpan(
          text: remaining.substring(0, idx),
          style: TextStyle(color: tc.fgDim, fontSize: 12, height: 1.45),
        ));
      }
      spans.add(TextSpan(
        text: term,
        style: TextStyle(
          color: tc.fg, fontSize: 12, fontWeight: FontWeight.w700, height: 1.45,
        ),
      ));
      remaining = remaining.substring(idx + term.length);
    }
    if (remaining.isNotEmpty) {
      spans.add(TextSpan(
        text: remaining,
        style: TextStyle(color: tc.fgDim, fontSize: 12, height: 1.45),
      ));
    }
    return RichText(
      text: TextSpan(
        style: TextStyle(fontFamily: 'JetBrainsMono'),
        children: spans,
      ),
    );
  }

  Widget _buildQuickReplies(TCTokens tc, SidebarEscalationData item) {
    if (item.quickReplies.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        for (int i = 0; i < item.quickReplies.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            height: 34,
            child: i == 0
                ? _PrimaryButton(
                    label: item.quickReplies[i],
                    onTap: () => onQuickReply(item.quickReplies[i]),
                    tc: tc,
                  )
                : _OutlineButton(
                    label: item.quickReplies[i],
                    onTap: () => onQuickReply(item.quickReplies[i]),
                    tc: tc,
                  ),
          ),
        ],
      ],
    );
  }
```

Also add the button and ghost helpers at the bottom of the file (after the existing `_NarratorBubbleInline` class):

```dart
class _PrimaryButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final TCTokens tc;
  const _PrimaryButton({required this.label, required this.onTap, required this.tc});

  @override
  State<_PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<_PrimaryButton> {
  bool _hov = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hov = true),
      onExit: (_) => setState(() => _hov = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          color: _hov
              ? Color.fromRGBO(
                  widget.tc.green.red,
                  widget.tc.green.green,
                  widget.tc.green.blue,
                  0.85,
                )
              : widget.tc.green,
          alignment: Alignment.center,
          child: Text(
            widget.label.toUpperCase(),
            style: TextStyle(
              color: widget.tc.bg,
              fontWeight: FontWeight.w700,
              fontSize: 11.5,
              letterSpacing: 0.8,
              fontFamily: 'JetBrainsMono',
            ),
          ),
        ),
      ),
    );
  }
}

class _OutlineButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final TCTokens tc;
  const _OutlineButton({required this.label, required this.onTap, required this.tc});

  @override
  State<_OutlineButton> createState() => _OutlineButtonState();
}

class _OutlineButtonState extends State<_OutlineButton> {
  bool _hov = false;
  @override
  Widget build(BuildContext context) {
    final tc = widget.tc;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hov = true),
      onExit: (_) => setState(() => _hov = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: _hov
                ? Color.fromRGBO(tc.fg.red, tc.fg.green, tc.fg.blue, 0.05)
                : Colors.transparent,
            border: Border.all(
              color: _hov ? tc.borderStr : tc.border,
              width: 1,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            widget.label.toUpperCase(),
            style: TextStyle(
              color: tc.fg,
              fontWeight: FontWeight.w700,
              fontSize: 11.5,
              letterSpacing: 0.8,
              fontFamily: 'JetBrainsMono',
            ),
          ),
        ),
      ),
    );
  }
}

class _GhostButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final TCTokens tc;
  const _GhostButton({super.key, required this.label, required this.onTap, required this.tc});

  @override
  State<_GhostButton> createState() => _GhostButtonState();
}

class _GhostButtonState extends State<_GhostButton> {
  bool _hov = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hov = true),
      onExit: (_) => setState(() => _hov = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            widget.label,
            style: TextStyle(
              color: _hov ? widget.tc.fg : widget.tc.fgXdim,
              fontWeight: FontWeight.w700,
              fontSize: 10,
              letterSpacing: 0.6,
              fontFamily: 'JetBrainsMono',
            ),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app
flutter test test/widgets/sidebar/sidebar_mini_dash_test.dart
```

Expected: all 11 tests pass (4 ambient + 7 escalation).

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/widgets/sidebar/sidebar_mini_dash.dart \
        tally_coding_app/test/widgets/sidebar/sidebar_mini_dash_test.dart
git commit -m "feat(sidebar): add SidebarMiniDash escalation takeover state — coral wash + stacked quick replies"
```

---

### Task 5: SidebarShell composite widget + barrel export

**Files:**
- Create: `tally_coding_app/lib/widgets/sidebar/sidebar_shell.dart`
- Create: `tally_coding_app/lib/widgets/sidebar/sidebar.dart`
- Create: `tally_coding_app/test/widgets/sidebar/sidebar_shell_test.dart`

- [ ] **Step 1: Write failing tests**

Create `tally_coding_app/test/widgets/sidebar/sidebar_shell_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/sidebar/sidebar_shell.dart';
import 'package:tally_coding_app/widgets/sidebar/workspace_row.dart';
import 'package:tally_coding_app/widgets/sidebar/sidebar_mini_dash.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/theme/theme_catalog.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: themeFromTokens(themeCatalog['tokyo-night']!),
  home: Scaffold(body: child),
);

void main() {
  group('SidebarShell', () {
    testWidgets('renders exactly 240 px wide', (tester) async {
      await tester.pumpWidget(_wrap(Row(children: [
        SidebarShell(
          workspaceName: 'pronoic',
          channels: const [],
          activeChannelName: null,
          openCount: 0,
          doneToday: 0,
          tasks: const [],
          narratorText: 'Idle.',
          narratorEmphasis: const [],
          escalations: const [],
          onWorkspaceSwitcherTap: () {},
          onSearchTap: () {},
          onChannelTap: (_) {},
          onAddChannel: () {},
          onQuickReply: (_) {},
          onSkipEscalation: () {},
          onOpenChannel: () {},
        ),
      ])));
      final shell = tester.getSize(find.byType(SidebarShell));
      expect(shell.width, 240.0);
    });

    testWidgets('WorkspaceRow appears at the top', (tester) async {
      await tester.pumpWidget(_wrap(Row(children: [
        SidebarShell(
          workspaceName: 'acme',
          channels: const [],
          activeChannelName: null,
          openCount: 0,
          doneToday: 0,
          tasks: const [],
          narratorText: 'Idle.',
          narratorEmphasis: const [],
          escalations: const [],
          onWorkspaceSwitcherTap: () {},
          onSearchTap: () {},
          onChannelTap: (_) {},
          onAddChannel: () {},
          onQuickReply: (_) {},
          onSkipEscalation: () {},
          onOpenChannel: () {},
        ),
      ])));
      expect(find.byType(WorkspaceRow), findsOneWidget);
      // WorkspaceRow must be above SidebarMiniDash in the layout
      final workspaceY = tester.getTopLeft(find.byType(WorkspaceRow)).dy;
      final miniDashY = tester.getTopLeft(find.byType(SidebarMiniDash)).dy;
      expect(workspaceY, lessThan(miniDashY));
    });

    testWidgets('SidebarMiniDash appears at the bottom (docked)', (tester) async {
      await tester.pumpWidget(_wrap(Row(children: [
        SidebarShell(
          workspaceName: 'acme',
          channels: const [],
          activeChannelName: null,
          openCount: 3,
          doneToday: 1,
          tasks: const [],
          narratorText: 'Running.',
          narratorEmphasis: const [],
          escalations: const [],
          onWorkspaceSwitcherTap: () {},
          onSearchTap: () {},
          onChannelTap: (_) {},
          onAddChannel: () {},
          onQuickReply: (_) {},
          onSkipEscalation: () {},
          onOpenChannel: () {},
        ),
      ])));
      expect(find.byType(SidebarMiniDash), findsOneWidget);
    });

    testWidgets('right border hairline is present', (tester) async {
      await tester.pumpWidget(_wrap(Row(children: [
        SidebarShell(
          workspaceName: 'acme',
          channels: const [],
          activeChannelName: null,
          openCount: 0,
          doneToday: 0,
          tasks: const [],
          narratorText: '',
          narratorEmphasis: const [],
          escalations: const [],
          onWorkspaceSwitcherTap: () {},
          onSearchTap: () {},
          onChannelTap: (_) {},
          onAddChannel: () {},
          onQuickReply: (_) {},
          onSkipEscalation: () {},
          onOpenChannel: () {},
        ),
      ])));
      expect(
        find.byWidgetPredicate((w) =>
          w is Container &&
          (w.decoration as BoxDecoration?)?.border?.right.width == 1.0),
        findsOneWidget,
      );
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app
flutter test test/widgets/sidebar/sidebar_shell_test.dart
```

Expected: compilation errors.

- [ ] **Step 3: Implement SidebarShell**

Create `tally_coding_app/lib/widgets/sidebar/sidebar_shell.dart`:

```dart
import 'package:flutter/material.dart';
import '../../theme/tc_tokens.dart';
import 'workspace_row.dart';
import 'sidebar_channels_list.dart';
import 'sidebar_mini_dash.dart';

/// The 240 px desktop sidebar that replaces ServerRail + _ChannelList.
///
/// Layout (top to bottom):
/// 1. [WorkspaceRow] — workspace badge + name + search icon
/// 2. [SidebarChannelsList] — scrollable compact channel rows (fills remaining space)
/// 3. [SidebarMiniDash] — docked footer (ambient or escalation takeover)
///
/// A 1 px hairline borders the right edge to separate from the main pane.
///
/// Example:
/// ```dart
/// SidebarShell(
///   workspaceName: 'pronoic',
///   channels: myChannels,
///   activeChannelName: 'general',
///   openCount: 6,
///   doneToday: 3,
///   tasks: runningTasks,
///   narratorText: 'Coder is patching.',
///   narratorEmphasis: ['Coder is patching'],
///   escalations: const [],
///   onWorkspaceSwitcherTap: () => _showWorkspacePicker(context),
///   onSearchTap: () => _openSearch(context),
///   onChannelTap: (name) => setState(() => _selected = name),
///   onAddChannel: () => _showNewChannelModal(context),
///   onQuickReply: (reply) => _resolveEscalation(reply),
///   onSkipEscalation: () => _skipEscalation(),
///   onOpenChannel: () => _openEscalationChannel(),
/// )
/// ```
class SidebarShell extends StatelessWidget {
  // WorkspaceRow props
  final String workspaceName;
  final VoidCallback onWorkspaceSwitcherTap;
  final VoidCallback onSearchTap;
  // SidebarChannelsList props
  final List<SidebarChannelEntry> channels;
  final String? activeChannelName;
  final void Function(String name) onChannelTap;
  final VoidCallback onAddChannel;
  // SidebarMiniDash props (ambient)
  final int openCount;
  final int doneToday;
  final List<SidebarMiniTaskData> tasks;
  final String narratorText;
  final List<String> narratorEmphasis;
  // SidebarMiniDash props (escalation)
  final List<SidebarEscalationData> escalations;
  final void Function(String reply) onQuickReply;
  final VoidCallback onSkipEscalation;
  final VoidCallback onOpenChannel;
  final int activeEscalationIndex;

  const SidebarShell({
    super.key,
    required this.workspaceName,
    required this.onWorkspaceSwitcherTap,
    required this.onSearchTap,
    required this.channels,
    required this.activeChannelName,
    required this.onChannelTap,
    required this.onAddChannel,
    required this.openCount,
    required this.doneToday,
    required this.tasks,
    required this.narratorText,
    required this.narratorEmphasis,
    required this.escalations,
    required this.onQuickReply,
    required this.onSkipEscalation,
    required this.onOpenChannel,
    this.activeEscalationIndex = 0,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: tc.bg,
        border: Border(right: BorderSide(color: tc.border, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top: workspace row
          WorkspaceRow(
            workspaceName: workspaceName,
            onSwitcherTap: onWorkspaceSwitcherTap,
            onSearchTap: onSearchTap,
          ),
          // Middle: scrollable channel list
          Expanded(
            child: SingleChildScrollView(
              child: SidebarChannelsList(
                channels: channels,
                activeChannelName: activeChannelName,
                onChannelTap: onChannelTap,
                onAddChannel: onAddChannel,
              ),
            ),
          ),
          // Bottom: docked mini dash (ambient or escalation)
          SidebarMiniDash(
            openCount: openCount,
            doneToday: doneToday,
            tasks: tasks,
            narratorText: narratorText,
            narratorEmphasis: narratorEmphasis,
            escalations: escalations,
            onQuickReply: onQuickReply,
            onSkipEscalation: onSkipEscalation,
            onOpenChannel: onOpenChannel,
            activeEscalationIndex: activeEscalationIndex,
          ),
        ],
      ),
    );
  }
}
```

Create barrel export `tally_coding_app/lib/widgets/sidebar/sidebar.dart`:

```dart
export 'workspace_row.dart';
export 'sidebar_channels_list.dart';
export 'sidebar_mini_dash.dart';
export 'sidebar_shell.dart';
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app
flutter test test/widgets/sidebar/sidebar_shell_test.dart
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/widgets/sidebar/sidebar_shell.dart \
        tally_coding_app/lib/widgets/sidebar/sidebar.dart \
        tally_coding_app/test/widgets/sidebar/sidebar_shell_test.dart
git commit -m "feat(sidebar): add SidebarShell composite + barrel export"
```

---

### Task 6: Wire SidebarShell into DiscordShellScreen._buildWide

**Files:**
- Modify: `tally_coding_app/lib/screens/discord_shell.dart`
- Create: `tally_coding_app/test/screens/discord_shell_wide_test.dart`

This task replaces `ServerRail` + `_ChannelList` + `_MembersPanel` in `_buildWide` with `SidebarShell`. The narrow layout (`_buildNarrow`) is untouched.

At this point, `SidebarMiniDash` and `SidebarShell` accept `MiniDashController` data through plain props (openCount, doneToday, tasks, narratorText, escalations). In this task we wire stub data from the existing `_tasks` list until B3's `MiniDashController` is available. B3 integration (Task 7) will replace the stubs.

- [ ] **Step 1: Write failing test**

Create `tally_coding_app/test/screens/discord_shell_wide_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/screens/discord_shell.dart';
import 'package:tally_coding_app/widgets/sidebar/sidebar_shell.dart';
import 'package:tally_coding_app/widgets/server_rail.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/theme/theme_catalog.dart';
import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/services/notifications_ws.dart';
import 'package:tally_coding_app/state/workspace_context.dart';

// Minimal stub client — returns empty lists, never throws.
class _StubClient extends TallyOrchClient {
  _StubClient() : super(baseUrl: 'http://localhost');
  @override Future<List<Task>> listTasks({int limit = 50}) async => [];
  @override Future<Map<String, dynamic>> health() async =>
    {'pool_ready': true, 'pool_target': 0, 'pool_joined': 0};
  @override Future<List<Map<String, dynamic>>> listMyWorkspaces() async =>
    [{'id': 1, 'name': 'test', 'role': 'admin'}];
  @override Future<List<Map<String, dynamic>>> listChannels(
      {required int workspaceId}) async => [];
}

class _StubWsClient extends NotificationsWsClient {
  _StubWsClient() : super(baseUrl: 'ws://localhost');
}

Widget _wideApp() {
  return ChangeNotifierProvider(
    create: (_) => WorkspaceContext()..onChange(1),
    child: MaterialApp(
      theme: themeFromTokens(themeCatalog['tokyo-night']!),
      home: MediaQuery(
        // Force wide layout: width above 1100 px breakpoint
        data: const MediaQueryData(size: Size(1440, 900)),
        child: DiscordShellScreen(
          client: _StubClient(),
          wsClient: _StubWsClient(),
        ),
      ),
    ),
  );
}

void main() {
  group('DiscordShellScreen wide layout', () {
    testWidgets('shows SidebarShell, not ServerRail', (tester) async {
      await tester.pumpWidget(_wideApp());
      await tester.pump(); // let initState complete
      expect(find.byType(SidebarShell), findsOneWidget);
      expect(find.byType(ServerRail), findsNothing);
    });

    testWidgets('shows workspace name in sidebar', (tester) async {
      await tester.pumpWidget(_wideApp());
      await tester.pump();
      expect(find.text('test'), findsOneWidget);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app
flutter test test/screens/discord_shell_wide_test.dart
```

Expected: tests fail — `SidebarShell` not found, `ServerRail` found instead.

- [ ] **Step 3: Update `_buildWide` in discord_shell.dart**

In `tally_coding_app/lib/screens/discord_shell.dart`:

1. Add import at the top (after existing imports):

```dart
import '../widgets/sidebar/sidebar.dart';
```

2. Replace the `_buildWide` method. The key changes:
   - Remove `ServerRail` widget and the `Container(width: 1, ...)` hairline after it
   - Remove `_ChannelList` widget and its hairline
   - Remove `_MembersPanel` and its hairline
   - Insert `SidebarShell` in their place
   - Feed stub ambient data from `_tasks` until B3's `MiniDashController` ships (Task 7)

```dart
Widget _buildWide(BuildContext context) {
  // Derive sidebar channel list from custom channels only (long-term channels).
  // B3 will extend this to include escalation state from MiniDashController.
  final sidebarChannels = _customChannels.map((ch) => SidebarChannelEntry(
    name: ch['name'] as String? ?? 'channel',
    needsAttention: ch['_unread_escalation'] == true,
    escalationCount: ch['_unread_escalation'] == true ? 1 : 0,
  )).toList();

  // Stub ambient data from current task list until B3's MiniDashController.
  final runningTasks = _tasks.where((t) => t.status == 'running').toList();
  final doneTodayCount = _tasks.where((t) => t.status == 'completed').length;

  return Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          if (_poolReady == false)
            _PoolWarmingBanner(
              target: _poolTarget,
              joined: _poolJoined,
              lastError: _poolLastError,
            ),
          Expanded(
            child: Row(
              children: [
                SidebarShell(
                  workspaceName: _activeWorkspaceName(),
                  onWorkspaceSwitcherTap: () => _openWorkspacePicker(context),
                  onSearchTap: () {}, // TODO: search — deferred
                  channels: sidebarChannels,
                  activeChannelName: _activeLongTermChannelName(),
                  onChannelTap: (name) {
                    final ch = _customChannels.firstWhere(
                      (c) => c['name'] == name,
                      orElse: () => <String, dynamic>{},
                    );
                    if (ch.isNotEmpty) {
                      setState(() => _selected = DirectChannelSelected(
                        ch['id'] as int,
                        name,
                      ));
                    }
                  },
                  onAddChannel: () async {
                    final newCh = await showDialog<Map<String, dynamic>>(
                      context: context,
                      builder: (_) => NewChannelModal(
                        client: widget.client,
                        workspaceId:
                            WorkspaceContext.of(context).activeWorkspaceId,
                      ),
                    );
                    if (newCh != null && mounted) await _fetchDirectChannels();
                  },
                  // Ambient mini-dash data (stub — B3 Task 7 replaces with controller)
                  openCount: runningTasks.length,
                  doneToday: doneTodayCount,
                  tasks: runningTasks.take(3).map((t) => SidebarMiniTaskData(
                    title: t.channelTitle,
                    agentRoles: _agentRolesFor(t),
                    progressPct: _progressFor(t),
                  )).toList(),
                  narratorText: 'Agents are running.',
                  narratorEmphasis: const [],
                  escalations: const [], // B3 Task 7 wires escalations
                  onQuickReply: (_) {},   // B3 Task 7
                  onSkipEscalation: () {}, // B3 Task 7
                  onOpenChannel: () {},    // B3 Task 7
                ),
                Expanded(child: _mainPane()),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// Helper: returns the display name of the active workspace.
/// Falls back to 'workspace' if not loaded yet.
String _activeWorkspaceName() {
  // WorkspaceContext only stores the id; the name comes from
  // _workspaces (loaded by ServerRail, now owned here).
  // Stub: return 'workspace' until Task 8 wires workspace list loading.
  return 'workspace';
}

/// Helper: returns the channel name for the currently selected long-term channel,
/// or null if a task channel / general is selected.
String? _activeLongTermChannelName() {
  if (_selected case DirectChannelSelected(channelName: final name)) {
    return name;
  }
  return null;
}

/// Stub: extract agent role names from a task's team_spec.
List<String> _agentRolesFor(Task t) {
  final agents = (t.teamSpec?['agents'] as List<dynamic>?) ?? const [];
  return agents
      .map((a) => (a as Map<String, dynamic>)['role'] as String? ?? 'coder')
      .toList();
}

/// Stub: estimate task progress — 50% for running, 100% for completed.
int _progressFor(Task t) =>
    t.status == 'completed' ? 100 : (t.status == 'running' ? 50 : 0);
```

3. Add `_openWorkspacePicker` method (replaces ServerRail's workspace switching):

```dart
/// Shows a simple workspace picker popover in the desktop layout.
/// Reuses the existing workspace-loading logic from ServerRail.
void _openWorkspacePicker(BuildContext context) {
  // Defer to _openSettings for now (workspace settings has the workspace list).
  // B5 can add a proper inline popover in a future iteration.
  _openSettings();
}
```

- [ ] **Step 4: Run all tests**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app
flutter test
```

Expected: all existing tests continue to pass; the 2 new wide-layout tests pass.

- [ ] **Step 5: Hot-reload check — wide layout renders correctly**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app
flutter run -d linux
```

Resize the window above 1100 px wide. Verify:
- SidebarShell visible at left (240 px), workspace name shown
- Channels list visible in sidebar middle
- SidebarMiniDash docked at sidebar bottom (stat row + narrator bubble)
- Kanban fills the right pane

Close the app.

- [ ] **Step 6: Commit**

```bash
git add tally_coding_app/lib/screens/discord_shell.dart \
        tally_coding_app/test/screens/discord_shell_wide_test.dart
git commit -m "feat(sidebar): wire SidebarShell into DiscordShellScreen wide layout — replaces ServerRail + ChannelList + MembersPanel"
```

---

### Task 7: Load workspace name into SidebarShell

**Files:**
- Modify: `tally_coding_app/lib/screens/discord_shell.dart`

`ServerRail` previously loaded the workspace list from `client.listMyWorkspaces()`. Since `ServerRail` is removed from the wide layout, `DiscordShellScreen` must own that load for the `WorkspaceRow` badge.

- [ ] **Step 1: Write failing test**

Append to `tally_coding_app/test/screens/discord_shell_wide_test.dart`:

```dart
    testWidgets('sidebar shows loaded workspace name after async load', (tester) async {
      await tester.pumpWidget(_wideApp());
      // Initial paint (before async load completes)
      await tester.pump();
      // Allow async _loadActiveWorkspaceName() to complete
      await tester.pumpAndSettle();
      expect(find.text('test'), findsOneWidget);
    });
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app
flutter test test/screens/discord_shell_wide_test.dart --name "loaded workspace name"
```

Expected: fails (shows 'workspace' stub, not 'test').

- [ ] **Step 3: Add workspace-name loading to DiscordShellScreen**

In `_DiscordShellScreenState`, add a field and a load method:

```dart
String _activeWorkspaceName = 'workspace'; // default until loaded
```

Add a `_loadActiveWorkspaceName()` async method:

```dart
Future<void> _loadActiveWorkspaceName() async {
  try {
    final wsId = WorkspaceContext.of(context).activeWorkspaceId;
    final list = await widget.client.listMyWorkspaces();
    if (!mounted) return;
    final ws = list.firstWhere(
      (w) => w['id'] == wsId,
      orElse: () => list.isNotEmpty ? list.first : <String, dynamic>{},
    );
    if (ws.isNotEmpty) {
      setState(() {
        _activeWorkspaceName = ws['name'] as String? ?? 'workspace';
      });
    }
  } catch (_) {
    // silent: badge shows 'workspace' as fallback
  }
}
```

Call it from `initState` (after `_fetch()`):

```dart
_loadActiveWorkspaceName();
```

Also call it from `didChangeDependencies` after the workspace-id check:

```dart
if (_lastFetchedDirectChannelsWorkspaceId != ctxId) {
  _lastFetchedDirectChannelsWorkspaceId = ctxId;
  _fetchDirectChannels();
  _loadActiveWorkspaceName(); // re-fetch name on workspace switch
}
```

Update `_activeWorkspaceName()` helper to read the field instead of returning a literal:

```dart
String _activeWorkspaceName() => _activeWorkspaceName; // reads the field
```

Note: the method name collides with the field name. Rename the method to `_workspaceDisplayName()`:

```dart
String _workspaceDisplayName() => _activeWorkspaceName;
```

Update the `SidebarShell` call in `_buildWide` to use `_workspaceDisplayName()`:

```dart
workspaceName: _workspaceDisplayName(),
```

- [ ] **Step 4: Run all tests**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app
flutter test
```

Expected: all tests pass including the new workspace-name test.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/screens/discord_shell.dart \
        tally_coding_app/test/screens/discord_shell_wide_test.dart
git commit -m "feat(sidebar): load active workspace name for WorkspaceRow badge"
```

---

### Task 8: Responsive layout — narrow keeps B3 bottom sheet, wide gets SidebarShell

**Files:**
- Modify: `tally_coding_app/lib/screens/discord_shell.dart`
- Create: `tally_coding_app/test/screens/discord_shell_responsive_test.dart`

The `LayoutBuilder` breakpoint at 1100 px already exists. This task adds test coverage for the breakpoint behavior and confirms `TALLY_FORCE_NARROW=true` still works.

- [ ] **Step 1: Write failing tests**

Create `tally_coding_app/test/screens/discord_shell_responsive_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/screens/discord_shell.dart';
import 'package:tally_coding_app/widgets/sidebar/sidebar_shell.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/theme/theme_catalog.dart';
import 'package:tally_coding_app/api.dart';
import 'package:tally_coding_app/services/notifications_ws.dart';
import 'package:tally_coding_app/state/workspace_context.dart';

class _StubClient extends TallyOrchClient {
  _StubClient() : super(baseUrl: 'http://localhost');
  @override Future<List<Task>> listTasks({int limit = 50}) async => [];
  @override Future<Map<String, dynamic>> health() async =>
    {'pool_ready': true, 'pool_target': 0, 'pool_joined': 0};
  @override Future<List<Map<String, dynamic>>> listMyWorkspaces() async =>
    [{'id': 1, 'name': 'test', 'role': 'admin'}];
  @override Future<List<Map<String, dynamic>>> listChannels(
      {required int workspaceId}) async => [];
}

class _StubWsClient extends NotificationsWsClient {
  _StubWsClient() : super(baseUrl: 'ws://localhost');
}

Widget _app({required double width}) {
  return ChangeNotifierProvider(
    create: (_) => WorkspaceContext()..onChange(1),
    child: MaterialApp(
      theme: themeFromTokens(themeCatalog['tokyo-night']!),
      home: MediaQuery(
        data: MediaQueryData(size: Size(width, 900)),
        child: DiscordShellScreen(
          client: _StubClient(),
          wsClient: _StubWsClient(),
        ),
      ),
    ),
  );
}

void main() {
  group('DiscordShellScreen responsive', () {
    testWidgets('wide (1440 px) shows SidebarShell', (tester) async {
      await tester.pumpWidget(_app(width: 1440));
      await tester.pump();
      expect(find.byType(SidebarShell), findsOneWidget);
    });

    testWidgets('narrow (375 px) does NOT show SidebarShell', (tester) async {
      await tester.pumpWidget(_app(width: 375));
      await tester.pump();
      expect(find.byType(SidebarShell), findsNothing);
    });

    testWidgets('at breakpoint boundary (1099 px) is narrow', (tester) async {
      await tester.pumpWidget(_app(width: 1099));
      await tester.pump();
      expect(find.byType(SidebarShell), findsNothing);
    });

    testWidgets('at breakpoint boundary (1100 px) is wide', (tester) async {
      await tester.pumpWidget(_app(width: 1100));
      await tester.pump();
      expect(find.byType(SidebarShell), findsOneWidget);
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they pass (breakpoint already exists)**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app
flutter test test/screens/discord_shell_responsive_test.dart
```

Expected: all 4 tests pass (the breakpoint logic is already in the codebase; this adds documentation-level test coverage).

If any test fails, inspect the `_buildNarrow` path and ensure it doesn't accidentally render `SidebarShell`.

- [ ] **Step 3: Commit**

```bash
git add tally_coding_app/test/screens/discord_shell_responsive_test.dart
git commit -m "test(sidebar): responsive breakpoint coverage — sidebar at ≥1100px, drawer below"
```

---

### Task 9: B3 controller integration — wire MiniDashController into SidebarShell

**Files:**
- Modify: `tally_coding_app/lib/screens/discord_shell.dart`

**Note:** This task REQUIRES B3 to have shipped `MiniDashController` at `lib/controllers/mini_dash_controller.dart` with this interface:

```dart
class MiniDashController extends ChangeNotifier {
  int get openCount;
  int get doneToday;
  List<MiniDashTaskData> get runningTasks;   // title + agentRoles + progressPct
  String get narratorText;
  List<String> get narratorEmphasis;
  List<EscalationItem> get escalations;      // channelName + taskName + question + quickReplies + emphasizedTerms
  int get activeEscalationIndex;
  void resolveEscalation(String reply);
  void skipEscalation();
}
```

If B3 has not shipped, stop here and wait.

- [ ] **Step 1: Write failing test**

Append to `tally_coding_app/test/screens/discord_shell_wide_test.dart`:

```dart
    testWidgets('SidebarShell openCount reflects MiniDashController', (tester) async {
      // This test requires a MiniDashController that reports openCount = 5.
      // Stub via ChangeNotifierProvider override.
      final controller = _StubMiniDashController(openCount: 5);
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: controller,
        child: _wideApp(),
      ));
      await tester.pump();
      expect(find.text('5'), findsOneWidget);
    });
```

Add stub at top of the test file:

```dart
class _StubMiniDashController extends ChangeNotifier
    implements MiniDashController {
  @override final int openCount;
  @override int get doneToday => 0;
  @override List<MiniDashTaskData> get runningTasks => [];
  @override String get narratorText => 'Idle.';
  @override List<String> get narratorEmphasis => [];
  @override List<EscalationItem> get escalations => [];
  @override int get activeEscalationIndex => 0;
  @override void resolveEscalation(String reply) {}
  @override void skipEscalation() {}
  _StubMiniDashController({required this.openCount});
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app
flutter test test/screens/discord_shell_wide_test.dart --name "openCount reflects"
```

Expected: compilation error (MiniDashController not available until B3 ships).

- [ ] **Step 3: Replace stub ambient data with MiniDashController in `_buildWide`**

In `tally_coding_app/lib/screens/discord_shell.dart`, update the `SidebarShell` call in `_buildWide` to read from `MiniDashController` (provided via `context.watch<MiniDashController>()`):

```dart
// Add at top of _buildWide:
final miniDash = context.watch<MiniDashController>();

// Replace stub fields in SidebarShell:
openCount: miniDash.openCount,
doneToday: miniDash.doneToday,
tasks: miniDash.runningTasks.map((t) => SidebarMiniTaskData(
  title: t.title,
  agentRoles: t.agentRoles,
  progressPct: t.progressPct,
)).toList(),
narratorText: miniDash.narratorText,
narratorEmphasis: miniDash.narratorEmphasis,
escalations: miniDash.escalations.map((e) => SidebarEscalationData(
  channelName: e.channelName,
  taskName: e.taskName,
  question: e.question,
  quickReplies: e.quickReplies,
  emphasizedTerms: e.emphasizedTerms,
)).toList(),
onQuickReply: miniDash.resolveEscalation,
onSkipEscalation: miniDash.skipEscalation,
onOpenChannel: () => _openEscalationChannel(miniDash),
activeEscalationIndex: miniDash.activeEscalationIndex,
```

Add `_openEscalationChannel` helper:

```dart
/// Navigate to the long-term channel that has the active escalation.
void _openEscalationChannel(MiniDashController controller) {
  if (controller.escalations.isEmpty) return;
  final item = controller.escalations[controller.activeEscalationIndex];
  final ch = _customChannels.firstWhere(
    (c) => c['name'] == item.channelName,
    orElse: () => <String, dynamic>{},
  );
  if (ch.isNotEmpty && mounted) {
    setState(() => _selected = DirectChannelSelected(
      ch['id'] as int,
      item.channelName,
    ));
  }
}
```

- [ ] **Step 4: Run all tests**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app
flutter test
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/screens/discord_shell.dart \
        tally_coding_app/test/screens/discord_shell_wide_test.dart
git commit -m "feat(sidebar): wire MiniDashController into SidebarShell — live escalation + ambient data"
```

---

### Task 10: Escalation cycle — Skip increments activeEscalationIndex

**Files:**
- Modify: `tally_coding_app/lib/widgets/sidebar/sidebar_mini_dash.dart`
- Modify: `tally_coding_app/test/widgets/sidebar/sidebar_mini_dash_test.dart`

When there are multiple escalations, tapping "Skip →" should cycle `activeEscalationIndex` forward (wraps to 0). This state is owned by `MiniDashController` in B3. However, `SidebarMiniDash` itself is stateless — it just fires `onSkipEscalation()` and the controller handles the index. Confirm the pill updates correctly when the parent rebuilds.

- [ ] **Step 1: Write test for pill update on skip**

Append to the escalation group in `tally_coding_app/test/widgets/sidebar/sidebar_mini_dash_test.dart`:

```dart
    testWidgets('skipping second escalation shows 2/2 pill', (tester) async {
      // Simulate parent rebuilding with activeEscalationIndex = 1
      final widget1 = _wrap(SidebarMiniDash(
        openCount: 0,
        doneToday: 0,
        tasks: const [],
        narratorText: '',
        narratorEmphasis: const [],
        escalations: [escalation, escalation],
        activeEscalationIndex: 0,
        onQuickReply: (_) {},
        onSkipEscalation: () {},
        onOpenChannel: () {},
      ));
      await tester.pumpWidget(widget1);
      expect(find.text('1/2'), findsOneWidget);

      final widget2 = _wrap(SidebarMiniDash(
        openCount: 0,
        doneToday: 0,
        tasks: const [],
        narratorText: '',
        narratorEmphasis: const [],
        escalations: [escalation, escalation],
        activeEscalationIndex: 1, // simulates controller advancing the index
        onQuickReply: (_) {},
        onSkipEscalation: () {},
        onOpenChannel: () {},
      ));
      await tester.pumpWidget(widget2);
      await tester.pump();
      expect(find.text('2/2'), findsOneWidget);
    });
```

- [ ] **Step 2: Run test to verify it passes**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app
flutter test test/widgets/sidebar/sidebar_mini_dash_test.dart --name "2/2 pill"
```

Expected: passes (widget is stateless; the pill is driven by `activeEscalationIndex` prop).

- [ ] **Step 3: Commit**

```bash
git add tally_coding_app/test/widgets/sidebar/sidebar_mini_dash_test.dart
git commit -m "test(sidebar): verify escalation skip-cycle updates pill via activeEscalationIndex prop"
```

---

### Task 11: Full test suite pass + flutter analyze

**Files:**
- No new files

- [ ] **Step 1: Run full test suite**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app
flutter test
```

Expected: all tests pass. Note the exact count. Fix any failures before proceeding.

- [ ] **Step 2: Run static analysis**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app
flutter analyze
```

Expected: no errors; warnings and infos are OK if pre-existing.

- [ ] **Step 3: Run on Linux desktop and verify both layouts**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app
flutter run -d linux
```

Checklist:
- [ ] Window at 1440 px wide: SidebarShell visible at left, workspace badge + name + search icon render, channels list in middle, ambient mini-dash stat row + task rows + narrator bubble docked at bottom
- [ ] Kanban fills the right pane with all 5 columns side-by-side
- [ ] Click a needs-attention channel row (if any): coral left accent + count pill + chevron visible
- [ ] Resize window below 1100 px: narrow layout takes over (drawer button in AppBar, no SidebarShell)
- [ ] Resize above 1100 px: SidebarShell returns

Close the app.

- [ ] **Step 4: Commit**

No code changes expected from this task. If analysis produced warnings that must be silenced:

```bash
git add <any fixed files>
git commit -m "fix(sidebar): address flutter analyze warnings"
```

Otherwise skip the commit.

---

### Task 12: Escalation state visual smoke test on Linux

**Files:**
- No new files — manual test only

This task verifies the Screen 7 escalation takeover visually matches the mockup before the PR is created.

- [ ] **Step 1: Open the app on Linux in wide layout**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app
flutter run -d linux
```

- [ ] **Step 2: Trigger a test escalation via hot-reload injection**

In a separate terminal, temporarily hardcode one `SidebarEscalationData` in `_buildWide`'s `SidebarShell` call (for visual verification only — revert after):

```dart
escalations: [
  const SidebarEscalationData(
    channelName: 'general',
    taskName: 'Fix daily-deals price formatting',
    question: 'Coder hit a rounding edge case. Round to 2 decimals or keep 4?',
    quickReplies: ['2 decimals', 'Keep 4'],
    emphasizedTerms: ['2 decimals', '4'],
  ),
],
```

Save and hot-reload.

- [ ] **Step 3: Verify against Screen 7.html**

Open `docs/design/claude-design/Tally Coding - Screen 7.html` in a browser. Compare with the running app:

- [ ] Coral wash overlay visible on mini-dash (subtle `rgba(247,118,142,0.06)`)
- [ ] 1 px coral top border on mini-dash footer (distinct from ambient 1 px TC.border)
- [ ] TallyAvatar (22 px) + `#general · NEEDS YOU` header
- [ ] `about: Fix daily-deals…` sub-line truncated
- [ ] Question text with "2 decimals" and "4" in TC.fg bold
- [ ] Primary button: solid TC.green + uppercase "2 DECIMALS"
- [ ] Outline button: 1 px TC.border + uppercase "KEEP 4"
- [ ] Ghost row: "💬 Open #general" + "Skip →"
- [ ] Channels list still shows "#general" with coral accent + "1" pill

- [ ] **Step 4: Revert the hardcoded escalation and hot-reload**

```bash
git diff tally_coding_app/lib/screens/discord_shell.dart
# confirm only the test escalation was added and nothing else
git checkout tally_coding_app/lib/screens/discord_shell.dart
```

- [ ] **Step 5: Commit final state**

```bash
git add tally_coding_app/lib/widgets/sidebar/ \
        tally_coding_app/test/widgets/sidebar/ \
        tally_coding_app/lib/screens/discord_shell.dart \
        tally_coding_app/test/screens/
git commit -m "feat(B5): desktop sidebar complete — SidebarShell replaces ServerRail on wide layout"
```

---

## Self-review

### Spec coverage check

| Spec requirement | Task |
|---|---|
| Desktop persistent left sidebar 240 px wide (section 5.2 Layer 2) | Task 5: SidebarShell sets `width: 240` |
| WorkspaceRow: Pronoic badge + name + chevron + search (Screen 6) | Task 1: WorkspaceRow |
| Channels list: compact 1-line rows, `#` + name + needs-attention (section 5.2 Layer 2) | Task 2: SidebarChannelsList |
| Needs-attention: 3 px coral left accent + coral tint + count pill + chevron (section 5.2 Layer 2) | Task 2: `_ChannelRow` with `needsAttention` |
| No glow shadows on needs-attention rows (section 5.2 Layer 2: "NO glow shadow") | Task 2: no `BoxShadow` anywhere |
| SidebarMiniDash docked at bottom, NO drag handle (section 5.2 Layer 3) | Task 3/4: `SidebarMiniDash` is a plain `Container`, `find.byKey('drag_handle')` asserted absent |
| Stat row: "N open │ M done today" (section 5.2 Layer 3) | Task 3: `_StatRow` |
| Per-task rows: 16 px micro-avatars + narrower progress bar (section 5.2 Layer 3) | Task 3: `_TaskRow` with `AgentAvatar(size: 16)` + 42 px progress bar |
| Tally narrator bubble: 22 px avatar + text with emphasis (section 5.2 Layer 3) | Task 3: `_NarratorBubbleInline(size: 22)` |
| Escalation takeover: coral wash + amber-glow border + stacked quick replies (section 5.2 Layer 3) | Task 4: `_buildEscalation` |
| Quick replies stacked vertically on desktop (section 5.2 Layer 3 note + Screen 7) | Task 4: `Column` of buttons |
| "1/N" pill in escalation state (section 5.2 Layer 3) | Task 4: `_buildEscalation` header row |
| "Skip →" ghost button cycles escalation (section 5.5) | Task 10: skip prop + `activeEscalationIndex` |
| Replaces server_rail on wide layout (scope brief) | Task 6: `_buildWide` |
| Mobile keeps B3 bottom sheet — sidebar only on desktop (scope brief) | Task 8: responsive tests confirm breakpoint |
| Breakpoint at 1100 px (existing codebase) | Task 8: tests at 1099 px (narrow) and 1100 px (wide) |
| Shared controller state with mobile sheet (architecture decision) | Task 9: `context.watch<MiniDashController>()` |
| Active channel highlight: `rgba(tc.fg, 0.04)` tint (architecture decision) | Task 2: `_ChannelRow` active state |

### Placeholder scan

No "TBD", "TODO", or "implement later" in any code block. One intentional `// TODO: search — deferred` comment inside `_buildWide` for the search icon handler — this is an explicit defer (spec says search is out of scope for B5), not a forgotten implementation.

### Type consistency check

All widget names used consistently:
- `WorkspaceRow` — defined Task 1, used Task 5
- `SidebarChannelsList` + `SidebarChannelEntry` — defined Task 2, used Task 5
- `SidebarMiniDash` + `SidebarMiniTaskData` + `SidebarEscalationData` — defined Tasks 3/4, used Task 5
- `SidebarShell` — defined Task 5, wired Task 6
- `MiniDashController` — referenced Task 9, awaits B3
- `activeEscalationIndex` — consistent across Tasks 4, 9, 10

Button label casing: `label.toUpperCase()` applied in both `_PrimaryButton` and `_OutlineButton` so tests check for `'2 DECIMALS'` and `'KEEP 4'` (uppercase), while `onQuickReply` receives the original-case string `'2 decimals'` / `'Keep 4'`. Tests in Task 4 reflect this correctly.

---

**Plan complete and saved to `docs/superpowers/plans/2026-05-25-sub-project-b5-desktop-sidebar.md`.**

Two execution options:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — execute tasks in this session using `executing-plans`, batch with checkpoints

Note: Tasks 1–8 can execute as soon as B3's `MiniDashController` type shapes are known (or before B3 ships, using stubs). Task 9 is the only hard B3 blocker — it wires the live controller. Tasks 10–12 follow sequentially.

Which approach?
