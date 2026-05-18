# Sprint 30 — Visual team builder

**Status: PASS** — The ⚙ button on the server rail opens a Kanban-style
team builder.  Stages are columns; agents are cards inside a column;
agents in the same column run concurrently; stages run strictly in
order.  Same JSON shape as the architect's output — what you hand-build
here is exactly what Tally would emit.  The builder can save the team
as a template OR run a task with it directly.

This is not the full n8n drag-and-edge canvas the locked roadmap
sketched.  Kanban columns express the parallel-vs-sequential semantics
cleanly without the edge-routing complexity, and they're a clean place
to start; full edge-drawing can layer on later when the team graph
shape needs to express anything more elaborate than "stages of
parallel agents."

## What was built

### Backend (orch v9)

`POST /templates` gained a `team_spec` alternative source.  Previously
the only way to save a template was `source_task_id` (Sprint 29's
promotion-from-completed-task path); now the builder can save a
hand-built team straight in:

```http
POST /templates
{
  "name": "fizzbuzz-fast",
  "team_spec": {
    "agents": [{"role": "Coder", ...}, {"role": "Tester", ...}],
    "stages": [[0], [1]],
    "workflow": "Coder -> Tester",
    "reasoning": "hand-built"
  },
  "note": "When you want a quick build+test loop without planning"
}
```

`source_task_id` and `team_spec` are mutually exclusive (400 if both
present, 400 if neither).  Validator does a light shape check:
`agents` is a non-empty list of `{role: str, ...}` dicts.  The
architect's deeper validation still runs at task-dispatch time.

### Flutter

**`scripts/team_builder.dart` (new)** — full-screen builder with:
- Horizontal-scroll Kanban canvas; each stage is a 280px column.
- Per-stage header shows agent count + a delete button (when there
  are ≥2 stages).
- Per-agent card with role dropdown (sourced from `/admin/agent_roles`),
  spec textarea, worker_affinity dropdown, remove button.  Card's
  left border tints to the agent's role color (Planner purple,
  Coder green, etc. — matches the timeline bands).
- `+ Add agent` button at the bottom of each column.
- `+ Add stage` button to the right of the last column.
- Task-description input pinned to the bottom; required for **Run**.
- Toolbar: **Save as template** (POST /templates with team_spec) and
  **Run** (POST /tasks with team_spec preset; pops back to the shell
  and jumps to the new task channel).

**`screens/discord_shell.dart`** — server rail gains a ⚙ icon below
the team divider.  Tap → push the builder.  Builder pops back with
the dispatched Task; the shell refreshes the channel list and selects
the new task.

**`api.dart`** — `listAgentRoles()` (GET /admin/agent_roles),
`saveTemplate({sourceTaskId | teamSpec, name, note})`, and
`submitTask(description, {teamSpec})`.

## E2E validation (2026-05-18, ~00:46-00:51 UTC)

1. **Direct template save** (the builder's "Save as template" path):

```
POST /templates
  body: {name: builder-fizzbuzz, team_spec: {...Coder, Tester w/ affinity=local...}}
  → 200 {"name": "builder-fizzbuzz", "team_spec": ...}

POST /templates  (both source_task_id + team_spec set)
  → 400 "pass exactly one of source_task_id or team_spec"
```

2. **Builder Run path** — submit a task with a hand-built team_spec
   that bypasses the architect entirely:

```
POST /tasks
  body: {description: "write greet.py …",
         team_spec: {agents:[Coder, Reviewer], stages:[[0],[1]], …}}
  → task_id: 69cf346a08c2…
  → team_spec stored verbatim (no architect call)

orchestrator log:
  00:49:50  starting team for task 69cf346a: 2 agents, stage 0 = [Coder]
  00:50:05  Coder snapshot: 1 file; stage 0 → 1: dispatching [Reviewer]
  00:51:46  Reviewer snapshot: 2 files; team complete (+116s)
```

The orchestrator skipped the architect call (`reasoning` in the saved
task_spec is what the builder set, not what Tally would emit),
honoured the stages, dispatched to the right workers, and the task
completed normally.

## Open items

1. **No edit-existing-template path.**  Today the builder always
   starts empty.  A "load template" picker → builder pre-populated
   with the saved team would be nice; pairs naturally with adding a
   templates list screen.
2. **No drag-and-drop reordering.**  Agents within a stage are in
   insertion order, stages in their declared order; you remove +
   re-add to reshuffle.  Real DnD needs Flutter's `ReorderableList`,
   roughly half a day.
3. **No edge graph yet.**  The Kanban shape only expresses "all
   agents in stage N depend on all agents in stage N-1."  A true
   per-agent dependency graph (e.g. "agent 5 depends on 2 and 3 but
   not 1") needs the n8n-style canvas.  Punt until a real team
   demands it.
4. **No live syntax preview.**  The builder produces a `team_spec`
   JSON on Run/Save but doesn't show it inline.  An "Inspect JSON"
   collapsible panel is small + worth adding when the user wants
   to copy-paste or fine-tune.
5. **Roundtrip from saved-template-list to builder is missing.**
   Once a Sprint 31+ templates list view exists, "Edit in builder"
   becomes a natural action that closes this loop.

## Next sprint

**Sprint 31 — Mobile build.**  Flutter Android (iOS when a Mac is
available); slim monitor + interrupt surface (the builder probably
stays desktop-only because Kanban + dropdowns are painful on a
phone).  The shell and task channel translate naturally; the
members panel collapses to a sheet.
