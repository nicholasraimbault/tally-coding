# Sprint 49 — Persistent agents + DMs + escalation chain

**Date:** 2026-05-20
**Builds on:** Sprint 47 (chat foundation), Sprint 48 (workflow editor + nodes_v1 executor)
**Parent spec:** [`2026-05-20-discord-shaped-workspace-design.md`](2026-05-20-discord-shaped-workspace-design.md)

## Locked decisions (from brainstorm)

| | |
|---|---|
| Cron library | **`croniter`** in our own asyncio polling loop. Our `persistent_agents` table owns the scheduling truth (`next_scheduled_run_at`). Misfire grace + coalesce implemented in ~20 LOC if/when needed. No APScheduler. |
| Escalation policy | **Agent → Tally → user DM, immediately.** When a persistent agent gets stuck (kind='escalation' message in its channel), Tally always DMs the workspace owner with a link. No silent waiting. |
| DM scope | **Tally + same-workspace humans + same-workspace persistent agents.** No cross-workspace DMs in Sprint 49 (defer to Sprint 50+ when identity questions land). |
| Tally implementation | **Deterministic rules only.** Tally responds when: (a) message author is human AND text contains `@tally`; (b) channel kind is `dm` AND Tally is a channel_member; (c) any agent posts `kind='escalation'`. No LLM classifier on every message. |
| Webhook auth | **Per-trigger HMAC-SHA256 secret.** Each `event_triggers_json[i]` carries `{kind: 'http', secret: '<random>'}` generated at trigger-creation time. Caller signs the POST body with the secret; orchestrator verifies via `X-Tally-Signature: sha256=<hex>` header. User can rotate via PATCH. |
| Persistent-agent fire shape | **Each fire creates a `tasks` row** (cost accounting + audit work unchanged); the new column `tasks.persistent_agent_id REFERENCES persistent_agents(id)` ties the fire back to the agent. **Messages land in the persistent agent's existing `kind='scheduled_agent'` channel**, NOT a new task channel. Channel becomes a chronological log of every fire. |
| Tally DM content | **Templated for Sprint 49.** Fixed format: `"@<owner> — <agent_name> needs your input on <reason>. See <#scheduled_agent_channel>."` No LLM call for the DM itself; the agent's escalation message supplies the `reason`. Sprint 50+ can add LLM-generated summaries. |
| One-channel-per-DM-pair | **Symmetric.** A `dm` channel between users A and B has both as `channel_members`. Creation is idempotent: if the channel already exists between (A, B), open it; else create one with both members. |

## Backend changes

### 1. `persistent_agents` table (per parent spec)

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

### 2. `tasks.persistent_agent_id` column (additive migration)

```sql
ALTER TABLE tasks ADD COLUMN persistent_agent_id INTEGER REFERENCES persistent_agents(id);
CREATE INDEX IF NOT EXISTS idx_tasks_persistent_agent ON tasks(persistent_agent_id);
```

Idempotent migration via the existing try/except sqlite3.OperationalError pattern.

### 3. Cron poller

`Orchestrator._persistent_agents_loop`: background asyncio task that polls every 30s, walks rows where `enabled=1 AND next_scheduled_run_at <= now`, fires each, and updates `next_scheduled_run_at` via `croniter(cron_schedule, now).get_next(float)`.

Boot wiring: started from `Orchestrator.__init__` alongside the existing worker/event pollers. Stops cleanly on shutdown.

```python
async def _persistent_agents_loop(self):
    while not self._stopping:
        now = time.time()
        rows = self.db._conn.execute(
            "SELECT id, cron_schedule "
            "FROM persistent_agents "
            "WHERE enabled=1 AND deleted_at IS NULL "
            "AND cron_schedule IS NOT NULL "
            "AND next_scheduled_run_at <= ?",
            (now,),
        ).fetchall()
        for agent_id, cron in rows:
            try:
                await self._fire_persistent_agent(agent_id, trigger="cron")
            except Exception as exc:
                logger.exception("persistent agent %s fire failed: %s", agent_id, exc)
            # Recompute next fire even on failure
            from croniter import croniter
            next_fire = croniter(cron, now).get_next(float)
            self.db._conn.execute(
                "UPDATE persistent_agents SET last_run_at=?, next_scheduled_run_at=? WHERE id=?",
                (now, next_fire, agent_id),
            )
        await asyncio.sleep(30)
```

### 4. `_fire_persistent_agent(agent_id, trigger)`

Creates a `tasks` row with `persistent_agent_id=agent_id`, status='pending' (no proposed step for persistent agents — they're pre-approved by the user when they were created), team_spec copied from `persistent_agents.team_spec_json`, then dispatches via the existing executor (Sprint 48 nodes_v1 path or flat path).

The persistent agent's `scheduled_agent` channel already exists (created when the agent was created — see frontend section). All agent messages from this fire land there via the existing channel-routing logic (the Sprint 47 message broadcast picks the channel from the task's `task_id` lookup; for persistent agents, we route to `scheduled_agent_channel_id` instead — see "Channel routing" below).

### 5. Channel routing for persistent-agent fires

Sprint 47 routes agent messages to the task's `kind='task'` channel via `get_task_channel_id(db, task_id)`. Sprint 49 adds: if the task has a `persistent_agent_id`, route to the persistent agent's `scheduled_agent` channel instead:

```python
def resolve_task_channel_id(db, task_id) -> int | None:
    """Sprint 49: prefer persistent_agent's scheduled_agent channel
    if the task was fired by a persistent agent."""
    row = db._conn.execute(
        "SELECT persistent_agent_id FROM tasks WHERE id=?", (task_id,)
    ).fetchone()
    if row and row[0]:
        ch = db._conn.execute(
            "SELECT id FROM channels WHERE persistent_agent_id=? AND kind='scheduled_agent'",
            (row[0],),
        ).fetchone()
        if ch:
            return int(ch[0])
    return get_task_channel_id(db, task_id)  # fallback to Sprint 47 behavior
```

`Db.create_task` (and orchestrator's broadcast path) call this new function instead of `get_task_channel_id` directly.

### 6. Webhook handler

`POST /webhooks/agents/{trigger_id}` accepts arbitrary JSON body. Header `X-Tally-Signature: sha256=<hex>`:

```python
@app.post("/webhooks/agents/{trigger_id}")
async def fire_event_trigger(trigger_id: str, request: Request) -> dict:
    """Sprint 49: fire a persistent agent via its event trigger.
    Auth: HMAC-SHA256 over raw request body using trigger's secret."""
    raw_body = await request.body()
    sig = request.headers.get("X-Tally-Signature", "")
    # Find the trigger
    rows = db._conn.execute(
        "SELECT id, event_triggers_json FROM persistent_agents WHERE deleted_at IS NULL"
    ).fetchall()
    for agent_id, triggers_json in rows:
        triggers = json.loads(triggers_json or "[]")
        for trig in triggers:
            if trig.get("id") == trigger_id and trig.get("kind") == "http":
                expected = "sha256=" + hmac.new(
                    trig["secret"].encode(),
                    raw_body,
                    hashlib.sha256,
                ).hexdigest()
                if hmac.compare_digest(sig, expected):
                    await state["orch"]._fire_persistent_agent(agent_id, trigger="webhook")
                    return {"ok": True, "agent_id": agent_id}
                else:
                    raise HTTPException(401, "invalid signature")
    raise HTTPException(404, "trigger not found")
```

`trigger_id` is a UUID generated when the trigger is configured. `secret` is a 32-char random hex string.

### 7. Escalation flow

A persistent agent (or any agent) can post a `kind='escalation'` message in its channel:

```json
{
  "kind": "escalation",
  "payload": {
    "reason": "Test suite is failing intermittently and I need guidance on whether to retry, skip, or report.",
    "agent_name": "nightly-tests",
    "agent_role": "Tester"
  }
}
```

Tally's deterministic responder reacts:
- Detects `kind='escalation'` in the channel
- Identifies the workspace owner (`workspaces.owner_user_id`)
- Ensures a Tally↔owner DM channel exists (creates one if not)
- Posts a `kind='text'` message in the DM channel:
  ```
  @<owner> — nightly-tests (Tester) needs your input: "Test suite is failing
  intermittently…". See #nightly-tests.
  ```
- Posts an `interactive_prompt` in the persistent agent's channel offering pause/resume/cancel buttons

The Tally responder runs as part of the `_broadcast_new_message` fan-out: after the new_message frame goes out to subscribers, check if the message warrants Tally action.

### 8. `tally` workspace_member

Every workspace has a synthetic `tally` workspace_member: `member_kind='tally', user_id=NULL, role='tally'`. Created by the backfill (and by `create_workspace` for new workspaces) so Tally can be a `channel_member` of relevant channels.

The Sprint 47 `_backfill_workspaces_and_channels` is extended to insert a Tally workspace_member if missing.

### 9. New endpoints

| Route | Behavior |
|---|---|
| `POST /persistent_agents` | Create a persistent agent. Body: `{name, role_name, team_spec, tool_allowlist?, model?, cron_schedule?, event_triggers?}`. Auto-creates the agent's `scheduled_agent` channel + owner + Tally as channel_members. Computes `next_scheduled_run_at` from `cron_schedule` on creation. |
| `GET /persistent_agents?workspace_id=N` | List persistent agents in a workspace. |
| `PATCH /persistent_agents/{id}` | Update fields (name, team_spec, cron_schedule, event_triggers, enabled, model, tool_allowlist). Re-computes next_scheduled_run_at if cron_schedule changed. Rotates HMAC secrets on event_triggers if user requests via `?rotate_secrets=true`. |
| `POST /persistent_agents/{id}/run_now` | Manually fire the agent. Owner-only. |
| `DELETE /persistent_agents/{id}` | Soft delete (sets `deleted_at`). Disables future fires; preserves history. |
| `POST /channels/dm` | Open or find a DM channel. Body: `{target_kind: 'human' \| 'tally' \| 'persistent_agent', target_id: str}`. Returns the channel_id. Idempotent: if a DM channel already exists between (caller, target), returns it. |

### 10. Tally DM templates

For Sprint 49, two fixed templates:

**Escalation DM** (Tally posts in Tally↔owner DM):
```
@{owner} — {agent_name} ({agent_role}) needs your input: "{reason_truncated_to_140}".
See #{scheduled_agent_channel}.
```

**Permanent failure DM** (after `consecutive_failures >= 3`):
```
@{owner} — {agent_name} has failed 3 times in a row. I've paused it.
See #{scheduled_agent_channel} for the failures. Enable again from settings.
```

These are templated string formats, no LLM call. `{reason_truncated_to_140}` is the agent's escalation reason cut to 140 chars + ellipsis.

### 11. Auto-pause on repeated failures

When `_fire_persistent_agent` catches an exception or the dispatched team_spec results in `status='failed'`, increment `consecutive_failures`. If it reaches 3, set `enabled=0` and emit the "permanent failure DM" to the owner. On a successful run, reset to 0.

This is the cost-control + sanity gate that prevents a broken cron from filling logs.

## Frontend changes

### 1. `WorkflowEditorScreen` — Trigger node

Sprint 48 deferred the Trigger node. Sprint 49 adds it to the palette as a third draggable: `Trigger`.

When the screen is opened in "persistent agent context" (vs Sprint 48's "task context"), the palette enables the Trigger item. A Trigger node carries:
- `cron_schedule: String?` (e.g., `"0 9 * * 1-5"`)
- `event_triggers: List<EventTrigger>` (a list of `{kind: 'http', name: 'GitHub PR'}` items; the secret is generated server-side on save)

Per-trigger config dialog (when user taps a Trigger node):
- Cron schedule TextField with a "Common patterns" dropdown (`every minute`, `every hour`, `daily 9am`, `weekdays 9am`, etc.)
- "+Add event trigger" list of HTTP triggers, each with a `name` field (the webhook URL + secret are shown read-only after save)

The screen distinguishes context via a new constructor field `persistentAgentId: int?`:

```dart
WorkflowEditorScreen({
  required client,
  String? taskId,            // for Sprint 48 task-context
  int? persistentAgentId,    // for Sprint 49 persistent-agent context
  required initialTeamSpec,
})
```

Save posts to whichever endpoint matches the context: `PATCH /tasks/{id}/team_spec` (task) or `PATCH /persistent_agents/{id}` (persistent agent).

### 2. Persistent agent management screen

New screen `PersistentAgentsScreen` reached from the channel rail's "Scheduled" category (a "+ New" tile next to it). Lists all `persistent_agents` in the workspace (via `GET /persistent_agents`); each row shows name, cron schedule (humanized), last run, enabled toggle. Tap → opens the agent's `scheduled_agent` channel + a configure button → opens `WorkflowEditorScreen` in persistent-agent context.

"New persistent agent" flow:
1. Tap "+ New" in Scheduled category
2. Dialog: name, role pick from existing agent roles, optional cron schedule
3. Submit → creates row via `POST /persistent_agents` + redirects into WorkflowEditorScreen (persistent-agent context) for fine-tuning the team_spec/triggers
4. Save in editor → done; the agent's scheduled_agent channel is now in the rail

### 3. DM list in channel rail

The channel rail (Sprint 47's left sidebar) already shows `#general`, `#backlog`, task channels under "Active tasks", and scheduled-agent channels under "Scheduled". Sprint 49 adds a "Direct messages" category at the bottom, listing all `kind='dm'` channels the user is a member of.

Each DM row shows:
- A small avatar or icon
- The other party's display name (other human / `tally` / `<persistent agent name>`)
- An unread badge if `last_read_message_id < latest message id`

Tap → opens the DM channel using Sprint 47's existing `MessageFeed` + `MessageComposer` (DM channels render exactly like task channels — same widgets).

### 4. "New DM" modal

A "+ New DM" tile next to the "Direct messages" category opens a modal:
- A search field
- Tabs: `People`, `Tally`, `Agents`
- People tab: lists workspace humans (via `GET /workspaces/{id}/members`)
- Tally tab: single "Tally" entry that opens the user↔Tally DM
- Agents tab: lists persistent agents (via `GET /persistent_agents`)
- Click → calls `POST /channels/dm` with `{target_kind, target_id}` → opens the returned channel

### 5. Escalation indicator in scheduled-agent channels

When a `kind='escalation'` message exists in a `scheduled_agent` channel, the channel rail shows a small orange dot next to its name. Resolved by:
- The user reads the channel (`POST /channels/{id}/read` brings `last_read_message_id` up to date), AND
- The escalation has been responded to (e.g., the user clicked a button on the agent's interactive_prompt)

### 6. `api.dart` additions

```dart
// Persistent agents
Future<Map<String, dynamic>> createPersistentAgent({
  required String name,
  required String roleName,
  required Map<String, dynamic> teamSpec,
  String? cronSchedule,
  List<Map<String, dynamic>>? eventTriggers,
  Map<String, dynamic>? toolAllowlist,
  String? model,
});
Future<List<Map<String, dynamic>>> listPersistentAgents({required int workspaceId});
Future<Map<String, dynamic>> updatePersistentAgent({required int id, Map<String, dynamic> patch});
Future<Map<String, dynamic>> runPersistentAgentNow({required int id});
Future<void> deletePersistentAgent({required int id});
// DMs
Future<Map<String, dynamic>> openDmChannel({required String targetKind, required String targetId});
Future<List<Map<String, dynamic>>> listWorkspaceMembers({required int workspaceId});
```

## Hook point changes

- **`Db.create_workspace`** (implicit in Sprint 47 backfill — Sprint 49 makes it explicit): inserts a `workspace_members` row with `member_kind='tally'` so Tally can be added to channels.
- **`_broadcast_new_message`** (Sprint 47 A10): after the WS fan-out, check if the just-inserted message is `kind='escalation'`. If so, trigger Tally's escalation handler.
- **`_fire_persistent_agent`** (new, called by cron loop + webhook handler + manual `/run_now`): inserts a `tasks` row with `persistent_agent_id` + dispatches.
- **`get_task_channel_id`** → use `resolve_task_channel_id` (preserves Sprint 47 behavior + adds persistent_agent_id branch).

## Testing

### Backend

- `test_persistent_agents_schema.py` — table exists, columns correct, indices present.
- `test_persistent_agents_crud.py` — POST/GET/PATCH/DELETE/run_now endpoints.
- `test_cron_loop.py` — schedule a row with `next_scheduled_run_at=now-1`, run one loop iteration, assert it fires and `next_scheduled_run_at` advances per croniter.
- `test_webhook_signature.py` — valid HMAC fires; invalid HMAC returns 401; unknown trigger_id returns 404.
- `test_escalation_to_dm.py` — insert a `kind='escalation'` message in a `scheduled_agent` channel; assert Tally creates a DM with the owner + posts the templated message.
- `test_dm_channel_idempotent.py` — calling `POST /channels/dm` twice with the same target returns the same channel_id.
- `test_tasks_persistent_agent_id_column.py` — column exists, FK to persistent_agents.
- `test_auto_pause_on_failures.py` — three consecutive failures sets enabled=0 + emits permanent-failure DM.
- `test_channel_routing.py` — messages from a persistent-agent task land in `scheduled_agent` channel, not a new task channel.

### Flutter

- `test/api_persistent_agents_test.dart` — 5 mock-HTTP tests for the api.dart methods.
- `test/api_dm_test.dart` — openDmChannel mock test.
- `test/persistent_agents_screen_test.dart` — list renders, tap row opens scheduled_agent channel.
- `test/workflow_editor_trigger_node_test.dart` — Trigger node appears in palette when persistentAgentId is set; doesn't appear when taskId is set.
- `test/dm_list_test.dart` — DM channels listed in rail.

## Verification

After Phala deploy:
- Create a persistent agent via `POST /persistent_agents` with `cron_schedule="* * * * *"` (every minute) and a tiny team_spec
- Wait 90s; verify a `tasks` row was created with `persistent_agent_id` set
- Verify messages land in the agent's `scheduled_agent` channel
- Test the webhook: `POST /webhooks/agents/{trigger_id}` with a valid HMAC → returns 200 + agent fires
- Test invalid HMAC → 401
- Manually insert a `kind='escalation'` message → verify Tally creates the DM
- Open the new DM channel via `POST /channels/dm {target_kind: 'tally'}` → verify it's idempotent

## Out of scope (deferred)

- **Cross-workspace DMs** — identity + auth questions; Sprint 50+.
- **LLM-generated Tally DM summaries** — Sprint 49 uses templates; Sprint 50+ could add LLM summarization for richer messages.
- **Tally "should-respond" classifier** — Sprint 49 is deterministic-only; Sprint 50+ could add a cheap classifier for proactive Tally engagement.
- **Persistent agent interval triggers** (e.g., "every 4 hours from now") — cron expressions can do this (`0 */4 * * *`); a dedicated `interval_seconds` field is a future addition.
- **Trigger node visual loop affordance** — back-edges with `max_iterations` are still drawn as ordinary edges; visual loop primitive is Sprint 50+.

## Effort estimate

- **Backend:** ~25h
  - persistent_agents schema + migrations + helpers: 4h
  - Cron loop + croniter integration: 3h
  - CRUD endpoints + tests: 6h
  - Webhook handler + HMAC verification + tests: 3h
  - Escalation handler + DM creation + Tally workspace_member: 5h
  - Channel routing changes + tests: 2h
  - Auto-pause + permanent-failure DM: 2h
- **Flutter:** ~25h
  - WorkflowEditorScreen Trigger node + per-trigger config: 8h
  - PersistentAgentsScreen (list + new-agent flow): 6h
  - DM list in channel rail + DM channel rendering: 4h
  - "+ New DM" modal: 4h
  - api.dart additions + tests: 3h
- **Deploy/verify:** ~5h

**Total:** ~55h.

## References

- Parent spec: [`2026-05-20-discord-shaped-workspace-design.md`](2026-05-20-discord-shaped-workspace-design.md)
- Sprint 48 complete: [`../../SPRINT-48-COMPLETE.md`](../../SPRINT-48-COMPLETE.md)
- croniter: https://pypi.org/project/croniter/
- HMAC pattern (GitHub webhooks): https://docs.github.com/en/webhooks/using-webhooks/validating-webhook-deliveries
