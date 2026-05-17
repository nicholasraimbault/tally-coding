# Sprint 17 — GHCR tag garbage collection

**Status: PASS** — Sprint 16's per-deploy build flow pushes a new
GHCR package version on every `pool.provision`, and overwritten tags
leave orphaned manifests behind. After ~30 deploys the GHCR project
had 42 versions, 28 of them untagged. Sprint 17 adds an admin GC
that classifies versions by tag pattern + worker activity and deletes
the stale ones. Validated end-to-end: 42 → 10 versions in one pass,
zero errors.

## What was built

### `WorkerPool.gc_image_versions(...)`

Lists every version of `tally-spike-day4-worker` on GHCR via
`gh api --paginate`, classifies each one, and deletes the stale ones
via `DELETE /user/packages/container/.../versions/{id}`.

Classification rules:

1. **Tagged with any non-`v10-tally-auto-*` tag** → **PROTECTED** (skip).
   This is what saves base images like `v10`, `v9`, `v1`, `latest`,
   and also any auto-deploy tags that happen to share a digest with a
   protected tag (observed: when older `docker tag` pushes pointed
   different team aliases at the same manifest as `v10`).
2. **Tagged only with `v10-tally-auto-<team_id>` where any team_id is
   currently active** → **PROTECTED** (skip). The orchestrator passes
   its set of active team IDs from `db.list_active_workers()` so the
   GC can't accidentally yank an image referenced by a CVM that's
   serving traffic.
3. **Tagged only with `v10-tally-auto-<team_id>` where all team_ids are
   retired**, AND **older than `older_than_seconds`** → **eligible**.
   The age guard avoids deleting a tag from a worker that retired
   seconds ago (mid-rotation race).
4. **Untagged** (orphaned manifest, no refs), AND older than threshold
   → **eligible**.

```python
def gc_image_versions(self, *, keep_team_ids: set[str],
                     older_than_seconds: int = 3600,
                     dry_run: bool = False) -> dict:
    ...
    # `gh api --paginate /user/packages/container/<pkg>/versions`
    # GH_TOKEN points at the user's PAT for delete:packages scope
    # (see "Auth setup" below).
```

Returns a structured summary:

```json
{
  "dry_run": false,
  "total_versions": 42,
  "eligible": [],
  "removed": [...32 entries...],
  "errors": [],
  "kept": {
    "active_worker_tag": 0,
    "protected_tag": 10,
    "too_recent": 0
  }
}
```

### Admin endpoint + CLI

```http
POST /admin/pool/gc
Authorization: Bearer <api_token>
{"dry_run": true, "older_than_hours": 1.0}
```

```bash
$ tally pool gc --dry-run --older-than-hours 1
GHCR GC (dry-run, older_than=1h)...
  total versions: 42
  kept (active worker tag):  0
  kept (protected tag):      10
  kept (too recent):         0
  eligible for removal:      32
    870986742 sha256:eb939... v10-tally-auto-1779038606-2127cf (2026-05-17T17:23:30Z)
    870986741 sha256:29fe3... v10-tally-auto-1779038606-a4d1a7 (2026-05-17T17:23:30Z)
    870986731 sha256:5c6b5... <untagged>                       (2026-05-17T17:23:30Z)
    ... and 29 more
  (re-run without --dry-run to delete)

$ tally pool gc --older-than-hours 1
GHCR GC (running, older_than=1h)...
  removed:                   32
```

### Auth setup (one-time per host)

`gh`'s default OAuth token doesn't carry the `delete:packages` scope —
`DELETE /user/packages/container/.../versions/{id}` returns HTTP 403.
The orchestrator looks for a Personal Access Token at
`~/.config/tally-orch/ghcr-token` and passes it via `GH_TOKEN` for the
delete calls only.

Generate the PAT at
https://github.com/settings/tokens/new?scopes=delete:packages,read:packages
(scopes pre-checked) and drop it in via:

```bash
zenity --password --title="GitHub PAT for GHCR delete" > ~/.config/tally-orch/ghcr-token
chmod 600 ~/.config/tally-orch/ghcr-token
```

Without the token file, `tally pool gc --dry-run` still works (listing
uses keyring auth) and actual deletes return 403 errors in the response
body so the operator can spot the missing setup.

## E2E validation (12:38-12:41 CDT 2026-05-17)

Initial GHCR state for `tally-spike-day4-worker`:

```
total       : 42 versions
tagged      : 14
untagged    : 28
v10-tally-auto-* tags : 5 (across 5 versions)
```

Dry run reported `32 eligible` — 28 untagged + 4 of the 5
`v10-tally-auto-*` versions (the 5th shares a digest with the
protected `v10` tag).

Real run: **32 removed, 0 errors.**

Post-GC state:

```
total       : 10 versions
tagged      : 10
untagged    : 0
v10-tally-auto-* tags : 1 (the digest also bears the `v10` tag, kept)
```

Verified via the same `gh api` query — every removed version is gone;
every protected version remains; no orphans.

## Files committed

- `services/orchestrator/tally_orchestrator/worker_pool.py`:
  - `GHCR_OWNER`, `GHCR_PACKAGE`, `DEPLOY_TAG_PREFIX` constants.
  - `gc_image_versions()` method (~80 LoC including doc).
- `services/orchestrator/tally_orchestrator/service.py`:
  - `PoolGcBody` pydantic model.
  - `POST /admin/pool/gc` endpoint (~25 LoC).
- `services/orchestrator/tally_orchestrator/cli.py`:
  - `cmd_pool_gc` handler + `tally pool gc` subcommand wiring.

No worker / SDK / deploy unit changes. `~/.config/tally-orch/ghcr-token`
is operator-provided and intentionally gitignored.

## Open items

1. **No automatic scheduling.** GC is manual via `tally pool gc` for
   now. A cron-style scheduler inside the orchestrator (or a
   `systemd --user` timer) would amortise the manual step away.
   Deferring until the project has enough churn that manual is
   annoying.
2. **`gh` is the hard dependency.** If `gh` isn't on the PATH, the
   method raises. We could drop down to `httpx` + manual REST calls
   to remove the dependency, but the gh CLI handles pagination and
   token lookup cleanly and is already implicit for `docker login`.
3. **Mixed-tag versions aren't pruned.** A version with one protected
   tag (`v10`) + N auto-deploy tags keeps the auto-deploy tags around
   forever (untagging individual tags isn't supported by GHCR's API
   for container packages — you'd have to re-push `v10` against a
   different manifest). Low impact: at most a handful of these per
   project.

## Next sprint candidates

1. **Clerk OIDC** — multi-user auth (single bearer token today).
2. **Mobile build** of `tally_coding_app` for Android.
3. **Persist result wakes in tally-workers** so a recovered
   orchestrator can pick up where it left off (today's Sprint 15
   stuck-task heal marks them `failed`).
4. **systemd timer for `tally pool gc`** so the manual step from
   Sprint 17 fades into background ops.
