# Sprint 27 — Parallel + branching workflows

**Status: PASS** — Tally's architect now emits a real
execution graph (`stages: list[list[int]]`), and the orchestrator
dispatches every agent in a stage concurrently, only advancing when
the whole stage is done.  The `Planner -> Coder -> (Reviewer ||
SecReviewer || Tester)` shape from the locked roadmap is now a thing
that runs, not just a thing that's documented.

## What was built

### Architect (`services/orchestrator/tally_orchestrator/architect.py`)

The system prompt teaches Tally about parallel execution and gives it
the schema:

```json
{
  "agents": [
    {"role": "Planner",  "spec": "..."},
    {"role": "Coder",    "spec": "..."},
    {"role": "Reviewer", "spec": "..."},
    {"role": "Tester",   "spec": "..."}
  ],
  "stages": [[0], [1], [2, 3]],
  "workflow": "Planner -> Coder -> (Reviewer || Tester)",
  "reasoning": "Reviewer and Tester both read the Coder's output but don't depend on each other; running them in parallel saves wall-time."
}
```

Validation (`_validate_stages`) enforces:
- every agent index appears exactly once across stages
- no negative / out-of-bounds / duplicate indices
- malformed → silently fall back to fully sequential

Backward compat: tasks without `stages` (Sprint 22-26 era) get a
synthetic `[[0], [1], …, [n-1]]` from `_resolve_stages` and run on
the same Sprint 22 codepath.

### Orchestrator (`tally_orchestrator/service.py`)

- `_resolve_stages(raw, n_agents)` mirrors the architect's validator
  as a backstop for hand-crafted team_specs and old DB rows.
- `_start_team` resolves the stages, picks `stages[0]`, fires
  `asyncio.create_task(self._dispatch_agent(...))` for every agent
  in that stage. With pool ≥ 2 they truly run in parallel; with pool
  = 1 they serialize through the worker (`acquire_idle` queues them)
  — the *graph* is parallel even when the *resource* is not.
- `_handle_result_event` now does stage-aware advancement: when an
  agent completes, look up its stage, check if *every* index in that
  stage has terminal status, and only then dispatch the next stage's
  agents.  Failures inside a stage still short-circuit the task.
- Sprint 27 defense: when a result event arrives without
  `agent_idx` on a multi-agent task with running agents, the
  orchestrator attributes it to the running agent on that worker
  instead of taking the legacy single-agent path (which would
  prematurely mark the task `completed`).
- Sprint 27 defense: when a result event arrives for a task that's
  already `completed`/`failed` (typical for late-arriving siblings
  of a failed parallel agent), record the agent row but don't
  re-aggregate or re-dispatch.

### Worker (`spike/day4/worker/worker_spike.py`)

Bug fix: the `except Exception` path was overwriting the entire
result dict, dropping `agent_idx` / `agent_role`.  A multi-agent
agent crashing (e.g., model name not available on Red Pill) would
then take the orchestrator's single-agent legacy path and mark the
whole task completed.  Fixed by re-stamping agent attribution after
the failure result is constructed.

Worker image: `tally-spike-day4-worker:v15`.

### Re-deploy

- Orchestrator image: `tally-orch:v5`.
- `worker_pool.BASE_IMAGE` → `v15`; `DEPLOY_TAG_PREFIX_V14` archived
  alongside the older Vn prefixes (Sprint 17 GC policy preserves them
  for cleanup of leftover per-deploy tags).
- CVM rolled to v5 in-place via `phala deploy --cvm-id …` (~64s).
- Pinned worker reseeded (`scripts/seed-cvm-orchestrator-env.py`)
  against v15; previous v14 worker `phala cvms delete`'d.

## E2E validation (2026-05-17, 23:00-23:03 CDT)

Submitted: *"Write a simple Python module greeting.py with hello()
and goodbye(), then have two reviewers check it in parallel: one for
code style and one for correctness."*

Tally architect picked:

```json
{
  "agents": ["Planner", "Coder", "Reviewer", "Reviewer"],
  "stages": [[0], [1], [2, 3]],
  "workflow": "Planner -> Coder -> (Reviewer || Reviewer)"
}
```

Orchestrator dispatch log (task `888dd1e4`):

```
23:00:57  starting team for task 888dd1e4: 4 agents, stage 0 = [Planner]
23:01:22  Planner snapshot: 1 file
23:01:22  stage 0 → 1: dispatching [Coder]
23:01:46  Coder snapshot: 2 files
23:01:46  stage 1 → 2: dispatching [Reviewer, Reviewer]   ← parallel!
23:01:46  dispatching agent 2/Reviewer  (got the worker first)
23:02:35  agent 2 (Reviewer) completed
          dispatching agent 3/Reviewer  (acquired after #2 finished)
23:03:38  agent 3 (Reviewer) completed
23:03:38  task 888dd1e4 team complete: 4 agents, 3 artifact(s)
```

The two `Reviewer` agents were dispatched in one `asyncio.gather`-like
fan-out at the stage 1→2 boundary; with `pool=1` they serialized
through the worker (Reviewer #2 was queued on `acquire_idle` while #1
held the in-flight slot). With pool=2 they'd genuinely overlap, but
the *graph* is parallel either way.

Worker logs (Reviewer #1) confirmed the seed:

```
[worker] task 888dd1e4 (decrypted): Write a simple Python module greeting.py …
[worker] agent role=Reviewer model=moonshotai/kimi-k2.6
[worker] seeded 2 file(s) from prior agents          ← Planner + Coder outputs
```

Stage-aware advancement: after Reviewer #1 (agent 2) completed at
23:02:35, the orchestrator did NOT advance to a non-existent "stage
3" — it correctly identified that stage 2 still had agent 3 pending
and stayed put.  Only when Reviewer #2 (agent 3) completed at
23:03:38 did the team finalize.

## Open items

1. **Pool=1 serializes parallel stages.**  With a single pinned worker
   in the hosted CVM, two parallel agents take turns through
   `acquire_idle` rather than running concurrently — the parallelism
   is declarative, not behavioural, under that resource constraint.
   Sprint 28+ (local-worker daemon) and a pool=N CVM topology give
   real concurrency.  TALLY_ACQUIRE_TIMEOUT may need bumping in the
   CVM env for stages with N≥3 agents.
2. **No CRDT merge semantics yet.**  Parallel agents writing the
   *same path* (e.g. both Reviewers writing `review.md`) hit
   `_task_artifacts` last-write-wins.  For disjoint workspaces
   (frontend/* vs backend/*) this is fine; for overlapping work it's
   the wrong primitive.  Full Skytale SharedContext (CRDT + HLC) is
   on the roadmap when this stops being acceptable.
3. **UI still renders agents in `agent_idx` order.**  Two parallel
   agents both look "working…" but the visual cue that they're a
   stage (not a sequence) is missing.  Sprint 30's visual team
   builder will surface stage boundaries.

## Next sprint

**Sprint 28 — Local-worker daemon.**  `tally-agent --install` drops a
systemd user unit + a wake-bearer keypair on the user's box; the
daemon registers as a worker so the orchestrator can place agents
with `worker_affinity: local_if_available` (e.g., Tester runs against
the user's real env). Same MLS handshake, same wake-driven RPC; new
opt-in path for environment-integrated agents.
