# Sprint 22 — Agent palette + multi-agent dispatch

**Status: PASS** — The orchestrator now executes a multi-agent team
end-to-end. Submitted a 2-agent `{Planner → Coder}` task; Planner ran
on Kimi-K2 for 16.3s producing `plan.md`; Coder ran on Kimi-K2 for
50.8s producing `fact.py + test_fact.py` plus a green pytest run; the
task wrapped at 67.4s with `status='completed'` and per-agent results
preserved in `tasks.result_json`.

Multi-agent is now real in the data model and the dispatch loop. The
Discord-shaped UI (Sprint 25) and Tally architect (Sprint 23) plug
into this engine without further schema changes.

## What was built

### Data model: agent palette + per-task agents

Two new tables. The palette is a seeded library of 7 roles; the
per-task table holds the resolved instances for a given task.

```sql
CREATE TABLE agent_roles (
    name           TEXT PRIMARY KEY,
    description    TEXT NOT NULL,
    default_model  TEXT NOT NULL,
    tools_json     TEXT NOT NULL,
    system_prompt  TEXT NOT NULL
);

CREATE TABLE agents (
    id              TEXT PRIMARY KEY,
    task_id         TEXT NOT NULL,
    agent_idx       INTEGER NOT NULL,
    role            TEXT NOT NULL,
    model           TEXT NOT NULL,
    spec            TEXT NOT NULL,
    status          TEXT NOT NULL,
    result_json     TEXT,
    worker_identity TEXT,
    started_at      REAL,
    finished_at     REAL
);
```

`tasks` gains a `team_spec` column (JSON) — the architect's output
attached to the task. Null for legacy single-agent submissions.

Palette seeded at orchestrator boot via `INSERT OR IGNORE` so an
operator who tweaks a role's prompt isn't overwritten by a redeploy:

| Role | Default model | Tools |
|---|---|---|
| Planner | `moonshotai/kimi-k2.6` | task_tracker, file_editor_read |
| Coder | `moonshotai/kimi-k2.6` (see "Open items") | bash, file_editor, terminal |
| Reviewer | `moonshotai/kimi-k2.6` | file_editor_read, bash_read |
| Tester | `moonshotai/kimi-k2.6` | bash, file_editor, terminal |
| DocWriter | `meta-llama/llama-3.3-70b-instruct` | file_editor |
| SecReviewer | `deepseek/deepseek-r1-0528` | file_editor_read, bash_read |
| DBA | `deepseek/deepseek-v3.2` | file_editor, bash |

### Worker v13: per-agent spec in task payload

`worker_spike.py`'s `handle_task_wake` now branches on
`agent_spec` in the task payload:

```python
agent_spec = task_spec.get("agent_spec")          # new in Sprint 22
agent_idx  = task_spec.get("agent_idx")
if agent_spec is not None:
    task_workspace = workspace_root / f"task-{task_id[:12]}" / f"agent-{agent_idx}-{role}"
```

Each agent runs in its own `agent-{idx}-{role}/` subdir under the
task workspace. `perform_task` accepts an `agent_spec` parameter that
swaps the LLM model + tools + system prompt for the role. Backward-
compatible: when `agent_spec is None`, the legacy single-agent flow
runs unchanged.

Tool name → OpenHands Tool object mapping:

```python
name_to_tool = {
    "bash": TerminalTool.name,        "bash_read": TerminalTool.name,
    "file_editor": FileEditorTool.name, "file_editor_read": FileEditorTool.name,
    "task_tracker": TaskTrackerTool.name, "terminal": TerminalTool.name,
}
```

Read-only variants map to the same Tool today — OpenHands doesn't
expose a read-only mode at the Tool level. Reviewer/SecReviewer
prompts say "do not modify code" to keep them honest; a permission
wrapper around the tool is future work.

### Orchestrator: `_start_team` and `_dispatch_agent`

`process_task` branches on `task.team_spec`:

- **Multi-agent path**: `_start_team(task, team_spec)` resolves each
  agent against the palette, inserts per-agent rows, dispatches the
  first agent.
- **Single-agent path**: `_dispatch_single_agent(task)` — the Sprint
  19 fire-and-forget flow, kept for tasks submitted without a
  team_spec.

`_dispatch_agent` builds the per-agent payload (role + model +
system_prompt + tools + task-specific spec) and sends it to the
worker. Same fire-and-forget contract as Sprint 19 — orchestrator
gets an ack, releases the handle lock, exits.

Event poller's `kind=result` handler routes to `_handle_result_event`,
which:

1. If `agent_idx` is in the result → multi-agent path.
2. Mark this agent completed (or failed).
3. If failed → short-circuit the workflow, mark the whole task failed.
4. If more agents remain in sequence → dispatch the next one.
5. If this was the last agent → aggregate per-agent results into
   `tasks.result_json` and flip the task to `completed`.

For Sprint 22 the workflow is strictly sequential by `agent_idx`.
Sprint 27 adds parallel + branching.

### API additions

- `POST /tasks` accepts optional `team_spec` in the body — bypasses
  the architect for Sprint 22 testing; Sprint 23 wires Tally to
  produce one when the client omits it.
- `GET /tasks/{id}/team` returns `{team_spec, agents: [...]}` — what
  the Discord-shaped UI's members sidebar will consume in Sprint 25.
- `GET /admin/agent_roles` returns the palette — the UI uses this for
  role glyphs / names without hardcoding the list.

## E2E run (15:33:17 – 15:34:25 CDT 2026-05-17)

```
15:33:17  POST /tasks { description, team_spec: {Planner, Coder} }
15:33:21  Planner running on worker oNnNWlhA (model: moonshotai/kimi-k2.6)
15:33:37  Planner completed at +16.3s; Coder running on worker oNnNWlhA
15:34:25  Coder completed at +50.8s
          task: completed, 67.4s, aggregate result includes both agents' outputs
```

Workspace tree:

```
task-3848a1d5e9/
├── agent-0-Planner/
│   └── plan.md                  (358 B; the Planner's output)
└── agent-1-Coder/
    ├── fact.py
    ├── test_fact.py
    ├── __pycache__/
    └── .pytest_cache/           (pytest actually ran on Coder's side)
```

Aggregate `tasks.result_json`:

```json
{
  "success": true,
  "agents": [
    {"role": "Planner", "agent_idx": 0, "model": "moonshotai/kimi-k2.6",
     "result": {"success": true, "files_created": ["plan.md"], ...}},
    {"role": "Coder",   "agent_idx": 1, "model": "moonshotai/kimi-k2.6",
     "result": {"success": true, "files_created": [
       "__pycache__/...", ".pytest_cache/...",
       "fact.py", "test_fact.py", ...
     ], ...}}
  ]
}
```

Both agents ran on the same worker (`oNnNWlhA`) — Sprint 22's
sequential dispatch only uses one worker at a time. Pool=2 was up but
only the first handle saw work for this task; parallel placement
arrives in Sprint 27.

## Files committed

- `services/orchestrator/tally_orchestrator/service.py`:
  - SCHEMA additions: `agent_roles`, `agents`.
  - `tasks.team_spec` ALTER + idempotent migration.
  - `Db._seed_agent_roles` (7 roles).
  - `Db.list_agent_roles`, `get_agent_role`, `set_task_team_spec`,
    `get_task_team_spec`, `insert_agent`, `list_agents`,
    `mark_agent_running`, `mark_agent_completed`, `mark_agent_failed`.
  - `Orchestrator.process_task` branches multi-agent vs single-agent.
  - `Orchestrator._start_team`, `_dispatch_agent`,
    `_dispatch_single_agent`, `_handle_result_event`.
  - `TaskSubmit.team_spec` pydantic field.
  - `POST /tasks` accepts team_spec.
  - `GET /tasks/{id}/team`, `GET /admin/agent_roles` endpoints.
- `spike/day4/worker/worker_spike.py`:
  - `build_llm(model_override)` switches Kimi → per-agent model.
  - `perform_task(agent_spec=...)` runs OpenHands with role-specific
    system prompt + tools.
  - `_tools_from_spec` maps role tool names to OpenHands Tool objects.
  - `handle_task_wake` reads `agent_spec` + `agent_idx` from payload;
    workspace dir becomes `task-{id}/agent-{idx}-{role}/`.
- `spike/day4/worker/docker-compose.yml`: image tag `v12` → `v13`.
- `services/orchestrator/tally_orchestrator/worker_pool.py`:
  - `BASE_IMAGE` `v12` → `v13`.
  - GC recognises new `v13-tally-auto-*` + retained `v12/v11/v10`
    prefixes for cleanup of leftovers.

`ghcr.io/nicholasraimbault/tally-spike-day4-worker:v13` pushed to
GHCR.

## Open items

1. **Per-role models other than Kimi-K2 are unverified.** The
   palette ships `qwen/qwen-2.5-7b-instruct`, `meta-llama/llama-3.3-
   70b-instruct`, `deepseek/deepseek-r1-0528`, `deepseek/deepseek-v3.2`
   as defaults; only `moonshotai/kimi-k2.6` has been validated
   end-to-end against the OpenHands tool loop. During Sprint 22 the
   first Coder default (`qwen/qwen2.5-coder-32b-instruct`, an older
   ID) returned 404 from Red Pill; the second (`qwen/qwen3-coder-
   next`) returned an upstream-provider error mid-conversation. The
   Coder + Tester defaults were rolled back to Kimi-K2 to ship; a
   "model survey + per-role tuning" mini-sprint is on the list.
2. **No workspace artifact passing yet.** Coder ran in its own
   `agent-1-Coder/` workspace without access to `agent-0-Planner/
   plan.md`. It produced a sensible `fact.py` because the user task
   was self-describing, but for tasks where Coder must follow the
   Planner's plan, the artifacts need to flow. That's Sprint 26.
3. **Sequential workflow only.** Sprint 22 dispatches agents by
   `agent_idx` order. Parallel (`A || B`) and branching (`if reviewer
   fails, loop back to coder`) workflows arrive in Sprint 27.
4. **Tool-name mapping is loose.** `bash_read` / `file_editor_read`
   currently resolve to the same Tool object as `bash` /
   `file_editor`. Reviewer/SecReviewer prompts compensate with "do
   not modify code", but this is a soft constraint. A permission
   wrapper would be a clean follow-up.
5. **`task_spec` race on submit.** `POST /tasks` creates the task as
   `pending` and immediately calls `set_task_team_spec`. The
   processor loop polls every 0.5s, so in principle there's a window
   where the task could be picked up as a single-agent task before
   the team_spec is set. In practice the round-trip is sub-ms and
   I haven't seen this race fire; a future hardening pass could
   accept team_spec at task-create time atomically.

## Next sprint

Per the roadmap: **Sprint 23 — Tally architect.** A single LLM call
(Kimi via Red Pill) reads the task description and emits the
`{agents, workflow, reasoning}` JSON the orchestrator now consumes.
That makes the "user describes a task; Tally builds a custom team"
UX real end-to-end.
