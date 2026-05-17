# Sprint 12 — Worker auto-provisioning + rotation

**Status: PASS** — `tally-orch` now provisions its own worker CVM if the env
file doesn't pin one. State persists in a new `workers` table, so a restart
reuses the existing CVM rather than burning $0.05 on a fresh deploy. A new
`tally pool rotate` command swaps the worker safely (provision new → persist
→ delete old → exit-1 so systemd respawns into the new state).

This sprint is **single-worker auto-management**. The N>1 pool with
concurrent task dispatch is still a future sprint — it needs per-worker MLS
sessions, which is a deeper refactor of the `Orchestrator` class.

## What was built

**`services/orchestrator/tally_orchestrator/worker_pool.py`** (new):

- `WorkerInfo` dataclass — `cvm_id`, `app_id`, `team_id`, `identity`,
  `created_at`.
- `WorkerPool` class:
  - `provision()` — generates a `tally-auto-<ts>` team id, builds a temp
    env file inheriting `scripts/.env`, shells out to
    `phala deploy -c docker-compose.yml -e <env> --name <name>` from
    `spike/day4/worker/`, parses `CVM ID:` + `App ID:` from stdout.
  - `_await_identity(cvm_id)` polls `phala cvms logs` every 8 s for an
    `identity=<base64>` line (cap 300 s). Surfaces Traceback / PermissionError
    early instead of running out the clock.
  - `delete(cvm_id)` shells `phala cvms delete --cvm-id <id>` (pipes `y` to
    its prompt).
- `_phala_binary()` resolves the CLI through PATH first, then falls back to
  `~/.npm-global/bin/phala` for systemd contexts where PATH might not be set.

**`tally_orchestrator/service.py`**:

- New `workers` table:
  ```sql
  CREATE TABLE workers (
    cvm_id TEXT PRIMARY KEY, app_id TEXT, team_id TEXT NOT NULL,
    identity TEXT NOT NULL, status TEXT NOT NULL,    -- 'active' | 'retired'
    created_at REAL NOT NULL, retired_at REAL
  );
  ```
- `Db.upsert_active_worker` demotes any prior 'active' row before inserting.
  Combined with the index on `status`, only one worker is `active` at a time.
- `Db.get_active_worker()` / `Db.retire_worker(cvm_id)`.
- `_resolve_worker(db, pool)` — three-tier fallback:
  1. **Env override**: if both `TEAM_ID` + `WORKER_IDENTITY_B64` are set, use
     them. Skips DB + provisioning entirely. Pre-Sprint 12 behaviour.
  2. **DB cache**: a previously-active worker survives an orchestrator
     restart without re-provisioning. ~$0.05 saved per dev restart.
  3. **Auto-provision**: `pool.provision()`, persist to DB, proceed.
- Two new admin endpoints (both bearer-token gated):
  - `GET /admin/pool/status` — current active worker + uptime
  - `POST /admin/pool/rotate` — provision new, persist as active (auto-retires
    prior), schedule background CVM deletion, schedule `os._exit(1)` after 2 s.
    Systemd's `Restart=on-failure` respawns; the new orchestrator picks the
    new worker out of the DB on `_resolve_worker`.

**CLI** (`tally_orchestrator/cli.py`):

- `tally pool status` — readable output of the active worker.
- `tally pool rotate` — blocks while the new worker is provisioned (~3 min),
  prints the new IDs, expects a connection reset (service is exiting) and
  treats that as success rather than an error.

**Env file template** (`~/.config/tally-orch/env`): `TEAM_ID` +
`WORKER_IDENTITY_B64` are now **optional**. Removing them lets the service
self-provision on first start. Setting them is the manual-override path for
debugging or pinning a specific CVM.

## E2E run

Cleared env worker pair + wiped `~/.local/share/tally-orch/`, then started
the service via systemd:

```
09:52:08  no worker configured — auto-provisioning via phala CLI (may take ~3-5min)
09:52:08  provisioning worker tally-worker-1779029528 via phala deploy...
09:55:11  received key package (310 bytes); creating MLS group
09:55:11  MLS session established
```

Total cold-start: **~3 minutes** from zero state to ready. `/admin/pool/status`
returned:

```json
{
  "worker": {
    "cvm_id": "cd2d6454-82cf-428d-87e2-617011013730",
    "team_id": "tally-auto-1779029528",
    "identity": "UY-uKFujrpvpjOPdzc7kKKH3ur7MG_6_aSFrkR88PSs",
    "uptime_seconds": 183
  }
}
```

Submitted a `power.py + pytest` task through `https://tally.pronoic.dev/tasks`:
ran on the auto-provisioned worker, `success: true` after ~35 s.

Then ran `tally pool rotate`:

```
provisioning new worker (this takes ~3-5 min)...
new worker provisioned:
  cvm_id:   821aefa9-b05a-4af3-8be2-0ede2b935032
  team_id:  tally-auto-1779029966
  identity: Wty9wMj5CcS7...
service exiting in 2s; systemd will respawn.
```

systemd respawned tally-orch; the new instance pulled the new worker out of
the DB and bootstrapped MLS against it. Submitted an `echo.py` task — landed
on the new worker, `success: true`. Old worker (`cd2d6454...`) was deleted
in the background.

## Wire timing

| Phase | Time |
|---|---|
| Auto-provision (cold) | ~3 min (CVM cold-start dominates) |
| Auto-provision (DB-cached restart) | ~1 s (no `phala deploy`, just MLS re-bootstrap) |
| Pool rotate (full cycle) | ~3 min (provision new + respawn + bootstrap) |
| Task dispatch (warm worker) | ~30-45 s (OpenHands run time) |

## Files committed

- `services/orchestrator/tally_orchestrator/worker_pool.py` (new, ~130 LoC)
- `services/orchestrator/tally_orchestrator/service.py` (+90):
  workers table, Db pool methods, `_resolve_worker`, /admin endpoints
- `services/orchestrator/tally_orchestrator/cli.py` (+50): `pool status` /
  `pool rotate` subcommands
- (deploy/tally-orch.service is unchanged — `Restart=on-failure` already does
  the right thing on `os._exit(1)`)

## Open items

1. **Single worker only.** Concurrent task dispatch still serializes against
   one CVM. The `Db.workers` table is keyed on `status='active'` with a
   demote-on-upsert pattern, so the schema isn't blocking a future N>1 pool;
   the bottleneck is per-worker MLS sessions in `Orchestrator`.
2. **`os._exit(1)` is heavy-handed.** A graceful drain + soft handoff (start
   the new orchestrator, drain the old via in-flight `dispatch_lock`, swap)
   would be nicer. Acceptable today because all task state lives in the DB
   and the only in-flight thing is whatever's mid-dispatch.
3. **No automated retry on MLS-bootstrap failure.** If `_resolve_worker`
   returns a stale identity (CVM died between restarts), the bootstrap
   raises and the service exits. systemd respawns into the same broken
   state. Adding a "if bootstrap fails, retire current + retry once" loop
   is small and would close this hole.
4. **`PHALA_CLOUD_API_KEY` is implicit.** The pool depends on a
   pre-authenticated `phala` CLI (auth lives in `~/.phala/`). For a hosted
   SaaS instance this becomes "the service identity has a Phala key";
   future sprint.
5. **Worker provisioning is blocking.** Service stays unresponsive (no
   uvicorn bind yet) for the ~3 min provisioning window. Acceptable for
   single-user dev; not for prod. Fix: start the API in a degraded "no
   worker" state, provision in the background, surface readiness via
   `/health`.

## Next sprint candidates

1. **N>1 worker pool** with per-worker MLS sessions + concurrent task
   dispatch (deeper refactor)
2. **Bootstrap retry on stale worker** (small, closes the listed hole)
3. **Clerk OIDC** for real multi-user auth (still pending from Sprint 10)
4. **Mobile build** of `tally_coding_app`
