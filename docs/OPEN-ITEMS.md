# Tally Coding — open items log

Aggregated open items across Sprints 24-28 + the round-of-fixes pass.
Sorted by status; the small/closable ones live in the relevant
`SPRINT-N-COMPLETE.md` and get crossed off there.  This file is the
parking lot for items that are intentionally deferred and worth a
sprint of their own.

## Deferred (big-scope; needs design, not just code)

### Worker self-replenish from inside a hosted CVM   *(Sprint 24 #1)*
The orchestrator running in a Phala CVM can't docker-in-docker, so it
can't provision a replacement worker when the pinned one dies.  Today
the recovery path is a laptop-side re-seed
(`scripts/seed-cvm-orchestrator-env.py`) + `phala deploy --cvm-id …`
to push the new env.

A real fix wants a *control plane* — a small companion service running
on a host with Docker that the CVM orchestrator can poke ("please
provision a replacement").  Options:
- A tiny CF Worker that fans out a `phala deploy` to a self-hosted
  GitHub Actions runner.  Heavy, but stays inside the existing
  pronoic ecosystem.
- A second CVM that's allowed dind via privileged mode (Phala
  doesn't currently expose that).
- A lightweight always-on "ops box" that just runs
  `scripts/seed-cvm-orchestrator-env.py` on demand.  Simplest.

**Why deferred:** picking the topology is a real decision, not just an
implementation.  And the Sprint 28 local-worker daemon already gives
the laptop a way to be a worker — adding *that* to the CVM's pool is
often enough headroom in practice.

### CRDT merge semantics for parallel artifacts   *(Sprint 27 #2)*
`_task_artifacts` is a plain dict; parallel agents writing the same
path last-write-wins.  For disjoint workspaces (`frontend/*` vs
`backend/*`) that's fine; for two agents both touching `README.md`
it's the wrong primitive.

The locked architecture memo names Skytale's `SharedContext` (CRDT +
HLC + write policies) as the substrate.  Doing it properly is its own
sprint:
1. Wire `SkytaleChannelManager` into the orchestrator.
2. Replace the in-memory dict with a `SharedContext` keyed by
   task_id, with one entry per path.
3. Define write policies per agent role (Reviewer can write only
   under `reviews/*`, etc.).

**Why deferred:** today's task shapes don't actually overlap.  When a
real merge conflict bites a real user, we'll have a concrete shape to
design around.

### Multi-host local workers   *(Sprint 28 #2)*
Today the compose env accepts exactly one `TEAM_ID_LOCAL` +
`WORKER_IDENTITY_B64_LOCAL` pair.  A team of users (e.g. multiple
laptops, all running `tally-agent`) would want a pool of local
workers, not just one.

Easy path: support `TEAM_ID_LOCAL_<n>` and `WORKER_IDENTITY_B64_LOCAL_<n>`
indexes, or accept a JSON-array env var.  Plus a `host=` tag on each
so the architect can route ("worker_affinity=host:nicks-laptop").

**Why deferred:** today this is a one-user product.  Multi-user pool
is what Sprint 32 (Clerk OIDC) tees up; do it then.

### @-mention redirect plumbing   *(Sprint 25 #2)*
The locked UX has @-mention redirects fire a `task:redirect` wake so
the worker accepts a course-correction at the next step boundary.
The UI surface ships in Sprint 25 (member tiles are clickable, but
the click is a no-op).  Worker-side acceptance + orchestrator-side
routing land at Sprint 33+.

**Why deferred:** the design depends on OpenHands' upcoming event-loop
APIs (mid-step interrupt is harder than between-step).

### Light theme   *(Sprint 25 #4)*
The shell + each panel hard-codes Discord-dark palette literals
(`Color(0xFF2B2D31)`, etc.).  A real light theme means extracting a
`ColorTokens` ThemeExtension and replacing ~80 literals across
`discord_shell.dart`, `general_channel.dart`, `task_channel.dart`,
`channel_header.dart` and the chip / member-tile widgets, then
following `MediaQuery.platformBrightness`.

**Why deferred:** the mechanical refactor surface is large and not
urgent — the dark theme works on every platform and most coding-tool
users have dark muscle memory.  Worth a focused 1-hour sprint when
someone asks for it.

### Worker re-bootstrap on stale MLS sessions
Not officially logged but worth a sprint of its own: when the
orchestrator restarts mid-task, the worker's MLS ratchet position is
ahead of the new orchestrator's freshly-bootstrapped session.  Today
we ack+skip the decrypt failures (Sprint 18 fix) and the next event
encrypted with the current ratchet works.  But for a long-running
worker through many orchestrator restarts, this drift compounds.

Real fix: a "re-handshake" path the orchestrator can trigger
unilaterally without dropping the worker.

## Closed in the round-of-fixes pass (Sprint 28.5)

- ✓ Sprint 24 #2 — Volume backup.  `/admin/backup` endpoints +
  nightly task that writes `tasks-<stamp>.db` to `ORCH_BACKUP_DIR`
  (default `/data/backups`, keeps 7).
- ✓ Sprint 26 #1 — Snapshot replay.  New `task_artifacts` table;
  result-event handler upserts; lifespan rehydrates the in-memory
  map for any non-terminal task.
- ✓ Sprint 26 #2 — Per-agent files panel (Flutter).  See SPRINT-25.5.
- ✓ Sprint 27 #3 — Stage boundaries visible.  Task channel header
  shows the stage number alongside the agent name.
- ✓ Sprint 28 #1 — Sandbox hardening.  Systemd unit now applies
  `ProtectHome=read-only` + `BindPaths={DATA_DIR}` +
  `ProtectKernelTunables=yes` and friends, with a successful smoke
  start.
- ✓ Sprint 28 #3 — Affinity fallover.  Strict `local`/`tee` retries
  once with no affinity before failing the task.
- ✓ Sprint 28 #4 — Standalone tally-agent venv.  `tally-agent install
  --standalone` provisions a dedicated venv at
  `~/.local/share/tally-agent/venv/` (requires cargo+rustup until
  skytale-sdk publishes `MlsEngine` to PyPI).

## Skipped this round

- Sprint 25 #4 — Light theme.  Punted; tracked above (mechanical
  refactor across 80+ color literals).
