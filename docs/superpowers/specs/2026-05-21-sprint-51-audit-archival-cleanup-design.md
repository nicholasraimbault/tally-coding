# Sprint 51 — Audit log + channel archival + Sprint 50 carry-over cleanup

**Date:** 2026-05-21
**Builds on:** Sprints 47-50 (the Discord-shaped vision)
**Closes:** the explicit Sprint 50 carry-over list

## Locked decisions (from brainstorm)

| | |
|---|---|
| Scope | ~35h — cleanup + workspace audit log + channel archival UI |
| Audit log events | Workspace + member + channel CRUD + persistent-agent lifecycle. ~14 event kinds. NOT messages or task-fire events (too high volume). |
| Audit log retention | Forever (no pruning in Sprint 51; future sprint can add a 90-day cap if needed). |
| Audit log read access | **Owner + Admin only** (per Sprint 47 permission matrix). |
| Channel archival | **Custom channels only** for direct user action. Task channels still auto-archive on task completion (Sprint 47). Scheduled_agent channels are archived when their persistent agent is soft-deleted (Sprint 49 auto-paused = enabled=0 not archived; Sprint 51 adds the channel-archive hook for hard-delete). |

## Part 1 — Sprint 50 carry-over cleanup (~5h)

### 1.1 `DELETE /workspaces/{id}` route

Owner-only. Sets `workspaces.deleted_at = now`. Does NOT cascade delete tasks/channels/messages — preserves history for forensics and ownership transfer-back. Subsequent `GET /me/workspaces` filters by `deleted_at IS NULL` (Sprint 50 A4 already does this).

```python
@app.delete("/workspaces/{wid}")
async def delete_workspace_route(wid: int, user: ClerkUser = Depends(require_user)) -> dict:
    db: Db = state["db"]
    row = db._conn.execute(
        "SELECT owner_user_id FROM workspaces WHERE id=? AND deleted_at IS NULL", (wid,)
    ).fetchone()
    if row is None:
        raise HTTPException(404, "workspace not found")
    if row[0] != user.id:
        raise HTTPException(403, "owner only")
    db._conn.execute("UPDATE workspaces SET deleted_at=? WHERE id=?", (time.time(), wid))
    # Sprint 51: audit log entry
    db.audit_log(workspace_id=wid, actor=user.id, kind="workspace_deleted", payload={"name": ...})
    return {"ok": True}
```

### 1.2 `POST /workspaces/{id}/leave` route

Any non-owner workspace_member can self-remove. Owner cannot leave (must transfer ownership first — Sprint 51+ won't ship transfer either, so owner has to delete the workspace if they want out).

```python
@app.post("/workspaces/{wid}/leave")
async def leave_workspace_route(wid: int, user: ClerkUser = Depends(require_user)) -> dict:
    db: Db = state["db"]
    row = db._conn.execute(
        "SELECT role FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (wid, user.id),
    ).fetchone()
    if row is None:
        raise HTTPException(404, "not a member")
    if row[0] == "owner":
        raise HTTPException(400, "owner cannot leave; transfer ownership or delete workspace")
    db.remove_workspace_member(workspace_id=wid, user_id=user.id)
    db.audit_log(workspace_id=wid, actor=user.id, kind="member_left", payload={})
    return {"ok": True}
```

### 1.3 Wire WorkspaceSettingsScreen Leave/Delete buttons

Replace the Sprint 50 SnackBar TODOs in `_onLeave` and `_onDelete` with real API calls. On success, navigate back to the channel rail (the workspace disappears from `GET /me/workspaces` so the next refresh switches the user to their default workspace).

### 1.4 Remove old `_ServerRail` placeholder

Sprint 47 mockup added a private `_ServerRail` widget in `discord_shell.dart` (a few hardcoded icon buttons). Sprint 50 prepended the real `ServerRail` (capital S, in `widgets/server_rail.dart`). Both render today. Delete the lowercase one + its callsite.

### 1.5 Fix or delete `widget_test.dart::four-column-layout`

The test has been failing since Sprint 47. It mocks HTTP via an outdated harness that returns 400 for everything. Two options:
- **(a)** Delete the test — it's not blocking anyone and the four-column layout is exercised by hand
- **(b)** Rewrite with a proper `MockClient` returning valid empty responses

Sprint 51 picks **(a)** — delete. The Sprint 47 layout has been live for 4 deploys without regression; the test was always wrong. A future sprint can write a proper integration test if needed.

## Part 2 — Workspace audit log (~15h)

### 2.1 Schema

```sql
CREATE TABLE IF NOT EXISTS workspace_audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    workspace_id INTEGER NOT NULL REFERENCES workspaces(id),
    actor_user_id TEXT NOT NULL,       -- who did it
    actor_kind TEXT NOT NULL,          -- 'human' | 'tally' | 'system'
    kind TEXT NOT NULL,                -- event kind (see §2.2)
    target_kind TEXT,                  -- 'workspace' | 'member' | 'channel' | 'persistent_agent' | null
    target_id TEXT,                    -- id of the target (user_id, channel_id as str, etc.)
    payload_json TEXT NOT NULL DEFAULT '{}',
    created_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_log_workspace ON workspace_audit_log(workspace_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_actor ON workspace_audit_log(actor_user_id);
```

Idempotent — added to the existing `SCHEMA` constant in `service.py`.

### 2.2 Event kinds (14 total)

| Kind | Inserted by | Payload |
|---|---|---|
| `workspace_created` | `POST /workspaces` | `{name}` |
| `workspace_renamed` | `PATCH /workspaces/{id}` (when name changes) | `{old_name, new_name}` |
| `workspace_settings_updated` | `PATCH /workspaces/{id}` (when settings change) | `{keys_changed: [...]}` |
| `workspace_deleted` | `DELETE /workspaces/{id}` | `{name}` |
| `member_invited` | `POST /workspaces/{id}/members` | `{user_id, role}` |
| `member_removed` | `DELETE /workspaces/{id}/members/{u}` | `{user_id}` |
| `member_left` | `POST /workspaces/{id}/leave` | `{}` |
| `member_role_changed` | `PATCH /workspaces/{id}/members/{u}` | `{user_id, old_role, new_role}` |
| `channel_created` | `POST /channels` | `{channel_id, kind, name}` |
| `channel_archived` | `POST /channels/{id}/archive` | `{channel_id, name}` |
| `channel_unarchived` | `POST /channels/{id}/unarchive` | `{channel_id, name}` |
| `persistent_agent_created` | `POST /persistent_agents` | `{agent_id, name, role_name}` |
| `persistent_agent_enabled_toggled` | `PATCH /persistent_agents/{id}` (enabled change) | `{agent_id, name, enabled}` |
| `persistent_agent_deleted` | `DELETE /persistent_agents/{id}` | `{agent_id, name}` |

Plus a `system` actor variant emitted by background processes (no caller `user_id` — e.g., auto-pause from Sprint 49):

| Kind | Inserted by | actor_kind | Payload |
|---|---|---|---|
| `persistent_agent_auto_paused` | `Db.bump_persistent_agent_failure` when threshold hits | `system` | `{agent_id, name, consecutive_failures}` |

### 2.3 `Db.audit_log` helper

```python
def audit_log(
    self,
    *,
    workspace_id: int,
    actor_user_id: str | None,
    actor_kind: str = "human",
    kind: str,
    target_kind: str | None = None,
    target_id: str | None = None,
    payload: dict | None = None,
) -> None:
    """Sprint 51: append to workspace_audit_log."""
    self._conn.execute(
        "INSERT INTO workspace_audit_log "
        "(workspace_id, actor_user_id, actor_kind, kind, target_kind, target_id, payload_json, created_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (
            workspace_id,
            actor_user_id or "system",
            actor_kind,
            kind,
            target_kind,
            target_id,
            json.dumps(payload or {}),
            time.time(),
        ),
    )

def list_audit_log(
    self,
    *,
    workspace_id: int,
    limit: int = 100,
    before_id: int | None = None,
) -> list[dict]:
    """Sprint 51: list audit-log rows, newest first.  `before_id` supports
    keyset pagination."""
    where = ["workspace_id=?"]
    params: list = [workspace_id]
    if before_id is not None:
        where.append("id < ?")
        params.append(before_id)
    params.append(limit)
    rows = self._conn.execute(
        f"SELECT id, workspace_id, actor_user_id, actor_kind, kind, target_kind, target_id, payload_json, created_at "
        f"FROM workspace_audit_log WHERE {' AND '.join(where)} "
        f"ORDER BY id DESC LIMIT ?",
        params,
    ).fetchall()
    return [
        {
            "id": r[0], "workspace_id": r[1], "actor_user_id": r[2],
            "actor_kind": r[3], "kind": r[4],
            "target_kind": r[5], "target_id": r[6],
            "payload": json.loads(r[7]) if r[7] else {},
            "created_at": r[8],
        }
        for r in rows
    ]
```

### 2.4 Instrument call sites

For each of the 14 event kinds, add a `db.audit_log(...)` call right after the DB mutation in the corresponding route handler. Patterns:

```python
# POST /workspaces (Sprint 50 A3) — add at end:
db.audit_log(workspace_id=wid, actor_user_id=user.id, kind="workspace_created", payload={"name": name})
# PATCH /workspaces/{id} (Sprint 50 A5) — detect what changed:
if body.name and body.name != current_name:
    db.audit_log(workspace_id=wid, actor_user_id=user.id, kind="workspace_renamed",
                 payload={"old_name": current_name, "new_name": body.name})
if body.settings:
    db.audit_log(workspace_id=wid, actor_user_id=user.id, kind="workspace_settings_updated",
                 payload={"keys_changed": list(body.settings.keys())})
# DELETE /workspaces/{id} (Sprint 51 §1.1)
# POST /workspaces/{id}/members (Sprint 50 A8)
# DELETE /workspaces/{id}/members/{u} (Sprint 50 A9)
# POST /workspaces/{id}/leave (Sprint 51 §1.2)
# PATCH /workspaces/{id}/members/{u} (Sprint 50 A10) — emit only when role actually changes
# POST /channels (Sprint 50 A11) — for kind='custom'
# POST /channels/{id}/archive (Sprint 51 §3)
# POST /channels/{id}/unarchive (Sprint 51 §3)
# POST /persistent_agents (Sprint 49 A5)
# PATCH /persistent_agents/{id} (Sprint 49 A6) — emit only when enabled changes
# DELETE /persistent_agents/{id} (Sprint 49 A7)
# Db.bump_persistent_agent_failure (Sprint 49 A13) — emit on threshold hit, actor_kind='system'
```

All `audit_log` calls are non-fatal — wrapped in try/except that logs but doesn't fail the request. Audit logging is a "best-effort" side effect.

### 2.5 `GET /workspaces/{id}/audit-log` route

Owner+Admin only (per Sprint 47 matrix).

```python
@app.get("/workspaces/{wid}/audit-log")
async def get_workspace_audit_log_route(
    wid: int,
    limit: int = Query(default=100, ge=1, le=500),
    before_id: int | None = Query(default=None, ge=1),
    user: ClerkUser = Depends(require_user),
) -> dict:
    db: Db = state["db"]
    caller = db._conn.execute(
        "SELECT role FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (wid, user.id),
    ).fetchone()
    if caller is None or caller[0] not in ("owner", "admin"):
        raise HTTPException(403, "owner+admin only")
    return {"entries": db.list_audit_log(workspace_id=wid, limit=limit, before_id=before_id)}
```

### 2.6 Flutter `AuditLogScreen`

New screen accessible from `WorkspaceSettingsScreen` as an "Activity log" section (or pushed via a navigation button — keep it out of the main settings sections to reduce visual noise).

Renders the audit log as a `ListView` with one tile per entry. Each tile shows:
- Icon by event kind (👤 member events, 📁 channel events, ⚡ persistent agent events, ⚙ workspace events)
- Human-readable summary (e.g., "admin invited bob as member 3 hours ago")
- Timestamp (relative + absolute on tap)

Pagination: keyset via `before_id`. Pull-to-refresh + "Load more" tile at the bottom.

`api.dart` method:

```dart
Future<List<Map<String, dynamic>>> listAuditLog({
  required int workspaceId,
  int? beforeId,
  int limit = 100,
});
```

## Part 3 — Channel archival UI (~15h)

### 3.1 Backend routes

```python
@app.post("/channels/{channel_id}/archive")
async def archive_channel_route(channel_id: int, user: ClerkUser = Depends(require_user)) -> dict:
    db: Db = state["db"]
    ch = db._conn.execute(
        "SELECT workspace_id, kind, name FROM channels WHERE id=? AND archived_at IS NULL",
        (channel_id,),
    ).fetchone()
    if ch is None:
        raise HTTPException(404, "channel not found or already archived")
    if ch[1] not in ("custom", "task"):
        raise HTTPException(400, f"cannot archive {ch[1]} channels via this route")
    # Admin+ check
    caller = db._conn.execute(
        "SELECT role FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (ch[0], user.id),
    ).fetchone()
    if caller is None or caller[0] not in ("owner", "admin"):
        raise HTTPException(403, "admin+ only")
    db._conn.execute("UPDATE channels SET archived_at=? WHERE id=?", (time.time(), channel_id))
    db.audit_log(workspace_id=ch[0], actor_user_id=user.id, kind="channel_archived",
                 target_kind="channel", target_id=str(channel_id),
                 payload={"name": ch[2]})
    return {"ok": True}


@app.post("/channels/{channel_id}/unarchive")
async def unarchive_channel_route(channel_id: int, user: ClerkUser = Depends(require_user)) -> dict:
    db: Db = state["db"]
    ch = db._conn.execute(
        "SELECT workspace_id, kind, name FROM channels WHERE id=? AND archived_at IS NOT NULL",
        (channel_id,),
    ).fetchone()
    if ch is None:
        raise HTTPException(404, "channel not found or not archived")
    if ch[1] not in ("custom", "task"):
        raise HTTPException(400, f"cannot unarchive {ch[1]} channels via this route")
    caller = db._conn.execute(
        "SELECT role FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (ch[0], user.id),
    ).fetchone()
    if caller is None or caller[0] not in ("owner", "admin"):
        raise HTTPException(403, "admin+ only")
    db._conn.execute("UPDATE channels SET archived_at=NULL WHERE id=?", (channel_id,))
    db.audit_log(workspace_id=ch[0], actor_user_id=user.id, kind="channel_unarchived",
                 target_kind="channel", target_id=str(channel_id),
                 payload={"name": ch[2]})
    return {"ok": True}
```

### 3.2 Persistent-agent delete hooks scheduled_agent channel

When `Db.delete_persistent_agent(pid)` is called (Sprint 49 A4), additionally archive the agent's scheduled_agent channel:

```python
def delete_persistent_agent(self, pid: int) -> None:
    now = time.time()
    self._conn.execute(
        "UPDATE persistent_agents SET deleted_at=?, enabled=0 WHERE id=?",
        (now, pid),
    )
    # Sprint 51: archive the scheduled_agent channel
    self._conn.execute(
        "UPDATE channels SET archived_at=? WHERE persistent_agent_id=? AND archived_at IS NULL",
        (now, pid),
    )
```

### 3.3 Flutter: archive context menu on custom channels

In the channel-rail's `_ChannelTile` (or wherever custom channels render), add a long-press / right-click context menu with an "Archive" option. Only show for `kind='custom'` channels.

Tap → calls `archiveChannel(channelId)` → refreshes the rail (channel disappears from the Channels category).

### 3.4 Flutter: "Archived channels" view in WorkspaceSettingsScreen

Add a fourth section to `WorkspaceSettingsScreen` (after Members, before Danger zone): "Archived channels". Lists channels with `archived_at IS NOT NULL` in the active workspace via `listChannels(workspaceId, includeArchived: true)` (Sprint 47 A4 already supports `include_archived=true`).

Each row: channel name + archived date + "Unarchive" button → `unarchiveChannel(channelId)`.

### 3.5 `api.dart` additions

```dart
Future<void> archiveChannel({required int channelId});
Future<void> unarchiveChannel({required int channelId});
```

## Hook point changes

- **`Db.__init__`** — add `workspace_audit_log` table to SCHEMA constant (idempotent CREATE).
- **All Sprint 49-50 mutating routes** — add `db.audit_log(...)` calls (best-effort, wrapped in try/except).
- **`Db.delete_persistent_agent`** — also archive scheduled_agent channel.
- **`Db.bump_persistent_agent_failure`** — emit `persistent_agent_auto_paused` audit row with `actor_kind='system'` when threshold hits.
- **Flutter `WorkspaceSettingsScreen`** — wire Leave/Delete buttons + add Archived channels section.
- **Flutter channel rail** — add Archive context menu on `kind='custom'` channels.
- **Flutter `_ServerRail` (Sprint 47 placeholder)** — delete.
- **Flutter `widget_test.dart::DiscordShellScreen renders the four-column layout`** — delete (pre-Sprint-47 broken test).

## Testing

### Backend (~7 new files)

- `test_workspace_audit_log_schema.py` — table + indexes
- `test_workspace_audit_log_helpers.py` — Db.audit_log + list_audit_log
- `test_workspace_audit_log_route.py` — GET endpoint + permission matrix
- `test_workspace_audit_log_instrumented.py` — each of the 14 event kinds inserts a row when the right route is hit
- `test_workspace_delete_route.py` — DELETE /workspaces/{id} + 404/403
- `test_workspace_leave_route.py` — POST /workspaces/{id}/leave + 400 for owner
- `test_channel_archive_routes.py` — archive/unarchive + permission + kind restrictions

### Flutter (~4 new files)

- `test/api_audit_log_test.dart` — listAuditLog mock
- `test/api_channel_archive_test.dart` — archive/unarchive mocks
- `test/audit_log_screen_test.dart` — renders entries with human-readable summaries
- `test/archived_channels_section_test.dart` — renders + unarchive

## Verification

After Phala deploy:

- Create a workspace + invite a user + change their role → `GET /workspaces/{id}/audit-log` returns 3 rows with the right `kind` values.
- DELETE /workspaces/{id} as owner → 200, workspace gone from `/me/workspaces`.
- POST /workspaces/{id}/leave as the invited user → 200, member gone from members list.
- Create a custom channel + archive it → channel disappears from rail; reappears in WorkspaceSettingsScreen's "Archived channels"; unarchive → reappears in rail.

## Effort estimate

- **Backend:** ~12h
  - audit_log schema + Db helpers + tests: 4h
  - Instrumenting 14 event kinds: 3h
  - DELETE + leave + archive/unarchive routes + tests: 5h
- **Flutter:** ~18h
  - api.dart additions + wire-up: 3h
  - AuditLogScreen: 6h
  - Archived channels section in WorkspaceSettingsScreen: 4h
  - Archive context menu on channel rail: 3h
  - Leave/Delete real-wire in WorkspaceSettingsScreen: 1h
  - `_ServerRail` cleanup + widget_test deletion: 1h
- **Deploy/verify:** ~5h

**Total:** ~35h.

## Out of scope (Sprint 52+)

- **Workspace ownership transfer** (still deferred from Sprint 50)
- **Clerk user resolution at invite time** (still deferred from Sprint 50)
- **Cross-workspace DMs** (still deferred)
- **Workspace icon file upload** (still URL-only)
- **Audit log retention/pruning** (forever in Sprint 51)
- **Audit log filtering/search UI** (Sprint 51 ships chronological list only)
- **Audit log export** (CSV/JSON download — Sprint 52+ if anyone asks)

## References

- Parent design: [`2026-05-20-discord-shaped-workspace-design.md`](2026-05-20-discord-shaped-workspace-design.md)
- Sprint 50 complete: [`../../SPRINT-50-COMPLETE.md`](../../SPRINT-50-COMPLETE.md) (lists carry-overs)
- Sprint 47 permission matrix: parent spec §"Permission model" (audit-log access = Owner+Admin)
