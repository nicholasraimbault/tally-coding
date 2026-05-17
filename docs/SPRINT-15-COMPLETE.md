# Sprint 15 — Restart resilience

**Status: PASS** — Three small, related fixes that close real bugs
surfaced during Sprint 14: stuck `running` rows after a crash, noisy
tracebacks for the (expected) MLS decrypt failures that follow a
restart, and the cgroup memory caps that previously only existed as
runtime overrides. Together they make the orchestrator survive a hard
kill mid-task without polluting state, swamping logs, or risking the
host.

## What was built

### 1. Stuck-`running` self-heal on startup

The processor loop only considers `status='pending'` rows for
dispatch. Before this sprint, a `running` task left behind by a crash
or OOM was invisible — it pinned nothing on the new pool, but it also
lied to the `/tasks` and `/tasks/{id}` endpoints forever (showing as
in-progress when no coroutine was driving it).

```python
def recover_stuck_running(self, error: str) -> int:
    """Demote every status='running' row to status='failed' with the
    given error message."""
    cursor = self._conn.execute(
        "UPDATE tasks SET status='failed', error=?, updated_at=? WHERE status='running'",
        (error, time.time()),
    )
    return cursor.rowcount or 0
```

Called once in `lifespan` after `Db` is constructed, before any
bootstrap. The `mark failed` (rather than `re-pending`) choice is
deliberate: a still-running worker might be mid-task on the other
side, and demoting to `pending` would cause a duplicate dispatch
racing for the same `/workspace`. Surfacing the failure lets the user
resubmit explicitly if they want a retry — and the previous
`worker_identity` is preserved on the row so the failure is
auditable.

### 2. Quiet MLS decrypt errors in the event poller

After an orchestrator restart, the worker's MLS session state outlives
the orchestrator's in-memory state. Any task-event wake the worker
sent against the previous ratchet position can't be decrypted by the
freshly-bootstrapped group on the orchestrator side. Pre-Sprint-15
this surfaced as a full
`skytale_sdk.errors.MlsError: CryptoProviderError(AeadError(...))`
traceback per stale wake, hiding the actually-noteworthy lines in the
journal.

```python
except Exception as exc:
    is_mls = (
        type(exc).__name__ in ("MlsError", "MlsSessionError")
        or "MLS engine error" in str(exc)
        or "CryptoProviderError" in str(exc)
    )
    if is_mls:
        logger.warning(
            "event decrypt failed for wake %s (likely stale session after restart); ack+skip",
            wake_id[:8],
        )
    else:
        logger.exception("event decode failed for wake %s: %s", wake_id[:8], exc)
```

MLS decrypt failures are now a single WARNING line per wake; anything
else still gets the full traceback. The `finally` block already
ack-and-skips the wake regardless, so the poller continues either
way.

### 3. `MemoryHigh`/`MemoryMax` baked into the tracked systemd unit

Sprint 14 added the caps via `systemctl --user set-property` at
runtime (after the 11G runaway). That worked but didn't survive a
unit reload or fresh install. Now in `deploy/tally-orch.service`:

```ini
MemoryHigh=2G
MemoryMax=3G
```

`systemctl --user revert tally-orch.service` was run to clean up the
runtime drop-ins; the tracked unit file is now the only source.

## E2E validation

```
12:09:13  T1 submitted, status=running on worker -XUjWRSa
12:09:13  systemctl --user kill --signal=SIGKILL tally-orch
12:09:13  service in 'activating (auto-restart)' state
12:09:17  recovered 1 stuck running task(s) on startup (demoted to failed)
12:09:40  bootstrap[-XUjWRSa]: MLS session established
12:09:40  ready; pool=1, processor loop started
12:09:40  event decrypt failed for wake 01KRVEKP (likely stale session
          after restart); ack+skip
12:10:02  T2 submitted on the recovered pool
12:10:15  T2 completed on worker -XUjWRSa: success=True
```

Final DB:

```
3e82dc73 | failed     | -XUjWRSaVJ-R | (killed mid-run)
d1ebfc21 | completed  | -XUjWRSaVJ-R | (post-recovery)
```

Memory under load: 167 MB (cap=2G hard cap=3G). No traceback noise in
the journal even though one stale wake hit the orchestrator a few ms
after bootstrap.

## Files committed

- `services/orchestrator/tally_orchestrator/service.py`:
  - `Db.recover_stuck_running()` (+~15 LoC).
  - `lifespan` calls it after `Db(...)` (+5 LoC, +1 WARNING log).
  - Event poller's `except` block classifies MLS errors as quiet
    warnings (+15 LoC).
- `deploy/tally-orch.service`:
  - `MemoryHigh=2G`, `MemoryMax=3G` (+5 LoC including comment).

No worker / SDK changes. Image `:v10` unchanged.

## Open items

1. **No replay for failed-on-restart tasks.** When the orchestrator
   crashes mid-task and the worker actually finished the work
   successfully, we have no way to retrieve that result — the
   result-wake the worker sent gets ack-and-skipped because we can't
   decrypt it. A future sprint could persist a per-task result hash
   in tally-workers so a recovered orchestrator could re-fetch and
   re-decrypt with a recovered session. Today, the user just
   resubmits.
2. **`MemoryMax=3G` is a guess.** Steady-state under one pool=2
   concurrent run is ~80-170MB. 3G is generous — bigger pools or
   longer tasks could need more. If we hit OOM in prod, the right
   answer is bumping the cap *and* finding what's leaking.
3. **Bootstrap is still parallel.** `_bootstrap_slot` runs via
   `asyncio.gather` for N>1. With the new MLS-error tolerance, a
   parallel-bootstrap retry storm is less catastrophic than before
   (no traceback noise), but the per-handle retry on bootstrap
   failure is still serial-ish; not a clean concurrency story. Punt.

## Next sprint candidates

1. **Clerk OIDC** — real multi-user auth (currently single bearer
   token; tunnel-only deployment).
2. **Mobile build** of `tally_coding_app` for Android / iOS.
3. **Per-tag worker images** so `tally pool scale 8` doesn't take
   24 minutes from serial Phala KMS sequencing.
4. **Persist result wakes in tally-workers** so a recovered
   orchestrator can pick up where it left off (replaces today's
   "task failed, resubmit").
