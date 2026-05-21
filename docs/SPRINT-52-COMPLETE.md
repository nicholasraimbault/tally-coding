# Sprint 52 — Admin gaps + audit log polish

**Status:** Code complete + deployed on `tally.pronoic.dev`
**Dates:** 2026-05-21 (spec) → 2026-05-21 (ship)
**Effort:** 17 commits, 20 files, +3,526 / -43 lines
**Image:** `tally-orch:v32` (deployed to Phala CVM `app_c3b5481b…`)
**Branch:** `feat/sprint-52-admin-gaps-audit-polish`
**Branch tags:** `s52-phase-a-done`, `s52-phase-b-done`, `s52-deployed-v32`, `s52-phase-c-done`, `s52-complete`

## What shipped

### Locked decisions

| | |
|---|---|
| Scope | ~40h — closes 5 deferred items from Sprints 50-51 (ownership transfer, Clerk validation, audit filter/export/prune) |
| Ownership transfer | 1-step. Owner picks any existing human workspace_member as recipient → recipient becomes owner, old owner auto-demoted to admin. No recipient-side acceptance. Atomic (BEGIN/COMMIT) — added after code review flagged autocommit-mode connection. |
| Clerk validation | Graceful fallback. `CLERK_SECRET_KEY` unset → skip (Sprint 50 behavior preserved); set → call Clerk REST `GET /v1/users/{id}` with 5-second timeout; 200 → True, 404 → False (invite rejected with `user_not_found`), 5xx/exception → None (graceful skip). Path-traversal guard on `user_id` (`re.fullmatch(r"user_[A-Za-z0-9]+")`) — added after review flagged SSRF surface. |
| Audit filters | `kind`, `actor_user_id`, `since`, `until` Query params on `GET /audit-log`. `since` inclusive, `until` exclusive. |
| Audit export | CSV via `GET /audit-log/export`. Owner+Admin only. 10,000 row cap. `csv.QUOTE_ALL` so JSON-in-payload column doesn't break the format. Honours filter Query params. |
| Audit retention | `POST /audit-log/prune {"older_than_days": int}`. 30-day floor (safety). Emits its own `audit_log_pruned` audit event after the DELETE. |

### Backend

**4 new routes + 1 helper + 1 helper extension:**

| Route / helper | Behavior |
|---|---|
| `POST /workspaces/{id}/transfer-ownership` | Owner-only. Atomic. Emits `workspace_ownership_transferred`. |
| `_validate_clerk_user(user_id)` (helper) | True / False / None. Path-traversal-safe via regex guard. |
| `POST /workspaces/{id}/members` (Sprint 50 route, extended) | One-line addition: `if exists is False: raise HTTPException(404, {"error":"user_not_found", ...})` after the existing authz checks. |
| `Db.list_audit_log` (Sprint 51 helper, extended) | 4 new optional kwargs (`kind`, `actor_user_id`, `since`, `until`). |
| `GET /workspaces/{id}/audit-log` (Sprint 51 route, extended) | Same 4 filter params as Query params. |
| `GET /workspaces/{id}/audit-log/export` | New. CSV download. 10k cap. |
| `POST /workspaces/{id}/audit-log/prune` | New. Owner+Admin. 30-day floor. Emits `audit_log_pruned`. |

**Audit kinds inventory:** Sprint 51 shipped 14 kinds; Sprint 52 adds 2 (`workspace_ownership_transferred`, `audit_log_pruned`). Total: 16 instrumented sites.

### Frontend

**`TallyOrchClient` additions (3 new + 1 extended):**

| Method | Wraps |
|---|---|
| `transferOwnership({workspaceId, newOwnerUserId})` | POST /workspaces/{id}/transfer-ownership |
| `listAuditLog({..., kind, actorUserId, since, until})` | GET /workspaces/{id}/audit-log (extended) |
| `exportAuditLogCsv({workspaceId, kind, actorUserId, since, until})` | GET /workspaces/{id}/audit-log/export → CSV string |
| `pruneAuditLog({workspaceId, olderThanDays})` | POST /workspaces/{id}/audit-log/prune |

**`WorkspaceSettingsScreen`:**
- New "Transfer ownership" button in Danger zone (owner-only). Opens `_TransferOwnershipDialog` with a dropdown of eligible human members. Old owner auto-demoted; SnackBar feedback; Navigator.pop on success.

**`AuditLogScreen` overhaul:**
- New collapsible "Filters" ExpansionTile at top: kind dropdown (Any + 17 kinds) + actor user_id text field + Clear/Apply buttons. Applying reloads `_loadFirst` with filter state.
- AppBar `actions:` now has 2 entries: `IconButton(Icons.download)` for CSV export + `PopupMenuButton` for prune.
- CSV export → `_ExportPreviewDialog` with 600×400 monospace SelectableText + "Copy to clipboard".
- Prune → `_PruneDialog` with days TextField (default 90, client-side 30 floor). On success, SnackBar reports deleted count + list refreshes.
- New `callerRole` constructor field threaded from WorkspaceSettingsScreen so prune visibility gate works (owner+admin only).

### Sprint 50-51 carry-overs closed

| Carry-over | Status |
|---|---|
| Workspace ownership transfer | ✅ Shipped (A1) |
| Clerk user resolution at invite time | ✅ Shipped (A2 + A3) |
| Audit log filtering / search UI | ✅ Shipped (A4 + A5 + B3) |
| Audit log retention/pruning | ✅ Shipped (A7 + B5) |
| Audit log export (CSV) | ✅ Shipped (A6 + B4) |

### Testing

- **Orchestrator:** 25 new pytest tests across 6 new files (`test_workspace_ownership_transfer`, `test_clerk_validation`, `test_audit_log_filters`, plus extensions to `test_audit_log_route`, `test_audit_log_export`, `test_audit_log_prune`). Full suite: **306 passed in 12.13s** — clean since Sprint 51.
- **Flutter:** 11 new tests across 3 new files (`api_ownership_transfer_test`, `api_audit_log_filters_test`, `api_audit_export_prune_test`) + extensions to `workspace_settings_screen_test` + `audit_log_screen_filters_test`. **75/75 PASS.**

### Code-review iterations

Two iterations driven by code-quality review (continuing the Sprint 47-51 review discipline):

1. **A1 → atomicity:** initial transfer-ownership impl had 3 sequential UPDATEs against an `isolation_level=None` connection — non-atomic. Wrapped in explicit `BEGIN`/`COMMIT`/`ROLLBACK` + added a rollback test that fakes a mid-transaction failure. Fix in `84d03d0`.
2. **A2 → path-traversal:** `_validate_clerk_user` interpolated user_id directly into the Clerk URL, allowing `user_x/../organizations` to escape the `/users/{id}` endpoint. Added `re.fullmatch(r"user_[A-Za-z0-9]+")` guard + 2 tests proving the regex short-circuits before any HTTP call. Fix in `29f5530`.

### Verification

Live smoke against `tally.pronoic.dev` post-deploy:

| Step | Result |
|---|---|
| `GET /health` | 200, pool_ready=false (pre-existing — no workers attached on prod) |
| `POST /workspaces/1/transfer-ownership` (self-transfer) | 400 `"cannot transfer to yourself"` (route exists; 400 path works) |
| `GET /workspaces/1/audit-log/export` | 200, CSV with proper QUOTE_ALL header + data rows |
| `POST /workspaces/1/audit-log/prune {"older_than_days":29}` | 400 `"older_than_days must be >= 30"` (floor enforced) |
| `GET /workspaces/1/audit-log?kind=workspace_created` | 200 `{"entries":[]}` (no entry of that kind on ws=1 since the workspace pre-dates audit instrumentation) |

## What's still deferred

| Item | Why deferred |
|---|---|
| Cross-workspace DMs | Identity model ramifications — separate sprint |
| Workspace icon file upload (presigned S3) | S3 infra is its own sprint |
| since/until in the Flutter filter bar UI | Unix timestamp text input is bad UX. Backend exposes them; UI sticks to kind+actor for now. |
| CLERK_SECRET_KEY enabled on production | Validation is dormant in prod (env var unset). Operators can flip it on via .env.prod whenever desired — A2's graceful fallback keeps existing behavior until then. |
| Promote workspace `owner_user_id` ↔ `workspace_members.role='owner'` dual-column invariant to a CHECK | Currently maintained only by `create_workspace` + transfer-ownership route. No other code path violates it, but a future contributor could. |

## Cumulative arc

Sprints 47-52 have shipped 6 production deploys (`tally-orch:v27`, `v28`, `v29.1`, `v30`, `v31`, `v32`), ~140 commits, full Discord-shaped workspace runtime + audit + admin polish + Clerk integration. The Flutter test suite has been green since Sprint 51 (75/75 in 52).

## References

- Sprint 52 spec: [`superpowers/specs/2026-05-21-sprint-52-admin-gaps-audit-polish-design.md`](superpowers/specs/2026-05-21-sprint-52-admin-gaps-audit-polish-design.md)
- Sprint 52 plan: [`superpowers/plans/2026-05-21-sprint-52-admin-gaps-audit-polish.md`](superpowers/plans/2026-05-21-sprint-52-admin-gaps-audit-polish.md)
- Sprint 51 complete: [`SPRINT-51-COMPLETE.md`](SPRINT-51-COMPLETE.md) (carry-over list)
- CVM: `app_c3b5481b3f33551af6270a21145df613160bf063`
- Image: `ghcr.io/nicholasraimbault/tally-orch:v32` (digest `sha256:5b5be5769a8c4ff28e503597b816ac5668709d9e116a7c8ce5a75e9ac79d16ec`)
