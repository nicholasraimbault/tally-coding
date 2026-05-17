# Sprint 28 — Local-worker daemon (`tally-agent`)

**Status: PASS** — Agents can now run on the user's laptop instead of
(or alongside) Phala TEE workers, via a `tally-agent` systemd user
service.  The orchestrator joins both workers into its pool and routes
per-agent based on the architect's `worker_affinity` field —
`local_if_available` for environment-aware agents like Tester,
`tee` for code-generation agents that shouldn't see the host's real
files.

This is the opt-in environment-integration story from the locked
architecture memo: same MLS handshake, same wake-driven RPC, just a
different process on the other end of the wire.

## What was built

### `scripts/tally-agent` (new CLI)

```
tally-agent install     # generate keypair, write systemd user unit
tally-agent enroll      # print TEAM_ID_LOCAL + WORKER_IDENTITY_B64_LOCAL
tally-agent start       # systemctl --user start tally-agent
tally-agent status      # systemctl --user status tally-agent
tally-agent stop        # systemctl --user stop tally-agent
tally-agent uninstall   # remove unit (keypair preserved)
tally-agent run         # foreground — used by systemd's ExecStart
```

State lives in `~/.local/share/tally-agent/`:
- `team_id` — the registered team name (`tally-local-<host>-<rand>`)
- `worker.key` — Ed25519 private key
- `workspace/` — per-task working dirs (mirrors the Phala worker layout)
- `mls-state/` — MLS group state (LiteFS-style; one group per
  orchestrator)
- `env` — `EnvironmentFile=` source for the systemd unit

The unit invokes `worker_spike.py` directly — no new daemon code; the
existing Phala worker is the local worker, just running on bare metal.
That means Sprint 26's artifact-passing + Sprint 27's stage logic +
Sprint 25's per-event agent attribution all work identically on the
laptop.

### Orchestrator changes (`tally-orch:v6`)

- `_resolve_pool` accepts a second pinned worker via
  `TEAM_ID_LOCAL` + `WORKER_IDENTITY_B64_LOCAL`, alongside the
  existing `TEAM_ID` + `WORKER_IDENTITY_B64`.  Tagged
  `worker_type="local"` vs `"tee"`.
- `WorkerHandle.worker_type` carries the tag through to the
  dispatcher.
- `acquire_idle(affinity=...)` filters candidate handles:
  - `"any"` / `None` — any handle (default; first available wins).
  - `"tee"` — only TEE handles (hard requirement).
  - `"local"` — only local handles (hard requirement).
  - `"local_if_available"` — prefer local; widen to any handle after
    half the timeout if no local handle frees up.
- `_dispatch_agent` reads the per-agent `worker_affinity` from
  `task.team_spec.agents[idx].worker_affinity` and passes it to
  `acquire_idle`.
- `docker-compose.yml` gains `TEAM_ID_LOCAL` /
  `WORKER_IDENTITY_B64_LOCAL` env vars; operators set them by pasting
  the output of `tally-agent enroll`.

### Architect changes (`architect.py`)

The system prompt teaches Tally about `worker_affinity` and when to
use each value (`tee` / `local` / `local_if_available` / `any`).  The
validator carries the field forward only when the architect chose a
non-default value — keeping team_specs small for the common case.

## E2E validation (2026-05-17, 23:17-23:23 CDT)

Setup: pool=2 with one TEE worker (`y1ThVtBD`,
`tally-auto-1779058615-2e569e`) + one local worker (`DDy_QDvA`,
`tally-local-xps16-ca1943`, running on the laptop as
`tally-agent.service`).  Orchestrator boot log:

```
using env-pinned tee   worker: team=tally-auto-…    identity=y1ThVtBD…
using env-pinned local worker: team=tally-local-xps16-… identity=DDy_QDvA…
bootstrapping pool of 2 worker(s) in parallel
bootstrap[y1ThVtBD]: MLS session established (team=tally-auto-…)
bootstrap[DDy_QDvA]: MLS session established (team=tally-local-…)
```

Task: *"Write fib.py with fib(n).  Run pytest against it locally on
the user's machine so the tests execute in the user's real
environment (set worker_affinity=local for the Tester)."*

Tally architect picked:

| agent     | affinity | spec                                          |
|-----------|----------|-----------------------------------------------|
| Planner   | any      | Decompose task into writing fib.py + tests    |
| Coder     | any      | Write fib.py with fib(n) function             |
| Reviewer  | any      | Review fib.py for style and edge cases        |
| **Tester**| **local**| Run pytest against fib.py                     |

Dispatch log (task `7f58cc50`):

```
23:17:47  Planner  → worker y1ThVtBD  (TEE; affinity=any)
23:18:17  Coder    → worker y1ThVtBD  (TEE)
23:19:17  Reviewer → worker y1ThVtBD  (TEE)
23:20:48  stage 2 → 3: dispatching [Tester]
23:20:48  Tester   → worker DDy_QDvA  (LOCAL; affinity=local) ✓
23:23:30  Tester snapshot: 5 files; team complete
```

The local agent's journalctl confirms the actual work happened on the
laptop, not in a CVM:

```
[worker] task 7f58cc50 (decrypted): Write a python module fib.py …
[worker] agent role=Tester model=moonshotai/kimi-k2.6
[worker] seeded 3 file(s) from prior agents  ← Planner+Coder+Reviewer outputs
…
$ ls -la
/home/nick/.local/share/tally-agent/workspace/task-7f58cc50a6cd/agent-3-Tester
…
Collecting pytest
…
7 passed in 0.01s
**Results:** All **7 tests passed** with **0 failures**.
```

The Tester provisioned `/tmp/venvs/fib_env`, installed `pytest` into
it, and executed `test_fib.py` against the seeded `fib.py` — *all on
the laptop*, with the orchestrator dispatching from a Phala CVM in
another datacenter, MLS-encrypted end-to-end over Tally Workers.

## Open items

1. **Sandboxing is light.** The systemd unit sets `NoNewPrivileges=yes`
   but skips `ProtectHome` / `BindReadOnlyPaths` (getting them right
   trips on the orchestrator venv path).  An OpenHands tool acting
   in good faith won't write outside `~/.local/share/tally-agent/`,
   but the constraint isn't kernel-enforced.  A future hardening
   sprint can layer a proper namespace + bubblewrap profile.
2. **Single local agent.** Multiple local agents (e.g., one daemon
   per workstation in a team) would need a per-host `tally-agent`
   install and N more `TEAM_ID_LOCAL_<n>` env vars.  Today the
   compose env supports exactly one local pin alongside one TEE pin.
   Easy to extend when the demand shows up.
3. **No graceful fallover when local goes away mid-task.** The
   orchestrator's auto-rotate (Sprint 18) detects worker failure
   after N consecutive errors but doesn't yet differentiate "TEE died,
   provision a replacement" from "user closed their laptop, downgrade
   affinity to tee."  Sprint 28.5 / 29 territory.
4. **Reused the orchestrator's venv.** `tally-agent install` doesn't
   create a fresh venv for the daemon — it borrows the orchestrator's
   `.venv` because it ships the MLS-enabled skytale-sdk wheel.  The
   downside: users without the orchestrator code installed can't run
   the local agent.  When skytale-sdk publishes a PyPI release with
   `MlsEngine`, `tally-agent` can install into a standalone venv.

## Next sprint

**Sprint 29 — "Save this team" templates.**  After two dozen tasks
the user notices they keep architecting similar teams.  Sprint 29
makes Tally remember: a user can promote a team_spec to a named
template and recall it from `#general` ("use my pytest-first team").
Templates start as an *emergent* feature, not a foundational primitive,
just like the locked architecture memo prescribed.
