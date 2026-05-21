# Sprint 48 — Workflow editor + pre-dispatch team confirm

**Status:** Code complete + deployed on `tally.pronoic.dev`
**Dates:** 2026-05-20 (spec) → 2026-05-20 (ship)
**Effort:** 22 commits, 27 files, +5,006 / -769 lines
**Image:** `tally-orch:v28` (deployed to Phala CVM `app_c3b5481b…`)
**Branch:** `feat/sprint-48-workflow-editor`
**Branch tags:** `s48-phase-a-done`, `s48-phase-b-done`, `s48-deployed-v28`

## What shipped

### Locked design decisions

| | |
|---|---|
| Canvas package | **`vyuh_node_flow`** v0.27.3 (MIT). Required upgrading Flutter 3.27.4 → 3.44.0 (Dart 3.6.2 → 3.12.0) for the `>=3.8.0` SDK constraint. |
| Existing `team_builder.dart` | **Deleted entirely** (631 lines from Sprint 30 kanban UI). |
| `team_proposal` message location | **`#general` only.** Task channel only created on Approve. |
| Edit-team flow | One editor, two contexts: per-task team review (Sprint 48) + persistent-agent management (Sprint 49). |

### Backend

**Task lifecycle (new statuses):**
- `tasks.status` enum extends with `proposed` and `cancelled`
- `TASK_STATUS_TERMINAL` and `TASK_STATUS_COUNTS_AGAINST_QUOTA` frozensets added as canonical references
- `POST /tasks` no longer dispatches — sets `status='proposed'` and posts a `team_proposal` message
- `Db.create_task` defaults to `status='proposed'` and no longer inserts the task channel inline
- `Db.approve_task` (new): idempotent transition `proposed → pending` + inserts the task channel + owner `channel_members` row
- Backfill skips `proposed`/`cancelled` tasks (no channels for unapproved/cancelled work)

**3 new lifecycle endpoints:**

| Route | Behavior |
|---|---|
| `POST /tasks/{id}/approve` | Owner-only. 404/403/409 guards. Transitions `proposed → pending`, creates the task channel, wakes the worker poller via `orch._kick_poller()` if present. |
| `PATCH /tasks/{id}/team_spec` | Owner-only, proposed-only. Updates `tasks.team_spec` + patches the `team_proposal` message payload + re-broadcasts via WebSocket so other clients see the updated spec. |
| `POST /tasks/{id}/cancel` | Owner-only, proposed-only. Sets `status='cancelled'` + marks the `team_proposal` message `cancelled=true` (UI greys the buttons). |

**`team_spec_compat.py` module:**
- `is_nodes_v1(spec)` — format detector
- `normalize(spec)` — flat-form → nodes_v1 converter. Each stage's agents become `kind='agent'` nodes (`id="s<i>a<j>"`); consecutive stages connect with `always` edges; appends a terminal `kind='output'` node. Preserves role/model/spec/worker_affinity fields.
- Conversion runs on-the-fly per read in Sprint 48; one-time persisted backfill deferred to Sprint 49.

**`nodes_v1` workflow executor:**
- Two pure graph-traversal helpers exposed at module level:
  - `_nodes_v1_entry_nodes(spec)` — nodes with no incoming edge (entry set)
  - `_nodes_v1_next_ready(spec, completed)` — nodes whose ALL incoming edges have fired given a `{node_id: 'succeeded' | 'failed'}` map. AND semantics across incoming edges.
- Edge conditions: `always` (default), `if_succeeded`, `if_failed`. `if_returned` is parsed but not evaluated (deferred).
- Branch nodes (parallel fan-out) and back-edges expressed via edge topology, not separate node kinds.
- `_start_team` extended with a `nodes_v1` branch: inserts agent rows for all `kind='agent'` nodes, dispatches entry nodes.
- `_handle_result_event` extended: on agent completion, computes `_nodes_v1_next_ready`, dispatches newly-ready agent nodes, falls through to task-completion aggregation when all are terminal.
- `agents.iteration_idx` column (idempotent migration) — for future back-edge cycle tracking.

**`messages.kind='team_proposal'`:**
- New message kind alongside Sprint 47's `text` / `interactive_prompt` / `interactive_prompt_response`. No schema change (kind is TEXT).
- `insert_team_proposal_message(db, task_id, user_id, description, team_spec)` helper in `channels.py` finds the user's `#general` channel and inserts a `kind='team_proposal'` message authored by `tally`. Returns the message_id or 0 if the user has no `#general`.

### Frontend

**`api.dart` additions:**
- `approveTask({required taskId})`
- `updateTaskTeamSpec({required taskId, required teamSpec})`
- `cancelTask({required taskId})`

**`TeamProposalCard` widget:**
- Renders `kind='team_proposal'` messages with task description, team summary (e.g., "Coder → Tester → Reviewer" from `nodes_v1` agent roles), 3 action buttons (Approve / Edit / Cancel).
- Switches to a greyed italic "cancelled" or "approved" label when those payload flags are set.

**`MessageFeed` extension:**
- New optional callback `onTeamProposalAction(taskId, action)`
- `kind='team_proposal'` messages dispatch to `TeamProposalCard` (alongside the Sprint 47 `interactive_prompt` branch).

**`WorkflowEditorScreen` (new):**
- Full-screen route opened from a `team_proposal` card's Edit button. Receives `client`, `taskId`, `initialTeamSpec` (nodes_v1 form).
- Real `NodeFlowEditor<_AgentNodeData, _EdgeData>` canvas from `vyuh_node_flow`. Drag-to-canvas palette (Agent, Output), connect ports to draw edges, tap a node for per-node config dialog, tap an edge for per-edge condition + max_iterations config.
- `_AgentNodeData` carries `kind`, `role`, `model`, `spec`, `worker_affinity`.
- `_EdgeData` carries `condition` (always/if_succeeded/if_failed) + `maxIterations`.
- Per-node config dialog: role dropdown, model TextField, spec multiline TextField, worker affinity dropdown.
- Per-edge config dialog: condition dropdown + max iterations TextField.
- Save calls `PATCH /tasks/{id}/team_spec` and returns to #general. Save does NOT dispatch — user must Approve afterward.
- `__x` / `__y` shadow fields in the spec preserve canvas positions across save/reopen cycles.

**`GeneralChannelScreen` integration:**
- Loads channel messages from `#general` via `getMessages(channelId)` on init + after each action
- Filters `kind='team_proposal'` and renders them via `TeamProposalCard` above the existing `_GeneralFeed`
- Wires the 3 action buttons: Approve calls `approveTask`, Edit pushes `WorkflowEditorScreen`, Cancel calls `cancelTask`. All three reload proposals on completion.

**Removed:**
- `tally_coding_app/lib/screens/team_builder.dart` (Sprint 30 kanban UI)
- Server-rail "Team builder" `IconButton` + drawer `TextButton.icon` + `_openBuilder()` handler

### Testing

- Orchestrator: 14 new pytest tests across `test_task_status_enum.py` (4), `test_team_spec_compat.py` (6), `test_workflow_executor_nodes_v1.py` (7), `test_team_proposal_message.py` (2), `test_task_approval_flow.py` (15: 3 from A6 + 5 from A7 + 3 from A8 + 4 from A9), `test_workspace_schema.py` (4 new + 3 updated). Combined Sprint 47's existing suite: **148 passed in 3.80s**.
- Flutter: 4 new widget tests covering `TeamProposalCard`, `MessageFeed` team_proposal dispatch, `api.dart` task lifecycle methods. **28 passed / 1 pre-existing FAIL** (the `DiscordShellScreen renders the four-column layout` failure tracked since Sprint 47).

### Verification

Live smoke against `tally.pronoic.dev` after the Phala roll:

| Step | Result |
|---|---|
| `GET /health` | 200, `status: ok` |
| `GET /channels?workspace_id=1` | 200, admin #general + #backlog visible (backfill ran on the live DB) |
| `GET /channels/1/messages` | 200, prior Sprint 47 smoke message preserved across deploy |
| `POST /tasks` | 503 `pool_not_ready` — production CVM has no workers attached, so the full task lifecycle (proposed → approve → dispatch) wasn't exercised live. Covered by pytest's 148-test suite via TestClient with `pool_ready=True` stubbed. |

### Flutter SDK upgrade

`vyuh_node_flow` 0.27.3 requires Dart `>=3.8.0`. The development machine had Flutter 3.27.4 (Dart 3.6.2, ~16 months old). Ran `flutter upgrade` → Flutter 3.44.0 / Dart 3.12.0. No regressions in the existing test suite. `vector_math` bumped 2.1.4 → 2.2.0 as a transitive side effect; all other deps unchanged.

## Reviewer-flagged TODOs in code (intentionally deferred)

- **`if_returned` edge condition evaluation.** The parser accepts `{"condition": "if_returned", "value": "X"}` on edges, but `_nodes_v1_next_ready` returns the node as not-ready for those edges. Adding structured-output evaluation requires agreeing on a returned-value extraction scheme — left to Sprint 49+ when persistent agents need it for their own state machines.
- **Back-edge / max_iterations execution.** The `agents.iteration_idx` column is in place, the edge config dialog accepts `max_iterations`, the parser preserves the field, but the executor still dispatches acyclically. Visual representation of back-edges in the canvas also pending — the canvas treats back-edges as ordinary edges today.
- **Architect cost on Cancel.** No refund — architect spend is sunk on POST /tasks. Matches Sprint 46 no-refunds-on-cancelled-work policy.

## Deferred to later sprints

- **Sprint 49** — Persistent agents (cron + event triggers + Trigger nodes for the workflow editor's second context); DMs UI; one-time persisted conversion of historical flat team_specs to nodes_v1.
- **Sprint 50** — Custom channel creation UI; multi-workspace switching UI; agent tool allowlist UI; 4-tier role management UI.

## Sprint 48 follow-up — Sprint 48.5 candidate

The deploy noted that production has no workers attached (`pool_ready: false`), so the Sprint 48 lifecycle (`POST /tasks` proposed → approve → dispatch) wasn't exercised end-to-end live. Pytest's TestClient covers it, but a fully live verification needs the worker pool. Either attach workers (`local` or `tee` tier) or accept the test-coverage-only verification stance.

## References

- Parent design: [`superpowers/specs/2026-05-20-discord-shaped-workspace-design.md`](superpowers/specs/2026-05-20-discord-shaped-workspace-design.md)
- Sprint 48 spec: [`superpowers/specs/2026-05-20-sprint-48-workflow-editor-design.md`](superpowers/specs/2026-05-20-sprint-48-workflow-editor-design.md)
- Sprint 48 plan: [`superpowers/plans/2026-05-20-sprint-48-workflow-editor.md`](superpowers/plans/2026-05-20-sprint-48-workflow-editor.md)
- Sprint 47 complete: [`SPRINT-47-COMPLETE.md`](SPRINT-47-COMPLETE.md)
- vyuh_node_flow: https://pub.dev/packages/vyuh_node_flow
- CVM: `app_c3b5481b3f33551af6270a21145df613160bf063`
- Image: `ghcr.io/nicholasraimbault/tally-orch:v28` (digest `sha256:c1ce81405f7ce630b07c52036551c5d58f700f7f2a615dc4958f587521910fcf`)
