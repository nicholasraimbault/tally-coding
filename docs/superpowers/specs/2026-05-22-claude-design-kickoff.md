# Claude Design — kickoff prompt

**Purpose:** all-in-one prompt for first-time use with Claude Design (claude.ai/design).
Pairs with the design spec at `docs/superpowers/specs/2026-05-22-ux-operator-journey-design.md`.

## Steps

1. **Open the canonical wireframe** in a browser:
   `.superpowers/brainstorm/6494-1779727014/content/v17-clean-separation.html`
2. **Take a screenshot** of that page (full-page, scroll-capture if available).
3. **Open Claude Design** at https://claude.ai/design (requires paid plan).
4. **Upload the screenshot** alongside the prompt below.
5. **Paste the prompt** (everything between the START and END markers).
6. **Iterate on Screen 1** until it's right. Don't ask Claude Design to render screens 2-8 until Screen 1 is approved — locking the design system first prevents drift.
7. **After Screen 1 is approved**, prompt for Screen 2 (Mini dash escalation takeover), then 3 (Channels sheet expanded), etc. — see the deliverables list inside the prompt.
8. **When all 8 screens are done**, click **Export → Handoff to Claude Code**. That bundle becomes input to the `writing-plans` step for sub-project B implementation.

## Iteration tips

- **Structural change** → use chat ("rearrange into two columns", "drop the search field").
- **Precise pixel tweak** → use inline comments on the canvas element.
- **Spacing/color polish** → use the adjustment knob sliders.
- **Apply across all screens** → say "apply this across the design" so the design system updates everywhere.
- **Lost an inline comment** → paste it into chat as a fallback (Claude Design occasionally drops them).

---

## The prompt — copy everything between `=== START ===` and `=== END ===`

=== START ===

<context>
PROJECT: Tally Coding — a Flutter app for orchestrating AI coding agents.
The user is "the Operator" — they own work, agents do it, they
orchestrate. Agents run in TEE-attested CVMs (privacy-first). The
app syncs real-time across phone + laptop.

The Flutter codebase exists. This redesign rebuilds the UI around a
unified Operator journey instead of a feature-by-feature accretion.
Architecture decisions are LOCKED — your job is the visual polish +
the design system, not redesigning behavior.

The attached screenshot is the canonical locked wireframe (v17 from
our brainstorm). It's ugly HTML, but the layout, status states,
component placement, and content hierarchy are what we want.
</context>

<audience>
Two ends of one spectrum, same UX:
  • Non-coder running a Shopify side-business — wants to type a goal
    and watch tasks get shipped from their phone.
  • Pro developer using Tally as a force multiplier — wants real PRs
    and full transparency into agent work.

Both Operators use the EXACT same UI. The UI accommodates trust
level via per-task settings, not via mode toggles or persona forks.
</audience>

<design_system>
Dark theme by default. Match modern dev-tool aesthetic (Linear,
Vercel, Discord dark mode — not Material default).

Colors:
  Background main:    #1a1d23
  Background elev:    #23272f
  Background sheet:   #23272f (with 14×14×14×0 px border-radius)
  Primary blue:       #6366f1   (Running state · CTAs · selected)
  Tally gradient:     #6366f1 → #a855f7   (Tally identity only)
  Success green:      #10b981   (Done · online indicators · agent pulse)
  Warning amber:      #f59e0b   (Needs-you · escalations)
  Border:             rgba(255,255,255,0.06–0.12)
  Text high:          #ffffff
  Text mid:           rgba(255,255,255,0.85)
  Text dim:           rgba(255,255,255,0.6)
  Card fill:          rgba(255,255,255,0.04–0.10)

Typography: tight modern sans (Inter / Geist / Söhne).
  Numeric stats: 18–22px bold
  Headers: 14–18px semibold
  Body: 12–14px regular
  Captions/labels: 10–11px uppercase tracking-wide

Iconography: minimal, line-style. Channel uses ＃. Task uses ▤.
Reserved emoji: 🧠 architect, ⌨ coder, 📖 reader, 🧪 tester.

Tally identity:
  • Avatar is always the gradient T circle (#6366f1 → #a855f7)
  • Has a green online badge (bottom-right of avatar, 30% size,
    cuts into avatar with 2px surface-matched border)
  • Speaks via "chat bubble" — soft fill rgba(255,255,255,0.06),
    14/14/14/3px border-radius (tail-pointer at bottom-left toward
    the avatar). No background-clickable affordance — the bubble
    is content, not an action.
</design_system>

<architecture>
LOCKED — do not redesign. Reference the attached v17 screenshot.

1. Single Kanban view is home.
   4 columns: To do · Running · Awaiting · Done.
   Mobile: smooth horizontal scroll (NOT column-snapped Notion-style).
   Desktop: 4 columns side-by-side in main pane.
   Cards = task channels. Tap card → opens task channel.
   ＋ New task FAB on mobile / header button on desktop.

2. Channel list = LONG-TERM channels only (#general, #health,
   #planning, user custom). Task channels NEVER appear here.
   Desktop: persistent left sidebar (~200px wide).
   Mobile: peek-able bottom sheet — 3 states:
     a. Mini dash (collapsed, default home)
     b. Channel list (expanded, swiped up)
     c. Off-screen (hidden while in a channel chat)

3. Mini dash (collapsed bottom sheet, mobile / sidebar bottom, desktop).
   AMBIENT STATE:
     • Stat row: "N open · M done today" + CONDITIONAL amber pill
       "⚠ K chats need you" (only renders when K>0)
     • Per-task rows: task name + agent micro-avatars (with pulsing
       green dots) + progress bar
     • Tally chat bubble at bottom: avatar w/ green badge + plain
       narrator status, NO "Tally:" prefix
   ESCALATION TAKEOVER STATE (replaces ambient entirely):
     • Amber-tinted background, amber border
     • Header: Tally avatar + channel context
       (e.g. "＃ general · needs you" + sub-line "about: Fix daily-deals")
     • "1 of N" queue badge
     • Question text (plain language)
     • Quick-reply buttons (inline 2-3, stacked 4-5)
     • Bottom row: "💬 Open #channel" + "Skip →"

4. Escalation routing:
   Agents post in task channels (agent space).
   Tally tries to resolve in task channel.
   If Tally can't decide, Tally posts a message in a LONG-TERM
   channel (default #general; configurable). User sees the
   escalation there with inline quick replies + jump-to-task link.
   User answers in the long-term channel.
   Tally relays answer back to task channel.
   Agents resume.

5. Push notifications fire on escalation. Inline action buttons in
   the OS notif match the takeover's quick replies — Yes/No or A/B
   resolvable WITHOUT opening the app. "Open" button deep-links to
   the relevant long-term channel.
</architecture>

<deliverables_overall>
Eight screens total. Generate them ONE AT A TIME — don't try to
ship all eight at once. After each, I'll review and iterate before
asking for the next.

A. Mobile screens (390 × 844, iPhone-class):
  1. Kanban view with ambient mini dash (default home)        ← FIRST
  2. Mini dash in escalation takeover state
  3. Channels sheet expanded (with one channel amber-highlighted)
  4. Task channel chat view (tapped a Kanban card)
  5. Long-term channel chat view (#general) showing Tally's
     escalation message with inline quick replies

B. Desktop screens (1440 × 900):
  6. Same as #1 but desktop layout (sidebar + main Kanban)
  7. Same as #2 but desktop layout

C. OS push notification:
  8. iOS lock-screen + banner with inline action buttons
</deliverables_overall>

<task>
Generate SCREEN 1 now. Don't generate any other screens yet.

SCREEN 1: Mobile Kanban view with ambient mini dash.
Dimensions: 390 × 844 (iPhone-class frame, with subtle device chrome).

Content to render:
  • Top header: workspace name "Pronoic ▾" + search icon + settings (gear)
  • Main: Kanban — currently-visible column is "⚡ Running · 2"
    - Card 1: title "Fix daily-deals price formatting" — 2 agents
      shown as 🧠 + ⌨ small avatars (with pulsing green online dots) —
      60% progress bar gradient blue→purple
    - Card 2: title "Build email digest worker" — 1 agent ⌨ pulsing —
      30% progress bar
  • Peek of next column on right edge (Awaiting · 1) — just enough
    visible to signal "swipe to see more" — NOT paginated/snapped
  • Floating + FAB bottom-right (primary blue #6366f1, subtle shadow)
  • Bottom sheet (collapsed mini dash) docked at bottom of viewport:
    - Drag handle pill at top
    - Stat row: "3 open · 3 done today"
      (no amber pill — healthy state, no escalations)
    - Two task progress rows with agent micro-avatars and progress
      bars (same data as the Kanban cards)
    - Tally chat bubble at bottom (purple-gradient avatar + green
      online dot + soft-filled bubble): "Diagnosed the daily-deals
      bug. Coder is patching — PR in ~5 min."

Goal: this is the default home state. Calm, informative, glanceable.
Show me what you'd ship to production.

DO NOT design other screens yet.
DO NOT change the architecture.
DO NOT add a Tally DM channel (Tally is ambient in every channel).
DO NOT show task channels in the channel list (they don't belong there).
DO NOT column-snap the Kanban scroll.
DO NOT add an onboarding wizard, FTUX overlay, or welcome modal —
this is the default empty state for a returning user.
</task>

<format>
Output as a single mobile-frame mockup on the canvas. Build the
design system on this first generation so subsequent screens inherit
the same colors, typography, spacing, and component styles. Subtle
gradients on the Tally bubble + primary CTAs are welcome — nothing
flashy or skeuomorphic.

If something is unclear, ASK in chat before generating instead of
guessing.
</format>

=== END ===
