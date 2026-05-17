# Sprint 13 — Worker self-healing (startup + runtime)

**Status: PASS** — `tally-orch` now recovers from worker death at both
lifecycle stages: stale-bootstrap on startup and consecutive task failures
at runtime. Both paths converge on the existing pool.provision +
upsert_active_worker + os._exit(1) flow from Sprint 12; systemd respawns
into a clean state.

## What was built

**Startup retry (`service.py` lifespan)**:

Wrapped `_resolve_worker` + `orchestrator.bootstrap` in a 3-attempt loop.
On bootstrap failure (e.g. the DB-cached worker's CVM is dead), the lifespan:

1. Logs the attempt + error
2. Marks the current active worker `retired`
3. Schedules a background CVM delete (in case it's a half-dead zombie)
4. Wipes the MLS state dir (so a stale group on disk doesn't poison the next
   bootstrap with the same orchestrator identity)
5. Loops back to `_resolve_worker`, which now falls through Sprint 12's
   tier-3 path (auto-provision)

After 3 failed attempts it lets the exception propagate; systemd respawns
the unit and the next boot starts the loop fresh.

**Runtime auto-rotate (`Orchestrator.process_task` + `_trigger_auto_rotate`)**:

- `self._consecutive_failures` counter; reset to 0 on every successful task,
  incremented on every exception in `process_task`
- `self._auto_rotate_threshold` defaults to 3, overridable via
  `TALLY_AUTO_ROTATE_THRESHOLD` (set to 1 for tests)
- When the counter crosses the threshold and a rotation isn't already in
  flight, fires `_trigger_auto_rotate` as a background task
- `_trigger_auto_rotate` is the same provision → upsert → schedule-delete →
  `os._exit(1)` flow that `/admin/pool/rotate` uses
- Failure inside `_trigger_auto_rotate` clears the `_rotating` flag so a
  later attempt can fire (avoids "rotating but never completes" deadlock)

**Tunables added** (both for test cycles; default behaviour unchanged):

| Env var | Default | Notes |
|---|---|---|
| `TALLY_AUTO_ROTATE_THRESHOLD` | 3 | consecutive failures before rotate |
| `TALLY_TASK_DISPATCH_TIMEOUT` | 300 (s) | per-wake dispatch timeout for tasks |

## E2E validation

**Test 1 — stale worker recovery on startup:**

Pre-state: `workers` DB has `821aefa9...` marked `active`; that CVM was
deleted out-of-band. No CVMs alive on Phala. Started the systemd unit:

```
10:11:01  bootstrap attempt 1/3 with worker Wty9wMj5CcS7
10:12:01  bootstrap attempt 1/3 failed: 408 Request Timeout
10:12:01  retired stale worker 821aefa9; will re-resolve
10:12:01  no worker configured — auto-provisioning via phala CLI
10:15:04  worker d5d99da1 ready: team=tally-auto-1779030721
10:15:04  bootstrap attempt 2/3 with worker WOnJqtJOXVFG
10:15:06  MLS session established
10:15:06  ready; processor + event-poller loops started
```

~3 min total. Attempt 1 fast-failed at the dispatch timeout (60 s for
bootstrap wakes); attempt 2 took the full provisioning cycle.

**Test 2 — runtime auto-rotate after consecutive task failures:**

Pre-state: service running with `d5d99da1` active (alive). Set
`TALLY_AUTO_ROTATE_THRESHOLD=1` + `TALLY_TASK_DISPATCH_TIMEOUT=45` so the
loop fires after one failure. Externally deleted `d5d99da1` then submitted a
task via the public URL:

```
10:18:35  task 61ea9417 dispatched
10:19:19  task failed (dispatch timeout)
10:19:19  auto-rotating worker after 1 consecutive task failures
10:19:19  auto-rotate: provisioning new worker
10:21:49  worker d8293c28 ready
10:21:49  auto-rotate: new worker d8293c28 persisted; exiting for respawn
10:21:55  MLS session established
10:21:55  ready
```

systemd respawned; new orchestrator bootstrapped against `d8293c28`. A
subsequent `double.py + pytest` task ran on the rotated worker and finished
in 31 s with `success: true`.

## DB shape after both tests

```
cvm_id          status    identity      created_at
cd2d6454…       retired   UY-uKFuj…     (sprint 12)
821aefa9…       retired   Wty9wMj5…     (sprint 12 rotate)
d5d99da1…       retired   WOnJqtJO…     (sprint 13 test 1)
d8293c28…       retired   fcoGivCO…     (sprint 13 test 2 — then deleted post-test)
```

The `status='retired'` rows are the audit trail of what ran when.

## Files committed

- `services/orchestrator/tally_orchestrator/service.py` (+45):
  bootstrap retry loop, failure counter, `_trigger_auto_rotate`, env-var
  tunables

No worker / Dockerfile / Flutter changes. Image `:v8` unchanged.

## Open items

1. **Auto-rotate aborts in-flight task.** When the threshold fires, the
   counter-triggering task has already been marked `failed`. A subtler
   strategy would `mark_pending` instead so the rotated worker picks it
   up — but then a permanently-broken task could trigger an infinite
   rotation loop. Today's behaviour ("fail the task, rotate, next task
   uses healthy worker") is the right default; revisit if/when retries
   become a feature.
2. **`shutil.rmtree(mls_state_dir)` between bootstrap attempts is a hammer.**
   It drops any partially-established MLS groups on disk. That's correct
   for the single-worker model (each retry starts fresh), but when N>1
   workers land in Sprint 14 we'll need per-worker state dirs so one
   rotation doesn't blow away the others.
3. **No alerting.** The service silently rotates on worker death. For a
   hosted setting we'd want a metric or webhook (`task_failures_total`,
   `worker_rotations_total`) so operators see when the underlying
   infrastructure is flaking, not just the symptom.

## Next sprint candidates

1. **N>1 worker pool** with per-worker MLS sessions + concurrent task
   dispatch (the schema in `workers` already supports multiple rows;
   the bottleneck is `Orchestrator.session` being a single instance)
2. **Clerk OIDC** swap-in
3. **Mobile build** of `tally_coding_app`
4. **Workspace cache** in service so reopening a finished task doesn't
   re-hit the worker
