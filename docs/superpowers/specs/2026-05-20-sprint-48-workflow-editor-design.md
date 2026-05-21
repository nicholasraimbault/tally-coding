# Sprint 48 — Workflow editor + pre-dispatch team confirm

**Date:** 2026-05-20
**Builds on:** Sprint 47 (chat foundation), Sprint 22-24 (architect + team_spec)
**Parent spec:** [`2026-05-20-discord-shaped-workspace-design.md`](2026-05-20-discord-shaped-workspace-design.md)

## Locked decisions (from parent + this round)

| | |
|---|---|
| Canvas package | **`vyuh_node_flow`** v0.27.3 (MIT). Has bezier/smoothstep/step edges + type-safe JSON ser/deser. We layer branching/loop/condition semantics on top via `team_spec.edges[].condition` field. |
| Existing `team_builder.dart` | **Deleted entirely.** New canvas is the only path. The 631-line Sprint 30 kanban UI goes away. |
| `team_proposal` message location | **`#general` only.** All one-off dispatches go through a `team_proposal` card in #general. The task channel is only created on Approve. |

## Backend changes

### 1. `team_spec` JSON: dual-format parser

Today's flat form (Sprint 22-29):

```json
{
  "agents": [
    {"role": "Coder", "model": "...", "spec": "...", "worker_affinity": "any"}
  ],
  "stages": [[0], [1]],
  "workflow": "sequential"
}
```

New nodes+edges form (Sprint 48):

```json
{
  "nodes": [
    {"id": "n1", "kind": "agent", "role": "Coder", "model": "...", "spec": "...", "worker_affinity": "any"},
    {"id": "n2", "kind": "agent", "role": "Reviewer", "spec": "..."},
    {"id": "out", "kind": "output"}
  ],
  "edges": [
    {"from": "n1", "to": "n2", "condition": "if_succeeded"},
    {"from": "n2", "to": "out"}
  ],
  "format": "nodes_v1"
}
```

- `team_spec_json` column on `tasks` accepts both forms during Sprint 48 (one-release deprecation window). Flat form is auto-converted to `nodes_v1` on first read via `team_spec_compat.normalize(spec) -> dict` helper added to `tally_orchestrator/team_spec_compat.py`.
- Format detection: presence of `"nodes"` key → nodes_v1; else → flat.
- `format` field is added to flat specs on conversion so downstream code can branch.
- Sprint 49 flat → nodes_v1 + flat form deprecated (warning logged on parse).

Edge conditions (Sprint 48):
- `"always"` (default) — fire on prior node completion regardless of status
- `"if_succeeded"` — fire only if prior node returned non-error
- `"if_failed"` — fire only if prior node returned error (loop back / fallback)
- `"if_returned": "X"` — fire if prior node's structured output matched X (future-use, parser accepts)

Edge metadata:
- `"max_iterations": N` — for self-loops or back-edges, caps re-runs of the cycle

Branch nodes (parallel fan-out) and loop nodes (back-edges) are **expressed via edge structure**, not separate node kinds. The orchestrator's executor (`_advance_task`) sees them as ordinary node→node edges with conditions; multiple outgoing edges from one node = parallel fan-out.

### 2. New task status: `proposed`

`tasks.status` enum extends from `pending|running|completed|failed|aborted|aborted_cost_cap|period_cap_reached` to also include `proposed` and `cancelled`.

- `proposed` — architect ran, team_spec generated, awaiting user approval. No agents dispatched yet. No worker resources consumed.
- `cancelled` — user explicitly cancelled the proposal. Terminal state. No dispatch.

Migration: idempotent — `status` is a TEXT column, no schema change needed. Code paths that filter by status need updates (e.g., quota counting only counts non-proposed/cancelled).

### 3. POST /tasks: defer dispatch behind approval

Today's flow:
```
POST /tasks {description, ...}
  → architect picks team_spec
  → INSERT INTO tasks (status='pending')
  → dispatch immediately
```

New flow (Sprint 48):
```
POST /tasks {description, ...}
  → architect picks team_spec
  → INSERT INTO tasks (status='proposed')
  → insert `team_proposal` message in #general channel
  → broadcast new_message WebSocket frame
  → return 200 {task_id, team_spec, status:'proposed'}
```

The `team_proposal` message has `kind='team_proposal'` with payload:

```json
{
  "task_id": "...",
  "description": "...",
  "team_spec": { /* nodes_v1 form */ },
  "options": [
    {"value": "approve", "label": "Approve & dispatch"},
    {"value": "edit", "label": "Edit in builder"},
    {"value": "cancel", "label": "Cancel"}
  ]
}
```

The Flutter MessageFeed (from Sprint 47 B4) renders `kind='team_proposal'` via a new `TeamProposalCard` widget that shows: description, team summary (agent count by role), 3 action buttons.

### 4. New endpoints

- `POST /tasks/{task_id}/approve` — transition `proposed` → `pending`, dispatch. Only the task owner (`tasks.user_id == caller`) may approve. 409 if status isn't `proposed`. 403 if not owner.
- `PATCH /tasks/{task_id}/team_spec` — update `team_spec_json`. Only valid when status='proposed'. Body: `{team_spec: {...nodes_v1...}}`. Owner-only. After update, re-broadcast the `team_proposal` message with the new spec.
- `POST /tasks/{task_id}/cancel` — transition `proposed` → `cancelled`. Owner-only. Updates the original `team_proposal` message's payload to mark it cancelled (UI grays out the buttons).

### 5. Workflow executor extension (nodes_v1 mode)

`Orchestrator._advance_task` currently follows the flat `stages` array (parallel within stage, sequential between stages). Sprint 48 extends it:

- If `team_spec.format == 'nodes_v1'`: traverse the node graph instead.
  - Find nodes with no incoming edges (entry points) → dispatch all in parallel.
  - On node completion, walk outgoing edges:
    - Evaluate `condition` against the just-completed node's result
    - For matching edges, mark target node ready to dispatch
    - Multiple matching outgoing edges = parallel fan-out
  - For back-edges with `max_iterations`: track iteration count per cycle in `agents.iteration_idx` (new column); refuse to dispatch beyond the cap.
- If `team_spec.format == 'flat'` (or no format key): existing flat executor unchanged.

Both executors share `mark_agent_completed`, `mark_agent_failed`, `set_task_worker` plumbing.

### Migration helper

`team_spec_compat.normalize(spec: dict) -> dict` converts flat → nodes_v1:

- For each stage `S` (index i), each agent `A` (position j): create a node with `id=f"s{i}a{j}"`, `kind='agent'`, copying role/model/spec/worker_affinity.
- For each agent in stage `i+1`: add edges from every agent in stage `i` (sequential between stages).
- For agents within a stage: no edges between them (parallel within stage = no edge = parallel by definition of the new executor).
- Append a single output node + edges from all final-stage agents.

This runs once on first read of an old task; the converted form is NOT persisted (so the original flat form is still readable for audit). Plan converts on-the-fly each time. Sprint 49 will add a one-time backfill that converts + persists.

### 6. New `messages.kind` value: `team_proposal`

Sprint 47 added `messages.kind` enum (text / interactive_prompt / interactive_prompt_response). Sprint 48 adds `team_proposal`. No schema migration — `kind` is TEXT.

## Frontend changes

### 1. `WorkflowEditorScreen` (new)

New route in `discord_shell.dart`: opens `WorkflowEditorScreen`. Accepts:

```dart
WorkflowEditorScreen({
  required TallyOrchClient client,
  required String taskId,
  required Map<String, dynamic> initialTeamSpec, // nodes_v1 form
})
```

Body uses `vyuh_node_flow`'s `FlowEditor` widget:

- **Node palette** (left rail): drag agent roles onto canvas. Roles list pulled from `GET /agent-roles?workspace_id=1` (existing endpoint from Sprint 40).
- **Canvas** (center): drag nodes, draw edges. Per-node config panel opens on tap: name, model, spec (TextArea), worker_affinity, tool_allowlist (chips).
- **Per-edge config**: condition dropdown (always / if_succeeded / if_failed / if_returned), max_iterations field (only if back-edge detected).
- **Top bar**: Save (calls `PATCH /tasks/{id}/team_spec`) → returns to #general. Cancel discards changes.
- **Output node**: terminal; always present; renamed visible-only.

Per the Sprint 47 cost-aware policy, the editor's Save button does NOT trigger dispatch — that requires user clicking Approve on the proposal card in #general.

### 2. `TeamProposalCard` widget (new)

Renders `messages.kind='team_proposal'`. Sits alongside `MessageBubble` and `InteractivePromptCard` in `MessageFeed`'s dispatch logic.

Shape:
- Card with task description, agent summary (e.g., "Coder → Reviewer → Tester"), 3 action buttons
- On `Approve`: POST `/tasks/{id}/approve` → close card / mark approved
- On `Edit`: push `WorkflowEditorScreen` with `taskId` + current spec → returns control to #general after save
- On `Cancel`: POST `/tasks/{id}/cancel` → mark cancelled

After Approve, the original card stays visible but disabled, and the task channel becomes accessible (the existing Sprint 47 `task` channel creation in `Db.create_task` already fires on insert; we move that hook to fire on approve instead, so the channel only exists for approved tasks).

### 3. Existing `team_builder.dart` removal

Delete `tally_coding_app/lib/screens/team_builder.dart` (631 lines). Update `discord_shell.dart` line ~175 to remove the navigation entry (the ⚙ tile on the server rail). The settings cog can still appear, but it routes to workspace settings (a Sprint 50 task) — for Sprint 48 it's hidden until Sprint 50 ships the settings screen.

### 4. `api.dart` additions

```dart
Future<Map<String, dynamic>> approveTask(String taskId);
Future<Map<String, dynamic>> updateTaskTeamSpec(String taskId, Map<String, dynamic> teamSpec);
Future<Map<String, dynamic>> cancelTask(String taskId);
```

All return the updated task row.

## Hook point changes

- **`Db.create_task` (Sprint 47 A12):** today inserts the task channel + owner channel_member inline. Sprint 48 moves that into a new method `Db.approve_task` so the channel exists only for approved tasks. `Db.create_task` keeps inserting the task row with status='proposed'.
- **`Tally architect agent` (Sprint 22-24):** today returns `team_spec` for immediate dispatch. Sprint 48: changes the `POST /tasks` handler that calls the architect to (a) skip the dispatch step (b) insert the `team_proposal` message instead. The architect itself is unchanged.

## Testing

### Backend

- `test_team_spec_compat.py` — flat → nodes_v1 conversion for 5 fixture team_specs (1-agent solo, 2-agent sequential, 3-agent two-stage parallel, 4-agent three-stage, real-world Sprint 30 template).
- `test_task_approval.py` — POST /tasks returns status='proposed'; POST /tasks/{id}/approve transitions to pending + dispatches; PATCH /tasks/{id}/team_spec updates spec only when proposed; POST /tasks/{id}/cancel transitions to cancelled.
- `test_team_proposal_message.py` — POST /tasks inserts `kind='team_proposal'` message in #general with the right payload; the message renders via the existing GET /channels/{id}/messages route.
- `test_workflow_executor_nodes_v1.py` — small graph (2 nodes, 1 edge) dispatched in nodes_v1 mode; edge condition `if_succeeded` skips failed branches; back-edge with `max_iterations=2` re-runs twice then stops.

### Flutter

- `test/workflow_editor_test.dart` — opens the editor with a fixture team_spec; drags a new node onto the canvas; adds an edge; saves; asserts the PATCH was called with the right body.
- `test/team_proposal_card_test.dart` — renders a `team_proposal` message; tapping Approve calls the right API.

## Verification

After Phala deploy:
- Submit a one-off task via the existing entry path
- Verify `#general` shows a TeamProposalCard with the architect's team
- Click Edit → editor opens with the team pre-loaded
- Drag a new agent node onto the canvas + connect it → click Save → returns to #general
- Click Approve → task moves to status=pending, task channel appears, dispatch fires
- Inspect that the task ran with the modified team_spec

## Out of scope (deferred to Sprint 49+)

- Persistent agents (cron + event triggers + Trigger nodes) — Sprint 49 will reuse this editor in a second context
- Loop-node UI affordance for back-edges — Sprint 48 supports the data model; the editor draws them as ordinary edges; a dedicated "loop" visual primitive can come later
- Flat-form deprecation warning (only logged in Sprint 49 once we're confident no flat-form tasks are being created)
- One-time persist-conversion of historical task team_specs to nodes_v1 (Sprint 49)

## Effort estimate

- **Backend:** ~20h
  - team_spec_compat + tests: 5h
  - POST/PATCH/POST endpoints + tests: 5h
  - Status enum + Db.create_task / approve_task split: 4h
  - team_proposal message insert + WebSocket broadcast: 2h
  - Workflow executor nodes_v1 mode + tests: 4h
- **Flutter:** ~25h
  - vyuh_node_flow integration + WorkflowEditorScreen: 12h
  - TeamProposalCard + MessageFeed dispatch wiring: 4h
  - api.dart additions + tests: 2h
  - Per-node + per-edge config panels: 5h
  - team_builder.dart removal + nav cleanup: 2h
- **Deploy/verify:** ~5h

**Total:** ~50h calendar, similar to Sprint 47.

## References

- Parent spec: [`2026-05-20-discord-shaped-workspace-design.md`](2026-05-20-discord-shaped-workspace-design.md)
- Sprint 47 complete: [`../../SPRINT-47-COMPLETE.md`](../../SPRINT-47-COMPLETE.md)
- vyuh_node_flow: https://pub.dev/packages/vyuh_node_flow
- Existing architect: `services/orchestrator/tally_orchestrator/service.py` (search `architect_team`)
- Existing executor: `services/orchestrator/tally_orchestrator/service.py` `Orchestrator._advance_task`
