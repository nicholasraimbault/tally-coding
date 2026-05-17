# Sprint 21 — `tally status` one-screen operator dashboard

**Status: PASS** — Single CLI command shows pool, recent tasks, recovery
sweeper state, and orchestrator memory in ~20 lines. Replaces the
three-command operator UX (`tally task list` + `tally pool status` +
`journalctl --user -u tally-orch`) for routine "is everything healthy"
checks.

## What was built

### `Orchestrator` sweep accounting

```python
self._started_at: float = time.time()
self._sweep_last_at: float | None = None
self._sweep_last_demoted: int = 0
self._sweep_total_demoted: int = 0
```

`run_recovery_sweeper` updates these every 60s; the status endpoint
reads them so the dashboard can show "last sweep N s ago, demoted M".
Without this the sweeper was invisible to operators — running but
unreported.

### `GET /admin/status` consolidated endpoint

Single payload combining the pool view, recent tasks, and sweeper
state so the CLI is one HTTP call instead of three:

```python
{
  "orchestrator": {
    "uptime_seconds": ..., "pool_size": ...,
    "sweep_last_at": ..., "sweep_last_demoted": ...,
    "sweep_total_demoted": ..., "recovery_timeout_seconds": ...,
    "auto_rotate_threshold": ...,
  },
  "workers": [ ... same shape as /admin/pool/status ... ],
  "tasks": [ ... task_limit most recent, default 10 ... ],
}
```

Bearer-token gated, same as the other `/admin/*` endpoints.

### `tally status` CLI subcommand

```
$ tally status
tally status — http://127.0.0.1:8080
──────────────────────────────────────────────────────────────────────
pool: 1 worker(s), 0 busy  uptime=7m37s
  cvm        identity       team suffix                  up       busy  fails
  22075862   rYl377WK-Vex   1779043406-f8e77c            5m02s    no    0

recent tasks (2):
  id         status         worker         elapsed  description
  bfe8ddb9   ✓ completed    rYl377WK-Vex   13s      write hello.py that prints hello
  01b408f5   ✓ completed    wXndxAcjCkZr   13s      write hello.py that prints hello world a

orchestrator:
  recovery sweeper: last=1s  demoted-last=0  demoted-total=0  timeout=600s
  memory: 81M (peak 166M, cap 2048M/3072M)
```

Memory pulled directly via `systemctl --user show tally-orch.service
--property=MemoryCurrent,MemoryPeak,MemoryHigh,MemoryMax` — no
orchestrator endpoint needed, the data lives in the cgroup.

`--task-limit N` overrides the default 10.

### Compact-age helper

```python
def _fmt_age(seconds):
    s = int(seconds)
    if s < 60:   return f"{s}s"
    if s < 3600: return f"{s // 60}m{s % 60:02d}s"
    if s < 86400: return f"{s // 3600}h{(s % 3600) // 60:02d}m"
    return f"{s // 86400}d{(s % 86400) // 3600:02d}h"
```

Used for both worker uptimes and task elapsed times. Avoids the
default `12.345s` formatting which breaks the column alignment.

## Validation

Submitted one task against a live pool=1 worker, ran `tally status`
mid-task (showed `▸ running`), then again after the task completed
(showed `✓ completed`, 13s elapsed). Both took <100 ms to render —
single HTTP call to `/admin/status` + a quick `systemctl show`.

Sweeper field updated correctly: `last=1s` immediately after a sweep
fired, `demoted-last=0` matching the actual zero-demotion run.

Memory output matched what `systemctl status tally-orch` showed
independently: `81M (peak 166M, cap 2048M/3072M)`.

## Files committed

- `services/orchestrator/tally_orchestrator/service.py`:
  - `Orchestrator.__init__`: `_started_at`, `_sweep_last_at`,
    `_sweep_last_demoted`, `_sweep_total_demoted` fields.
  - `run_recovery_sweeper`: updates the three sweep counters each
    iteration.
  - New `GET /admin/status` endpoint.
- `services/orchestrator/tally_orchestrator/cli.py`:
  - `cmd_status` handler.
  - `tally status` subparser wired in.
  - `_fmt_age` and `_systemd_memory` helpers.

No worker / SDK / deploy unit changes; no image bump.

## Open items

1. **No live refresh.** `tally status` is a one-shot snapshot. A
   `--watch N` flag that re-fetches every N seconds and re-renders
   in place would close the gap for "watch a task finish" use cases
   today served by `tally task tail <id>`. Punt.
2. **Memory display is host-local.** `_systemd_memory` shells out
   to `systemctl --user show` which only works when the CLI is
   running on the orchestrator host. From a laptop hitting a
   remote orchestrator, the memory line silently disappears. A
   future sprint could expose memory via `/admin/status`
   (cgroup-parsing on the server side) so it works remotely too.

## Next sprint

Per the proposed roadmap, **Sprint 22: Python SDK quickstart +
minimal example** — `pip install skytale-sdk`, a 10-line example
that creates an encrypted channel. Aligns with CLAUDE.md's primary
direction ("Python SDK is the primary interface").
