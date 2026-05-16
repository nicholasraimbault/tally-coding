# Day 4 Spike: Multi-Agent Coordination Across Two Phala CVMs

Validates the full orchestrator → worker → OpenHands → response loop across two
independently deployed Phala CVMs, communicating exclusively through Tally Workers.

## Goal

Prove that two isolated CVMs can coordinate a real coding task with no direct
network path between them. The relay (Tally Workers) carries the task dispatch
and the result; neither CVM knows the other's IP.

## Architecture

```
orchestrator CVM                Tally Workers                  worker CVM
─────────────                  ─────────────                  ──────────
team_init()
dispatch_wake(task:start) ───► stores wake ◄─── read_inbox() (long-poll)
                                                decode payload
                                                OpenHands SDK runs
                                                  TerminalTool
                                                  FileEditorTool
                                                  TaskTrackerTool
                               complete_wake ◄── complete_wake(result)
dispatch_wake returns ◄────── stores response
decode response
print success/failure
```

The worker exits after handling one task. For repeat tests, redeploy the worker
CVM (or restart the container). This is the per-task ephemeral lifecycle (gap
B.16); a persistent pool model is a v0.2 concern.

## Prerequisites

- `phala login` authenticated
- `.env` file in both `worker/` and `orchestrator/` (see `.env.example` below)
- A `TEAM_ID` — generate one with `python -c "import uuid; print(uuid.uuid4())"`

### `.env.example` (worker)

```
TALLY_WORKERS_URL=https://tally.nraimbault16.workers.dev
TEAM_ID=<your-uuid>
REDPILL_API_KEY=<your-key>
REDPILL_BASE_URL=https://api.redpill.ai/v1
REDPILL_MODEL=moonshotai/Kimi-K2-6
```

### `.env.example` (orchestrator)

```
TALLY_WORKERS_URL=https://tally.nraimbault16.workers.dev
TEAM_ID=<same-uuid-as-worker>
WORKER_IDENTITY_B64=<copied-from-worker-logs>
TASK=Create greet.py that prints 'hello, world' and a test_greet.py with pytest. Install pytest, run it, report.
```

## Deploy: Worker CVM

```bash
cd spike/day4/worker
phala deploy -e .env --name spike-day4-worker
```

Watch the logs until you see the ready line:

```
[worker] ready; team=<team_id>; identity=<bearer-prefix>...
```

The full bearer token is the worker's `identity_b64`. Phala streams container
logs via `phala logs <app-id>`. Copy the 43-character bearer string — you need
it as `WORKER_IDENTITY_B64` for the orchestrator.

The worker then enters its long-poll loop, waiting for a `task:start` wake.

## Deploy: Orchestrator CVM

Once you have the worker's bearer:

```bash
cd spike/day4/orchestrator
WORKER_IDENTITY_B64=<copied-bearer> phala deploy -e .env --name spike-day4-orchestrator
```

Or add `WORKER_IDENTITY_B64` to the orchestrator `.env` before deploying.

## Verify

**Orchestrator logs** should show:
```
[orchestrator] dispatching task to worker=<prefix>...
[orchestrator] wake completed wake_id=<uuid>
[orchestrator] worker reported: {"success": true, "files_created": ["greet.py", "test_greet.py"]}
```

**Worker logs** should show:
```
[worker] received wake_id=<prefix>
[worker] task: Create greet.py that prints 'hello, world'...
[worker] completed wake_id=<prefix>; result={'success': True, ...}
```

Exit code 0 from the orchestrator = success. Exit code 1 = the worker reported
`success: false` (check worker logs for the error detail).

## Teardown

```bash
phala cvms delete <worker-app-id>
phala cvms delete <orchestrator-app-id>
```

App IDs are shown in `phala deploy` output and in `phala cvms list`.

## Notes

**Gap B.15 — CVM-to-CVM networking via Tally Workers:** The two CVMs never
communicate directly. All messages travel over the public internet through the
Tally Workers Cloudflare Worker. This is the intended architecture for v0.1:
neither party needs to know the other's address, and the relay provides the
delivery guarantee. Direct CVM-to-CVM transports (e.g., WireGuard mesh,
libp2p) are a future optimization, not a requirement.

**Gap B.16 — Per-task vs pooled worker lifecycle:** The worker as written exits
after completing one task (`return 0` at the end of `main()`). This is the
per-task ephemeral model: one CVM deployment per task invocation. For a v0.2
persistent pool, replace `return 0` with `continue` and add a graceful-shutdown
signal handler. The Tally Workers side is already stateless across tasks; the
change is purely in the worker loop.

**OpenHands SDK import paths:** `openhands.sdk`, `openhands.tools.terminal`,
`openhands.tools.file_editor`, and `openhands.tools.task_tracker` are the
expected module paths for `openhands-ai`. Verify against the installed version
if imports fail at container startup.
