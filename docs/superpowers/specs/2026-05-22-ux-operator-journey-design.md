# UX-First Operator Journey Design

**Date:** 2026-05-22
**Status:** Foundation spec — implementation decomposed into three sub-project plans (A/B/C below)
**Companion wireframes:** `.superpowers/brainstorm/6494-1779727014/content/*.html` (v1–v17 iterations; v17 is the locked design)

---

## 1. Context

Tally Coding's MVP shipped through Sprint 54+ with a Discord-shaped workspace runtime: multi-channel rail, persistent agents, real-time sync, audit log, monitoring, integration_test loop. Functional but built feature-by-feature; the UX accrued without a unifying mental model.

The trigger for this redesign was a Twitter post (David Frosdick, 2026-05-22) showing a non-coder shipping AI-built Shopify changes via Hetzner VPS + Tailscale + Cloudflare Tunnel + Termius + Claude CLI — a 7-tool stack that works only because the user reverse-engineered it. Tally already wins technically (TEE attestation, multi-agent orchestration, real-time sync) but loses on UX vs "I just SSH and type."

This spec defines a single coherent Operator journey that the existing Flutter app evolves into, with three sub-projects sized for independent implementation plans.

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

## 5. Design direction (locked at v17)

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

### 5.2 Architecture (three layers)

**Layer 1 — Kanban (main work view)**

- Four columns: **To do · Running · Awaiting · Done**.
- Mobile: continuous smooth horizontal scroll (NOT column-snapped like Notion). Roughly 1 column visible at a time with peek of the next.
- Desktop: all four columns side-by-side in the main pane (sidebar at left).
- Cards = task channels. Tap a card → opens that task channel full-screen.
- Auto-archive "Done" cards after N days (configurable; default 7).
- ＋ New task as a floating FAB on mobile, header button on desktop.
- Drag-to-change-status (desktop) / long-press-to-status-menu (mobile) as manual overrides.

**Layer 2 — Channel list (long-term only)**

- Desktop: persistent sidebar at left (~200px wide).
- Mobile: peek-able bottom sheet. Collapsed = mini dash; expanded = channel list; fully off-screen when viewing a channel chat (returns only on Kanban).
- Contains: persistent channels (#general, #health, #planning, custom). No task channels.
- Sorted by recent activity.
- Channels with pending escalations: amber left-border + glowing dot + preview text describing what's pending.
- ＋ New channel at bottom.
- Account row + settings access at the very bottom.

**Layer 3 — Mini dash (collapsed bottom sheet, mobile only; equivalent surface on desktop sidebar bottom)**

Two states:

*Ambient state (no pending escalations):*
- Stat header: `[N] open · [M] done today` (+ conditional `⚠ K chats need you` amber pill).
- Per-running-task rows: task name + agent micro-avatars (with pulsing green dots) + progress bar.
- Tally chat bubble status: avatar with green online badge + soft-fill rounded bubble with plain-language status from Tally ("Diagnosed the bug. Coder is patching — PR in ~5 min."). No "Tally:" prefix; the avatar is the speaker.

*Escalation takeover (replaces ambient state entirely):*
- Amber-tinted background (`linear-gradient` + amber border).
- Header: Tally avatar + channel context (`# general · needs you` or `▤ task-name · needs you`) + "1 of N" queue badge.
- Sub-line: which task this escalation relates to.
- Question text (plain language).
- Quick-reply buttons (2-3 inline, or stacked vertically for 4-5).
- Bottom row: `💬 Open #channel` (or "Open task") + `Skip →`.
- Multi-escalation: "1 of N" + Skip cycles forward; resolving = posts reply in the long-term channel + agents resume.

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
- Tally's avatar + timestamp + `⚠ needs you` pill.
- Plain-language summary referencing the task by name + a deep-link to the task channel.
- Inline quick replies if applicable.

### 5.4 Routing config

- **Default escalation channel** = `#general`.
- **Per-project routing** (future): bugs → `#engineering`, monitoring → `#health`, etc.
- **Per-task override** (future): operator can pick where this specific task's escalations land.

### 5.5 Skip semantics

- Skip ≠ Dismiss. The escalation message stays in the long-term channel; the agent stays paused.
- Skipped escalations surface as the `⚠ K chats need you` pill in the stat row AND highlight the long-term channel in the channels list (amber left-border + dot).
- Resolving from inside the channel (answering the question) clears the highlight + decrements the pill.

### 5.6 Push notifications

- Fired when an escalation lands in a long-term channel (regardless of whether the user is on the device).
- Inline action buttons in the OS notification match the quick replies in the takeover card — Yes/No or A/B resolvable without opening the app.
- "Open" button in the notification → deep-link directly to the relevant long-term channel.

### 5.7 Tally's voice

- Conversational; not bureaucratic. "Diagnosed the daily-deals bug" not "Task #142: diagnosis complete."
- Honest when things are off: "ran into a flaky test, retrying once."
- Soft CTAs framed as questions: "Want me to start on the Klaviyo plan?"
- Update frequency: event-driven (state changes) + at least every 5 min for tasks in flight.
- 80-160 character cap for chat bubble status (longer text wraps but feels uncomfortable; nudge Tally to be brief).

## 6. Sub-project decomposition

The foundation design above is too large for a single implementation plan. Decomposed into three sub-projects with shared infrastructure but independent shippable value:

### Sub-project A — First-task flow

**Goal:** "I just signed up → I have my first task running" in under 60 seconds.

**Scope:**
- First-launch empty Kanban state with welcome / goal examples.
- Quick-add bottom sheet for entering a goal (mobile) + modal (desktop).
- Architect plan preview screen (proposed tasks + agents + trust setting).
- ＋ New task button visibility (FAB mobile + header desktop).
- New-workspace silent auto-creation on signup (no wizard).

**Touches:** `DiscordShellScreen` (first-paint), new screens for goal entry + plan preview, `WorkspaceContext` initialization on signup, the architect agent's plan-proposal output.

### Sub-project B — Ongoing-watch flow

**Goal:** "Agents are working. I'm at my phone in line at the grocery store. What's happening, and what needs me?"

**Scope:**
- Mini dash (collapsed bottom sheet) implementation: stat row + per-task progress + Tally chat bubble.
- Escalation takeover card replacing the mini dash.
- Channels list expanded sheet (peek-able mobile + sidebar desktop) — LONG-TERM channels only.
- Channel-list highlighting for channels with pending escalations.
- Push notifications with inline action buttons.
- Tally's narrator messages (LLM-driven, conversational status updates).
- Smooth horizontal scroll Kanban (replaces the current rail).
- Tap-card-to-open-task-channel transition.

**Touches:** every existing screen in `lib/screens/`, the orchestrator's escalation routing logic (new — Tally needs to decide which long-term channel to escalate to), the NotificationsWsClient for inline-action-able pushes.

### Sub-project C — Wrap-up flow

**Goal:** "The work is done. Did it ship? Is it ok? What changed?"

**Scope:**
- Done-state task card with result summary.
- "Result lands" rendering inside the task channel (PR link / deploy summary / done message).
- Rollback affordance.
- Audit log integration into the result view (Sprint 51's audit infrastructure).
- Done-column auto-archive.
- "Just finished" mini-dash state (green-tinted celebration with Review/Later CTAs).

**Touches:** Task channels' final-message rendering, archive routes, audit log surface in the UI, status persistence.

### Build order

1. **Sub-project B first.** Highest-leverage because (a) every Operator hits the ongoing-watch flow most often, (b) it requires the most architectural change (Kanban replacing rail, mini dash, escalation routing), so doing it first sets the foundation other sub-projects depend on. Sub-projects A and C live INSIDE B's new world.
2. **Sub-project A second.** Polishes the entry point. Smaller change once B's infrastructure exists.
3. **Sub-project C third.** Final-mile delivery. Today's Sprint 51 audit log already covers most of the data needs; C is mostly UI work.

Each sub-project gets its own `writing-plans` invocation and ships as a separate PR sequence.

## 7. What's NOT in scope for this spec

- **Server rail (multi-workspace switcher).** Stays largely as-is. May get rehoused under the sidebar in sub-project B's plan.
- **Settings, billing, account screens.** Polished separately; not part of the Operator journey.
- **Workflow editor (vyuh_node_flow).** Power-user feature; accessible via "Edit plan" in the plan-preview but its own screen is unchanged.
- **Templates screen, custom roles, OIDC config.** Operational tooling, not Operator-facing day-to-day.
- **Onboarding wizard.** Explicitly dropped — silent workspace creation + first-launch empty Kanban with goal examples replaces it.
- **In-app code editor / file tree (`file_tree.dart`).** Power-user feature; not load-bearing for the unified persona.
- **Productizing the AI-driven test loop** (the `integration_test/` infrastructure built earlier today). Internal-only tool for now; productize later if customers ask.

## 8. Open questions (defer to sub-project plans)

- **Routing config UX:** how does the operator set per-task / per-project escalation channels? Per-task picker in the quick-add modal? Workspace settings global default? Both? — A or B sub-project plan decides.
- **Drag-to-change-status mechanics on mobile:** long-press menu vs swipe gestures vs no manual override at all. — B sub-project plan decides.
- **Tally's status update frequency:** how often does Tally regenerate the chat bubble status? Event-driven only, periodic, or both? — B sub-project plan + orchestrator-side decision.
- **Done auto-archive default:** 7 days, 30 days, never? — C sub-project plan.
- **What "Done" actually means** for different task types: PR merged (dev) vs deploy completed (indie) vs Tally-marked-done. — C sub-project plan.

## 9. Wireframe references

All wireframes from this brainstorm session are in `.superpowers/brainstorm/6494-1779727014/content/`:

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

`.superpowers/` is gitignored — these are session artifacts. The locked design (v17) is sufficient to drive implementation; older iterations are kept for context.

## 10. Acceptance criteria for this spec

- [x] Single Operator persona defined; covers indie hacker / pro dev / team lead via spectrum.
- [x] 5-step core loop articulated as the universal Operator workflow.
- [x] Visual architecture (Kanban + sidebar + mini dash) locked to v17.
- [x] Escalation routing model (agents → Tally → long-term channel → user) specified.
- [x] Three sub-projects decomposed with shippable boundaries.
- [x] Build order justified (B first).
- [x] Out-of-scope items explicit so sub-project plans stay focused.
- [ ] User reviews + approves this spec.
- [ ] `writing-plans` skill invoked for the first sub-project (B).
