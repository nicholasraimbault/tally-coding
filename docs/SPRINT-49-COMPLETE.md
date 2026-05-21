# Sprint 49 — Persistent agents + DMs + escalation chain

**Status:** Code complete + deployed on `tally.pronoic.dev`
**Dates:** 2026-05-20 (spec) → 2026-05-21 (ship)
**Effort:** 27 commits, 28 files, +6,133 / -135 lines
**Image:** `tally-orch:v29.1` (deployed to Phala CVM `app_c3b5481b…`)
**Branch:** `feat/sprint-49-persistent-agents`
**Branch tags:** `s49-phase-a-done`, `s49-phase-b-done`, `s49-deployed-v29`

## What shipped

### Locked decisions

| | |
|---|---|
| Cron library | **`croniter` 6.2.2** in our own asyncio polling loop. DB owns scheduling truth via `next_scheduled_run_at`. |
| Escalation policy | **Agent → Tally → user DM immediately.** No silent waiting. |
| DM scope | **Tally + same-workspace humans + same-workspace persistent agents.** No cross-workspace DMs (Sprint 50+). |
| Tally implementation | **Deterministic rules only.** Responds on `@tally` mentions, DM channels, or `kind='escalation'` messages. No LLM classifier on every message. |
| Webhook auth | **Per-trigger HMAC-SHA256.** `X-Tally-Signature: sha256=<hex>` header over raw POST body. |
| Persistent-agent fire shape | Each fire creates a `tasks` row with `persistent_agent_id` set; messages route to the agent's `scheduled_agent` channel (not a new task channel). |
| Tally DM content | Templated, no LLM (Sprint 49). |
| DM channels | Symmetric one-channel-per-pair, idempotent creation. |

### Backend

**`persistent_agents` table:**

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
CREATE INDEX IF NOT EXISTS idx_persistent_agents
    ON persistent_agents(workspace_id, enabled, next_scheduled_run_at);
```

Plus `tasks.persistent_agent_id INTEGER REFERENCES persistent_agents(id)` (idempotent migration).

**Db helpers:** `create_persistent_agent`, `list_persistent_agents`, `get_persistent_agent`, `update_persistent_agent`, `delete_persistent_agent` (soft delete), `bump_persistent_agent_failure`, `reset_persistent_agent_failures`. `create_persistent_agent` also creates the `scheduled_agent` channel + owner + Tally channel_members + computes `next_scheduled_run_at` from cron.

**6 new endpoints:**

| Route | Behavior |
|---|---|
| `POST /persistent_agents` | Create. Workspace-member-only. Server generates HMAC secrets + ids for new HTTP event triggers. |
| `GET /persistent_agents?workspace_id=N` | List active agents. Returns empty for non-members (workspace-isolation). |
| `PATCH /persistent_agents/{id}` | Update. Owner-only via workspace membership. Recomputes `next_scheduled_run_at` if cron changes. |
| `POST /persistent_agents/{id}/run_now` | Manual fire. Owner-only. |
| `DELETE /persistent_agents/{id}` | Soft delete (sets `deleted_at` + `enabled=0`). |
| `POST /channels/dm` | Idempotent DM creation. Targets: `tally` / `human` / `persistent_agent`. |

**Cron poller:** `Orchestrator._persistent_agents_loop` runs every 30s alongside the existing worker/event pollers. Queries `enabled=1 AND deleted_at IS NULL AND cron_schedule IS NOT NULL AND next_scheduled_run_at <= now`, fires each via `_fire_persistent_agent`, advances `next_scheduled_run_at` via `croniter(cron, now).get_next(float)`. Disables agents with malformed cron expressions instead of crashing.

**`_fire_persistent_agent(pid, *, trigger)`:** creates a `tasks` row with `persistent_agent_id=pid`, status='pending' (no proposed step), team_spec copied from the agent, owner copied from the workspace. Worker poller picks it up. `trigger` is one of `cron` / `webhook` / `manual`.

**Channel routing:** `channels.resolve_task_channel_id` prefers a persistent agent's `scheduled_agent` channel when the task has `persistent_agent_id`; falls back to Sprint 47's `get_task_channel_id`. Single call-site replacement in `_dispatch_agent` (user-intervention injection from Sprint 47 A11).

**HMAC webhook:** `POST /webhooks/agents/{trigger_id}` accepts raw POST body, verifies `X-Tally-Signature: sha256=<hex>` via `hmac.compare_digest` against the trigger's stored secret, fires `_fire_persistent_agent(agent_id, trigger="webhook")`.

**Tally escalation responder:** wired into `_broadcast_new_message`. When a `kind='escalation'` message broadcasts, looks up the workspace owner, ensures a Tally↔owner DM channel via `ensure_dm_channel` (idempotent), posts a templated text message to the DM, re-enters broadcast for the DM message. Templates are inline string formats — no LLM.

**Auto-pause:** `consecutive_failures` increments in 4 task-completion call sites (`mark_completed`, `mark_failed`, `mark_recovered`, `sweep_recovering`). At 3 consecutive failures, the agent is disabled + a permanent-failure DM lands in the Tally↔owner channel.

**Tally membership backfill:** Sprint 47's `_backfill_workspaces_and_channels` extended to add a `member_kind='tally'` workspace_member to every workspace + a Tally `channel_member` to every existing `#general` / `#backlog` channel without one.

### Frontend

**`TallyOrchClient` additions:** `createPersistentAgent`, `listPersistentAgents`, `updatePersistentAgent`, `runPersistentAgentNow`, `deletePersistentAgent`, `openDmChannel`.

**`WorkflowEditorScreen` (extended):**
- New constructor field `persistentAgentId: int?` (alongside Sprint 48's `taskId: String?` — exactly one required).
- `_AgentNodeData` extended with `cronSchedule` + `eventTriggers` for `kind='trigger'`.
- Trigger palette item (red `Icons.alarm`) shown only in persistent-agent context. Singleton-gated like Output.
- `_TriggerConfigDialog`: cron TextField + 5 preset ActionChips (every minute / every hour / daily 9am / weekdays 9am / nightly 9pm) + event-trigger list with add/remove/name editing. Server-assigned `id` + `secret` preserved on existing entries.
- Save routes to `updatePersistentAgent` for persistent-agent context, `updateTaskTeamSpec` for task context.

**`PersistentAgentsScreen` (new):** list view + per-agent `PopupMenuButton` (edit / run_now / toggle enable / delete). Edit pushes into `WorkflowEditorScreen` in persistent-agent context. "+ New" AppBar button opens `_NewPersistentAgentDialog` (name + role dropdown + optional cron with preset chips) → creates via API → pushes into the editor.

**Channel rail (extended):** added "SCHEDULED" and "DIRECT MESSAGES" categories below "TASKS". Each renders matching channels by kind. "+ New scheduled" tile pushes `PersistentAgentsScreen`. "+ New DM" tile opens `NewDmModal`. Refactored `_ChannelList.build()` from `Expanded + ListView.builder` to a single ListView with section spreads to support multiple categories.

**`NewDmModal` (new):** 3-tab Dialog (People / Tally / Agents). People is hardcoded to `admin` for Sprint 49 (TODO Sprint 50: real workspace members). Tally tab is a single entry. Agents tab fetches `listPersistentAgents`. Each tile calls `openDmChannel(targetKind, targetId)` and returns the channel dict via `Navigator.pop`.

**DM + scheduled_agent channel rendering:** `TaskChannelScreen` extended with `directChannelId: int?` + `channelTitle: String?` fields. When `directChannelId` is set, skips the task→channel resolution path and uses the channel directly. Task-specific UI (status header, files panel, cost ticker) is gated on `taskId != null` so DM and scheduled_agent channels render with just the MessageFeed + MessageComposer.

**Escalation indicator:** `_loadEscalationStatus` fires `getMessages?limit=1` for each scheduled_agent channel after rail load; stamps `_unread_escalation=true` on channels whose latest message is `kind='escalation'`. Channel tile renders an orange `Icons.circle` dot when set.

### Testing

- Orchestrator: 40 new pytest tests across `test_persistent_agents_schema.py` (5), `test_persistent_agents_crud.py` (7), `test_persistent_agents_routes.py` (12), `test_channel_routing.py` (2), `test_cron_loop.py` (3), `test_webhook_signature.py` (3), `test_escalation_to_dm.py` (3), `test_dm_channel_route.py` (4), `test_auto_pause_on_failures.py` (4). Combined with Sprint 48's suite: **193 passed in 5.40s**.
- Flutter: 9 new widget tests across `api_persistent_agents_test.dart` (5), `api_dm_test.dart` (1), `persistent_agents_screen_test.dart` (2), `message_feed_test.dart` (1 new escalation test). **37 pass / 1 pre-existing FAIL** (the `DiscordShellScreen renders the four-column layout` failure tracked since Sprint 47).

### Verification

Live smoke against `tally.pronoic.dev`:

| Step | Result |
|---|---|
| `GET /health` | 200, `status: ok` |
| `POST /persistent_agents` with `cron_schedule="0 21 * * *"` | 200, returns full row with auto-generated HMAC secret + computed `next_scheduled_run_at` |
| `GET /persistent_agents?workspace_id=1` | 200, lists the new agent |
| `POST /channels/dm {target_kind: "tally"}` | 200, returns DM channel |
| `POST /channels/dm {target_kind: "tally"}` (again) | 200, returns SAME channel id (idempotent) |
| `POST /webhooks/agents/{fake}` | 404 (trigger not found) |
| `DELETE /persistent_agents/{id}` | 200, soft-deleted (`deleted_at` set) |

### Deploy quirk: cached Phala digest

The first deploy of `:v29` returned 500 on `POST /persistent_agents` with `cron_schedule` set. Root cause: the orchestrator Dockerfile pins deps via an inline `pip install` list (not `uv sync`, because `uv.lock` references local-path packages unavailable in the container). Sprint 49 A4 added `croniter` to `pyproject.toml` + `uv.lock` but missed the Dockerfile.

Even after fixing the Dockerfile + rebuilding `:v29`, Phala had cached the original `:v29` image digest. Bumped to `:v29.1` to force a fresh pull. Both issues are committed (`699b776` adds croniter to Dockerfile, `4edddda` bumps compose tag).

Lesson for future sprints: when adding a Python dep, also add it to `services/orchestrator/Dockerfile`'s inline pip install list. And for the same image tag, force re-pull either with a digest pin or a `.N` suffix.

## Reviewer-flagged TODOs in code (intentionally deferred)

- **People tab in NewDmModal hardcoded to `admin`.** Real workspace-member listing requires a `GET /workspaces/{id}/members` endpoint, deferred to Sprint 50 along with multi-user workspaces.
- **Escalation indicator does N extra `GET /messages?limit=1` calls** per scheduled_agent channel on rail load. Acceptable at current scale (typically <5 scheduled agents per workspace). Sprint 50+ can add a server-side `unread_kinds` field on the channels response.
- **`if_returned` edge condition in workflow executor** still parses but doesn't evaluate (Sprint 48 deferred this too).
- **Back-edge / max_iterations execution** still acyclic (Sprint 48 deferred too).

## Deferred to later sprints

- **Sprint 50** — Custom channel creation UI; multi-workspace switching UI; agent tool allowlist UI; 4-tier role management UI; real workspace-member endpoint + multi-user People tab; cross-workspace DMs.
- **LLM-generated Tally DM summaries** (Sprint 50+).
- **Tally "should-respond" classifier** for proactive engagement (Sprint 50+).
- **Visual loop / max_iterations affordance in the canvas** (future).

## References

- Parent design: [`superpowers/specs/2026-05-20-discord-shaped-workspace-design.md`](superpowers/specs/2026-05-20-discord-shaped-workspace-design.md)
- Sprint 49 spec: [`superpowers/specs/2026-05-20-sprint-49-persistent-agents-design.md`](superpowers/specs/2026-05-20-sprint-49-persistent-agents-design.md)
- Sprint 49 plan: [`superpowers/plans/2026-05-20-sprint-49-persistent-agents.md`](superpowers/plans/2026-05-20-sprint-49-persistent-agents.md)
- Sprint 48 complete: [`SPRINT-48-COMPLETE.md`](SPRINT-48-COMPLETE.md)
- croniter: https://pypi.org/project/croniter/ (v6.2.2)
- CVM: `app_c3b5481b3f33551af6270a21145df613160bf063`
- Image: `ghcr.io/nicholasraimbault/tally-orch:v29.1` (digest `sha256:8956151e91961eafcdac67f654a29b0f5eca918dc9b91328913c926bee634e58`)
