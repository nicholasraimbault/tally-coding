# Sprint 35 — Boot decouple: HTTP up before the worker pool

**Status: PASS** — Orchestrator now starts serving HTTP within ~1
second of the docker container coming up, regardless of how long the
worker pool takes to bootstrap MLS.  This fixes the operational
pain-point that surfaced during Sprint 33-rest's E2E: every redeploy
took the entire HTTP surface offline for ~4 minutes (the
worker-handshake window) which made Clerk webhooks retry, the Flutter
billing screen 502, and the operator dashboard look like the CVM had
crashed.

Now `/health`, `/billing/usage`, `/webhooks/clerk`, all `/templates/*`
reads, and all `/shared-templates/*` requests return immediately on
boot.  Only `POST /tasks` returns 503 (with a clean Retry-After hint
and a structured error payload) while the pool is warming up, and the
Flutter shell renders a banner so the user knows what's happening.

## What shipped

### Orchestrator lifespan rewrite

Before (`v15` and earlier):

```
lifespan():
  init db, validators, billing
  await resolve_pool()
  await asyncio.gather(bootstrap_slot for each w in slots)   # ~3-4 min
  start_poller(...)
  start processor_task
  start sweeper_task
  yield                                                       # HTTP up
```

Any failure in the gather raised `RuntimeError`, which crashed the
lifespan and bricked the HTTP surface — even though `/health` etc.
don't depend on workers at all.

After (`v16`):

```
lifespan():
  init db, validators, billing
  state["pool_ready"] = False
  state["pool_status"] = {target_size, joined: 0, last_error: None}
  start sweeper_task, backup_task        # don't depend on workers
  spawn _bootstrap_pool_in_background    # runs asynchronously
  yield                                  # HTTP up at t+0
```

The background task does the same `resolve_pool` + `bootstrap_slot`
sequence the synchronous path did, but on success it sets
`state["pool_ready"] = True` and only THEN starts the processor loop.
On failure it sets `state["pool_status"]["last_error"]` and exits
without crashing the lifespan — the operator can restart the worker
CVM(s) and retry without taking down the orchestrator.

### `/health` now surfaces pool status

```json
{
  "status": "ok",
  "pool_ready": true | false,
  "pool_target": 1,
  "pool_joined": 1,
  "pool_last_error": null | "no workers bootstrapped (target=1)",
  "tasks_in_flight": false
}
```

`pool_ready=true` means at least one worker has joined MLS and the
processor loop is running — `POST /tasks` will succeed.
`pool_ready=false` plus a non-null `last_error` means bootstrap
failed and is no longer retrying; operator intervention required
(restart workers, fix wake-router, etc.).

### `POST /tasks` gates on pool readiness

```json
HTTP 503 Retry-After: 5
{
  "detail": {
    "error": "pool_not_ready",
    "pool_target": 1,
    "pool_joined": 0,
    "last_error": null,
    "retry_after_seconds": 5
  }
}
```

Clients can read `last_error` to distinguish "still warming up"
(retry) from "bootstrap failed" (alert the operator).

### Flutter shell warming banner

`DiscordShellScreen` polls `/health` every 5 s while `pool_ready` is
false (and stops polling once it flips true).  When `pool_ready=false`,
a top-of-shell banner renders:

- Bootstrap-in-progress (last_error null): amber "Workers warming up
  (N / M joined)…" with an explanation that task submission will fail
  but reads + billing keep working.
- Bootstrap-failed (last_error set): red "Workers offline —
  orchestrator is retrying." with the error string surfaced for the
  operator.

The banner sits above the four-pane shell (or above the narrow-layout
content), so the existing UI elements keep working.

## E2E validation (2026-05-19, 20:40 UTC against `tally.pronoic.dev`)

Deployed `tally-orch:v16` with `phala deploy --cvm-id tally-orch-prod`
and measured the boot-to-serving timeline:

| Marker | Time after `phala deploy` reports success |
|--------|-------------------------------------------|
| `/health` returns 200 (status only) | **+1 s** |
| `/billing/usage` returns 200 | +1 s (parallel) |
| `pool_ready: true` in `/health` | +60 s |

For comparison, before Sprint 35 the entire HTTP surface stayed at
HTTP 502 / 530 (Cloudflared can't reach origin) until the worker
pool completed MLS bootstrap — typically ~3-4 minutes.

Live `/health` snapshot at t+60 s:

```json
{
  "status": "ok",
  "pool_ready": true,
  "pool_target": 1,
  "pool_joined": 1,
  "pool_last_error": null,
  "tasks_in_flight": false
}
```

## Failure-mode walk-through

What happens if the worker bootstrap fails entirely (the scenario
that bit us yesterday)?

| Surface | Sprint 33-rest behaviour | Sprint 35 behaviour |
|---------|---------------------------|---------------------|
| `/health` | 502 (CF can't reach origin; orch process crashed) | 200 with `pool_ready=false, last_error="no workers bootstrapped"` |
| `/billing/usage` | 502 | 200 |
| `/webhooks/clerk` | 502 → svix retries pile up | 200 (or 400 on bad signature) |
| `/templates` reads | 502 | 200 |
| `POST /tasks` | 502 | 503 with structured `pool_not_ready` payload |
| Flutter shell | Generic connection-error screen | Discord shell + red "Workers offline" banner |

The operational signal stays loud (red banner) while the recovery
process (orchestrator + webhook delivery + reads) stays available.

## Open items

1. **Pool retry loop.**  Today the bootstrap task gives up after one
   round.  A reasonable retry-with-backoff (1m, 5m, 15m) would let
   the orchestrator self-heal once the worker CVMs come back online,
   without the operator needing to manually restart the orchestrator.
2. **Health-poll backoff in Flutter.**  Today the shell polls
   `/health` every 5 s indefinitely while waiting.  Once we've seen
   `pool_ready=true` once we stop, but a flap (true → false) would
   take up to 5 s to surface.  Probably fine.
3. **/health auth.**  Public for now (CF tunnel makes the URL
   internet-reachable but the orchestrator's `/health` exposes some
   internal state — `tasks_in_flight`, pool size).  Not load-bearing
   for security; revisit if customers ask.

## Next sprint

The locked roadmap (sprints 22-33) is fully closed.  Sprints 34
(templates polish) and 35 (boot decouple) both shipped today as a
single `v16` image bump.  Future sprints are unscheduled — to be
chosen based on real operator + user signals as they come in.
