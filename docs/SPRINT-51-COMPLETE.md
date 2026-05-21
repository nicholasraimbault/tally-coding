# Sprint 51 — Audit log + channel archival + Sprint 50 carry-over cleanup

**Status:** Code complete + deployed on `tally.pronoic.dev`
**Dates:** 2026-05-21 (spec) → 2026-05-21 (ship)
**Effort:** 18 commits, 22 files, +2,808 / -181 lines
**Image:** `tally-orch:v31` (deployed to Phala CVM `app_c3b5481b…`)
**Branch:** `feat/sprint-51-audit-archival-cleanup`
**Branch tags:** `s51-phase-a-done`, `s51-phase-b-done`, `s51-deployed-v31`, `s51-phase-c-done`, `s51-complete`

## What shipped

### Locked decisions

| | |
|---|---|
| Scope | ~35h — cleanup + workspace audit log + channel archival UI |
| Audit events | 14 kinds: workspace + member + channel CRUD + persistent-agent lifecycle (including `actor_kind='system'` for auto-pause) |
| Audit retention | Forever (no pruning) |
| Audit read access | Owner + Admin only (per Sprint 47 permission matrix) |
| Channel archival | Custom + task channels via direct route; scheduled_agent auto-archives on persistent-agent delete |

### Backend

**New schema** — `workspace_audit_log` table (9 columns: id, workspace_id, actor_user_id, actor_kind, kind, target_kind, target_id, payload_json, created_at) + 2 indexes (`idx_audit_log_workspace`, `idx_audit_log_actor`). Idempotent via the `SCHEMA` constant.

**Db helpers:**
- `audit_log(workspace_id, actor_user_id, actor_kind='human', kind, target_kind, target_id, payload)` — best-effort insert; callers wrap in try/except so logging never breaks the request.
- `list_audit_log(workspace_id, limit, before_id)` — newest-first, keyset-paginated.

**14 instrumented event sites** (all wrapped in try/except so audit failures are non-fatal):

| Site | Kind |
|---|---|
| `POST /workspaces` | `workspace_created` |
| `PATCH /workspaces/{id}` (name changed) | `workspace_renamed` |
| `PATCH /workspaces/{id}` (settings changed) | `workspace_settings_updated` |
| `DELETE /workspaces/{id}` | `workspace_deleted` |
| `POST /workspaces/{id}/members` | `member_invited` |
| `DELETE /workspaces/{id}/members/{u}` | `member_removed` |
| `POST /workspaces/{id}/leave` | `member_left` |
| `PATCH /workspaces/{id}/members/{u}` (role changed) | `member_role_changed` |
| `POST /channels` (kind=custom) | `channel_created` |
| `POST /channels/{id}/archive` | `channel_archived` |
| `POST /channels/{id}/unarchive` | `channel_unarchived` |
| `POST /persistent_agents` | `persistent_agent_created` |
| `PATCH /persistent_agents/{id}` (enabled flipped) | `persistent_agent_enabled_toggled` |
| `DELETE /persistent_agents/{id}` | `persistent_agent_deleted` |
| `Db.bump_persistent_agent_failure` (threshold hit) | `persistent_agent_auto_paused` (actor_kind='system') |

**5 new routes:**

| Route | Behavior |
|---|---|
| `DELETE /workspaces/{id}` | Owner-only soft delete (sets `deleted_at`). |
| `POST /workspaces/{id}/leave` | Non-owner self-remove. Owner gets 400 (must delete instead). |
| `POST /channels/{id}/archive` | Admin+ only. Restricted to `kind IN ('custom', 'task')`. |
| `POST /channels/{id}/unarchive` | Admin+ only. Same kind restriction. |
| `GET /workspaces/{id}/audit-log?limit=N&before_id=N` | Owner+Admin only. Keyset pagination via `before_id`. Limit clamped 1–500. |

**`Db.delete_persistent_agent` extended** to also archive the agent's `scheduled_agent` channel.

### Frontend

**`TallyOrchClient` additions (5 methods):** `listAuditLog`, `archiveChannel`, `unarchiveChannel`, `deleteWorkspace`, `leaveWorkspace`.

**`AuditLogScreen` (new):** humanized list of audit entries with icon-by-kind (👤 member events, 🏷 channel events, ⚡ persistent agent events, 🏢 workspace events, ⏱ system events). Keyset pagination via "Load more" footer tile. Empty state when no entries. Pull-to-refresh.

**`WorkspaceSettingsScreen`** updates:
- Leave / Delete buttons now call real API endpoints (Sprint 50's SnackBar TODOs replaced)
- New "Activity log" `ListTile` entry (Owner+Admin only) pushes `AuditLogScreen`
- New "Archived channels" section between Activity log and Danger zone — lists custom channels with `archived_at != null` + per-row "Unarchive" button

**Channel rail extension:** custom channel tiles gain a trailing `PopupMenuButton` (`more_horiz` icon) with an "Archive" option. Archive → calls API → refreshes rail with success SnackBar.

### Sprint 50 carry-overs closed

| Carry-over | Status |
|---|---|
| Leave/Delete workspace endpoints | ✅ Shipped (A4, A5) |
| Wire Leave/Delete buttons in settings | ✅ Shipped (B3) |
| Old `_ServerRail` placeholder cleanup | ✅ Deleted (B6) — 129 lines of dead code removed |
| Broken `widget_test.dart::four-column-layout` | ✅ Deleted (B7) — file no longer present |

### Testing

- Orchestrator: 32 new pytest tests across 7 new files (`test_audit_log_schema`, `test_audit_log_helpers`, `test_audit_log_instrumented` (12 tests), `test_audit_log_route`, `test_workspace_delete`, `test_workspace_leave`, `test_channel_archive`). Full suite: **275 passed in 10.22s**.
- Flutter: 9 new tests across 4 new files (`api_audit_log_test`, `api_channel_archive_test`, `api_workspace_lifecycle_test`, `audit_log_screen_test`) plus 1 new assertion in `workspace_settings_screen_test`. **64/64 PASS — first fully-green Flutter suite since Sprint 47.**

### Verification

Live smoke against `tally.pronoic.dev`:

| Step | Result |
|---|---|
| `GET /health` | 200 |
| `POST /workspaces` → `DELETE /workspaces/{id}` | 200 + 200; workspace gone from `/me/workspaces` |
| `POST /channels` (custom) → `POST /archive` → `POST /unarchive` | 200 × 3 |
| `GET /workspaces/1/audit-log` | 200, returns ordered entries: `channel_unarchived`, `channel_archived`, `channel_created` (newest first) |

## What's still deferred

Carry-overs that did NOT make Sprint 51:

| Item | Why deferred |
|---|---|
| Workspace ownership transfer | Substantial — needs dedicated route + tests + UI |
| Clerk user resolution at invite time | Clerk API integration + error handling |
| Cross-workspace DMs | Identity ramifications |
| Workspace icon file upload (presigned S3) | URL-only today; S3 infra is its own sprint |
| Audit log retention/pruning | Forever in Sprint 51; 90-day cap or operator-controlled pruning later |
| Audit log filtering / search UI | Sprint 51 ships chronological list only |
| Audit log export (CSV/JSON) | Sprint 52+ if anyone asks |

## Cumulative arc

Sprints 47-51 have shipped 5 production deploys (`tally-orch:v27`, `v28`, `v29.1`, `v30`, `v31`), ~125 commits, full Discord-shaped workspace runtime plus its audit + cleanup tail. The Flutter test suite is green for the first time since Sprint 47.

## References

- Sprint 51 spec: [`superpowers/specs/2026-05-21-sprint-51-audit-archival-cleanup-design.md`](superpowers/specs/2026-05-21-sprint-51-audit-archival-cleanup-design.md)
- Sprint 51 plan: [`superpowers/plans/2026-05-21-sprint-51-audit-archival-cleanup.md`](superpowers/plans/2026-05-21-sprint-51-audit-archival-cleanup.md)
- Sprint 50 complete: [`SPRINT-50-COMPLETE.md`](SPRINT-50-COMPLETE.md) (had the carry-over list)
- Sprint 47 permission matrix: parent Discord-shaped workspace spec §"Permission model"
- CVM: `app_c3b5481b3f33551af6270a21145df613160bf063`
- Image: `ghcr.io/nicholasraimbault/tally-orch:v31` (digest `sha256:3cbae24bd0e4ec650527e2ff6523a652ab30474d581fd62121f6bcfd3821a746`)
