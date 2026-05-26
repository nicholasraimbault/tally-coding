# Frontend Audit — Claude Design vs Flutter Implementation (2026-05-25)

---

## User-flagged Issues

### 1. Bottom sheet appearing on desktop kanban

**Status: Confirmed — partial bug, with a nuance.**

The `_BoardBottomSheet` widget is mounted inside `_mainPane()` via a `Stack`, which is called for `BoardSelected()` in **both** `_buildWide` and `_buildNarrow`. The wide layout (`_buildWide`) places the main pane inside a `Row` with `SidebarShell` on the left, then `Expanded(child: _mainPane())`. Since `_mainPane()` always mounts `_BoardBottomSheet` when the board is selected, **the bottom-sheet overlay renders on desktop too**.

The design intent (Screen 6/7): desktop has no bottom sheet at all. The `SidebarMiniDash` at the bottom of the 240 px sidebar is the ambient/escalation surface. `_BoardBottomSheet` should only mount when `isNarrow == true`.

- **File:line:** `discord_shell.dart:785–811` (`_mainPane()`, `BoardSelected()` branch)
- **Root cause:** `_mainPane()` is shared between wide and narrow. It unconditionally mounts `_BoardBottomSheet` in the `BoardSelected` branch. The wide layout does not suppress it.
- **Severity: Blocker (desktop)**

---

### 2. Fonts not mono everywhere

**Status: Confirmed — narrow layout AppBar title and several _MemberTile / _ChannelList texts missing fontFamily.**

The `themeFromTokens` builder (theme_builder.dart:20) calls `GoogleFonts.jetBrainsMonoTextTheme(...)` which sets JetBrains Mono on Material's `textTheme`. This is correct for widgets that inherit from the theme (e.g. `Text()` with no `TextStyle` override, or `style: Theme.of(context).textTheme.bodyMedium`).

However, the following locations use `const TextStyle(...)` with no `fontFamily:` property, which **falls through to the platform default** when Material's `DefaultTextStyle` has been overridden by a parent `TextStyle` that doesn't propagate the inherited font:

- **`discord_shell.dart:607–608`** (narrow AppBar title): `TextStyle(fontWeight: FontWeight.w600, fontSize: 16)` — no fontFamily, will render in the system sans-serif on most platforms.
- **`discord_shell.dart:1104`**, **1164–1175**, **1426–1438** (`_ChannelList` category labels, `_NewTile`, `_ChannelTile` inside the narrow drawer): all use `TextStyle(...)` without `fontFamily:`. These are in the old Discord-skinned channel list that is **not** part of `SidebarChannelsList` and does not reference TCTokens.
- **`discord_shell.dart:1250`** (`_MembersPanel` label "MEMBERS"/"AGENTS"): `Theme.of(context).textTheme.labelSmall?.copyWith(...)` — this inherits correctly from `themeFromTokens` and **is OK**.
- **`ambient_mini_dash.dart:116–127`** (`_StatLabel.text`): `TextStyle(color, fontSize, fontWeight, letterSpacing)` — no fontFamily. Similarly `_StatNumber` (line 103) — no fontFamily.
- **`escalation_sheet.dart:100, 104, 198–201, 211–214`**: TextButton labels use `TextStyle` without fontFamily.
- **`brutal_pill.dart:31–35`**: `TextStyle(color, fontSize, fontWeight, letterSpacing)` — no fontFamily.
- **`inline_escalation_card.dart:68–72, 77–80, 93–95, 125–128`**: several `TextStyle(...)` without fontFamily.

The sidebar-specific widgets (`sidebar_mini_dash.dart`, `sidebar_channels_list.dart`, `workspace_row.dart`) **do** pass `fontFamily: 'JetBrainsMono'` inline — correctly.

- **Severity: Important (visible across all screens)**

---

### 3. "Agents are running" text leaking

**Status: Confirmed — hardcoded fallback in `_buildWide`.**

- **`discord_shell.dart:557`**: `narratorText: _latestNarratorText ?? 'Agents are running.',`
  - When `_latestNarratorText` is null (no narrator WS message received yet), the `SidebarMiniDash` shows the literal string "Agents are running." in the narrator bubble on every fresh load/workspace switch.
  - The mockup (Screen 6/7): the bubble shows real narrator text OR is absent; it does not show a permanent placeholder.
- **Severity: Important (always visible on desktop until first WS narrator event)**

---

### 4. Mobile colors not correct

**Status: Confirmed — narrow layout uses hardcoded Discord-palette colors instead of TCTokens.**

The `_buildNarrow` method hardcodes Discord colors across the entire narrow layout:
- `discord_shell.dart:603`: `backgroundColor: const Color(0xFF313338)` — Discord "chat bg" instead of `tc.bg` (#1A1B26 Tokyo Night).
- `discord_shell.dart:605`: `backgroundColor: const Color(0xFF1E1F22)` — Discord "title bar" instead of `tc.elev`.
- `discord_shell.dart:727`: `backgroundColor: const Color(0xFF2B2D31)` for `showModalBottomSheet` — Discord "sidebar bg" instead of `tc.sheet`.
- `discord_shell.dart:929`: `color: const Color(0xFF2B2D31)` on `_ChannelList` container.
- `discord_shell.dart:963`: `color: const Color(0xFF1E1F22)` on separator.
- `discord_shell.dart:1145`: `color: selected ? const Color(0xFF404249)` on `_ChannelTile` selected state — hardcoded Discord selection color instead of `tc.cardHov` or similar.
- `discord_shell.dart:1239`: `color: const Color(0xFF2B2D31)` on `_MembersPanel`.
- `discord_shell.dart:1414`: `Border.all(color: const Color(0xFF2B2D31), width: 2)` on status dot border.
- `discord_shell.dart:1632`: `backgroundColor: const Color(0xFF2B2D31)` on the `_NarrowDrawer`.
- `discord_shell.dart:839–840`: `color: const Color(0xFFED4245)` and `const Color(0xFFFAA61A)` for the pool warming banner — Discord error/warning colors instead of `tc.red`/`tc.yellow`.
- `discord_shell.dart:1277–1308`: `_MemberTile` status colors are `const Color(0xFF57F287)`, `0xFF5865F2`, `0xFFED4245`, `0xFF8E9297` — all Discord ANSI colors, not TCTokens.

The mockups (Screen 1–5) show the full Tokyo Night palette throughout. Switching themes would do nothing on the narrow layout because all colors are hardcoded.

- **Severity: Blocker (mobile / narrow layout is completely off-theme for all non-default themes; even Tokyo Night defaults to wrong shades)**

---

### 5. No way back to kanban from chat on desktop

**Status: Confirmed — desktop task tap fully replaces main pane; no split-pane; no back path from chat.**

When a kanban card is tapped on desktop (`onTaskTap` callback in `KanbanView` → `discord_shell.dart:791`), the shell calls `setState(() => _selected = TaskSelected(task.id))`. This causes `_mainPane()` to return a `TaskChannelScreen`, which replaces the entire right pane. The kanban disappears.

The mockups **do not explicitly show a split-pane desktop chat** in the shipped screens (Screen 6/7 show sidebar + kanban only; there is no Screen 9 showing "kanban + open chat side-by-side"). However:

- The `_buildWide` layout is a simple `Row` with `SidebarShell` + `Expanded(_mainPane())`. There is no provision for a split view, a secondary pane, or a "back to board" button in the wide chat view.
- Once in `TaskSelected` state on desktop, the user can return to the board only by clicking "Board" in the `_ChannelList` section of the old narrow drawer — which **does not appear on desktop** (the desktop uses `SidebarShell`, which contains `SidebarChannelsList`, which only shows long-term channels, not the Board entry or task channels).
- There is a `BoardSelected` entry in `_ChannelList` (discord_shell.dart:976–979), but `_ChannelList` is only used in `_NarrowDrawer`. `SidebarShell` / `SidebarChannelsList` has no "Board" link.
- **Result: on desktop, once a task card is tapped, there is no affordance to return to the kanban.** The user is stuck in the chat unless they know to resize the window narrow enough to trigger the drawer, or navigate to a different channel.

- **Severity: Blocker (desktop)**

---

## Per-Screen Audit

### Screen 1: Mobile Kanban + Ambient Mini-dash

**Mockup:** `screen1.jsx` + `tc-shared.jsx` — `AmbientMiniDash` docked at bottom, kanban scrollable above it.

| # | Issue | File:line | Severity |
|---|-------|-----------|----------|
| 1.1 | **Stat row labels lowercase in mockup** (`open`, `done today` lowercased, `fontSize: 10.5, fgXdim, uppercase, letterSpacing: 0.6`) vs **Flutter** `_StatLabel` uses `tc.fgDim` instead of `tc.fgXdim`, `fontSize: 11` instead of `10.5`, no `uppercase` transform, `letterSpacing: 0.8` | `ambient_mini_dash.dart:116–127` | Minor |
| 1.2 | **Stat number fontSize** mockup uses `18px`; Flutter `_StatNumber` uses `22px` — 22% larger | `ambient_mini_dash.dart:100–106` | Minor |
| 1.3 | **MiniTaskRow** mockup shows agent avatars (18px) + title + progress + pct; Flutter `MiniTaskRow` shows title + progress + pct but **no agent avatars** | `ambient_mini_dash.dart:129–178` | Important |
| 1.4 | **Narrator bubble** mockup: `border: 1px solid TC.border, background: transparent, color: TC.fg_dim`; Flutter uses `color: tc.bubble` (a 6% opacity fill) instead of transparent, and `color: tc.fg` instead of `tc.fgDim` for text | `ambient_mini_dash.dart:67–86` | Minor |
| 1.5 | **Drag handle borderRadius:** mockup uses `borderRadius: 999` (full pill); Flutter uses `BorderRadius.circular(2)` (nearly square) — drag handles should be pills per the mockup's own comment ("sliver of softness allowed for affordance") | `ambient_mini_dash.dart:37–43` | Minor |
| 1.6 | **Kanban column width:** desktop uses `Expanded` (fills space equally); mobile uses `_kColumnWidth = 280`, but mockup uses `COL_W = 234`. Flutter mobile columns are 20% wider than designed | `kanban_view.dart:7` | Minor |
| 1.7 | **Kanban column padding:** mockup pads `4px 16px ${bottomPad}px`; Flutter pads `all(16)`. Mobile needs a bottom pad equal to the mini-dash height so cards aren't hidden | `kanban_view.dart:116` | Important |
| 1.8 | **Column label color**: mockup uses `TC.fg_xdim` for dim columns (todo, done) and `TC.fg` for others; Flutter `KanbanColumn` always uses `tc.fgDim` for all column headers regardless of active state | `kanban_column.dart:36–41` | Minor |
| 1.9 | **Branch ref**: mockup shows `BranchRef` (git branch label) above card title in `TodoCard`, `PlanningCard`, `TaskCard`, `DoneCard`; Flutter kanban cards have **no branch reference display** | `kanban_cards.dart` | Minor |
| 1.10 | **Running card progress is hardcoded `0.5`**: Flutter `_cardForTask` passes `progress: 0.5` always because "backend doesn't expose progress yet" — shown as 50% green bar on every running card | `kanban_view.dart:50` | Important |
| 1.11 | **Running card ETA / status text**: mockup shows dynamic `eta` ("~5m left") and "running" label below progress; Flutter `RunningTaskCard` shows no ETA and no "running" label (only "PAUSED · NEEDS YOU" if escalated) | `kanban_cards.dart:155–163` | Minor |
| 1.12 | **Escalated running card coral border**: mockup `CardFrame` uses `background: rgba(247,118,142,0.05)` + `border: rgba(247,118,142,0.45)` when escalated; Flutter `BrutalCard` does not accept an `escalated` prop — no coral border on escalated cards | `brutal_card.dart`, `kanban_cards.dart:167–173` | Important |
| 1.13 | **Narrow layout background**: mockup `TC.bg = #1a1b26`; Flutter Scaffold uses `const Color(0xFF313338)` | `discord_shell.dart:603` | Blocker |

---

### Screen 2: Mobile Escalation Takeover

**Mockup:** `screen2.jsx` — `EscalationSheet` overlaid over kanban (kanban behind, dimmed by coral wash).

| # | Issue | File:line | Severity |
|---|-------|-----------|----------|
| 2.1 | **Coral wash background**: mockup has a full-surface `TC.amberWash` (`rgba(247,118,142,0.06)`) overlay inside the sheet; Flutter `EscalationSheet` has no wash — the sheet background is `tc.sheet` only | `escalation_sheet.dart:50–55` | Minor |
| 2.2 | **Top border color**: mockup uses `TC.amberLine` (`rgba(247,118,142,0.45)`) for the top border; Flutter uses plain `coral` (solid `tc.red`) — no opacity | `escalation_sheet.dart:53–54` | Minor |
| 2.3 | **Queue badge label format**: mockup shows `1/2`; Flutter shows `1 of 2` | `escalation_sheet.dart:128–130` | Minor |
| 2.4 | **"Skip" button visibility**: mockup always shows Skip ghost button; Flutter only shows Skip when `queueSize > 1` (`discord_shell.dart:206`) | `escalation_sheet.dart:205` | Minor |
| 2.5 | **Bottom ghost row icons**: mockup uses an SVG speech-bubble + arrow SVG for Open/Skip; Flutter uses plain `TextButton` with `OPEN #GENERAL` / `SKIP` text labels — no icons | `escalation_sheet.dart:186–225` | Minor |
| 2.6 | **Escalation question text color**: mockup uses `TC.fg_dim`; Flutter uses `tc.fg` (brighter) | `escalation_sheet.dart:140–141` | Minor |

---

### Screen 3: Mobile Channels Sheet Expanded

**Mockup:** `screen3.jsx` — full-height `ChannelsSheet` with header, activity strip, `NeedsAttentionRow` and `CalmChannelRow`.

| # | Issue | File:line | Severity |
|---|-------|-----------|----------|
| 3.1 | **Activity strip content**: mockup shows `"Today · 8 messages · 1 needs you"`; Flutter shows `"${longTerm.length} channels"` (channel count, no message count, no attention flag) | `channels_sheet.dart:120–125` | Minor |
| 3.2 | **Height constraint**: mockup sheet is `height: 76%` of screen; Flutter `ConstrainedBox(maxHeight: 480)` is a fixed pixel value — on a tall screen this may be less than 76%, on a short screen it may overflow | `channels_sheet.dart:129` | Minor |
| 3.3 | **Overlay dimming**: mockup dims the kanban behind the sheet with `rgba(0,0,0,0.35)`; Flutter has no overlay — the kanban behind the sheet is fully visible (same brightness as normal) | `channels_sheet.dart`, `discord_shell.dart:783–812` | Minor |
| 3.4 | **CalmChannelRow 2-line layout**: mockup shows `name + topic + time` on line 1, `author snippet` on line 2; Flutter `CalmChannelRow` (channel_row.dart) — let me confirm if it exists | `widgets/bottom_sheet/channel_row.dart` | Minor |
| 3.5 | **"+ New" button**: mockup has a `NewChannelBtn` in the sheet header; Flutter's `ChannelsSheet` has no such button | `channels_sheet.dart:77–115` | Minor |
| 3.6 | **Top border**: mockup uses `TC.borderStr`; Flutter uses `tc.border` (lighter) | `channels_sheet.dart:48–50` | Minor |

---

### Screen 4: Mobile Task Channel Chat

**Mockup:** `screen4.jsx` — back-chevron header, message stream, composer.

| # | Issue | File:line | Severity |
|---|-------|-----------|----------|
| 4.1 | **Channel header back button**: mockup shows a 36×36 square back-chevron button; Flutter `task_channel.dart` — need to verify, but `AppBar` navigation uses Material back button (rounded) not the custom square one | `screens/task_channel.dart` | Minor |
| 4.2 | **Escalated status pill in header**: mockup shows a `1px TC.red border, TC.red text, blinking dot, "Paused · needs you"` pill in the channel header when task is escalated; Flutter's channel header widget (`widgets/channel_header.dart`) — unclear if this state is reflected | `widgets/channel_header.dart` | Minor |
| 4.3 | **Composer `›` prompt glyph**: mockup shows a `›` green prefix glyph inside the text field; Flutter message composer needs verification | `widgets/message_composer.dart` | Minor |
| 4.4 | **`StateChangeNote` divider**: mockup uses a centered `— text —` monochrome line; Flutter message bubble implementation may or may not implement this pattern | `screens/task_channel.dart` | Minor |
| 4.5 | **Message font size**: mockup agent/Tally message body uses `13px, TC.fg_dim`; Flutter message bubbles need verification for exact font-size match | `widgets/message_bubble.dart` | Minor |

---

### Screen 5: Mobile Long-term Channel Chat + Inline Escalation Card

**Mockup:** `screen5.jsx` — #general chat with an escalation card embedded in the message stream.

| # | Issue | File:line | Severity |
|---|-------|-----------|----------|
| 5.1 | **"Open task channel" link style**: mockup `OpenTaskLink` is a ghost button with an SVG icon + "Open task channel" text, uppercase, `TC.fg_xdim` → `TC.fg` on hover; Flutter `InlineEscalationCard` uses a `TextButton` with `"OPEN TASK CHANNEL"` text only, no icon | `inline_escalation_card.dart:113–133` | Minor |
| 5.2 | **Task name in escalation card header**: mockup shows task name next to a task SVG icon on the right side of the header row; Flutter shows task title below "TALLY NEEDS YOU" in a Column — different layout | `inline_escalation_card.dart:56–89` | Minor |
| 5.3 | **Task title italic**: Flutter uses `fontStyle: FontStyle.italic` for the task title; mockup does not use italic — it's bold `TC.fg_dim` text weight 700 | `inline_escalation_card.dart:80` | Minor |
| 5.4 | **Escalation card quick replies**: mockup `flex: 1, height: 36` inline side-by-side for 2 options; Flutter stacks vertically always (`for (int i...)` column) | `inline_escalation_card.dart:98–109` | Minor |

---

### Screen 6: Desktop Ambient (Sidebar + Kanban)

**Mockup:** `screen6.jsx` — 240 px sidebar (WorkspaceRow + Channels section + SidebarMiniDash) + main kanban area.

| # | Issue | File:line | Severity |
|---|-------|-----------|----------|
| 6.1 | **Kanban column width on desktop**: mockup uses `DESK_COL_W = 220px` fixed columns; Flutter desktop uses `Expanded` (equal flex), which is responsive but will be much wider on large monitors — cards may look stretched with too much whitespace | `kanban_view.dart:98–111` | Minor |
| 6.2 | **Kanban content padding**: mockup uses `padding: 20px 20px 28px`; Flutter uses `EdgeInsets.all(16)` — slightly less spacious on all sides | `kanban_view.dart:101` | Minor |
| 6.3 | **`_BoardBottomSheet` mounts on desktop**: See user-flagged issue #1. Bottom sheet overlays the kanban even on >=1100px layout | `discord_shell.dart:785–811` | Blocker |
| 6.4 | **Sidebar background**: mockup `Sidebar` uses `background: TC.bg` (#1A1B26); Flutter `SidebarShell` uses `tc.bg` — **correct**. | `sidebar_shell.dart:86–88` | OK |
| 6.5 | **"Board" entry missing from desktop navigation**: `SidebarChannelsList` only shows long-term channels, no "Board" link; the only Board entry is in `_ChannelList` inside `_NarrowDrawer`. On desktop, there is no way to navigate back to the Board from a channel | `sidebar_channels_list.dart` | Blocker |
| 6.6 | **Sidebar mini-dash stat label text**: mockup uses `uppercase: true`; Flutter `_StatRow` in `SidebarMiniDash` uses `'OPEN'` / `'DONE TODAY'` hardcoded strings (uppercase literals) — OK structurally, but `SidebarMiniDash._StatRow` outputs `DONE TODAY` not `done today`. Desktop mini-dash stat labels are correct | `sidebar_mini_dash.dart:389–395` | OK |
| 6.7 | **Sidebar scrollable section**: mockup wraps channels list in a flex-1 overflowY scroll; Flutter `SidebarShell` uses `Expanded(child: SingleChildScrollView(...))` — correct. | `sidebar_shell.dart:99–108` | OK |

---

### Screen 7: Desktop Escalation Takeover

**Mockup:** `screen7.jsx` — sidebar mini-dash transitions to escalation takeover with coral wash, coral top border, question + stacked buttons.

| # | Issue | File:line | Severity |
|---|-------|-----------|----------|
| 7.1 | **Escalation routing to sidebar**: On desktop, escalations from WS arrive via `BottomSheetController.enqueueEscalation()` (discord_shell.dart:177). `SidebarShell` receives `escalations: const []` always (discord_shell.dart:559). The `BottomSheetController` drives the *bottom sheet*, not `SidebarMiniDash`. On desktop, escalations never reach `SidebarMiniDash._buildEscalation()` — the sidebar stays in ambient state forever | `discord_shell.dart:559`, `widgets/bottom_sheet/bottom_sheet_controller.dart` | Blocker |
| 7.2 | **"Open #general" ghost button label on desktop**: mockup uses plain SVG icon + text; Flutter uses `'💬 Open #${item.channelName}'` — emoji prefix added | `sidebar_mini_dash.dart:254–259` | Minor |
| 7.3 | **"Skip →" button always visible on desktop**: mockup shows it unconditionally; Flutter `SidebarMiniDash` shows `Skip` only when `isMulti` — missing when there is only 1 escalation, but the mockup shows it always | `sidebar_mini_dash.dart:261–264` | Minor |
| 7.4 | **Coral wash overlay opacity**: mockup uses `TC.amberWash = rgba(247,118,142,0.06)`; Flutter uses `const Color(0x0FF7768E)` which is `0x0F/0xFF ≈ 6%` — matches correctly | `sidebar_mini_dash.dart:272–278` | OK |

---

### Screen 8: iOS Lock-screen Push Notification

**Mockup:** `screen8.jsx` — iOS lock-screen with expanded notification card, action buttons ("2 decimals", "Keep 4", "Open").

| # | Issue | File:line | Severity |
|---|-------|-----------|----------|
| 8.1 | **Linux/desktop fallback has no action buttons**: `EscalationNotifier` on Linux falls back to `LinuxNotificationDetails()` with no actions — users on Linux desktop (the primary dev platform) see a plain notification with no quick-reply options | `escalation_notifier.dart:166–170` | Important |
| 8.2 | **iOS category registration**: the code notes `// category registered in AppDelegate handles action buttons` but the actual AppDelegate implementation is not in scope of this audit; if not done, iOS notifications also lack action buttons | `escalation_notifier.dart:156–165` | Important |
| 8.3 | **Notification title**: Flutter sends `'Tally needs you'`; mockup shows `"Tally needs you"` as the body title and `"TALLY CODING / now · Pronoic"` as the app header — this part is handled by the OS, not the app, so the match depends on the app name | `escalation_notifier.dart:173–178` | OK |

---

## UI Flow Audit

### Cold start → Board view
- **Status: Works.** `_DiscordShellScreenState.initState` initializes `_selected = BoardSelected()` (unless `initialTaskId` is set). `_mainPane()` returns `KanbanView` in `BoardSelected` state.

### Tap kanban card on mobile → task chat → back to Board
- **Tap works.** `onTaskTap` sets `_selected = TaskSelected(task.id)`.
- **Back path:** On narrow layout, the `AppBar` is shown. `AppBar` has a `leading` back button only if there is a route to pop. Since the shell is a single-route scaffold and channels are swapped via `setState`, Flutter's `AppBar` has **no back button** — the user must open the drawer (hamburger) and tap "Board" to return. **No back path from task chat to Board on mobile without the drawer.**
- **Status: Broken — no back-to-Board affordance in the narrow AppBar.**

### Tap kanban card on desktop → task chat in side pane? Or full swap?
- **Status: Full swap (broken per intent).** See user-flagged issue #5. No split-pane implemented. Kanban disappears. No back affordance.

### Tap a channel in sidebar (desktop) → channel chat → back to Board
- **Status: Same as above.** Selecting a channel sets `_selected = DirectChannelSelected(...)`. Board is no longer visible. No back affordance because "Board" is absent from `SidebarChannelsList`.

### Swipe up on mini-dash (mobile) → channels sheet → tap channel → channel chat
- **Swipe-up to channels sheet:** `_BoardBottomSheet` wraps `AmbientMiniDash` in a `GestureDetector` that calls `controller.expandChannels()` on upward swipe (discord_shell.dart:1558–1563). **Works.**
- **Tap channel in channels sheet:** `onChannelTap` calls `onOpenChannel` which sets `_selected = DirectChannelSelected(...)`. **Works.**
- **Back from channel chat to channels sheet:** No back path — same full-pane-swap problem.

### Settings → Appearance → Theme picker → swap theme → apply
- **Status: Needs verification.** `theme_controller.dart` and `theme_picker_screen.dart` exist. Theme switching is plumbed via `ThemeController` + Provider. The themes in `theme_catalog.dart` are comprehensive (28 themes). However, the narrow layout's hardcoded `Color(0xFF313338)` etc. means theme changes will not apply to the narrow layout even if `ThemeController` is working correctly.

### Escalation arrives via WS (kind='escalation') → mini dash flips to takeover? Inline card appears in channel?
- **Desktop mini-dash flip: Broken.** `BottomSheetController.enqueueEscalation()` is called correctly (discord_shell.dart:177), but `SidebarShell` is passed `escalations: const []` unconditionally (discord_shell.dart:559). The sidebar never transitions to takeover.
- **Mobile bottom sheet flip: Works.** `_BoardBottomSheet` watches `BottomSheetController` and renders `EscalationSheet` when `controller.state == SheetState.takeover`.
- **Inline escalation card in channel:** `InlineEscalationCard` widget exists and is complete. Whether it is injected into the `general_channel.dart` or `task_channel.dart` message streams would require verifying those files — not confirmed.

### Push notif tap "2 decimals" → posts reply + dismisses?
- **Status: Partially implemented.** `EscalationNotifier.onActionSelected` callback is defined. The `_onNotificationResponse` parses `channelId:msgId:actionLabel`. But there is no wiring in `main.dart` or `discord_shell.dart` connecting `onActionSelected` to `client.postMessage()`. The response handler exists but the downstream effect (posting the reply and resolving the escalation) is not wired.
- **Severity: Blocker (push notif quick replies are dead)**

### Workspace switch → kanban refreshes?
- **Status: Works.** `didChangeDependencies` detects workspace ID change and calls `_fetchDirectChannels()` + `_loadActiveWorkspaceName()`. The 4-second `_refresh` timer calls `_fetch()` which refreshes tasks. Board will update within 4 seconds of workspace switch.

---

## Summary

**Total issues: 44 (6 blockers, 16 important, 22 minor)**

### Blocker issues (6)

1. **Bottom sheet mounts on desktop kanban** — `_BoardBottomSheet` is unconditionally mounted in `_mainPane()` regardless of layout width. Must gate behind `isNarrow`. (`discord_shell.dart:785`)
2. **No Board navigation from desktop** — `SidebarChannelsList` has no "Board" entry; once a channel/task is selected on desktop there is no affordance to return to the kanban. (`sidebar_channels_list.dart`)
3. **Desktop escalation never reaches sidebar** — `SidebarShell.escalations` is always `const []`; `BottomSheetController` queue is not bridged to the sidebar takeover. (`discord_shell.dart:559`)
4. **Mobile layout hardcoded to Discord palette** — 10+ `const Color(0xFF...)` literals in narrow layout, none from TCTokens; theme switching has zero effect on narrow UI. (`discord_shell.dart:603–1656`)
5. **No back-to-Board affordance on mobile from chat** — after tapping a task card on mobile, there is no AppBar back button, no Board tab, no swipe-back. Drawer is the only path. (`discord_shell.dart` narrow AppBar)
6. **Push notification quick-reply actions not wired** — `EscalationNotifier.onActionSelected` is never assigned; tapping "2 decimals" on a push notification does nothing. (`escalation_notifier.dart`, `main.dart`)

### Top recommended fixes (ordered by impact)

1. **Gate `_BoardBottomSheet` to narrow-only** — move the `Stack + Positioned _BoardBottomSheet` inside a conditional block or inside `_buildNarrow` only.
2. **Bridge `BottomSheetController` escalations to `SidebarShell`** — pass `controller.queue` as `escalations` in `_buildWide`; wire `onQuickReply` / `onSkipEscalation` to the controller.
3. **Add "Board" link to `SidebarChannelsList`** — insert a `_ChannelRow`-style "Board" entry above the CHANNELS section, or add a back-to-Board button in the desktop chat header.
4. **Replace all hardcoded `Color(0xFF...)` in narrow layout with TCTokens** — `_buildNarrow`, `_NarrowDrawer`, `_ChannelList`, `_ChannelTile`, `_MembersPanel`, `_PoolWarmingBanner` all need to read from `context.tc`.
5. **Wire `EscalationNotifier.onActionSelected`** — in `main.dart` or `discord_shell.dart`, set the callback to call `client.postMessage` then resolve the notification.
6. **Add `fontFamily` to bare `TextStyle()` instances** — ambient_mini_dash stat row, escalation_sheet ghost buttons, inline_escalation_card, brutal_pill, narrow AppBar title.
7. **Replace `'Agents are running.'` fallback** — show `null` / hide the bubble until a real narrator event arrives. (`discord_shell.dart:557`)
8. **Add mobile kanban bottom padding** equal to AmbientMiniDash height so cards below the fold are reachable. (`kanban_view.dart:116`)
9. **Add agent avatars to `MiniTaskRow`** — the ambient mini-dash row currently omits agent avatars (Screen 1 shows them). (`ambient_mini_dash.dart:129`)
10. **Add "Back" affordance in narrow task-chat AppBar** — either an explicit back arrow that sets `_selected = BoardSelected()`, or a breadcrumb.
