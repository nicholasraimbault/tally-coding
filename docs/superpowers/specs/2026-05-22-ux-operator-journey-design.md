# UX-First Operator Journey Design

**Date:** 2026-05-22 (initial) · updated 2026-05-25 with Claude Design iteration + Flutter 3.44 triage
**Status:** Foundation spec — iterated through Claude Design 2026-05-25; ready for writing-plans on sub-project B
**Visual reference:** `docs/design/claude-design/` (8 Claude Design mockups + tc-shared design system; source of truth for visual layer)
**Brainstorm wireframes:** `.superpowers/brainstorm/6494-1779727014/content/*.html` (v1–v17 iterations; v17 locked the architecture; gitignored session artifacts)

---

## 1. Context

Tally Coding's MVP shipped through Sprint 54+ with a Discord-shaped workspace runtime: multi-channel rail, persistent agents, real-time sync, audit log, monitoring, integration_test loop. Functional but built feature-by-feature; the UX accrued without a unifying mental model.

The trigger for this redesign was a Twitter post (David Frosdick, 2026-05-22) showing a non-coder shipping AI-built Shopify changes via Hetzner VPS + Tailscale + Cloudflare Tunnel + Termius + Claude CLI — a 7-tool stack that works only because the user reverse-engineered it. Tally already wins technically (TEE attestation, multi-agent orchestration, real-time sync) but loses on UX vs "I just SSH and type."

This spec defines a single coherent Operator journey that the existing Flutter app evolves into, with three sub-projects sized for independent implementation plans (plus one post-MVP roadmap sub-project added during iteration).

## 2. The Operator persona

We collapsed an earlier persona model (indie hacker / pro dev / team lead — three tiers) into one persona varying along a spectrum:

> **The Operator** — someone who owns work that needs doing, has agents to do it, and orchestrates rather than executes.

What varies (UI accommodates, doesn't fork):

| Spectrum | Light end | Heavy end |
|---|---|---|
| Coding skill | "Just tell me the deal is shipped" | "Show me the diff before merge" |
| Trust dial | Auto-merge, async approval later | Manual approval per step |
| Scale | 1-3 agents, 1 channel | 50+ agents, dozens of channels |
| Primary device | Phone-first (David shopping) | Desktop with phone as remote |
| Project type | Shopify section, blog post, side script | Production codebase |

The multi-agent delegation + escalation flow IS the product — not a power-user feature gated behind a tier. Every Operator uses the same shape; the UI surfaces detail proportional to the user's preferences.

## 3. The 5-step core loop

```
1. State a goal     ─▶  2. Architect plans + assembles team
                                ↓
                        3. Workers execute; escalate when stuck
                                ↓
                        4. Operator approves / iterates / vetoes
                                ↓
                        5. Result lands (PR / deploy / done)
                                ↓
                        (return to 1)
```

All UX decisions flow from making this loop fast, transparent, and mobile-capable.

## 4. User stories

**Core (every Operator):**
- Type or voice a goal in natural language; no DSL.
- See the architect's proposed plan before agents execute (or skip preview at high trust).
- Edit / approve / veto the proposed team before dispatch.
- See real-time progress for work in flight.
- Get pushed when something truly needs me; not flooded with low-stakes questions.
- Resolve common escalations in one tap (mobile).
- Clear "this is done, here's what changed" decision point.
- Hash-chained audit of what happened.

**Spectrum (some Operators):**
- Schedule recurring goals (persistent agents — Sprint 49).
- High-trust auto-dispatch for known goal patterns.
- Inspect agent reasoning + diff at any time.
- Roll back a result.
- Result lands as a GitHub PR (dev) or a deployed change (indie).
- Continue with follow-up questions in the same channel without re-stating context.
- Pick a terminal theme (Settings → Appearance → Theme).

## 5. Design direction (locked at v17 + Claude Design 2026-05-25 iteration)

### 5.1 The "what changed from the current app" summary

| Concept | Today | After |
|---|---|---|
| Primary navigation | Discord-style channel rail | Single unified Kanban (smooth horizontal scroll mobile; side-by-side desktop) |
| Channel list location | Center column with everything mixed in | Sidebar (desktop) / peek-able bottom sheet (mobile) — LONG-TERM channels only |
| Task channels | Visible in rail alongside everything | Hidden from channel list; accessible only via Kanban card tap |
| Tally DM | Dedicated channel | Ambient in every channel; no separate DM |
| Mini dashboard | None | Bottom sheet collapsed state shows two ambient metrics + per-task progress + Tally chat bubble status |
| Escalations | Implicit (Sprint 47 task channels) | Explicit takeover card replacing the mini dash; routes through a long-term channel |
| Status reporting | None | Tally posts plain-language status updates as chat bubble in mini dash |
| New-task entry | n/a | Inline `+ New task` ghost row at the bottom of each Kanban column (Notion mobile pattern) — no FAB anywhere |
| Visual identity | Indigo/purple gradients, rounded corners, Material defaults | Brutal Terminal: mono everywhere, square corners, 1px hairlines, no gradients, no shadows; Tokyo Night default theme; in-app theme picker (28 curated themes) |

### 5.2 Architecture (three layers)

**Layer 1 — Kanban (main work view)**

- Five columns: **To do · Planning · Running · Awaiting · Done**.
  - `Planning` is where the architect agent is breaking down the task before dispatching to workers; the column was added during Claude Design iteration after the original 4-column draft.
- Mobile: continuous smooth horizontal scroll (NOT column-snapped like Notion). Roughly 1.5 columns visible at a time with peek of the next.
- Desktop: all five columns side-by-side in the main pane (sidebar at left). At 1440-width, columns are ~220px wide with 14px gaps, fitting all five visibly.
- Cards = task channels. Tap a card → opens that task channel full-screen.
- Auto-archive "Done" cards after N days (configurable; default 7).
- Inline `+ New task` ghost row at the bottom of each column (Notion mobile pattern). No FAB on mobile or desktop. The inline row is transparent until hover/tap; centered `+` glyph + label, both at ~50-55% white.
- Drag-to-change-status (desktop) / long-press-to-status-menu (mobile) as manual overrides.

**Layer 2 — Channel list (long-term only)**

- Desktop: persistent sidebar at left (240px wide).
- Mobile: peek-able bottom sheet. Collapsed = mini dash; expanded = channel list; fully off-screen when viewing a channel chat (returns only on Kanban).
- Contains: persistent channels (`#general`, `#health`, `#planning`, custom). No task channels.
- Sorted by recent activity.
- Channels with pending escalations: 3px coral left-edge accent + coral row tint + "1 escalation" coral pill + amber chevron. NO glow shadow (per Brutal Terminal — flat hairlines only).
- Mobile expanded sheet shows richer rows (channel name + topic + last-message snippet with author avatar + relative time + "Today · N messages · K needs you" activity strip at top).
- Desktop sidebar shows compact 1-line rows (`#` + name only, hover lifts to TC.fg).
- `+` icon-only adder in the sidebar section header.
- Account row + settings access at the bottom of sidebar / footer of expanded mobile sheet.

**Layer 3 — Mini dash (collapsed bottom sheet, mobile only; equivalent surface on desktop sidebar bottom)**

Two states:

*Ambient state (no pending escalations):*
- Stat header: `[N] open │ [M] done today` (vertical bar separator, not dot). Numerics tabular 700; labels uppercase tracking-wide.
- Per-running-task rows: task name + agent micro-avatars (with terminal cursor blink on active state) + solid green progress bar on TC.border track (no gradient, no glow).
- Tally chat bubble status: square green block avatar + "T" monogram + terminal cursor blink badge + 1px-border square box with plain-language status from Tally ("Diagnosed the bug. Coder is patching — PR in ~5 min."). No "Tally:" prefix; the avatar is the speaker. Emphasis ("Coder is patching") in TC.fg + 700.

*Escalation takeover (replaces ambient state entirely):*
- Coral wash overlay `rgba(247, 118, 142, 0.06)` + 1px coral top border + 60px coral fade gradient from top edge (the sole gradient allowed inside Brutal Terminal, used as ambient lighting not as fill).
- Header: Tally avatar + channel context (`# general · needs you` with "needs you" in coral) + sub-line `about: <task name>` truncated.
- Right corner: "1 of N" coral pill — 1px coral border, transparent bg, coral text, square corners.
- Question text (plain language); emphasized key options ("2 decimals" / "4") in TC.fg + 700.
- Quick-reply buttons (2-3 inline on mobile sheet; stacked vertically in the narrower desktop sidebar variant). Primary = solid TC.green block with TC.bg text, uppercase mono bold. Outline = transparent + 1px TC.border + TC.fg text.
- Bottom row: `💬 Open #channel` (or "Open task") + `Skip →` ghost buttons, uppercase tracked.
- Multi-escalation: "1 of N" + Skip cycles forward; resolving = posts reply in the long-term channel + agents resume.
- **Kanban card backreference:** the corresponding Running card in the kanban behind the sheet flips to a paused/needs-you state (coral border + coral "Paused · needs you" footer + agent cursor blink stops) — visually couples the takeover to the card it's about.

### 5.3 Escalation routing

> Escalations from agents always reach the user THROUGH a long-term channel. Task channels never page the user directly.

The chain:

```
Worker agent stuck in task channel
        ↓ asks @tally
Tally tries to resolve in task channel
        ↓ can't decide
Tally posts a message in a long-term channel  → USER SEES IT
(defaults to #general; configurable per task)
        ↓ user answers there
Tally relays the answer back to task channel
        ↓
Agents resume
```

The user-visible escalation message inside the long-term channel:
- Tally's standard left-gutter avatar + name + timestamp.
- Below name row: a featured **escalation card** (NOT a normal speech bubble) — 1px coral border + coral wash background + square corners. Distinguishes "Tally needs you" from regular Tally narration.
- Card header: Tally small avatar + "Tally needs you" coral semibold + task-icon ▤ + task name in TC.fg_dim italic.
- Question + bold-emphasized options.
- Inline quick replies (same primary/outline pattern as the mini-dash takeover).
- "💬 Open task channel" ghost link at the bottom.

This card pattern is the **inline complement** to the mini-dash takeover sheet — same escalation, two surfaces, depending on whether the user has the app open and is in the channel (inline card) or on the kanban view (sheet takeover).

### 5.4 Routing config

- **Default escalation channel** = `#general`.
- **Per-project routing** (future): bugs → `#engineering`, monitoring → `#health`, etc.
- **Per-task override** (future): operator can pick where this specific task's escalations land.

### 5.5 Skip semantics

- Skip ≠ Dismiss. The escalation message stays in the long-term channel; the agent stays paused.
- Skipped escalations surface as the `⚠ K chats need you` pill in the stat row AND highlight the long-term channel in the channels list (coral left-border + coral row tint).
- Resolving from inside the channel (answering the question via either the inline escalation card or a free-text reply) clears the highlight + decrements the pill.

### 5.6 Push notifications

- Fired when an escalation lands in a long-term channel (regardless of whether the user is on the device).
- Inline action buttons in the OS notification match the quick replies in the takeover card — Yes/No or A/B resolvable without opening the app.
- "Open" button in the notification → deep-link directly to the relevant long-term channel.
- iOS notification chrome is **exempt** from Brutal Terminal rules (system UI; uses iOS-native glassmorphic card with rounded corners + SF font). Only the Tally app icon (solid green block + "T") and the action button accent (TC.green) follow our system.

### 5.7 Tally's voice

- Conversational; not bureaucratic. "Diagnosed the daily-deals bug" not "Task #142: diagnosis complete."
- Honest when things are off: "ran into a flaky test, retrying once."
- Soft CTAs framed as questions: "Want me to start on the Klaviyo plan?"
- Update frequency: event-driven (state changes) + at least every 5 min for tasks in flight.
- 80-160 character cap for chat bubble status (longer text wraps but feels uncomfortable; nudge Tally to be brief).
- Tally never codes directly. High-level reasoning, communication, and strategy only. Code execution = worker agents.

## 6. Visual identity — Brutal Terminal + Tokyo Night

### 6.1 Structural rules

The visual layer is fully custom (no Material or Cupertino defaults). Hard constraints applied to every surface:

- **Font:** JetBrains Mono only. No sans-serif anywhere. Title weight 700; body weight 400-500; labels uppercase 700 with `letterSpacing 0.6-1.0`; numerics 700 with `font-variant-numeric: tabular-nums`.
- **Geometry:** `border-radius: 0` everywhere. Three exceptions:
  1. Bottom sheet drag handle pill (`borderRadius: 999`) — sliver of affordance softness, required so users recognize "swipe target."
  2. iOS lock-screen notification card (`borderRadius: 18`) — system chrome, not ours.
  3. iOS app icon (`borderRadius: 9`) — iOS app-icon convention.
- **Borders:** 1px hairlines only. No box-shadows except for the iOS notification's system-native shadow.
- **Gradients:** none. The sole exception is the 60px coral fade gradient from the top of escalation takeover sheets — used as ambient lighting, not as fill.
- **Shadows:** none anywhere except iOS system chrome.
- **Backdrop filters / glassmorphism:** none except iOS notification card.

### 6.2 Token system

Default theme = Tokyo Night. Token names use semantic roles (not color names) so themes can swap freely:

```dart
TC = {
  bg:        #1a1b26,   // primary surface
  elev:      #24283b,   // elevated surface
  sheet:     #1f2030,   // bottom sheet
  border:    #2f3349,   // hairline border
  borderStr: #3b3f5c,   // stronger hairline (hover)

  fg:        #c0caf5,   // primary text
  fg_dim:    #a9b1d6,   // secondary text
  fg_xdim:   #7a82af,   // tertiary text
  fg_dimmer: #565f89,   // disabled / decorative

  // ANSI-semantic signal colors
  green:     #9ece6a,   // Tally identity · healthy · success · primary CTA
  red:       #f7768e,   // escalation · alert · attention (replaces amber)
  cyan:      #7dcfff,   // Coder agent
  magenta:   #bb9af7,   // Architect agent
  yellow:    #e0af68,   // Reader agent
  orange:    #ff9e64,   // Tester agent
}
```

### 6.3 Iconography and motion

- **Custom SVG icons**, 1px stroke (no fill), `strokeWidth 1.5-1.8`. No gradient strokes. Tinted from token system (TC.fg_dim default, TC.green / TC.red for state).
- **Agent identity:** square colored blocks with monogram letters (A, C, R, T) — never emoji. Architect=magenta, Coder=cyan, Reader=yellow, Tester=orange.
- **Tally identity:** solid green block + "T" monogram + terminal cursor blink badge (sharp on/off at 1.2s cycle, no easing, no glow). Pulsing-with-glow animations from the prior design are replaced by this terminal cursor blink across all "active" indicators.
- **Active-agent indicator on agent avatars:** a single pixel-square green cursor in the bottom-right corner of the avatar block, same blink timing as Tally badge.

### 6.4 What's exempt from Brutal Terminal rules

- iOS lock-screen notification card (Screen 8) — system chrome.
- iOS app icon — iOS convention.
- Bottom sheet drag handle pill — affordance recognition.
- The 60px coral fade gradient at the top of escalation takeover sheets — ambient lighting.

Everything else: no exceptions.

## 7. In-app theme picker

### 7.1 The catalog

28 curated themes ship at launch, sourced from iTerm2-Color-Schemes / standard ANSI palette repos. Organized into four groups:

- **Modern Favorites:** Tokyo Night (default), Tokyo Night Storm, Catppuccin Mocha/Macchiato/Frappé, Rosé Pine, Rosé Pine Moon, Kanagawa Wave, Everforest Dark
- **Classics:** One Dark, Dracula, Monokai Classic, Monokai Pro, Nord, Gruvbox Dark, Gruvbox Material, Solarized Dark, Ayu Dark, Ayu Mirage, Night Owl
- **Statement:** Synthwave '84, Phosphor Green, Phosphor Amber, Paper White
- **Light:** Solarized Light, Catppuccin Latte, Rosé Pine Dawn, Gruvbox Light

Each theme defines the full TC token set (bg, fg, fg_dim, fg_xdim, fg_dimmer, border, borderStr, green, red, cyan, magenta, yellow, orange). Stored as a Dart const map (or shipped JSON manifest) keyed by theme slug.

**Reference picker:** the interactive theme picker built during design exploration is at `/tmp/tally-vid-exploration/index.html` (transient — to be reproduced inside the Flutter app). The HTML version doubles as the visual spec for the in-app picker.

### 7.2 The picker UX

- Lives under `Settings → Appearance → Theme`.
- Sidebar list of themes (4 swatches per row: bg / fg / green / red) + filter input.
- Preview pane showing live components in the selected theme (kanban card, Tally bubble, channel needs-attention row, escalation card — same components used in the design exploration picker).
- URL hash / deep-link by theme slug for sharing recommendations.
- Keyboard navigation (↑↓ to step through themes).

### 7.3 Persistence

- User's chosen theme persists to local storage (per-device).
- Default theme on fresh install = Tokyo Night.
- Theme is a global UI state, not per-workspace (devs have one terminal config; the app should match).
- Future (post-MVP): "import from iTerm/Ghostty/Alacritty config" — read user's terminal color scheme and apply as a custom theme.

## 8. Sub-project decomposition

The foundation design above is too large for a single implementation plan. Decomposed into three core sub-projects with shared infrastructure but independent shippable value, plus one post-MVP roadmap sub-project added during iteration.

### 8.1 Sub-project A — First-task flow

**Goal:** "I just signed up → I have my first task running" in under 60 seconds.

**Scope:**
- First-launch empty Kanban state with welcome / goal examples.
- Quick-add bottom sheet for entering a goal (mobile) + modal (desktop).
- Architect plan preview screen (proposed tasks + agents + trust setting).
- Inline `+ New task` ghost rows wired up in each column.
- New-workspace silent auto-creation on signup (no wizard).

**Touches:** `DiscordShellScreen` (first-paint), new screens for goal entry + plan preview, `WorkspaceContext` initialization on signup, the architect agent's plan-proposal output.

### 8.2 Sub-project B — Ongoing-watch flow

**Goal:** "Agents are working. I'm at my phone in line at the grocery store. What's happening, and what needs me?"

**Scope:**
- Mini dash (collapsed bottom sheet) implementation: stat row + per-task progress + Tally chat bubble.
- Escalation takeover card replacing the mini dash.
- Channels list expanded sheet (peek-able mobile + sidebar desktop) — LONG-TERM channels only.
- Channel-list highlighting for channels with pending escalations.
- Push notifications with inline action buttons.
- Tally's narrator messages (LLM-driven, conversational status updates).
- Smooth horizontal scroll Kanban with 5 columns (replaces the current rail).
- Tap-card-to-open-task-channel transition.
- **Brutal Terminal design system** translated to Flutter widgets + ThemeData (the tc-shared.jsx components map 1:1).
- **In-app theme picker** under `Settings → Appearance → Theme` with the 28-theme catalog.
- **Long-term-channel inline escalation card** (Screen 5 pattern) for resolving escalations from within the channel.
- **Desktop sidebar variant** of mini-dash + escalation takeover (Screens 6 + 7).

**Touches:** every existing screen in `lib/screens/`, the orchestrator's escalation routing logic (new — Tally needs to decide which long-term channel to escalate to), the NotificationsWsClient for inline-action-able pushes, the entire `lib/theme/` (or equivalent) for the design system + theme picker.

### 8.3 Sub-project C — Wrap-up flow

**Goal:** "The work is done. Did it ship? Is it ok? What changed?"

**Scope:**
- Done-state task card with result summary.
- "Result lands" rendering inside the task channel (PR link / deploy summary / done message).
- Rollback affordance.
- Audit log integration into the result view (Sprint 51's audit infrastructure).
- Done-column auto-archive.
- "Just finished" mini-dash state (green-tinted celebration with Review/Later CTAs).

**Touches:** Task channels' final-message rendering, archive routes, audit log surface in the UI, status persistence.

### 8.4 Sub-project D — Gen-UI catalog (post-MVP, roadmap)

**Goal:** "Tally doesn't just send text. Tally composes the right interface for each decision."

Added to the roadmap during 2026-05-25 iteration after Google IO Flutter 3.44 keynote highlighted C2UI protocol + Flutter Gen-UI SDK.

**Scope:**
- Define a Tally widget catalog (mini diff viewer, schema comparison table, checkbox file tree, multi-select region map, decision tree, code-block + line-comment, etc.) on top of the Brutal Terminal component system.
- Wire Tally's escalation generation to compose UIs from the catalog dynamically using C2UI protocol (open standard from Google) instead of just text + 2-button quick replies.
- Implement the AI-critic loop pattern (per Google DeepMind visual layout learnings): render → critic reviews → fix violations → present to user.
- Position: Tally's escalations become composable, rich, interactive — not chat-bubble text.

**Touches:** orchestrator's escalation generation pipeline, new `lib/widgets/gen_ui/` catalog, integration of `c2ui_dart` package, Tally's prompt templates.

**Depends on:** Sub-project B (Brutal Terminal design system + escalation pattern) shipping first.

### 8.5 Build order

1. **Sub-project B first.** Highest-leverage because (a) every Operator hits the ongoing-watch flow most often, (b) it requires the most architectural change (Kanban replacing rail, mini dash, escalation routing, design system + theme picker), so doing it first sets the foundation other sub-projects depend on. Sub-projects A, C, D all live INSIDE B's new world.
2. **Sub-project A second.** Polishes the entry point. Smaller change once B's infrastructure exists.
3. **Sub-project C third.** Final-mile delivery. Today's Sprint 51 audit log already covers most of the data needs; C is mostly UI work.
4. **Sub-project D fourth (post-MVP).** Differentiator feature. Requires B's component system + escalation pattern to exist first.

Each sub-project gets its own `writing-plans` invocation and ships as a separate PR sequence.

## 9. Flutter 3.44 + Dart 3.12 implementation decisions

Triaged at the Google IO 2026 keynote (2026-05-25) for relevance to Tally Coding. Numbered for traceability.

### 9.1 Material + Cupertino decoupling — bake in

Flutter 3.44 moves Material and Cupertino out of the core framework into standalone packages (`material_ui` / `cupertino_ui`). The core framework gets a library of unopinionated widget primitives refactored out of these design libraries.

**Action:** Pin tally_coding_app to the new packages. Build the Brutal Terminal design system on the unopinionated primitives where possible (avoid Material defaults entirely). Means we never get forced into Material 3 Expressive when it lands.

### 9.2 Widget previews with Inspector support — bake in

Flutter 3.44 adds widget previews with Flutter Inspector integration — sandbox testing widgets against a matrix of screen sizes, themes, and text scales.

**Action:** Use widget previews as the theme-validation harness for the 28-theme picker. Every Brutal Terminal component should render correctly across all 28 themes; widget previews give us the matrix. Add to sub-project B's deliverables.

### 9.3 Dart/Flutter MCP + agent skills + hot reload via agent — install now

Flutter 3.44 ships:
- Dart/Flutter MCP server (gives agents access to Dart project info + tools)
- Hot reload that automatically works with every coding agent
- Dart and Flutter agent skills (progressive-disclosure best-practice guides)
- Firebase agent skills for Flutter (we skip — no Firebase)

**Action:** For *our* development workflow building tally_coding_app — install the Dart/Flutter MCP server (`.mcp.json` in tally_coding_app dir) and the agent skills. Claude Code iterating on Flutter UI now gets automatic hot reload + grounding in framework best practices.

### 9.4 Gen-UI / C2UI protocol + Flutter Gen-UI SDK — roadmap

C2UI is an open standard from Google for agent↔client UI composition. Flutter Gen-UI SDK builds on it (+500% downloads YTD). Lee Chang's Google DeepMind visual layout experiment validated the approach (opinionated framework + AI-critic loop + templates over primitives).

**Action:** Roadmap as **sub-project D** (see 8.4). Sub-project B's Brutal Terminal component system should be designed Gen-UI-compatible from day one: named widgets, type-safe props, no hard-coded message-to-widget bindings. This lets D wire in C2UI later without refactoring.

### 9.5 Genkit Dart (preview) — Tier-2 spike

Open source framework for full-stack AI/agentic Dart apps. Model-agnostic API (Google/Anthropic/OpenAI/etc.). Type-safe structured output, tool calling, multi-turn conversations, built-in observability.

**Action:** One-day spike when sub-project B reaches the orchestrator/agent interface layer. Genkit could wrap our Red Pill calls and give us structured output + tool calling + observability for free. Risk: preview status. Reward: free dev velocity on every LLM call. Make explicit go/no-go decision before continuing past the spike.

### 9.6 Canonical leading Flutter desktop — passive

Canonical (Ubuntu publisher) is now lead maintainer + strategic steward for Flutter desktop (Linux/macOS/Windows embedders). Better Linux support over time, more reliable Wayland fix-ups, less risk of regression.

**Action:** No code change. Note that our primary developer environment + many target users run Linux, so this is good news passively. Mention in CHANGELOG when the next Flutter upgrade picks up canonical-driven improvements.

### 9.7 iOS share extension (Flutter views in app extensions) — post-MVP roadmap

Flutter 3.44 enables embedding Flutter views inside iOS app extensions like the share extension.

**Action:** "Send to Tally" iOS share extension — share a URL, code snippet, screenshot, error message from any iOS app → spawns a task in Tally Coding. Real mobile-native wedge for the dev audience. Add to post-MVP roadmap; not part of sub-project A/B/C/D scope.

### 9.8 Deferred — multi-window APIs + on-device LLMs

- **Desktop windowing APIs (experimental):** multi-window apps. Could pop chat channels into separate native windows for power-user multi-monitor setups. Defer to post-MVP polish; not load-bearing.
- **Gemma 3 + LiteRT-LM on-device:** Tally Coding's privacy story is TEE-based remote orchestration via Phala CVM + Red Pill, not on-device. An optional "local Tally" mode (narration + simple decisions stay on-device, only heavy reasoning goes to TEE) could be a privacy upsell. Defer until a paying customer asks.

### 9.9 Skip — Firebase ecosystem

Firebase AI Logic with server prompt templates, Firebase agent skills for Flutter, Dart Cloud Functions for Firebase — all skipped. We use Phala CVM + custom orchestrator, not Firebase. No Firebase dependency added.

## 10. What's NOT in scope for this spec

- **Server rail (multi-workspace switcher).** Stays largely as-is. May get rehoused under the sidebar in sub-project B's plan.
- **Settings / billing / account screens beyond `Settings → Appearance`.** Polished separately; not part of the Operator journey. The theme picker is the only Settings surface this spec touches.
- **Workflow editor (`vyuh_node_flow`).** Power-user feature; accessible via "Edit plan" in the plan-preview but its own screen is unchanged.
- **Templates screen, custom roles, OIDC config.** Operational tooling, not Operator-facing day-to-day.
- **Onboarding wizard.** Explicitly dropped — silent workspace creation + first-launch empty Kanban with goal examples replaces it.
- **In-app code editor / file tree (`file_tree.dart`).** Power-user feature; not load-bearing for the unified persona.
- **Productizing the AI-driven test loop** (the `integration_test/` infrastructure built earlier today). Internal-only tool for now; productize later if customers ask.
- **iOS share extension (#9.7), desktop multi-window APIs (#9.8), on-device LLM mode (#9.8).** Roadmap items, not MVP.

## 11. Open questions (defer to sub-project plans)

- **Routing config UX:** how does the operator set per-task / per-project escalation channels? Per-task picker in the quick-add modal? Workspace settings global default? Both? — A or B sub-project plan decides.
- **Drag-to-change-status mechanics on mobile:** long-press menu vs swipe gestures vs no manual override at all. — B sub-project plan decides.
- **Tally's status update frequency:** how often does Tally regenerate the chat bubble status? Event-driven only, periodic, or both? — B sub-project plan + orchestrator-side decision.
- **Done auto-archive default:** 7 days, 30 days, never? — C sub-project plan.
- **What "Done" actually means** for different task types: PR merged (dev) vs deploy completed (indie) vs Tally-marked-done. — C sub-project plan.
- **Theme picker scope at launch:** ship all 28 themes? Tighter curated 8-10? — B sub-project plan; default is "all 28" but easy to trim.
- **Genkit Dart spike outcome:** keep direct Red Pill calls vs adopt Genkit wrapper. — B sub-project plan, spike milestone.
- **Gen-UI catalog widget set:** which specific widgets ship in v1 of sub-project D? — D sub-project plan when scheduled.

## 12. References

### 12.1 Claude Design mockups (source of truth for visual design)

8 reference mockups + design system, committed at `docs/design/claude-design/`:

| File | Surface |
|---|---|
| `tc-shared.jsx` | Design system: TC tokens + primitive components (avatars, cards, progress bars, headers, sheets, escalation chrome) |
| `screen1.jsx` + `Tally Coding - Screen 1.html` | Mobile · 5-col kanban + ambient mini dash |
| `screen2.jsx` + `... Screen 2.html` | Mobile · escalation takeover (bottom sheet) |
| `screen3.jsx` + `... Screen 3.html` | Mobile · channels sheet expanded (rich variant) |
| `screen4.jsx` + `... Screen 4.html` | Mobile · task channel chat |
| `screen5.jsx` + `... Screen 5.html` | Mobile · long-term channel chat with inline escalation card |
| `screen6.jsx` + `... Screen 6.html` | Desktop · ambient (1440×900, sidebar + kanban) |
| `screen7.jsx` + `... Screen 7.html` | Desktop · escalation takeover (sidebar mini-dash flipped) |
| `screen8.jsx` + `... Screen 8.html` | iOS · lock-screen push notification (system chrome exception) |

See `docs/design/claude-design/README.md` for viewing instructions.

### 12.2 Brainstorm wireframes (architectural lock)

All wireframes from the brainstorm session are in `.superpowers/brainstorm/6494-1779727014/content/` (gitignored — session artifacts; v17 locked the architecture):

| File | Sub-system |
|---|---|
| `welcome.html`, `design-directions.html` | Direction selection (locked B + Kanban) |
| `nav-architecture.html`, `dual-entry.html` | Navigation model + dual entry points |
| `unified-model-v2.html`, `unified-kanban-v3.html`, `unified-kanban-v4.html` | Iterations on the unified Kanban model |
| `sidebar-v5.html`, `v6-ambient-tally.html` | Sidebar/bottom-sheet + Tally ambient |
| `v7-mini-dash.html`, `v8-tally-narrator.html` | Mini dash + Tally narrator voice |
| `v9-mini-dash-look.html`, `v10-mini-dash-b-fixed.html`, `v11-tally-bubble.html`, `v12-cleaner-stats.html` | Mini dash visual polish iterations |
| `v13-escalation-takeover.html`, `v14-skip-and-needs-you.html` | Escalation takeover + Skip + chats-need-you |
| `v15-inline-attention.html`, `v16-channel-escalations.html`, `v17-clean-separation.html` | Channel highlighting + final clean separation (locked design) |

The locked design (v17) drove the Claude Design iteration. Claude Design mockups (12.1) supersede these for visual implementation; brainstorm wireframes remain authoritative for architectural decisions.

## 13. Acceptance criteria for this spec

- [x] Single Operator persona defined; covers indie hacker / pro dev / team lead via spectrum.
- [x] 5-step core loop articulated as the universal Operator workflow.
- [x] Visual architecture (Kanban + sidebar + mini dash) locked to v17 brainstorm.
- [x] Visual identity locked to Brutal Terminal + Tokyo Night via Claude Design iteration (2026-05-25).
- [x] In-app theme picker spec'd (28-theme catalog, Settings → Appearance → Theme).
- [x] Escalation routing model (agents → Tally → long-term channel → user) specified with both sheet + inline-card surfaces.
- [x] Four sub-projects decomposed with shippable boundaries (A, B, C core; D post-MVP).
- [x] Build order justified (B first, then A, C, D).
- [x] Flutter 3.44 / Dart 3.12 implementation decisions triaged.
- [x] Out-of-scope items explicit so sub-project plans stay focused.
- [x] User reviewed + approved Brutal Terminal + Tokyo Night identity (2026-05-25).
- [x] Claude Design mockups committed to `docs/design/claude-design/` (2026-05-25).
- [ ] `writing-plans` skill invoked for the first sub-project (B).
