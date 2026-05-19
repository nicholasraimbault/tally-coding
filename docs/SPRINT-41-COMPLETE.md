# Sprint 41 — Multi-task workflows (architect chains tasks)

**Status: PASS** — Tasks can now be branched off completed
predecessor tasks.  A child task's first agent inherits the
parent's final artifact set as `seed_files`, so users can build
iterative pipelines (do A, then build on A's output with B,
then build on B with C…).  Validated end-to-end against
`tally-orch:v23`: parent wrote `parent.txt` ("hello"), child
hydrated 1 file from parent, modified to "hello world", landed.

Persistent projects (S37) handle the cross-task case "iterate
inside a long-lived workspace".  S41 adds the orthogonal axis:
**branch a fresh thread of work from any completed task**,
regardless of project membership.

## What shipped

### Orchestrator (`tally-orch:v23`)

**Schema (additive, idempotent).**

```sql
CREATE TABLE IF NOT EXISTS task_dependencies (
    parent_task_id TEXT NOT NULL,
    child_task_id  TEXT NOT NULL,
    created_at     REAL NOT NULL,
    PRIMARY KEY (parent_task_id, child_task_id),
    FOREIGN KEY (parent_task_id) REFERENCES tasks(id),
    FOREIGN KEY (child_task_id)  REFERENCES tasks(id)
);
CREATE INDEX idx_task_deps_parent ON task_dependencies(parent_task_id);
CREATE INDEX idx_task_deps_child  ON task_dependencies(child_task_id);
```

A task has at most one parent in this model (we enforce by
convention — the schema supports many-to-many).  A task can
have arbitrarily many children — fan-out is fine.

**Db helpers.**

| Method | Behaviour |
|---|---|
| `link_tasks(parent_task_id, child_task_id)` | Insert (or no-op on duplicate) the parent → child edge. |
| `get_parent_task_id(task_id)` | First parent (None if no row). |
| `list_child_task_ids(parent_task_id)` | All children in created-at order. |

**Seed-file hydration priority (refactored `_seed_files_for_task`):**

1. In-memory `_task_artifacts[task_id]` — set by a prior agent in
   the same task (Sprint 26).
2. **Parent task's final artifacts** (Sprint 41) — when a
   `task_dependencies` row points at a successful parent.  Reads
   from the durable `task_artifacts` table (kept around on
   successful completion as of S41, per the new retention
   policy below).
3. Project HEAD (Sprint 37) — when the task belongs to a project
   AND has no parent.
4. Empty dict.

**Retention change.**  Pre-S41: `task_artifacts` rows for a
completed task were deleted right after the per-project merge
(Sprint 26.5 / Sprint 37).  Post-S41: deletion only happens on
*failed* tasks.  Successful tasks keep their artifact set
indefinitely so they can seed future children.  Storage cost
bounded by Sprint 26's per-task artifact caps; a sweeper
("delete completed-task artifacts after N days with no
children") is a clean future optimisation.

**`TaskSubmit` + `TaskResponse` model.**

- `TaskSubmit.parent_task_id: str | None = None` — submit-time
  link.  Validated:
    - parent must exist + be owned by caller (or admin),
    - parent must be in status `completed` (in-flight parents
      would race the child's seed hydration).
- `TaskResponse.parent_task_id: str | None` + `child_task_ids:
  list[str] = []` — enrichment fields populated on response
  build for `POST /tasks` and `GET /tasks/{id}`.

Logs the link at INFO so the operator can see "task X linked
as child of parent=Y" + "task X: hydrated N file(s) from parent
task=Y".

### Flutter (`tally_coding_app`)

**`lib/api.dart`.**  `submitTask` gains a `parentTaskId` named
arg.  `Task` model adds `parentTaskId` + `childTaskIds`.

**`lib/screens/task_channel.dart`.**

- `_HeaderTrailing` now renders a **🔀 Branch this task** icon
  alongside the existing **🔖 Save as template** + status badge.
  Visible only when `task.status == 'completed'`.
- `_BranchTaskDialog`: shows the parent's description as context,
  asks the user for the new task description, submits with
  `parentTaskId: parent.id` + inherits `projectId` from the
  parent (so the child still lives in the same project if any).

## E2E validation (2026-05-19, ~23:22 UTC against `tally.pronoic.dev`)

```
1. POST /tasks {description: "write parent.txt that says hello", team_spec={Coder}}
   → parent 2c663b4a… submitted

2. Wait for parent to complete.
   23:22:22  parent task done; team_artifacts.parent.txt = "hello" (5 bytes)

3. POST /tasks {description: "read parent.txt and append world",
                parent_task_id: 2c663b4a..., team_spec={Coder}}
   → child fafdec60… submitted

   orchestrator log:
   23:22:31  task fafdec60 linked as child of parent=2c663b4a
   23:22:31  task fafdec60: hydrated 1 file(s) from parent task=2c663b4a

4. Wait for child to complete.
   23:22:38  child done; team_artifacts.parent.txt = "hello world" (11 bytes)

5. GET /tasks/{parent_id}/files → ["parent.txt" 5 bytes]
   GET /tasks/{child_id}/files  → ["parent.txt" 11 bytes]
```

End-to-end multi-task workflow verified: child inherited parent's
file, modified it, and produced a new artifact set.  The whole
chain takes ~16 seconds (parent ~9s + child ~7s on the warm pool).

## Open items

1. **Multi-parent fan-in.**  Schema supports it; submit endpoint
   doesn't yet take a list.  When a user wants to "merge
   workspaces from two branches", we'd accept `parent_task_ids:
   [...]` and merge artifacts before seeding — last-writer-wins
   per path (matches S26 semantics).
2. **Architect picks the parent.**  Today the user supplies
   `parent_task_id` explicitly via the branch dialog.  A future
   "Tally, what should we do next?" architect call could read
   the workspace + suggest a child task with a sensible
   description.  Likely surfaces as a button on the task channel
   that pre-fills the branch dialog with the architect's
   suggested description.
3. **Artifact retention sweeper.**  Successful tasks keep their
   `task_artifacts` rows forever now.  At scale that's worth
   trimming — sweep tasks with no children + completion older
   than e.g. 30 days.  No urgency until storage shows up in the
   ops dashboard.
4. **DAG visualisation in the channel list.**  Today the channel
   sidebar lists tasks in flat reverse-chrono order regardless of
   parent / child.  A small indent + line for branched threads
   would help long-running projects with many tasks.

## Next sprint

**S42 — smarter LLM routing.**  Architect picks model per agent
based on task complexity (easy → llama-3.3-70b, hard → kimi /
deepseek-r1).  Direct margin win on Red Pill spend now that the
S39 cost dashboard makes the savings visible.
