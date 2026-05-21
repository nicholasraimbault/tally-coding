# Sprints 47-50 — Discord-shaped workspace + chat-style task channels + scheduled agents + native workflow editor

**Status:** Design (pre-implementation, brainstorm complete)
**Date:** 2026-05-20
**Scope:** 4 sprints (47-50), ~150-200h total dev, ~6-8 weeks calendar at solo-dev pace

## Why this exists

Today's Tally Coding shell is Discord-shaped at the surface but limited
underneath: one `#general` for talking to Tally, auto-created per-task
channels that are read-only event streams, and a flat list of agents
dispatched per task. No mid-task user intervention. No long-lived
agents. No custom channels. No way to hire a human collaborator with
override-able authority. No expressive workflow editor.

The vision: keep the Discord metaphor but make it actually true —
real chat in task channels (intervene as the work happens), custom
channels with mixed agent/human members, persistent scheduled agents
with their own runtime, a node-based workflow editor that replaces
the basic team builder, and a 4-tier permission system so you can
hire a human manager who has real authority but the workspace owner
can still override.

This spec covers four sequenced sprints that ship the vision
holistically.  Each sub-project gets its own implementation plan
when its sprint starts.

## Goals

- Task channels feel like real group chat: bidirectional messaging,
  agents see user messages inline in their next LLM turn, agents can
  post interactive prompts the user can click to answer.
- Workspaces are Discord-style multi-tenant: a user account can own
  multiple AND be a member of others.
- Permission model has 4 workspace-wide roles (Owner / Admin /
  Manager / Member) + per-channel role overrides + per-agent tool
  allowlists.  The "hire a manager, override their decisions" case
  works cleanly.
- Tally is present in every channel but only generates responses when
  explicitly addressed (@mention, DM, agent escalation) or when a
  cheap should-respond classifier says she should chime in.  She
  never writes code directly — only strategy, reasoning, comms,
  delegation.
- Persistent agents run on cron + event triggers, have their own
  channel for run history, and escalate via Tally → user DM when
  stuck.
- Native node-based workflow editor replaces the current basic team
  builder.  Same editor opens in two contexts: pre-task team review
  (after Tally proposes a team) and persistent-agent creation.
- Pre-dispatch confirmation: every Tally-proposed team is shown to
  the user as a `team_proposal` message in `#general` with three
  actions: Approve / Edit in builder / Cancel.
- Custom channels: user creates with arbitrary name + member list
  (humans + agents + Tally) + per-channel role overrides.

## Non-goals (for these sprints; deferred)

- Iframe-embedded n8n or any 3rd-party workflow editor — we build a
  native node-based editor in Flutter.
- Custom (user-defined) workspace roles beyond the 4 presets —
  enterprise tier later.
- Real-time co-editing of the workflow canvas (multiple users editing
  same workflow simultaneously) — Sprint 51+.
- Cross-workspace channels (a channel shared between two workspaces)
  — never planned.
- Bot integrations (webhook-based 3rd party bots posting messages)
  — separate sprint.
- Email notifications, SMS notifications — Sprint 46 deferred items.
- Mobile push beyond the existing UnifiedPush (APNs/FCM) — pre-stable
  launch sprint.

## Decisions locked during brainstorm (2026-05-20)

1. **Mid-task user intervention**: inline in next LLM turn.  User
   messages join the agent's prompt context on its next step; agents
   that are mid-tool-call finish that call first.  No interrupt /
   pause via plain messages.  (Optional `/pause` and `/stop` slash
   commands deferred.)
2. **Long-lived agent triggers**: cron + event triggers (both).
   Each persistent agent has optional cron schedule AND optional
   event triggers (webhook, file change, message in a watched
   channel, agent-to-agent calls).
3. **Escalation chain**: Tally tries to solve first, DMs user only
   when stuck.  Agent → @tally in channel → Tally evaluates with
   channel context → attempts fix (extra tool call, retry, dispatch
   helper) → if can't, `notify_user(...)` → DM to user.
4. **Workspaces**: multi-workspace Discord style.  Each account owns
   multiple AND joins others.  Server rail switches between them.
   Billing tier applies per-workspace.
5. **Roles**: 4 workspace-wide (Owner / Admin / Manager / Member) +
   per-channel role overrides (promote Member → channel admin, demote
   anyone → channel-read-only) + per-agent tool allowlist (existing
   `agent_roles.default_tools` exposed in UI).
6. **Channel types**: `#general` (existing, workspace-wide), task
   channels (existing, auto-created per task), scheduled-agent
   channels (new), custom channels (new), DMs (new), `#backlog`
   (new — workspace task queue).
7. **Tally presence**: in every channel always; reads all context but
   only generates a response when @mention'd / DM'd / agent
   escalation / `auto_jump_in` channel flag is true (cost-controlled
   via a cheap should-respond classifier).
8. **Tally capability constraint**: Tally never writes code directly.
   Her tools = `send_message`, `dispatch_agent`, `ask_user`,
   `summarize_progress`, `read_channel_history`, `propose_team`,
   `notify_user`.  Never `bash`, `file_editor`, `terminal`.  If
   Tally needs code written, she dispatches a Coder agent and
   delegates.
9. **Workflow editor**: native node-based editor in Flutter.  Same
   editor used for pre-task team review AND persistent-agent
   creation.  Replaces existing basic `team_builder.dart`.
10. **Build sequence**: 47 chat foundation → 48 workflow editor +
    pre-dispatch confirm → 49 persistent agents + DMs → 50 custom
    channels + multi-workspace UI.

## Runtime architecture

### Workspaces

Top-level unit.  Each user account has zero-or-more owned workspaces
and zero-or-more memberships in others.  Workspace identity carries:

- `id`, `name`, `owner_user_id`, `created_at`, billing tier (which
  plan slug; today's Sprint 46 plans apply per-workspace), credit
  pool, custom branding (later).

A user's `default workspace` is auto-created on signup.  Existing
single-user-mode admin user gets one named "admin's workspace"
backfilled.  Multi-workspace UI ships in Sprint 50; the data model
supports it from Sprint 47.

### Members

A `workspace_members` row links a `user_id` to a `workspace_id` with
a `role` enum: `owner` | `admin` | `manager` | `member`.  Tally and
persistent agents are also workspace members (special `kind` field:
`human` | `tally` | `persistent_agent`).  Per-task agents are NOT
workspace members — they're task-scoped.

### Channels

Conversation unit.  Six channel types:

| Type | Auto-created? | Lifecycle | Default membership |
|---|---|---|---|
| `general` | Yes (1 per workspace) | Permanent | All workspace members |
| `backlog` | Yes (1 per workspace) | Permanent | All workspace members |
| `task` | Yes (per task) | Lives during task; archived after | Tally + dispatching user + agents on the team |
| `scheduled_agent` | Yes (per persistent agent or group) | Permanent (until agent deleted) | Tally + the agent + workspace Owner/Admins |
| `custom` | User-created | Permanent (until deleted) | User-defined member list |
| `dm` | Auto-created on first DM | Permanent | The 2 (or more) participants |

`channel_members` rows hold per-channel membership + optional role
override.  Effective permission for a write is resolved as:
`channel_member.role_override` (if set) else `workspace_member.role`.

### Messages

`messages` table columns:

- `id` (autoincrement PK)
- `channel_id` (FK to channels)
- `author_kind` (`human` | `agent` | `tally` | `system`)
- `author_id` (user_id, agent_id, or null for tally/system)
- `kind` (`text` | `tool_call` | `system_event` | `interactive_prompt` | `team_proposal` | `task_status`)
- `payload_json` (kind-specific structure)
- `created_at`, `edited_at` (nullable), `reply_to_id` (nullable FK)
- `unread_for_users_json` (array of user_ids who haven't read this
  message — denormalized for fast "unread count" UI)

WebSocket fans out new-message events to active clients in the
channel.  Old clients fetch via `GET /channels/{id}/messages?since_id=...`.

### Tally

A workspace member with `kind=tally`, role enum value `'tally'`
(distinct from the human role hierarchy of `owner | admin | manager
| member`).  One Tally per workspace (not shared across workspaces
— separate context).  In every channel.
Capabilities (her tool allowlist):

- `send_message(channel_id, text)` — post a chat message
- `dispatch_agent(team_spec, channel_id)` — create + start agents
- `ask_user(user_id, prompt, options)` — interactive prompt with
  response options (Block / Note only / etc.)
- `summarize_progress(channel_id, since)` — read recent messages,
  produce a status summary
- `read_channel_history(channel_id, limit, since)` — read past
  messages for context
- `propose_team(description)` — generate a team_spec from a task
  description (existing architect functionality, exposed as a tool)
- `notify_user(user_id, urgency, summary)` — send a DM to user with
  escalation context

**Explicitly forbidden** tools for Tally: `bash`, `file_editor`,
`terminal`, `python_repl`, anything that produces code or runs
commands.  Tally is strategy/coordination/comms only.

Tally's response policy:

1. **Always respond** when:
   - `@tally` mention in any message
   - DM channel where Tally is a participant
   - Agent calls `escalate_to_tally(message)` (a tool available to
     all persistent agents and per-task agents)
   - Channel has `tally_auto_jump_in=true` AND the cheap
     should-respond classifier says "yes" for this message
2. **Read but don't respond** otherwise.  Tally still updates her
   context (the message is in channel history for next time), but
   she doesn't generate an LLM call.

Cost-control: the should-respond classifier is a small model (e.g.
llama-3.1-8B at $0.05/M tokens) invoked on each message in channels
with `tally_auto_jump_in=true`.  Returns a probability score; if
above threshold, full Tally (kimi or llama-3.3) is invoked.  Default
`tally_auto_jump_in=false` for most channels; true only for
`#general` and DMs where she's the primary participant.

### Persistent agents

Workspace-level members.  Created via the workflow editor.  Stored
in `persistent_agents` table:

- `id`, `workspace_id`, `name` (user-chosen, e.g. "Nightly QA"),
  `role_name` (FK to `agent_roles` — the seeded palette),
  `team_spec_json` (full workflow if the agent is itself a small
  team), `tool_allowlist` (subset of role's default tools), `model`
  (which Red Pill model)
- `cron_schedule` (nullable, e.g. `0 21 * * *`)
- `event_triggers_json` (array of trigger configs, e.g.
  `[{"kind":"webhook","url":"..."}, {"kind":"channel_message","channel_id":42}]`)
- `enabled` (boolean), `last_run_at`, `next_scheduled_run_at`,
  `consecutive_failures` (int)

Orchestrator runs a scheduler loop (extending the existing Sprint 44
quota sweeper pattern) that:

1. Polls `persistent_agents WHERE enabled=1 AND next_scheduled_run_at <= now`
2. For each due agent, posts a "run starting" message to its channel
3. Invokes the agent's team_spec via the existing dispatch path
4. On completion, posts result to channel
5. On failure or escalation, mentions Tally; she resolves or DMs user

Event triggers register webhooks at `/webhooks/agents/{trigger_id}`
that fire the agent on POST.

### Workflow editor

Native Flutter canvas.  Replaces existing `team_builder.dart`.
Opened in two contexts:

1. **Pre-task team review** (Sprint 48): Tally posts a `team_proposal`
   interactive message in `#general` after architecting a team from
   the user's description.  Three actions: Approve (dispatch),
   Edit in builder (opens editor with the proposed team_spec
   pre-loaded), Cancel.  When user clicks Edit, the workflow editor
   opens; on Save, the message updates with the new team_spec and
   the user can Approve again.
2. **Persistent agent management** (Sprint 49): from a workspace
   settings page or the channel rail (+ next to "Scheduled" category),
   user creates or edits a persistent agent.  The editor opens to a
   blank canvas or the existing agent's workflow.

Canvas features:

- **Agent nodes** (drag from palette of roles) — config: name, model,
  tool allowlist, per-node spec
- **Edges** between nodes — config: trigger condition (always /
  if previous succeeded / if previous returned X)
- **Branch nodes** — split into parallel branches that all run
  concurrently
- **Loop nodes** — route back to upstream node; loop terminates on
  condition
- **Trigger nodes** (for persistent agents only) — entry point with
  cron + event trigger config
- **Output node** — terminal node that publishes results

Data: extends today's `team_spec` JSON to:

```json
{
  "nodes": [
    {"id": "n1", "kind": "trigger", "cron": "0 21 * * *"},
    {"id": "n2", "kind": "agent", "role": "Tester", "spec": "..."},
    {"id": "n3", "kind": "agent", "role": "Reviewer", "spec": "..."},
    {"id": "out", "kind": "output"}
  ],
  "edges": [
    {"from": "n1", "to": "n2"},
    {"from": "n2", "to": "n3", "condition": "if_succeeded"},
    {"from": "n2", "to": "n2", "condition": "if_failed", "max_iterations": 3}
  ]
}
```

Backward compatibility: today's flat `agents + stages + workflow`
team_spec is auto-converted to nodes+edges form by a migration helper.
Both formats accepted on POST `/tasks` for one release; flat form
deprecated in Sprint 49.

Flutter rendering: `CustomPainter`-based canvas with draggable nodes
+ Bezier-curve edges + per-node config panels.  Mature Flutter
packages exist (e.g. `flow_compose`, `flutter_node_editor`); pick
one in Sprint 48 implementation plan.

## Data model

Schema additions across sprints:

### Sprint 47

```sql
CREATE TABLE IF NOT EXISTS workspaces (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    owner_user_id TEXT NOT NULL,
    plan_slug TEXT NOT NULL DEFAULT 'free',
    stripe_customer_id TEXT,
    created_at REAL NOT NULL,
    settings_json TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS workspace_members (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    workspace_id INTEGER NOT NULL REFERENCES workspaces(id),
    member_kind TEXT NOT NULL,   -- 'human' | 'tally' | 'persistent_agent'
    user_id TEXT,                -- for kind=human; null otherwise
    persistent_agent_id INTEGER, -- for kind=persistent_agent
    role TEXT NOT NULL,          -- 'owner' | 'admin' | 'manager' | 'member' | 'tally' | 'agent'
    joined_at REAL NOT NULL,
    UNIQUE(workspace_id, user_id),
    UNIQUE(workspace_id, persistent_agent_id)
);
CREATE INDEX IF NOT EXISTS idx_workspace_members ON workspace_members(workspace_id, role);

CREATE TABLE IF NOT EXISTS channels (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    workspace_id INTEGER NOT NULL REFERENCES workspaces(id),
    kind TEXT NOT NULL,          -- 'general' | 'backlog' | 'task' | 'scheduled_agent' | 'custom' | 'dm'
    name TEXT NOT NULL,
    task_id TEXT,                -- for kind=task; FK to tasks
    persistent_agent_id INTEGER, -- for kind=scheduled_agent
    auto_jump_in_for_tally INTEGER NOT NULL DEFAULT 0,
    created_at REAL NOT NULL,
    archived_at REAL
);
CREATE INDEX IF NOT EXISTS idx_channels_ws ON channels(workspace_id, kind, archived_at);

CREATE TABLE IF NOT EXISTS channel_members (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    channel_id INTEGER NOT NULL REFERENCES channels(id),
    member_kind TEXT NOT NULL,
    user_id TEXT,
    persistent_agent_id INTEGER,
    task_agent_id INTEGER,       -- for per-task agents
    role_override TEXT,          -- nullable; overrides workspace role for this channel
    joined_at REAL NOT NULL,
    last_read_message_id INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_channel_members ON channel_members(channel_id);
CREATE INDEX IF NOT EXISTS idx_channel_members_user ON channel_members(user_id, channel_id);

CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    channel_id INTEGER NOT NULL REFERENCES channels(id),
    author_kind TEXT NOT NULL,   -- 'human' | 'agent' | 'tally' | 'system'
    author_user_id TEXT,
    author_agent_id INTEGER,
    kind TEXT NOT NULL,          -- 'text' | 'tool_call' | 'system_event' | 'interactive_prompt' | 'team_proposal' | 'task_status'
    payload_json TEXT NOT NULL,
    reply_to_id INTEGER,
    created_at REAL NOT NULL,
    edited_at REAL
);
CREATE INDEX IF NOT EXISTS idx_messages_channel ON messages(channel_id, created_at DESC);
```

Existing `quotas` table extended with `workspace_id` FK; existing
admin user's quota row backfills to its auto-created workspace.

### Sprint 48

No new tables — extends `messages.kind` enum with `team_proposal`
support.  `tasks.team_spec_json` already exists; extend its parser
to accept the new nodes+edges format alongside the flat format.

### Sprint 49

```sql
CREATE TABLE IF NOT EXISTS persistent_agents (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    workspace_id INTEGER NOT NULL REFERENCES workspaces(id),
    name TEXT NOT NULL,
    role_name TEXT NOT NULL,
    team_spec_json TEXT NOT NULL,
    tool_allowlist_json TEXT,
    model TEXT,
    cron_schedule TEXT,
    event_triggers_json TEXT NOT NULL DEFAULT '[]',
    enabled INTEGER NOT NULL DEFAULT 1,
    last_run_at REAL,
    next_scheduled_run_at REAL,
    consecutive_failures INTEGER NOT NULL DEFAULT 0,
    created_at REAL NOT NULL,
    deleted_at REAL
);
CREATE INDEX IF NOT EXISTS idx_persistent_agents ON persistent_agents(workspace_id, enabled, next_scheduled_run_at);
```

### Sprint 50

No new tables — extends `channel_members.role_override` usage (UI for
custom-channel creation).  `workspaces` table expands with branding
settings JSON.

## Permission model

Effective permission for an action is resolved as:

1. Action requires permission `P` (e.g., `dispatch_task` requires
   `manage_agents`)
2. Lookup `channel_members.role_override` for `(channel_id, user_id)` — if set, use that role
3. Otherwise, lookup `workspace_members.role` for `(workspace_id, user_id)`
4. Map role → permission set: Owner has all, Admin has all except
   transfer-ownership, Manager has all except invite/remove members
   and billing, Member has read-only-in-channels-they-belong-to +
   chat + dispatch via `#general`
5. Per-agent: each agent has `tool_allowlist` (subset of its role's
   default tools); orchestrator enforces at tool-call time

Permission table (workspace-wide actions):

| Action | Owner | Admin | Manager | Member |
|---|:-:|:-:|:-:|:-:|
| Transfer ownership | ✓ | | | |
| Invite/remove members | ✓ | ✓ | | |
| Manage billing | ✓ | ✓ | | |
| Create/delete channels | ✓ | ✓ | ✓ | |
| Manage persistent agents | ✓ | ✓ | ✓ | |
| Dispatch one-off tasks | ✓ | ✓ | ✓ | ✓ |
| Edit team in workflow builder | ✓ | ✓ | ✓ | ✓ |
| Chat in channels (where member) | ✓ | ✓ | ✓ | ✓ |
| View workspace audit log | ✓ | ✓ | ✓ | |

Channel-level overrides:

- `role_override='channel_admin'` — bypass workspace role; this user has Admin powers in this channel only
- `role_override='read_only'` — this user can read but not send messages

## Sprint 47 — Chat foundation + permission groundwork (detailed)

**Backend** (~25h):

- 4 new schema migrations (`workspaces`, `workspace_members`,
  `channels`, `channel_members`, `messages`) — additive + idempotent
- Backfill: existing admin user gets a "admin's workspace" row;
  existing tasks get their corresponding task-channel rows; existing
  members get workspace_members rows with `role='owner'`
- 6 new routes:
  - `GET /channels?workspace_id=...` — list channels in workspace
  - `GET /channels/{id}/messages?since_id=...` — paginated history
  - `POST /channels/{id}/messages` — send a message (role-gated)
  - `PATCH /channels/{id}/messages/{message_id}` — edit message (author only)
  - `POST /channels/{id}/read` — update `last_read_message_id`
  - `POST /channels/{id}/members/{user_id}/role_override` — per-channel role override (Admin+ only)
- WebSocket extension: existing `/ws/notifications` adds a new event
  type `{type: "new_message", channel_id, message_id}`; clients
  subscribe to channels they're members of
- Agent context loop extension: when an agent runs its next LLM
  call, the orchestrator fetches new messages in the task channel
  since the agent's last turn and prepends them as `user`-role
  messages in the prompt context (so the agent reads them like
  teammate comments).  Interactive-prompt messages render in the
  agent's prompt as `assistant`-role lines so the agent can produce
  a structured response.

**Flutter** (~20h):

- Replace `task_channel.dart` event-stream renderer with a
  `MessageFeedWidget`: message bubbles by author, timestamps, unread
  indicators, agent tool-call markers, interactive-prompt action buttons
- New `MessageComposer` widget below the feed: `TextField` →
  `POST /channels/{id}/messages` with optimistic local insert
- New `ChannelHeader` shows: channel name, member avatars (overflow
  icon for >5), settings cog
- WebSocket client extension: subscribe to channel-message events;
  insert into local feed state
- Existing cost ticker chip + cap-abort dialog (Sprint 46) keep
  rendering in the task channel header

**Testing** (~5h):

- Migration idempotency tests
- Permission resolution unit tests (workspace role + channel override)
- Message-send role-gating integration tests
- WebSocket fan-out tests (multi-client)
- Agent context inclusion test (post a message; verify agent's next
  prompt includes it)

**Total estimated effort:** ~50h (~1.5-2 weeks calendar)

## Sprint 48 — Workflow editor + pre-dispatch confirm (outline)

**Scope:**

- Native Flutter node-based canvas (`flutter_node_editor` or
  `flow_compose` package, decision in plan)
- `team_spec` extended format (nodes + edges + conditions) with
  backward-compatible parser
- `messages.kind='team_proposal'` rendered as interactive 3-button
  card (Approve / Edit / Cancel)
- Tally's `propose_team` flow updated: instead of immediately
  dispatching, post a `team_proposal` message; on Approve, dispatch
- Edit-team flow: button opens workflow editor in a new screen with
  the proposed team pre-loaded; on Save, update the message + go back
  to the channel; user clicks Approve when ready
- Existing `team_builder.dart` removed (or kept as a "compact mode"
  for quick edits without the canvas)

**Estimated effort:** ~45-55h (canvas is non-trivial in Flutter).

## Sprint 49 — Persistent agents + DMs + scheduled-agent channels (outline)

**Scope:**

- `persistent_agents` table + CRUD endpoints
- Scheduler loop (cron + event triggers, extending Sprint 44 sweeper)
- Webhook receiver for event triggers (`/webhooks/agents/{trigger_id}`)
- Tally's `escalate_to_tally` tool exposed to all agents; escalation
  flow: agent → @tally in channel → Tally tries fix → on failure,
  `notify_user(...)` → DM message
- DM channel auto-creation on first DM
- Flutter: scheduled-agent channel renderer (run log with start/end
  markers per cron tick); persistent-agent management UI (uses
  workflow editor from Sprint 48); DM list in channel rail

**Estimated effort:** ~50-60h.

## Sprint 50 — Custom channels + multi-workspace UI + agent tool allowlist UI (outline)

**Scope:**

- `POST /channels` route — create custom channel with arbitrary
  members + role overrides
- Custom channel creation modal in Flutter
- Multi-workspace switching UI (server rail interactivity)
- Workspace settings page (rename, invite members, transfer
  ownership, billing portal redirect)
- Agent tool allowlist UI — per-agent toggles for tools (e.g., "this
  agent can read files but not run bash")
- Polish: search-channel, channel mute, notification preferences

**Estimated effort:** ~40-50h.

## Migration strategy

Existing state on `tally-orch:v26.4`:

- 1 admin user with `unlimited` plan via Sprint 46's `quotas` table
- 22 lifetime tasks in production with team_spec JSON
- No workspaces; no channels in DB (channels were a Flutter-side
  construct only)
- No messages in DB (SSE-only event stream)

Sprint 47 migration steps:

1. Schema migration (additive)
2. Backfill: insert one workspace row per existing user, assign
   `role=owner`
3. For each existing task: insert one `channels` row (kind=task,
   task_id=task.id, archived_at=task.updated_at if task.status in
   ('completed','failed'))
4. For each existing agent in each task: insert a `channel_members`
   row (task agents are still per-task; not persistent agents)
5. Existing `quotas.user_id` → `workspaces.owner_user_id` link via
   `workspace_members.user_id` join

No data loss.  Old tasks become viewable as archived channels.
Existing API endpoints (`POST /tasks`, etc.) keep working — they
auto-resolve the dispatching user's default workspace.

## Open items (deferred from these sprints)

1. **Real-time co-editing of workflow canvas** — Sprint 51+
2. **Cross-workspace channels** — never planned
3. **Custom workspace roles** — enterprise tier
4. **Workspace branding / theming** — enterprise tier
5. **Audit log** — partial in Sprint 47 (messages are the audit log);
   richer audit UI in a later sprint
6. **Notification routing per-user-per-channel** — Sprint 51+
7. **Channel search** — Sprint 50 has basic; full-text search Sprint 51+
8. **Workflow editor "test run" mode** — run the workflow with mock
   inputs to verify before saving — Sprint 51+
9. **Per-channel `tally_auto_jump_in` configuration UI** — Sprint 50
   includes the flag; UI to toggle it deferred to polish sprint
10. **Multiple Tallys per workspace** — never planned; one Tally
    per workspace context is intentional

## Sprint 1 (Sprint 47) effort estimate

| Area | Hours |
|---|---:|
| Schema migrations + backfill | 4 |
| Channel routes + message routes | 6 |
| Permission middleware | 4 |
| WebSocket extension + agent context inclusion | 6 |
| Flutter: MessageFeedWidget + MessageComposer | 10 |
| Flutter: ChannelHeader + WS client + interactive prompts | 6 |
| Migration of existing task_channel.dart | 4 |
| Tests (migration, permission, fan-out, agent context) | 6 |
| Sprint completion doc + commit + deploy | 4 |
| **Total** | **50** |

Roughly 1.5-2 weeks of focused calendar time.

## References

- Brainstorm conversation: this session (2026-05-20)
- Sprint 46 spec: `2026-05-20-credit-based-pricing-design.md`
- Sprint 46.5 spec: `2026-05-20-clerk-stripe-overage-integration.md`
- Existing Flutter screens: `tally_coding_app/lib/screens/{discord_shell,general_channel,task_channel,team_builder}.dart`
- Existing schema: `services/orchestrator/tally_orchestrator/service.py` SCHEMA constant (~line 77)

---

End of design spec.  Implementation plan for Sprint 47 to follow via `writing-plans` skill.
