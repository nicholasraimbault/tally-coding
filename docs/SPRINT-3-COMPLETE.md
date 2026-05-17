# Sprint 3 — Long-lived worker + orchestration service + CLI

**Status: PASS** — 3 sequential OpenHands tasks completed end-to-end in ~110 s
total over one long-lived Phala TEE worker CVM, all dispatched via the new
`tally-orch` HTTP service and `tally` CLI, all transported as MLS ciphertext.

## What was validated

The Sprint 2 architecture was per-task: spin up a worker CVM, run one task,
tear it down. Each task paid ~2 min provision + ~30 s container start + ~30 s
spike before any work happened. Sprint 3 flips this:

- **One** long-lived worker CVM, multi-task, MLS session reused across all tasks
- **One** orchestrator service holds the MLS session, exposes HTTP `/tasks`
- Tasks queued in SQLite, processed serially by a background asyncio task
  (serialization required because MlsEngine's sender ratchet is stateful)
- CLI talks to the service over HTTP — same UX whether the service is local
  or remote

Three tasks of increasing complexity ran back-to-back:

| Task ID | Description | Runtime | Files |
|---|---|---|---|
| `170a0f8de5` | hello.py + pytest | ~30 s | hello.py, test_hello.py |
| `118310e576` | fibonacci.py with fib(n) + 3 pytest cases | ~40 s | fibonacci.py, test_fibonacci.py |
| `2abf03ccf2` | wordcount.py reading stdin + pytest | ~45 s | wordcount.py, test_wordcount.py |

All 3: `success: True`, pytest green. No worker re-bootstrap between them —
single MLS session amortized the bootstrap cost across 3 tasks (and could
amortize across N).

## Components

```
tally-coding/
  spike/day4/worker/worker_spike.py    ← long-lived loop (no exit after task)
  services/orchestrator/
    tally_orchestrator/
      service.py                       ← FastAPI app + background processor
      cli.py                           ← `tally task ...`
    pyproject.toml                     ← editable deps on local
                                         tally_coding_core + skytale-sdk
```

### `service.py` lifecycle

1. **Lifespan startup**: reads env (TEAM_ID, WORKER_IDENTITY_B64, paths)
2. **MLS bootstrap** (offloaded to thread since dispatch_wake is blocking):
   - `mls:bootstrap {phase: request_kp}` → worker returns KeyPackage
   - `MlsSession.create_and_add(kp)` → Welcome
   - `mls:bootstrap {phase: welcome, welcome: ...}` → worker joins
3. **Processor loop**: poll SQLite `tasks` table for `pending`, take one,
   encrypt → `dispatch_wake(task:start, ...)` → decrypt response → mark
   completed/failed. Serial by `asyncio.Lock`.
4. **HTTP endpoints** (FastAPI):
   - `POST /tasks {description}` → enqueue, return 201 with task_id immediately
   - `GET /tasks/{id}` → status + result
   - `GET /tasks?limit=N` → recent N
   - `GET /health`

### `cli.py` — `tally` command

```
tally task submit "<description>" [--tail]
tally task list
tally task get <id>
tally task tail <id>
```

`tally task submit --tail` blocks and polls `GET /tasks/{id}` every 2 s until
status flips to `completed` or `failed`, then prints the result JSON.

### Wire-level: what tally-workers saw

Bootstrap (2 plaintext wakes, public MLS artifacts only):
- `mls:bootstrap {"phase":"request_kp"}` → response carrying the worker's
  310-byte KeyPackage
- `mls:bootstrap {"phase":"welcome","welcome":"..."}` (780 byte Welcome) →
  `{"ok":true}`

Per task (1 MLS-encrypted wake, ciphertext only):
- `task:start` with payload = ~290–400 bytes of MLS ciphertext. Tally Workers
  never sees the task description in plaintext.

## Bootstrap timing

```
22:21:14.055  bootstrapping MLS session
22:21:14.411  HTTP 200 /teams/.../init                (356 ms)
22:21:14.717  HTTP 200 /teams/.../wakes (request_kp)  (306 ms)
22:21:14.719  created MLS group (no InvalidLifetime retry needed this run)
22:21:15.127  HTTP 200 /teams/.../wakes (welcome)     (408 ms)
22:21:15.128  MLS session established
22:21:15.128  ready; processor loop started
```

Total bootstrap: **1.07 s** wall-clock from "bootstrapping" to "ready."
(Worker had been running ~10 min before service start, so its KeyPackage
was well past `not_before`; no clock-skew retry triggered.)

## Per-task timing (cold MLS session is reused)

```
22:21:46.x   3 tasks submitted via CLI (instant 201 each; queued in SQLite)
22:22:09     task 1 completed                       (~30 s total inc dispatch + agent)
22:22:48     task 2 completed                       (~39 s)
22:23:33     task 3 completed                       (~45 s)
```

vs. Sprint 2 / Day 4 (per-task CVM): each task would have cost ~3-5 min just
for the CVM cold-start. Sprint 3 collapses that to seconds per task once a
worker is warm.

## Cost

- One worker CVM (~tdx.small) running ~15 min for the spike: ~$0.015
- Sprint 3 total spend on Phala: ~$0.02
- Orchestrator service runs locally; no cloud cost

## Files changed

- `spike/day4/worker/worker_spike.py`: removed the post-task `return 0`;
  each task now uses a per-wake `/workspace/task-<wake_id[:12]>/` subdir
- `services/orchestrator/`: new directory, ~280 LoC of Python
- `spike/day4/worker/docker-compose.yml`: image bumped to
  `ghcr.io/nicholasraimbault/tally-spike-day4-worker:v5`

## Open items

1. **Service auth**: `POST /tasks` is unauthenticated. Fine for `127.0.0.1`
   single-user; Sprint 4 wires Clerk (GitHub OAuth) when exposing remotely.
2. **Worker pool**: still one worker per service. Sprint 5 candidate: a pool
   manager that maintains N warm workers + load-balances across MLS groups.
3. **State**: SQLite is local. Sprint 4 candidate: swap for Convex for
   multi-device sync.
4. **MLS session rotation**: the orchestrator's session never rotates. For
   long-running services, periodic key rotation + member churn become
   relevant (the `MlsEngine` API supports both; just not wired here).
5. **CVM lifecycle**: still manual `phala deploy` per worker. Sprint 5 also
   covers pool provisioning automation.

## Next sprint candidates (in priority order)

1. **Flutter UI** wired to `tally-orch` over HTTP — first product surface
2. **Clerk auth** in front of `tally-orch` POST endpoints
3. **Convex** for task state (replaces SQLite, enables multi-device)
4. **Worker pool** for concurrent users / faster cold-warm
