# Sprint 18 — Persisted result wakes: recover task results after orchestrator crash

**Status: PASS** — Killed the orchestrator mid-task; on respawn the
task transitioned to a new `recovering` state, the worker finished its
OpenHands run on the other side, pushed the result as a `kind=result`
event wake, the orchestrator decrypted it and transitioned the task to
`completed`. End-to-end recovery from a hard kill, with the task's
actual result intact (not lost like Sprint 15's "demote to failed").

## What was built

### Worker emits result as a `kind=result` event (in addition to the synchronous response)

`worker_spike.py / handle_task_wake`: after `perform_task` finishes,
push the result onto the streaming-event queue *before* returning the
encrypted result for the synchronous `complete_wake` response.

```python
# inside handle_task_wake, finally block
if emitter_thread is not None and orchestrator_bearer:
    event_queue.put({"kind": "result", "task_id": task_id, "result": result})
    event_queue.put(_EMITTER_SHUTDOWN)
    emitter_thread.join(timeout=15)
return session.encrypt(json.dumps(result).encode("utf-8"))
```

tally-workers retains undelivered wakes at-least-once until the
recipient acks via `complete_wake` — so the result event survives an
arbitrarily long orchestrator downtime. Image bumped to `v11`.

### `recovering` task status

Sprint 15 had `recover_stuck_running` demote `running` → `failed`
immediately on startup. Sprint 18 turns it into a transient state:
`running` → `recovering`. The processor loop still ignores it (only
`pending` rows get dispatched), but the event poller and the new
recovery sweeper can act on it.

```python
def recover_stuck_running(self, _unused="") -> int:
    cursor = self._conn.execute(
        "UPDATE tasks SET status='recovering', updated_at=? "
        "WHERE status='running'", (time.time(),))
    return cursor.rowcount or 0

def mark_recovered(self, task_id: str, result: dict) -> bool:
    cursor = self._conn.execute(
        "UPDATE tasks SET status='completed', result_json=?, updated_at=? "
        "WHERE id=? AND status IN ('recovering','running')",
        (json.dumps(result), time.time(), task_id))
    return (cursor.rowcount or 0) > 0
```

`mark_recovered` is guarded — if the task is already completed
(synchronous-response path arrived first), it's a no-op. Idempotent
across the inevitable duplicate event deliveries.

### Event poller routes `kind=result` to `mark_recovered`

```python
if event.get("kind") == "result":
    task_id = inner.get("task_id", "")
    result = event.get("result", {})
    recovered = self.db.mark_recovered(task_id, result)
    if recovered:
        logger.info("recovered task %s via result event from worker %s",
                    task_id[:8], worker_identity[:8])
```

### Recovery sweeper: stale `recovering` → `failed`

If the worker *also* crashed during the orchestrator's downtime, no
result event will arrive. A background task demotes any `recovering`
row older than `TALLY_RECOVERY_TIMEOUT` (default 300s) to `failed` so
the row doesn't lie forever:

```python
async def run_recovery_sweeper(self):
    timeout_s = float(os.environ.get("TALLY_RECOVERY_TIMEOUT", "300"))
    while True:
        n = self.db.sweep_recovering(timeout_s, "no result event arrived ...")
        if n: logger.warning("recovery sweeper demoted %d ...", n)
        await asyncio.sleep(60)
```

### Bootstrap timeout: 60s → 240s

Sprint 14's `bootstrap_handle` used `timeout_seconds=60` for each of
the 3 handshake wakes. With the new orchestrator-restart-against-
busy-worker scenario, the worker's main loop is mid-task and won't
pop the handshake wake from its inbox for up to ~60-90 seconds.
Bumping to 240s gives comfortable headroom and keeps Sprint 15's
"retire-on-bootstrap-failure" path from firing during a normal
restart-mid-task.

### `tally` CLI: `recovering` status icon

```python
icons = {"pending": "·", "running": "▸", "recovering": "↻",
         "completed": "✓", "failed": "✗"}
```

## E2E validation (13:06-13:08 CDT 2026-05-17)

```
13:06:35  service started; pool=1; identity=pp3mqGJ4 on team ...-457a19
13:07:04  submitted task 2ec9bc3e ("write fact.py + pytest test")
13:07:04  task 2ec9bc3e → running on worker pp3mqGJ4
13:07:04  systemctl --user kill -SIGKILL tally-orch
13:07:07  service auto-restart; transitioned 1 stuck running task(s)
          to recovering on startup
13:07:08  bootstrap[pp3mqGJ4]: requesting worker key package
          (worker is busy finishing OpenHands; handshake wake sits
           in its inbox)
13:07:53  bootstrap[pp3mqGJ4]: MLS session established
          (worker finished its task, popped the handshake wake,
           re-joined the new MLS group)
13:07:58  recovered task 2ec9bc3e via result event from worker pp3mqGJ4
```

Final DB:

```
2ec9bc3e | completed | pp3mqGJ49juP | 54.7s | (no error)
```

Result JSON contains the `files_created` list with `fact.py` and
`test_fact.py` — the worker's actual work product, intact, after a
SIGKILL of the orchestrator.

## Files committed

- `services/orchestrator/tally_orchestrator/service.py`:
  - `Db.recover_stuck_running` → returns rows transitioned to
    `recovering` instead of `failed`.
  - `Db.mark_recovered(task_id, result)` — idempotent
    recovering/running → completed transition.
  - `Db.sweep_recovering(older_than_seconds, error)` — demote stale
    recovering rows.
  - `Orchestrator.run_recovery_sweeper()` — periodic background loop
    invoking sweep_recovering.
  - Event poller decodes `kind=result` events and calls
    `mark_recovered`.
  - `bootstrap_handle` timeout 60s → 240s for handshake wakes.
  - Lifespan starts the sweeper alongside the processor loop;
    shutdown cancels both.
- `services/orchestrator/tally_orchestrator/cli.py`:
  - `fmt_status` icon for `recovering`.
- `spike/day4/worker/worker_spike.py`:
  - `handle_task_wake` pushes `kind=result` event onto event_queue
    before the synchronous return. Also wraps `perform_task` in a
    try/except so a raised exception still produces a result event
    (a `{"success": False, "error": ...}` shape) for the recovery
    path.
- `spike/day4/worker/Dockerfile`:
  - `SKYTALE_BRANCH` default `feat/py-mls-engine` → `master` (the PR
    landed; the old branch is gone).
- `spike/day4/worker/docker-compose.yml`:
  - Image tag `v10` → `v11`.
- `services/orchestrator/tally_orchestrator/worker_pool.py`:
  - `BASE_IMAGE` constant `v10` → `v11`.
  - `DEPLOY_TAG_PREFIX_V10` retained for Sprint 17 GC compatibility;
    `DEPLOY_TAG_PREFIX` now `v11-tally-auto-`.
  - `gc_image_versions` recognizes both prefixes.

New worker image `ghcr.io/nicholasraimbault/tally-spike-day4-worker:v11`
pushed to GHCR.

## Open items

1. **The synchronous-response path is now redundant.** Both the
   `complete_wake` response and the `kind=result` event carry the
   same encrypted result. We could drop the synchronous response
   entirely and rely solely on the event path — that would remove the
   dispatch_wake `timeout_seconds=300` flag and let task dispatch
   become a fire-and-forget ack. Punt because backward-compat is fine
   for now and the dual path is what gives us the "running" → quick
   transition for the UI.
2. **`_bootstrapped` flag isn't persisted across restarts.** A probe
   tried at `bootstrap_handle` to skip the handshake when MLS state
   was already on disk; the probe failed with "group not found"
   because Skytale's `MlsEngine.encrypt` doesn't auto-resume the
   group object from disk without an explicit `create_group` /
   `join_from_welcome` call. The 240s handshake timeout works around
   this in practice, but ideally `MlsEngine` would offer a
   `load_group` entry point. Skytale-side change; future sprint.
3. **Result events from the previous epoch can't be decrypted.** If a
   worker emitted a result event with the *old* MLS group (before the
   orchestrator-restart-induced rekey), Sprint 15's
   ack-and-skip handles it gracefully but the task stays
   `recovering` until the sweeper demotes it. A 5min recovery window
   covers normal task timing; tasks longer than 5min that overlap a
   restart would still fail. Acceptable given how rare that overlap
   is in practice.

## Next sprint candidates

1. **Clerk OIDC** — multi-user auth.
2. **Mobile build** of `tally_coding_app` for Android.
3. **systemd timer for `tally pool gc`** so the manual step from
   Sprint 17 fades into background ops.
4. **Drop synchronous task response** — make task dispatch fire-and-
   forget; orchestrator UI watches the same event stream the
   recovery path uses.
