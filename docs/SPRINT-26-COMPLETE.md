# Sprint 26 — Workspace artifact passing

**Status: PASS** — Each agent now sees the *team's* accumulated
workspace, not just its own.  The orchestrator collects every agent's
file output into an in-memory artifact map, then seeds the next agent's
workspace from it via the existing MLS-encrypted task wake.

The agents stop pretending they're working in a vacuum: Coder reads the
plan.md the Planner wrote; Reviewer reads the actual code the Coder
wrote; Tester runs against the code in front of it.

## Why this isn't full Skytale SharedContext yet

The locked architecture in `memory/project_tally_coding_architecture.md`
calls for SharedContext (CRDT + HLC + write policies) as the artifact
substrate.  We landed the *protocol* — orchestrator-mediated artifact
flow over MLS, identical confidentiality properties — but skipped the
CRDT semantics for now because the current workflow is strictly
sequential (`A → B → C`, no concurrent writers).  Sprint 27 introduces
parallel workflows (`A → (B || C) → D`), and *that* is when CRDT
merge semantics become load-bearing.  Until then, last-writer-wins is
correct, and the orchestrator's `_task_artifacts[task_id]` dict is
indistinguishable from a SharedContext snapshot from the outside.

## What was built

### Worker (`spike/day4/worker/worker_spike.py`)

- `_materialize_seed_files(workspace, seed_files)` — write the
  orchestrator-supplied `{path: base64_content}` dict into the agent's
  workspace before OpenHands runs.  Per-file cap 256 KB; path
  traversal blocked; skipped path segments (`.git`, `__pycache__`,
  etc.) silently dropped.
- `_snapshot_workspace(workspace)` — after OpenHands returns, read
  every file in the workspace, base64-encode, return as
  `{relative_path: b64}`.  Per-file cap 256 KB; total cap 2 MB per
  agent.
- `handle_task_wake`: reads `seed_files` from the decrypted task
  spec; calls `_materialize_seed_files` before `perform_task`; calls
  `_snapshot_workspace` after and attaches `files_b64` to the
  result (multi-agent runs only — legacy single-agent path skips).
- Worker image bumped to `v14`
  (`ghcr.io/nicholasraimbault/tally-spike-day4-worker:v14`).

### Orchestrator (`services/orchestrator/tally_orchestrator/service.py`)

- `Orchestrator._task_artifacts: dict[str, dict[str, str]]` — per-task
  accumulator of `{path: base64_content}`.  In-memory only;
  cleared on task terminal (completed/failed).
- `_dispatch_agent` payload now includes
  `seed_files=self._task_artifacts.get(task_id, {})`.
- `_handle_result_event` pops `files_b64` off the result dict
  *before* persisting (the SQLite row stays small) and merges into
  `_task_artifacts[task_id]`.  Logs the running artifact count.
- Orchestrator image bumped to `v3`
  (`ghcr.io/nicholasraimbault/tally-orch:v3`).
- `worker_pool.BASE_IMAGE` bumped to `v14`; deploy-tag prefix
  rotated from `v13-tally-auto-` to `v14-tally-auto-` (Sprint 17 GC
  policy preserves the old prefix as `DEPLOY_TAG_PREFIX_V13`).

### Seed script (`scripts/seed-cvm-orchestrator-env.py`)

Now preserves any existing `.env.prod` values for `TALLY_API_TOKEN`
(so the Flutter app's bearer doesn't change across re-seeds) and
`CF_TUNNEL_TOKEN` (Sprint 24 ingress).  Without this, every worker
re-seed silently broke the prod URL and rotated the API token.

## E2E validation (2026-05-17, 22:38-22:41 CDT)

Task `26e21b63` — *"write primes.py with is_prime(n). Add a small
pytest that checks primes up to 20 and runs."*  Tally picked a 4-agent
team (Planner → Coder → Reviewer → Tester).

Orchestrator log per agent (snapshot count = artifacts in team
workspace after that agent):

```
22:38:05  Planner   dispatched
22:38:29  Planner   snapshot: 1 file(s); team artifacts now=1      (+24s)
22:38:29  Coder     dispatched (seeded with 1 file)
22:39:11  Coder     snapshot: 3 file(s); team artifacts now=3      (+42s)
22:39:11  Reviewer  dispatched (seeded with 3 files)
22:40:19  Reviewer  snapshot: 4 file(s); team artifacts now=4      (+68s)
22:40:19  Tester    dispatched (seeded with 4 files)
22:41:17  Tester    snapshot: 5 file(s); team artifacts now=5      (+58s)
22:41:17  team complete: 4 agents, 5 artifact(s) accumulated
```

Total wall-time: 3 min 12 s (~7% slower than Sprint 25's stateless
pattern; the slowdown is the seed/snapshot serialization, well within
the per-agent budget).

**The killer test** — the Tester emitted this to its OpenHands chat:

> All 21 parametrized tests in `test_primes.py` (covering integers 0–20)
> passed successfully. The `tests.md` file has been created with the full
> pass/fail counts and test output.

It couldn't have done that without the Coder's `primes.py` + `test_primes.py`
in its workspace.  Before Sprint 26 the Tester had nothing to run; now
the seed materializes those files, OpenHands sees them, pytest sees
them, the test count is *real*.

Worker log confirming the seed/snapshot symmetry:

```
[worker] task 26e21b63 (decrypted): write primes.py …
[worker] agent role=Coder model=moonshotai/kimi-k2.6
[worker] seeded 1 file(s) from prior agents          ← Planner's plan.md
…
[worker] snapshot: 3 file(s), 7124 b64 bytes          ← Coder's outputs
…
[worker] snapshot: 5 file(s), 6988 b64 bytes          ← Tester's tests.md added
```

Worker image: `tally-spike-day4-worker:v14`.  Orchestrator image:
`tally-orch:v3`.  Both deployed in-place to the existing CVM via
`phala deploy --cvm-id …` (~55s rolling update).  Old v13 worker
retired (`phala cvms delete`).

## Open items

1. **Snapshot replay on orchestrator restart.**  The artifact map is
   in-memory.  If the orchestrator restarts mid-task, the artifact
   map is empty and the next agent gets no seed.  The result events
   that *were* persisted in SQLite still have `files_b64` stripped
   (we drop them before persist).  The right answer: write a
   compact rebuild on lifespan boot that re-runs through the
   agents' result rows and rehydrates the artifact map.  Punt to
   Sprint 26.5 — restart-mid-task is rare and the worst case is the
   in-flight task getting a poorer-quality seed.

2. **No file-aware UI yet.**  The Flutter app shows
   `files_created` (just names) per agent.  Showing the per-agent
   diff (this agent added X, modified Y) would land naturally
   alongside Sprint 30's visual team builder.

3. **Binary files passed verbatim.**  Base64 is content-agnostic
   but image/PDF/etc. files balloon the wake size fast.  The 2 MB
   total-per-agent cap is the safety net; a future refinement can
   route binary artifacts through a separate transport (Skytale
   blob channel) and pass only the manifest through the wake.

## Next sprint

**Sprint 27 — Parallel + branching workflows.**  Tally's architect
already supports `A || B` notation in its system prompt; Sprint 27
wires up the dispatcher to actually run two agents concurrently
against a forked workspace and merge the snapshots (this is where
the SharedContext CRDT semantics start to matter for real).
