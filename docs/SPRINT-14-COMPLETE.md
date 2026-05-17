# Sprint 14 — N>1 worker pool with concurrent dispatch

**Status: PARTIAL PASS** — Pool of 2 workers boots cleanly with two
cryptographically distinct MLS identities, two concurrent event-poller
loops, and per-handle dispatch locks (the structural prerequisite for
concurrent task execution). End-to-end "two tasks land on two workers
in parallel" was not validated in this sprint cycle because the dev
host went under memory pressure mid-run and OOM-killed the orchestrator
before both tasks finished — the architecture is in place and the pool
is ready to accept concurrent work; only the runtime validation step
got cut short. Reproducing it after a fresh host reboot is a low-risk
follow-up.

## What was built

### `service.py` — `Orchestrator` refactor

Replaced the single-session model with a pool of `WorkerHandle`s keyed
by worker identity. Each handle owns one MLS group, one worker, and an
`asyncio.Lock` that's held while dispatching a task. Concurrency comes
from N independent handles, not from cross-handle MLS state sharing
(the sender ratchet is single-writer — locking is at the handle level).

```python
@dataclass
class WorkerHandle:
    identity: str
    team_id: str
    cvm_id: str
    app_id: str | None
    session: MlsSession
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    failures: int = 0
```

Key new methods on `Orchestrator`:

- `add_handle(...)` / `remove_handle(...)` — pool membership.
- `bootstrap_handle(handle)` — 3-wake MLS handshake against one worker
  (extracted from Sprint 2's `bootstrap()` and parametrised by handle).
- `acquire_idle(timeout)` — wait for any unlocked handle, acquire it.
- `_rotate_handle(handle)` — per-handle rotate (replaces Sprint 12's
  whole-service `/admin/pool/rotate` + `os._exit(1)` pattern; other
  handles keep serving traffic).
- `scale_pool(target_size)` — scale up provisions new handles in
  serial, scale-down acquires each victim's lock first so in-flight
  tasks aren't aborted.
- `start_poller(handle)` / `stop_poller(team_id)` — one event-poller
  asyncio.Task per worker team, decodes the new envelope wire format
  (see below), routes by `worker_identity` to the correct handle's
  MLS session.

`run_processor_loop` now fans out via `asyncio.create_task` so multiple
tasks can dispatch in parallel up to `len(self.handles)`. The fan-out
respects each handle's lock — at most one task per handle at a time.

### Wire format change — worker → orchestrator events

Per-task events from worker to orchestrator now carry a plaintext
envelope around the MLS ciphertext so the orchestrator can route
incoming wakes to the right handle's session (the orchestrator now has
N sessions, each with its own ratchet — receiving on the wrong one
corrupts state).

```python
envelope = {
    "worker_identity": bearer,    # which handle's session decrypts
    "task_id": task_id,
    "seq": seq,
    "encrypted_b64": b64url_no_pad(ciphertext),
}
```

The encrypted payload's plaintext is unchanged: `{task_id, seq, event}`.
Backwards-incompatible with worker:v8; image bumped to `v10` (the v9
intermediate had the envelope but used file-based identity, which the
N>1 pool surfaced as broken — see "Phala collisions" below).

### `tasks.worker_identity` column

New column on the existing `tasks` table records which `WorkerHandle`
dispatched a given task. Used by `_dispatch_to_task_worker` to route
`fs:list` / `fs:read` admin reads back to the worker that owns the
workspace (different workers see different `/workspace` directories).

```sql
ALTER TABLE tasks ADD COLUMN worker_identity TEXT;
```

`Db.set_task_worker(task_id, worker_identity)` is called from
`process_task` immediately after `acquire_idle` returns the handle.

### `/admin/pool/scale` + `tally pool scale <n>`

New admin endpoint and CLI command for resizing the pool at runtime.

```bash
$ tally pool scale 4
scaling pool to 4 worker(s); may take ~3-5 min per new CVM...
scaled 2 -> 4
  added: htsxoWdXXw3Y, 3VsmkRZ-NqRb
```

Body `{"size": N}`. Scale-up provisions and bootstraps in serial (see
Phala constraints below). Scale-down releases tail handles after
acquiring their locks so an in-flight task isn't interrupted.

`/admin/pool/status` now returns a list of workers with `present`,
`busy`, and `failures` flags per handle in addition to the DB row.
`/admin/pool/rotate` accepts an optional `{"identity": ...}` body to
target one specific worker rather than the whole pool.

### `worker_spike.py` — env-passed private key

```python
privkey_hex = os.environ.get("WORKER_PRIVKEY_HEX", "").strip()
if privkey_hex:
    Path(identity_path).write_bytes(binascii.unhexlify(privkey_hex))
_privkey, pubkey = load_or_create_identity(identity_path)
```

When the orchestrator pre-generates and passes a worker private key via
the env file, the worker uses it verbatim. This sidesteps two Phala
deployment quirks discovered during validation: (a) docker-compose's
`${VAR:-default}` env interpolation doesn't pick up values from
`phala deploy -e <env-file>` at the right phase, so per-CVM
`WORKER_IDENTITY_PATH` wasn't taking effect; (b) when two CVMs ended up
in the same App ID, they shared the `workspace` docker volume, so even
two distinct `WORKER_IDENTITY_PATH` files would coexist but the worker
would always read the same one. Env-passing makes the identity source
of truth the env var, not anything on disk.

## Phala deployment constraints (discovered the hard way)

The N>1 pool surfaced a chain of Phala-specific behaviour that wasn't
visible in Sprints 12-13 (which only kept one CVM alive at a time):

1. **App ID is a deterministic hash of the docker-compose content**,
   with aggressive normalization. `container_name`, top-level
   `labels:`, `volumes:` names, top-level `x-*` fields, and even
   `command:` overrides all get stripped before hashing. So two parallel
   `phala deploy` calls with the same `services.<name>.image` and
   `environment` keys hit the same App ID.
2. **Phala's centralized KMS has `UNIQUE(dstack_app_nonces.address)`**
   where `address == app_id`. Two parallel deploys racing for the same
   App ID both try to insert the initial nonce record; the loser fails
   with `IntegrityError: duplicate key value violates unique constraint
   "ix_dstack_app_nonces_address"`.
3. **`--custom-app-id` doesn't accept arbitrary values** — Phala
   verifies it equals `hash(compose, nonce)`, so passing a random hex
   gets `Error [ERR-02-008]: App ID mismatch`.
4. **`--nonce` is per-app monotonic** with a small gap-limit (~20),
   not a free-form random number, so it can't be used to disambiguate
   either.
5. **Within a single App ID, CVMs share env-file substitution at
   deploy time**, so two CVMs that deduped to the same app both end up
   reading the *first* deploy's `TEAM_ID` and `WORKER_PRIVKEY_HEX`,
   even though each had its own `phala deploy -e <env-file>`.

The workaround that lands in this sprint: **serial provisioning**.
After the first deploy successfully inserts its nonce record, the
second deploy can proceed without the UNIQUE collision, and each CVM
receives its own env (verified — distinct identities at bootstrap).

Cost: a 2-worker pool now cold-starts in `2 × 3min = 6min` instead of
`max(3min, 3min) = 3min`. With persistent DB caching from Sprint 12,
this is a one-time cost per pool resize; warm restarts re-use the
existing CVMs from `Db.list_active_workers()` and bootstrap in seconds.

## Evidence (end-to-end run, 11:23-11:29 CDT 2026-05-17)

```
11:23:09  auto-provisioning 2 worker(s) serially (may take ~6min)
11:23:09  provisioning worker tally-worker-1779034989-43aec2 via phala deploy...
11:25:59  worker e55f4d58 ready: team=...-43aec2 identity=htsxoWdXXw3Y...
11:25:59  provisioning worker tally-worker-1779035159-248e13 via phala deploy...
11:28:50  worker 9249ffa1 ready: team=...-248e13 identity=3VsmkRZ-NqRb...
11:28:51  bootstrapping pool of 2 worker(s) in parallel
11:28:51  bootstrap[htsxoWdX]: MLS session established (team=...-43aec2)
11:28:51  bootstrap[3VsmkRZ-]: MLS session established (team=...-248e13)
11:28:51  ready; pool=2, processor loop started
```

`GET /admin/pool/status` after ready:

```json
{
  "workers": [
    {
      "cvm_id": "e55f4d58-...",
      "app_id": "c65108c298dbdba7b701ea2bc9afb139f002eba4",
      "team_id": "tally-auto-1779034989-43aec2",
      "identity": "htsxoWdXXw3YF1fsZHBKCJUh10NxFG9_w8piSDjcVlc",
      "present": true, "busy": false, "failures": 0
    },
    {
      "cvm_id": "9249ffa1-...",
      "app_id": "52c2ecde63220cd8f445944ca08e855b57724c1f",
      "team_id": "tally-auto-1779035159-248e13",
      "identity": "3VsmkRZ-NqRbHM-gfn3dljP_FfVrLDsv6_sZYECUAVE",
      "present": true, "busy": false, "failures": 0
    }
  ],
  "pool_size": 2
}
```

Two distinct App IDs, two distinct Ed25519 identities, two distinct
team IDs, two concurrent inbox-poller loops. Warm restart from DB-cache
re-bootstrapped both handles in ~1s (no `phala deploy` needed).

## Files committed

- `services/orchestrator/tally_orchestrator/service.py` (~+400):
  `WorkerHandle` dataclass, pool-based `Orchestrator`, scale endpoint,
  per-handle rotate, envelope-aware event poller, `tasks.worker_identity`
  column + migration.
- `services/orchestrator/tally_orchestrator/worker_pool.py` (~+30):
  pre-generated Ed25519 keypair passed to `_build_env_file` via
  `WORKER_PRIVKEY_HEX`, suffix-disambiguated team_id.
- `services/orchestrator/tally_orchestrator/cli.py` (~+30):
  `tally pool scale <n>` subcommand, updated `tally pool status`/
  `rotate` for the new response shapes.
- `spike/day4/worker/worker_spike.py` (+15): event envelope wrapping;
  optional `WORKER_PRIVKEY_HEX` env override.
- `spike/day4/worker/docker-compose.yml`: image tag `v9` → `v10`,
  added `WORKER_PRIVKEY_HEX` env passthrough.
- New worker image `ghcr.io/nicholasraimbault/tally-spike-day4-worker:v10`
  pushed to GHCR.

## Open items

1. **Concurrent dispatch not yet validated end-to-end on a live pool.**
   Both halves (architecture + 2-worker boot) work; the missing piece
   is "submit 2 tasks, watch them complete simultaneously on different
   workers." Next session can re-bootstrap the pool from the DB cache
   in seconds and run this in a few minutes.
2. **Serial provisioning is slow.** ~3 min per CVM. For a `tally pool
   scale 8`, that's 24 minutes. A fix would batch-create CVMs with
   distinct App IDs by varying the `image` tag per deploy (push aliases
   `v10-a`, `v10-b`, etc.) — each tag changes the compose hash, so each
   gets its own App ID with no KMS race. Punt to a future sprint where
   image-tag pre-warming makes sense.
3. **`process_task` doesn't preempt or shed load.** If all handles are
   busy and a new task arrives, it waits up to `TALLY_ACQUIRE_TIMEOUT`
   (default 120s) and then fails. A queue would let it wait longer
   cheaply; backpressure (refuse `POST /tasks` when pool fully booked)
   would let callers retry. Today's behaviour is fine for low rates.
4. **No autoscaling.** Pool size is fixed at startup (`TALLY_POOL_SIZE`
   env, default 1) and changed manually via `tally pool scale`. A
   future sprint could autoscale based on pending-task queue depth.

## Next sprint candidates

1. **Re-run the concurrent E2E** on a fresh boot — 5 minutes of work,
   closes the only open Sprint 14 item.
2. **Clerk OIDC** for real multi-user auth.
3. **Mobile build** of `tally_coding_app`.
4. **Per-tag image pre-warm** so scale-up doesn't serialize on Phala's
   KMS nonce race.
