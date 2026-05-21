# Sprint 52 — Admin gaps + audit log polish

**Date:** 2026-05-21
**Builds on:** Sprints 47-51 (Discord-shaped vision + audit log)
**Closes:** ownership transfer + Clerk invite validation + audit log search/export/retention

## Locked decisions

| | |
|---|---|
| Scope | ~40h. Opt 1 (admin gaps) + Opt 2 (audit polish). |
| Ownership transfer | 1-step. Owner picks any existing workspace_member as recipient → recipient becomes owner, old owner auto-demoted to admin. UI confirms via dialog. No recipient-side acceptance step. |
| Clerk validation | Graceful fallback: if `CLERK_SECRET_KEY` env unset → skip validation (preserves trust-the-caller behavior). If set → call Clerk REST GET /v1/users/{user_id}; 404 returns `{"error": "user_not_found", "user_id": ...}`. |
| Audit log filters | Query params: `kind` (string), `actor_user_id` (string), `since` (REAL timestamp), `until` (REAL timestamp). Plus the existing `limit` + `before_id`. |
| Audit log export | CSV, max 10,000 rows per request, UTF-8 with quote escaping. Same column set as GET /audit-log response. Owner+Admin only. |
| Audit log retention | Admin-triggered `POST /workspaces/{id}/audit-log/prune` with `{older_than_days: int}`. Hard floor of 30 days (`older_than_days < 30` returns 400). Pruning emits an `audit_log_pruned` audit event. |

## Backend changes

### 1. Workspace ownership transfer

**Pydantic model + route:**

```python
class WorkspaceOwnershipTransferRequest(BaseModel):
    new_owner_user_id: str


@app.post("/workspaces/{wid}/transfer-ownership")
async def transfer_workspace_ownership(
    wid: int,
    body: WorkspaceOwnershipTransferRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 52: transfer workspace ownership.  Owner-only.  Target must
    already be a workspace_member (any role).  Old owner auto-demoted
    to admin.  Atomic: both UPDATEs in the same transaction (or both fail)."""
    db: Db = state["db"]
    # Verify caller is owner
    owner_row = db._conn.execute(
        "SELECT owner_user_id FROM workspaces WHERE id=? AND deleted_at IS NULL",
        (wid,),
    ).fetchone()
    if owner_row is None:
        raise HTTPException(404, "workspace not found")
    if owner_row[0] != user.id:
        raise HTTPException(403, "only the owner can transfer ownership")
    if body.new_owner_user_id == user.id:
        raise HTTPException(400, "cannot transfer to yourself")
    # Verify target is a workspace_member
    target = db._conn.execute(
        "SELECT role FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (wid, body.new_owner_user_id),
    ).fetchone()
    if target is None:
        raise HTTPException(404, "target user is not a member of this workspace")
    # Atomic transfer: bump target to 'owner', demote old owner to 'admin'
    db._conn.execute(
        "UPDATE workspace_members SET role='owner' "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (wid, body.new_owner_user_id),
    )
    db._conn.execute(
        "UPDATE workspace_members SET role='admin' "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (wid, user.id),
    )
    db._conn.execute(
        "UPDATE workspaces SET owner_user_id=? WHERE id=?",
        (body.new_owner_user_id, wid),
    )
    try:
        db.audit_log(
            workspace_id=wid, actor_user_id=user.id,
            kind="workspace_ownership_transferred",
            target_kind="member", target_id=body.new_owner_user_id,
            payload={"old_owner": user.id, "new_owner": body.new_owner_user_id},
        )
    except Exception as exc:
        logger.warning("audit_log workspace_ownership_transferred failed: %s", exc)
    return {"ok": True, "new_owner": body.new_owner_user_id}
```

No schema changes — uses existing `workspaces.owner_user_id` + `workspace_members.role`.

### 2. Clerk validation on invite

Extend `POST /workspaces/{wid}/members` (Sprint 50 A8) to optionally validate the user_id via Clerk REST API before inserting the row.

```python
# Module-level constants:
CLERK_API_BASE = "https://api.clerk.com/v1"
_CLERK_VALIDATE_TIMEOUT = httpx.Timeout(5.0)


async def _validate_clerk_user(user_id: str) -> bool | None:
    """Sprint 52: validate a user_id against Clerk's REST API.
    Returns:
      - True: user exists
      - False: user not found in Clerk
      - None: validation skipped (Clerk not configured)
    """
    secret = os.environ.get("CLERK_SECRET_KEY", "").strip()
    if not secret:
        return None
    try:
        async with httpx.AsyncClient(timeout=_CLERK_VALIDATE_TIMEOUT) as client:
            resp = await client.get(
                f"{CLERK_API_BASE}/users/{user_id}",
                headers={"Authorization": f"Bearer {secret}"},
            )
        if resp.status_code == 200:
            return True
        if resp.status_code == 404:
            return False
        # Other errors (rate limit, server issue) — log + return None to skip
        logger.warning("Clerk validation returned %s for %s; skipping", resp.status_code, user_id)
        return None
    except Exception as exc:
        logger.warning("Clerk validation failed for %s: %s; skipping", user_id, exc)
        return None
```

In `invite_workspace_member_route` (Sprint 50 A8), before `db.add_workspace_member(...)`:

```python
    # Sprint 52: optional Clerk validation
    exists = await _validate_clerk_user(body.user_id)
    if exists is False:
        raise HTTPException(404, {"error": "user_not_found", "user_id": body.user_id})
```

The route is now `async def`. Existing tests call it via `TestClient` which already supports async routes; should be a no-op test change.

### 3. Audit log filters

Extend `GET /workspaces/{wid}/audit-log` (Sprint 51 A8) and the underlying `Db.list_audit_log` to accept filter params.

`Db.list_audit_log` signature:

```python
def list_audit_log(
    self,
    *,
    workspace_id: int,
    limit: int = 100,
    before_id: int | None = None,
    kind: str | None = None,            # Sprint 52: filter
    actor_user_id: str | None = None,   # Sprint 52: filter
    since: float | None = None,         # Sprint 52: filter (created_at >= since)
    until: float | None = None,         # Sprint 52: filter (created_at < until)
) -> list[dict]:
    limit = min(max(1, limit), 500)
    where = ["workspace_id=?"]
    params: list = [workspace_id]
    if before_id is not None:
        where.append("id < ?")
        params.append(before_id)
    if kind is not None:
        where.append("kind=?")
        params.append(kind)
    if actor_user_id is not None:
        where.append("actor_user_id=?")
        params.append(actor_user_id)
    if since is not None:
        where.append("created_at >= ?")
        params.append(since)
    if until is not None:
        where.append("created_at < ?")
        params.append(until)
    params.append(limit)
    rows = self._conn.execute(
        f"SELECT id, workspace_id, actor_user_id, actor_kind, kind, target_kind, target_id, payload_json, created_at "
        f"FROM workspace_audit_log WHERE {' AND '.join(where)} "
        f"ORDER BY id DESC LIMIT ?",
        params,
    ).fetchall()
    return [...]  # same dict construction as Sprint 51
```

Route signature:

```python
@app.get("/workspaces/{wid}/audit-log")
async def get_workspace_audit_log_route(
    wid: int,
    limit: int = Query(default=100, ge=1, le=500),
    before_id: int | None = Query(default=None, ge=1),
    kind: str | None = Query(default=None, max_length=64),
    actor_user_id: str | None = Query(default=None, max_length=128),
    since: float | None = Query(default=None, ge=0),
    until: float | None = Query(default=None, ge=0),
    user: ClerkUser = Depends(require_user),
) -> dict:
    # ... auth check unchanged ...
    return {"entries": db.list_audit_log(
        workspace_id=wid, limit=limit, before_id=before_id,
        kind=kind, actor_user_id=actor_user_id, since=since, until=until,
    )}
```

### 4. Audit log export (CSV)

New route. Owner+Admin only. Returns `text/csv` with the same columns as the GET response. Capped at 10,000 rows. Supports the same filter params.

```python
@app.get("/workspaces/{wid}/audit-log/export")
async def export_workspace_audit_log_route(
    wid: int,
    kind: str | None = Query(default=None, max_length=64),
    actor_user_id: str | None = Query(default=None, max_length=128),
    since: float | None = Query(default=None, ge=0),
    until: float | None = Query(default=None, ge=0),
    user: ClerkUser = Depends(require_user),
) -> Response:
    """Sprint 52: export audit log as CSV.  Owner+Admin only.  Capped at 10,000 rows."""
    db: Db = state["db"]
    caller = db._conn.execute(
        "SELECT role FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (wid, user.id),
    ).fetchone()
    if caller is None or caller[0] not in ("owner", "admin"):
        raise HTTPException(403, "owner+admin only")
    entries = db.list_audit_log(
        workspace_id=wid, limit=10000,
        kind=kind, actor_user_id=actor_user_id, since=since, until=until,
    )
    import csv
    import io
    buf = io.StringIO()
    writer = csv.writer(buf, quoting=csv.QUOTE_ALL)
    writer.writerow(["id", "created_at", "actor_user_id", "actor_kind", "kind",
                     "target_kind", "target_id", "payload_json"])
    for e in entries:
        writer.writerow([
            e["id"], e["created_at"], e["actor_user_id"], e["actor_kind"],
            e["kind"], e["target_kind"] or "", e["target_id"] or "",
            json.dumps(e["payload"]),
        ])
    return Response(
        content=buf.getvalue(),
        media_type="text/csv",
        headers={"Content-Disposition": f'attachment; filename="audit-log-ws{wid}.csv"'},
    )
```

`Response` is from `fastapi.responses` — verify imported.

### 5. Audit log prune

New route. Admin one-shot. Deletes rows older than `older_than_days` (>= 30). Emits its own audit event.

```python
class AuditLogPruneRequest(BaseModel):
    older_than_days: int


@app.post("/workspaces/{wid}/audit-log/prune")
async def prune_workspace_audit_log_route(
    wid: int,
    body: AuditLogPruneRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 52: prune audit log entries older than N days.  Owner+Admin only.
    30-day floor (safety)."""
    if body.older_than_days < 30:
        raise HTTPException(400, "older_than_days must be >= 30")
    db: Db = state["db"]
    caller = db._conn.execute(
        "SELECT role FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (wid, user.id),
    ).fetchone()
    if caller is None or caller[0] not in ("owner", "admin"):
        raise HTTPException(403, "owner+admin only")
    cutoff = time.time() - (body.older_than_days * 86400)
    cur = db._conn.execute(
        "DELETE FROM workspace_audit_log WHERE workspace_id=? AND created_at < ?",
        (wid, cutoff),
    )
    deleted = cur.rowcount
    # Audit the prune itself (so the "who pruned the log" lookup works)
    try:
        db.audit_log(
            workspace_id=wid, actor_user_id=user.id,
            kind="audit_log_pruned", payload={"deleted": deleted, "older_than_days": body.older_than_days},
        )
    except Exception as exc:
        logger.warning("audit_log audit_log_pruned failed: %s", exc)
    return {"ok": True, "deleted": deleted}
```

## Frontend changes

### 1. `api.dart` additions

```dart
Future<Map<String, dynamic>> transferOwnership({required int workspaceId, required String newOwnerUserId});
// Sprint 51's listAuditLog gains optional filter params
Future<List<Map<String, dynamic>>> listAuditLog({
  required int workspaceId,
  int? beforeId,
  int limit = 100,
  String? kind,
  String? actorUserId,
  double? since,
  double? until,
});
// Returns raw CSV bytes for client-side download
Future<String> exportAuditLogCsv({
  required int workspaceId,
  String? kind,
  String? actorUserId,
  double? since,
  double? until,
});
Future<Map<String, dynamic>> pruneAuditLog({required int workspaceId, required int olderThanDays});
```

### 2. WorkspaceSettingsScreen — Transfer ownership

In the Danger zone section, add a "Transfer ownership" button (Owner only, above "Delete workspace"):

```dart
ElevatedButton(
  onPressed: () async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _TransferOwnershipDialog(members: _members.where((m) => m['member_kind'] == 'human' && m['user_id'] != /* owner */).toList()),
    );
    if (result == null) return;
    try {
      await widget.client.transferOwnership(workspaceId: widget.workspaceId, newOwnerUserId: result);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ownership transferred')));
      Navigator.of(context).pop(); // return to rail; caller refreshes
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Transfer failed: $e')));
    }
  },
  style: ElevatedButton.styleFrom(backgroundColor: Colors.purple),
  child: const Text('Transfer ownership'),
),
```

`_TransferOwnershipDialog` shows a dropdown of eligible members (humans other than owner).

### 3. AuditLogScreen — filter bar

Above the list, add a collapsible filter bar:

- Kind dropdown (populated from the 15 known kinds; "Any" default)
- Actor TextField
- Since / Until date pickers (showDatePicker)
- "Apply" button → re-loads list with filter params

When any filter is non-empty, show a small chip row above the list ("kind=member_invited", "actor=bob", etc.) with an X to clear.

### 4. AuditLogScreen — Export CSV button

In the AppBar actions:

```dart
IconButton(
  icon: const Icon(Icons.download),
  tooltip: 'Export CSV',
  onPressed: () async {
    final csv = await widget.client.exportAuditLogCsv(
      workspaceId: widget.workspaceId,
      kind: _kindFilter,
      actorUserId: _actorFilter,
      since: _sinceFilter,
      until: _untilFilter,
    );
    // Show in a dialog with a "Copy" button (download-as-file requires platform plugins
    // we don't want to add for Sprint 52; copy-to-clipboard is the simplest UX).
    await showDialog(context: context, builder: (_) => _ExportPreviewDialog(csv: csv));
  },
),
```

`_ExportPreviewDialog` renders the CSV in a scrollable text view + a "Copy to clipboard" button (`Clipboard.setData(ClipboardData(text: csv))`). For Sprint 52, this is the simplest path. Sprint 53+ can add a real file-download via `file_picker` or `path_provider`.

### 5. AuditLogScreen — Prune button

Owner+Admin only. In the AppBar overflow menu:

```dart
PopupMenuButton<String>(
  itemBuilder: (_) => [
    if (widget.callerRole == 'owner' || widget.callerRole == 'admin')
      const PopupMenuItem(value: 'prune', child: Text('Prune older entries…')),
  ],
  onSelected: (action) async {
    if (action == 'prune') {
      final days = await showDialog<int>(
        context: context,
        builder: (_) => _PruneDialog(),
      );
      if (days == null) return;
      try {
        final result = await widget.client.pruneAuditLog(workspaceId: widget.workspaceId, olderThanDays: days);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Pruned ${result['deleted']} entries')));
        _loadFirst();
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Prune failed: $e')));
      }
    }
  },
),
```

`_PruneDialog` shows a number input with a minimum of 30.

`AuditLogScreen` gains a `callerRole: String` constructor param (passed in from WorkspaceSettingsScreen).

## Testing

### Backend (~7 new files)

- `test_workspace_ownership_transfer.py` — owner can transfer; target must be member; new owner is correct; old owner demoted to admin; non-owner returns 403; self-transfer returns 400; emits audit
- `test_clerk_validation.py` — graceful skip when CLERK_SECRET_KEY unset; HTTP-mocked Clerk returning 200/404; 404 surfaces user_not_found
- `test_audit_log_filters.py` — list_audit_log with kind / actor_user_id / since / until filters
- `test_audit_log_route_filters.py` — GET /audit-log with all 4 query params
- `test_audit_log_export.py` — CSV format + 10k cap + same filter params
- `test_audit_log_prune.py` — admin+ only + 30-day floor + emits audit_log_pruned event
- (no new file for client-side smoke; combined into Phase A smoke)

### Flutter (~4 new files)

- `test/api_audit_log_filters_test.dart` — listAuditLog with filter params builds correct query string
- `test/api_ownership_transfer_test.dart` — transferOwnership POST shape
- `test/api_audit_export_prune_test.dart` — export + prune
- `test/audit_log_screen_filters_test.dart` — filter bar UI; selecting filters triggers re-load

Update `test/workspace_settings_screen_test.dart` to verify Transfer button appears (owner) / not appears (non-owner).

## Verification

Live smoke against `tally.pronoic.dev`:

- Create a workspace, invite a user, transfer ownership to them → both UPDATEs persisted; old owner is admin; audit event recorded
- Try to invite a fake user when `CLERK_SECRET_KEY` is set → 404 `user_not_found`
- GET /audit-log with `kind=channel_archived` → only channel_archived events
- GET /audit-log/export?kind=workspace_created → CSV with proper headers + body
- POST /audit-log/prune {older_than_days: 30} → returns deleted count + emits audit_log_pruned

## Out of scope (Sprint 53+)

- Cross-workspace DMs (identity model)
- Workspace icon file upload (S3)
- Audit log streaming (WebSocket subscription to new events)
- Real file-download for CSV export (requires Flutter file plugin)
- Audit log retention via cron (auto-prune on schedule)
- Ownership transfer with recipient-side acceptance flow (2-step)

## Effort estimate

- **Backend:** ~20h
  - Transfer ownership route + tests: 4h
  - Clerk validation + tests + httpx-mock: 4h
  - List_audit_log filter params + route + tests: 4h
  - CSV export + tests: 3h
  - Prune route + tests + audit-of-audit: 3h
  - Phase A smoke: 2h
- **Flutter:** ~15h
  - api.dart additions + tests: 3h
  - Transfer ownership dialog + button in settings: 4h
  - Filter bar in AuditLogScreen: 4h
  - Export CSV button + preview dialog: 2h
  - Prune button + dialog: 2h
- **Deploy/verify:** ~5h

**Total:** ~40h.

## References

- Sprint 51 complete: [`../../SPRINT-51-COMPLETE.md`](../../SPRINT-51-COMPLETE.md) (lists carry-overs)
- Sprint 47 permission matrix: parent Discord-shaped workspace spec
- Clerk REST API: https://clerk.com/docs/reference/backend-api/tag/Users#operation/GetUser
