# Sprint 19 — Fire-and-forget task dispatch

**Status: PASS** — `process_task` now returns ~300 ms after submitting
a task to a worker (was ~30 s, the OpenHands runtime). The synchronous
`dispatch_wake` response no longer carries the result — that flows
back through the persistent `task:event kind=result` channel Sprint 18
introduced. Worker now acks the wake immediately and runs the task in
the same single-threaded loop, the handle's lock releases right after
the ack, and a new `WorkerHandle.in_flight_task` marker tracks worker
busyness across the gap between dispatch-ack and result-event arrival.

## What was built

### Worker v12: ack-first

`worker_spike.py` main loop now branches for `TASK_CONTEXT_ID`:

```python
if context_id == TASK_CONTEXT_ID:
    if not session.bootstrapped:
        # reject with explicit "not bootstrapped" ack
        continue
    ack_bytes = session.encrypt(json.dumps({"ack": True}).encode())
    client.complete_wake(team_id, wake_id, b64url_no_pad(ack_bytes), bearer=bearer)
    # now run the task synchronously; result emits via kind=result event
    handle_task_wake(...)
    continue
```

The worker stays single-threaded (one task at a time), so the inbox
poll only resumes after `handle_task_wake` returns. tally-workers
considers the original task wake complete the moment we call
`complete_wake`, so the dispatching orchestrator's `dispatch_wake`
HTTP request returns within seconds.

### `WorkerHandle.in_flight_task: str | None`

```python
@dataclass
class WorkerHandle:
    ...
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    failures: int = 0
    in_flight_task: str | None = None
```

`lock` guards MLS sender-ratchet state during the brief dispatch.
`in_flight_task` tracks worker busyness across the result-wait. Both
must be free for `acquire_idle` to pick the handle.

### `Orchestrator.process_task` rewritten

Skeleton:

```python
handle = await self.acquire_idle(timeout=120)
try:
    handle.in_flight_task = task["id"]
    self.db.set_task_worker(...); self.db.mark_running(...)
    payload = ...
    ack_bytes = await asyncio.to_thread(self._dispatch_blocking, handle,
        context_id=TASK_CONTEXT_ID, payload=ciphertext,
        timeout_seconds=int(os.environ.get("TALLY_TASK_ACK_TIMEOUT", "30")))
    ack = json.loads(handle.session.decrypt(ack_bytes).decode("utf-8"))
    if not ack.get("ack"):
        raise RuntimeError(...)
    handle.failures = 0
    # process_task is done; result event will land later
finally:
    handle.lock.release()
```

`TALLY_TASK_DISPATCH_TIMEOUT=300` is gone; the new `TALLY_TASK_ACK_TIMEOUT`
defaults to 30 s and only covers the ack roundtrip.

### Event poller clears `in_flight_task` on `kind=result`

When the deferred result event arrives:

```python
if event.get("kind") == "result":
    task_id = inner.get("task_id", "")
    result = event.get("result", {})
    completed = self.db.mark_recovered(task_id, result)
    if completed:
        logger.info("task %s result event from worker %s: success=%s", ...)
        await self._publish_status(task_id, "completed", {...})
    if target.in_flight_task == task_id:
        target.in_flight_task = None
```

The same `mark_recovered` path serves both: tasks already in `running`
state (normal fire-and-forget completion) and tasks demoted to
`recovering` by a mid-flight orchestrator restart (Sprint 18's path).

### Recovery sweeper handles `in_flight_task`

`Db.sweep_recovering` now returns the demoted task_ids (was just
`int`). `Orchestrator.run_recovery_sweeper` clears `in_flight_task`
on any handle whose currently-tracked task got demoted, bumps that
handle's `failures` counter, and triggers `_rotate_handle` once
the threshold is crossed — silent task loss is a strong signal that
the worker is unhealthy.

### `/admin/pool/status` shows `in_flight_task`

```json
[
  {
    "identity": "wXndxAcjCkZr...",
    "busy": false,
    "in_flight_task": null,
    "failures": 0
  }
]
```

`busy` is now `lock.locked() OR in_flight_task is not None`.

## E2E validation (13:29-13:30 CDT 2026-05-17)

```
13:29:35.304  client: POST /tasks
13:29:35.334  client: response 200 (30 ms total HTTP roundtrip)
13:29:35.353  orchestrator: dispatching task 01b408f5 to worker wXndxAcj
13:29:35.637  orchestrator: task 01b408f5 acked by worker wXndxAcj;
              awaiting result event   ← dispatch returned in 284 ms
13:29:39      task observed as 'running' in DB (status_change pushed)
13:29:48.547  orchestrator: task 01b408f5 result event from worker
              wXndxAcj: success=True
13:29:49      task observed as 'completed' in DB, elapsed=13.23 s
```

Pre-Sprint-19 the dispatch would have blocked for ~13 s (worker
runtime). Now it blocks ~300 ms (ack roundtrip). Result delivery is
unchanged in latency (worker still takes ~13 s for a `hello.py` task),
but the orchestrator can dispatch other tasks during that window.

`/admin/pool/status` after completion:

```json
[{"identity": "wXndxAcjCkZr...", "busy": false,
  "in_flight_task": null, "failures": 0}]
```

In-flight marker cleaned up; failures stayed at 0.

## Files committed

- `spike/day4/worker/worker_spike.py`: main loop branches for
  `TASK_CONTEXT_ID` — ack-first, run-then-emit-result.
- `spike/day4/worker/docker-compose.yml`: image tag `v11` → `v12`.
- `services/orchestrator/tally_orchestrator/worker_pool.py`:
  - `BASE_IMAGE` `v11` → `v12`.
  - `DEPLOY_TAG_PREFIX_V11` retained for GC of Sprint 18 leftovers.
  - `DEPLOY_TAG_PREFIX` now `v12-tally-auto-`.
  - `gc_image_versions` recognises all three prefixes.
- `services/orchestrator/tally_orchestrator/service.py`:
  - `WorkerHandle.in_flight_task` field.
  - `Orchestrator.process_task` fire-and-forget.
  - `Orchestrator.acquire_idle` respects `in_flight_task`.
  - Event poller clears `in_flight_task` on `kind=result`.
  - `Db.sweep_recovering` returns demoted task_ids.
  - `Orchestrator.run_recovery_sweeper` clears stuck `in_flight_task`
    and bumps `failures` on the affected handle.
  - `/admin/pool/status` exposes `in_flight_task`.

`ghcr.io/nicholasraimbault/tally-spike-day4-worker:v12` pushed to GHCR.

## Open items

1. **`TALLY_TASK_DISPATCH_TIMEOUT` deprecation isn't enforced.** The
   env var is no longer read by the orchestrator, but operator env
   files still mention it. Could add a one-time WARN if the env is
   set, pointing at the new `TALLY_TASK_ACK_TIMEOUT`.
2. **Workers older than v12 are incompatible.** A v10 or v11 worker
   would block on `handle_task_wake` for the full OpenHands runtime
   before calling `complete_wake`; the orchestrator's 30 s ack
   timeout would expire and the task would be marked failed.
   Mitigation: the orchestrator's auto-provision flow uses
   `BASE_IMAGE` from `worker_pool.py`, which is now `v12`. Pre-Sprint-19
   CVMs in long-lived projects would need rotation.
3. **`in_flight_task` is in-process state, not persisted.** A worker
   stuck on a task that the sweeper hasn't demoted yet would lose
   its `in_flight_task` marker across an orchestrator restart. The
   sweeper would clean up eventually. Acceptable for now; the cost
   is "no new tasks land on this worker for up to 5 min after
   restart" rather than "tasks get lost".

## Next sprint

Per the proposed roadmap, **Sprint 20: systemd timer for `tally pool gc`**
— a ~30-min sprint that drops a `tally-orch-gc.timer` next to the
existing `tally-orch.service` so the operator-grade GC from Sprint 17
runs nightly without manual invocation.
