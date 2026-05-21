# Sprint 51 — Audit log + channel archival + Sprint 50 carry-over cleanup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** Ship the workspace audit log + channel archival UI + close the Sprint 50 UX TODOs (Leave/Delete workspace, old _ServerRail cleanup, broken widget_test).

**Architecture:** One new schema table (`workspace_audit_log`) + ~14 instrumented event hooks across existing routes + 1 new audit-log read route + 2 new workspace-lifecycle routes (DELETE workspace, POST leave) + 2 channel archive routes. Flutter: AuditLogScreen, archive context menu in channel rail, archived-channels section in WorkspaceSettingsScreen, wire Leave/Delete real APIs.

**Tech Stack:** Same as Sprint 50 — no new deps.

---

## Phase A — Backend (10 tasks, ~12h)

### Task A1: workspace_audit_log table

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — extend SCHEMA
- Create: `services/orchestrator/tests/test_audit_log_schema.py`

- [ ] **Step 1: Write the failing test**

```python
"""Sprint 51: workspace_audit_log table."""
from tally_orchestrator.service import Db


def test_workspace_audit_log_table_present(db: Db):
    row = db._conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='workspace_audit_log'"
    ).fetchone()
    assert row is not None


def test_workspace_audit_log_columns(db: Db):
    cols = {r[1] for r in db._conn.execute("PRAGMA table_info(workspace_audit_log)").fetchall()}
    expected = {
        "id", "workspace_id", "actor_user_id", "actor_kind", "kind",
        "target_kind", "target_id", "payload_json", "created_at",
    }
    assert expected.issubset(cols)


def test_workspace_audit_log_indexes(db: Db):
    idxs = {r[1] for r in db._conn.execute("PRAGMA index_list('workspace_audit_log')").fetchall()}
    assert "idx_audit_log_workspace" in idxs
    assert "idx_audit_log_actor" in idxs
```

- [ ] **Step 2: Run + verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_audit_log_schema.py -v
```

Expected: 3 FAILs.

- [ ] **Step 3: Add to SCHEMA constant**

Append to `SCHEMA` in `service.py`:

```sql
CREATE TABLE IF NOT EXISTS workspace_audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    workspace_id INTEGER NOT NULL REFERENCES workspaces(id),
    actor_user_id TEXT NOT NULL,
    actor_kind TEXT NOT NULL,
    kind TEXT NOT NULL,
    target_kind TEXT,
    target_id TEXT,
    payload_json TEXT NOT NULL DEFAULT '{}',
    created_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_log_workspace ON workspace_audit_log(workspace_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_actor ON workspace_audit_log(actor_user_id);
```

- [ ] **Step 4: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_audit_log_schema.py -v
cd services/orchestrator && uv run pytest tests/ -q
```

Expected: 3 PASS + no regressions.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_audit_log_schema.py
git commit -m "[s51] schema: workspace_audit_log table + indexes"
```

### Task A2: Db.audit_log + list_audit_log helpers

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — `Db` class
- Create: `services/orchestrator/tests/test_audit_log_helpers.py`

- [ ] **Step 1: Write the failing tests**

```python
"""Sprint 51: Db helpers for audit log."""
from tally_orchestrator.service import Db


def test_audit_log_inserts_row(db: Db):
    db.audit_log(
        workspace_id=1, actor_user_id="admin",
        kind="workspace_created", payload={"name": "test"},
    )
    row = db._conn.execute(
        "SELECT kind, actor_user_id, payload_json FROM workspace_audit_log WHERE workspace_id=1 ORDER BY id DESC LIMIT 1"
    ).fetchone()
    assert row[0] == "workspace_created"
    assert row[1] == "admin"


def test_audit_log_system_actor(db: Db):
    db.audit_log(
        workspace_id=1, actor_user_id=None, actor_kind="system",
        kind="persistent_agent_auto_paused", payload={"agent_id": 5},
    )
    row = db._conn.execute(
        "SELECT actor_user_id, actor_kind FROM workspace_audit_log WHERE workspace_id=1 ORDER BY id DESC LIMIT 1"
    ).fetchone()
    assert row[0] == "system"
    assert row[1] == "system"


def test_list_audit_log_returns_newest_first(db: Db):
    for i in range(3):
        db.audit_log(workspace_id=1, actor_user_id="admin", kind=f"test_{i}", payload={})
    rows = db.list_audit_log(workspace_id=1, limit=10)
    kinds = [r["kind"] for r in rows]
    # newest first
    assert kinds[0] == "test_2"
    assert kinds[1] == "test_1"
    assert kinds[2] == "test_0"


def test_list_audit_log_keyset_pagination(db: Db):
    for i in range(5):
        db.audit_log(workspace_id=1, actor_user_id="admin", kind=f"e{i}", payload={})
    first = db.list_audit_log(workspace_id=1, limit=2)
    assert len(first) == 2
    next_page = db.list_audit_log(workspace_id=1, limit=2, before_id=first[-1]["id"])
    # Should not include any id from first
    first_ids = {e["id"] for e in first}
    next_ids = {e["id"] for e in next_page}
    assert first_ids.isdisjoint(next_ids)
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_audit_log_helpers.py -v
```

Expected: 4 FAILs.

- [ ] **Step 3: Implement helpers**

In `service.py` `Db` class:

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
        """Sprint 51: append to workspace_audit_log.  Best-effort —
        callers wrap in try/except so logging failure doesn't break the
        request."""
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
        """Sprint 51: list audit log entries newest-first with keyset pagination."""
        limit = min(max(1, limit), 500)
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

- [ ] **Step 4: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_audit_log_helpers.py -v
cd services/orchestrator && uv run pytest tests/ -q
```

Expected: 4 PASS + no regressions.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_audit_log_helpers.py
git commit -m "[s51] Db.audit_log + list_audit_log helpers"
```

### Task A3: Instrument 14 event kinds + permanent-failure system event

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — sprinkle `db.audit_log(...)` calls
- Create: `services/orchestrator/tests/test_audit_log_instrumented.py`

- [ ] **Step 1: Write the failing tests**

```python
"""Sprint 51: each Sprint 49-50 mutating route inserts an audit row."""
import pytest
from fastapi.testclient import TestClient
# ... standard client fixture (copy from existing route tests) ...


def _audit_kinds(svc, workspace_id) -> list[str]:
    db = svc.state["db"]
    return [r[0] for r in db._conn.execute(
        "SELECT kind FROM workspace_audit_log WHERE workspace_id=? ORDER BY id DESC",
        (workspace_id,),
    ).fetchall()]


def test_workspace_created_audit(client):
    import tally_orchestrator.service as svc
    r = client.post("/workspaces", json={"name": "auditable"})
    wid = r.json()["id"]
    assert "workspace_created" in _audit_kinds(svc, wid)


def test_member_invited_audit(client):
    import tally_orchestrator.service as svc
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "member"})
    assert "member_invited" in _audit_kinds(svc, 1)


def test_member_removed_audit(client):
    import tally_orchestrator.service as svc
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "member"})
    client.delete("/workspaces/1/members/bob")
    assert "member_removed" in _audit_kinds(svc, 1)


def test_member_role_changed_audit(client):
    import tally_orchestrator.service as svc
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "member"})
    client.patch("/workspaces/1/members/bob", json={"role": "admin"})
    assert "member_role_changed" in _audit_kinds(svc, 1)


def test_custom_channel_created_audit(client):
    import tally_orchestrator.service as svc
    client.post("/channels", json={"workspace_id": 1, "kind": "custom", "name": "x", "members": [{"kind": "human", "id": "admin"}]})
    assert "channel_created" in _audit_kinds(svc, 1)


def test_persistent_agent_created_audit(client):
    import tally_orchestrator.service as svc
    client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "x", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
    })
    assert "persistent_agent_created" in _audit_kinds(svc, 1)


def test_persistent_agent_enabled_toggled_audit(client):
    import tally_orchestrator.service as svc
    r = client.post("/persistent_agents", json={"workspace_id": 1, "name": "x", "role_name": "Tester", "team_spec": {"nodes": [], "edges": []}})
    pid = r.json()["id"]
    client.patch(f"/persistent_agents/{pid}", json={"enabled": False})
    assert "persistent_agent_enabled_toggled" in _audit_kinds(svc, 1)


def test_persistent_agent_auto_paused_audit_system_actor(client):
    """When bump_persistent_agent_failure hits 3, emit a system-actor audit row."""
    import tally_orchestrator.service as svc
    r = client.post("/persistent_agents", json={"workspace_id": 1, "name": "x", "role_name": "Tester", "team_spec": {"nodes": [], "edges": []}})
    pid = r.json()["id"]
    db = svc.state["db"]
    for _ in range(3):
        db.bump_persistent_agent_failure(pid)
    row = db._conn.execute(
        "SELECT kind, actor_kind FROM workspace_audit_log "
        "WHERE workspace_id=1 AND kind='persistent_agent_auto_paused' ORDER BY id DESC LIMIT 1"
    ).fetchone()
    assert row is not None
    assert row[1] == "system"
```

(Use the `client` fixture from `test_workspace_crud.py`.)

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_audit_log_instrumented.py -v
```

Expected: 8 FAILs (no instrumentation yet).

- [ ] **Step 3: Instrument the 14 event sites**

Add `db.audit_log(...)` calls after the DB mutation in each route. Wrap in try/except so logging failure is non-fatal:

```python
        # Pattern (wrap each audit_log call):
        try:
            db.audit_log(workspace_id=..., actor_user_id=user.id, kind="...", payload={...})
        except Exception as exc:
            logger.warning("audit_log insert failed: %s", exc)
```

Sites to instrument (find each via grep):

| Site (route) | Kind | Payload |
|---|---|---|
| `POST /workspaces` | `workspace_created` | `{name}` |
| `PATCH /workspaces/{id}` (if name changed) | `workspace_renamed` | `{old_name, new_name}` |
| `PATCH /workspaces/{id}` (if settings changed) | `workspace_settings_updated` | `{keys_changed: [...]}` |
| `DELETE /workspaces/{id}` (Sprint 51 §1.1 — added in A4) | `workspace_deleted` | `{name}` |
| `POST /workspaces/{id}/members` | `member_invited` | `{user_id, role}` |
| `DELETE /workspaces/{id}/members/{u}` | `member_removed` | `{user_id}` |
| `POST /workspaces/{id}/leave` (Sprint 51 §1.2 — added in A5) | `member_left` | `{}` |
| `PATCH /workspaces/{id}/members/{u}` (only if role changed) | `member_role_changed` | `{user_id, old_role, new_role}` |
| `POST /channels` (custom only) | `channel_created` | `{channel_id, kind, name}` |
| `POST /channels/{id}/archive` (Sprint 51 §3.1 — added in A6) | `channel_archived` | `{name}` |
| `POST /channels/{id}/unarchive` (Sprint 51 §3.1 — added in A6) | `channel_unarchived` | `{name}` |
| `POST /persistent_agents` | `persistent_agent_created` | `{agent_id, name, role_name}` |
| `PATCH /persistent_agents/{id}` (only if `enabled` flipped) | `persistent_agent_enabled_toggled` | `{agent_id, name, enabled}` |
| `DELETE /persistent_agents/{id}` | `persistent_agent_deleted` | `{agent_id, name}` |
| `Db.bump_persistent_agent_failure` (when threshold hit) | `persistent_agent_auto_paused` | `{agent_id, name, consecutive_failures}` + `actor_kind='system'` |

**Note on A4-A6 dependency:** Tasks A4 (DELETE workspace), A5 (POST leave), and A6 (archive/unarchive) add routes that A3 then instruments. The cleanest sequencing: A3 instruments only the routes that exist today; A4/A5/A6 each instrument their own audit_log call as part of the route. To keep TDD clean, this task A3 instruments the **existing** routes (10 of the 14); A4/A5/A6 each add their own instrumentation. The auto_paused test in A3 still works because `Db.bump_persistent_agent_failure` is already in the codebase from Sprint 49.

Update A3's test expectations accordingly — remove the `channel_archived`/`channel_unarchived`/`workspace_deleted`/`member_left` test assertions from A3 (those land in A4-A6).

- [ ] **Step 4: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_audit_log_instrumented.py -v
cd services/orchestrator && uv run pytest tests/ -q
```

Expected: 8 PASS + no regressions.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_audit_log_instrumented.py
git commit -m "[s51] audit: instrument 10 existing Sprint 49-50 event sites + system actor"
```

### Task A4: DELETE /workspaces/{id} route + audit

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Create: `services/orchestrator/tests/test_workspace_delete.py`

- [ ] **Step 1: Write failing tests**

```python
"""Sprint 51: DELETE /workspaces/{id}."""
import pytest
from fastapi.testclient import TestClient
# ... client fixture ...


def test_delete_workspace_owner_can_delete(client):
    import tally_orchestrator.service as svc
    r = client.post("/workspaces", json={"name": "doomed"})
    wid = r.json()["id"]
    r2 = client.delete(f"/workspaces/{wid}")
    assert r2.status_code == 200
    # Soft-deleted: not in /me/workspaces
    r3 = client.get("/me/workspaces")
    assert not any(w["id"] == wid for w in r3.json()["workspaces"])


def test_delete_workspace_non_owner_returns_403(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    r = client.post("/workspaces", json={"name": "x"})
    wid = r.json()["id"]
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="stranger", source="clerk", plan="free", email="s@x.com",
    )
    r2 = client.delete(f"/workspaces/{wid}")
    assert r2.status_code in (403, 404)  # 404 if non-member can't see it


def test_delete_workspace_emits_audit(client):
    import tally_orchestrator.service as svc
    r = client.post("/workspaces", json={"name": "audit-me"})
    wid = r.json()["id"]
    client.delete(f"/workspaces/{wid}")
    db = svc.state["db"]
    row = db._conn.execute(
        "SELECT kind, payload_json FROM workspace_audit_log "
        "WHERE workspace_id=? AND kind='workspace_deleted' ORDER BY id DESC LIMIT 1",
        (wid,),
    ).fetchone()
    assert row is not None
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_delete.py -v
```

Expected: 3 FAILs.

- [ ] **Step 3: Add the route**

```python
@app.delete("/workspaces/{wid}")
async def delete_workspace_route(wid: int, user: ClerkUser = Depends(require_user)) -> dict:
    db: Db = state["db"]
    row = db._conn.execute(
        "SELECT owner_user_id, name FROM workspaces WHERE id=? AND deleted_at IS NULL", (wid,)
    ).fetchone()
    if row is None:
        raise HTTPException(404, "workspace not found")
    if row[0] != user.id:
        raise HTTPException(403, "owner only")
    db._conn.execute("UPDATE workspaces SET deleted_at=? WHERE id=?", (time.time(), wid))
    try:
        db.audit_log(workspace_id=wid, actor_user_id=user.id, kind="workspace_deleted", payload={"name": row[1]})
    except Exception as exc:
        logger.warning("audit_log workspace_deleted failed: %s", exc)
    return {"ok": True}
```

- [ ] **Step 4-5: Verify + commit**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_delete.py -v
cd services/orchestrator && uv run pytest tests/ -q
```

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_workspace_delete.py
git commit -m "[s51] DELETE /workspaces/{id} — owner-only soft delete + audit"
```

### Task A5: POST /workspaces/{id}/leave route + audit

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Create: `services/orchestrator/tests/test_workspace_leave.py`

- [ ] Tests (mirror A4 style, 3 tests):
  - non-owner leave succeeds + removed from members
  - owner leave returns 400
  - audit row written

- [ ] Route:

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
        raise HTTPException(400, "owner cannot leave; delete workspace instead")
    db.remove_workspace_member(workspace_id=wid, user_id=user.id)
    try:
        db.audit_log(workspace_id=wid, actor_user_id=user.id, kind="member_left", payload={})
    except Exception as exc:
        logger.warning("audit_log member_left failed: %s", exc)
    return {"ok": True}
```

- [ ] Commit: `[s51] POST /workspaces/{id}/leave — non-owner self-remove + audit`

### Task A6: POST /channels/{id}/archive + unarchive routes

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Create: `services/orchestrator/tests/test_channel_archive.py`

- [ ] Tests (4-5):
  - archive a custom channel succeeds; archived_at set
  - archive a #general channel returns 400 (kind restriction)
  - non-admin archive returns 403
  - unarchive succeeds; archived_at cleared
  - audit rows written for both

- [ ] Routes (see spec §3.1 for code):
  - `POST /channels/{channel_id}/archive` — admin+, kind in ('custom', 'task') only
  - `POST /channels/{channel_id}/unarchive` — admin+, same kind restriction

- [ ] Commit: `[s51] POST /channels/{id}/archive + /unarchive routes + audit`

### Task A7: Db.delete_persistent_agent archives the channel + emits auto-paused audit

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — extend `Db.delete_persistent_agent` and `Db.bump_persistent_agent_failure`
- Append: `services/orchestrator/tests/test_audit_log_instrumented.py`

- [ ] **Step 1: Extend Db.delete_persistent_agent**

```python
def delete_persistent_agent(self, pid: int) -> None:
    now = time.time()
    # Get name for audit + workspace for log
    row = self._conn.execute(
        "SELECT name, workspace_id FROM persistent_agents WHERE id=?", (pid,)
    ).fetchone()
    self._conn.execute(
        "UPDATE persistent_agents SET deleted_at=?, enabled=0 WHERE id=?",
        (now, pid),
    )
    # Sprint 51: archive the scheduled_agent channel
    self._conn.execute(
        "UPDATE channels SET archived_at=? WHERE persistent_agent_id=? AND archived_at IS NULL",
        (now, pid),
    )
    # Audit log
    if row:
        try:
            self.audit_log(
                workspace_id=row[1], actor_user_id=None, actor_kind="system",
                kind="persistent_agent_deleted",
                target_kind="persistent_agent", target_id=str(pid),
                payload={"name": row[0]},
            )
        except Exception:
            pass
```

Note: actor_kind should reflect the calling context. Since `delete_persistent_agent` is called from the DELETE /persistent_agents/{id} route which has a user.id, the route should call audit_log itself with actor_user_id=user.id. The above shows the system fallback if someone calls db.delete_persistent_agent directly outside an HTTP route. Refine in implementation: route emits audit with caller, Db helper just does the data mutation. This means the audit_log call moves OUT of Db.delete_persistent_agent and INTO the DELETE /persistent_agents/{id} route handler — A3 already covers this. Just ensure the channel-archive UPDATE stays in Db.delete_persistent_agent.

- [ ] **Step 2: Extend Db.bump_persistent_agent_failure**

```python
# Inside the existing bump_persistent_agent_failure:
if new_count >= 3:
    # ... existing disable + DM logic ...
    # Sprint 51: audit log
    try:
        self.audit_log(
            workspace_id=workspace_id, actor_user_id=None, actor_kind="system",
            kind="persistent_agent_auto_paused",
            target_kind="persistent_agent", target_id=str(pid),
            payload={"name": name, "consecutive_failures": new_count},
        )
    except Exception:
        pass
```

- [ ] **Step 3: Append test**

```python
def test_delete_persistent_agent_archives_channel(client):
    """Sprint 51: deleting a persistent agent archives its scheduled_agent channel."""
    import tally_orchestrator.service as svc
    r = client.post("/persistent_agents", json={"workspace_id": 1, "name": "x", "role_name": "Tester", "team_spec": {"nodes": [], "edges": []}})
    pid = r.json()["id"]
    client.delete(f"/persistent_agents/{pid}")
    db = svc.state["db"]
    row = db._conn.execute(
        "SELECT archived_at FROM channels WHERE persistent_agent_id=?", (pid,)
    ).fetchone()
    assert row[0] is not None
```

- [ ] Commit: `[s51] delete_persistent_agent archives channel + auto-paused audit`

### Task A8: GET /workspaces/{id}/audit-log route

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Create: `services/orchestrator/tests/test_audit_log_route.py`

- [ ] Tests (4):
  - owner can read
  - admin can read
  - manager returns 403
  - keyset pagination works (`before_id` query param)

- [ ] Route:

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

- [ ] Commit: `[s51] GET /workspaces/{id}/audit-log — owner+admin only, keyset pagination`

### Task A9-A10: Combine & Phase A smoke + tag

A9: full pytest sweep — should be ~265 tests.

A10: local boot + curl smoke for:
- POST /workspaces (verify audit row appears in workspace_audit_log)
- POST /workspaces/{id}/members → DELETE /members/{u} (verify audit rows)
- DELETE /workspaces/{id} (verify audit row)
- POST /workspaces/{id}/leave for a different user (verify audit row)
- POST /channels custom + archive + unarchive (verify audit rows)
- GET /workspaces/{id}/audit-log (verify response shape)

```bash
git tag s51-phase-a-done
```

---

## Phase B — Frontend (8 tasks, ~18h)

### Task B1: api.dart additions

3 new methods:
- `listAuditLog({workspaceId, beforeId?, limit})`
- `archiveChannel({channelId})`
- `unarchiveChannel({channelId})`
- `deleteWorkspace({id})`
- `leaveWorkspace({id})`

5 methods total. 5 mock-HTTP tests in `test/api_audit_log_test.dart` + `test/api_channel_archive_test.dart` + `test/api_workspace_lifecycle_test.dart` (3 test files).

Commit: `[s51] api.dart: audit log + channel archive + workspace lifecycle methods`

### Task B2: AuditLogScreen

New screen at `tally_coding_app/lib/screens/audit_log.dart`. Accessed from `WorkspaceSettingsScreen` via an "Activity log" button.

- Fetches `listAuditLog(workspaceId)` on init
- Renders ListView with one tile per entry
- Each tile: icon-by-kind (👤 / 📁 / ⚡ / ⚙) + human-readable summary
- Pull-to-refresh + "Load more" tile at bottom (uses `before_id`)
- Empty state when no entries

Widget test in `test/audit_log_screen_test.dart` (3 cases: renders entries, empty state, pagination triggers second fetch).

Commit: `[s51] AuditLogScreen: entries list + pagination`

### Task B3: Wire Leave/Delete in WorkspaceSettingsScreen

Replace Sprint 50's SnackBar TODOs in `_onLeave` and `_onDelete` with real API calls. On success:
- Delete: navigate back to the channel rail (`Navigator.pop`), then trigger workspace-rail refresh
- Leave: same

Add an `onWorkspaceRemoved` callback prop so the parent (`discord_shell.dart`) can refresh its workspace list and switch the active workspace.

Commit: `[s51] WorkspaceSettingsScreen: wire Leave/Delete to real API + parent callback`

### Task B4: Archive context menu on channel rail

In `_ChannelTile` (or wherever custom channels render in `discord_shell.dart`), wrap with `GestureDetector` for long-press OR add a trailing 3-dot menu. Show "Archive" only when `channel['kind'] == 'custom'`.

Tap "Archive" → `archiveChannel(channelId)` → refresh rail.

Widget test: `test/channel_archive_context_menu_test.dart` (long-press shows menu; tap Archive calls API).

Commit: `[s51] channel rail: archive context menu on custom channels`

### Task B5: Archived channels section in WorkspaceSettingsScreen

Add a fourth section (after Members, before Danger zone): "Archived channels". Fetches `listChannels(workspaceId, includeArchived: true)` and filters to those with `archived_at != null`. Each row: name + archived date + "Unarchive" button.

Widget test: `test/archived_channels_section_test.dart`.

Commit: `[s51] WorkspaceSettingsScreen: Archived channels section`

### Task B6: Remove old _ServerRail placeholder

Delete the lowercase `_ServerRail` private widget from `discord_shell.dart` (Sprint 47 placeholder). Sprint 50 prepended the real `ServerRail` (capital S); both currently render. Delete the placeholder + its callsite in `_buildWide` (and `_NarrowDrawer` if applicable).

Verify visually: only one rail of workspace icons should render.

Commit: `[s51] remove Sprint 47 _ServerRail placeholder (superseded by ServerRail)`

### Task B7: Delete broken widget_test.dart four-column test

```bash
# Remove only the failing test; keep the rest of widget_test.dart if it has other tests.
```

Read `tally_coding_app/test/widget_test.dart`. If `DiscordShellScreen renders the four-column layout` is the ONLY test, delete the whole file. Else delete just that `testWidgets(...)` block.

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app && /home/nick/.local/flutter/bin/flutter test
```

Expected: all tests pass, no failures.

Commit: `[s51] remove broken widget_test.dart::four-column-layout (pre-Sprint-47 stale)`

### Task B8: Phase B smoke + tag

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter analyze
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter test
```

Expected: zero failures (B7 just removed the long-standing pre-existing one).

```bash
git tag s51-phase-b-done
```

---

## Phase C — Deploy + sprint completion (3 tasks, ~5h)

### Task C1: Build + push tally-orch:v31

- Update Dockerfile LABEL to v31 + Sprint 51 description
- Update docker-compose to `:v31`
- No new pip deps (audit log uses sqlite + json — stdlib)
- `docker build` + `docker push`
- Commit: `[s51] image: bump to v31`

### Task C2: Phala deploy v31 + live smoke

- `phala deploy --cvm-id ... --wait`
- Live smoke:
  - Create workspace → audit log includes `workspace_created`
  - DELETE workspace → audit log includes `workspace_deleted` + workspace gone from `/me/workspaces`
  - Archive a custom channel via POST /channels/{id}/archive → channel hidden from listChannels default
  - Tag `s51-deployed-v31`

### Task C3: SPRINT-51-COMPLETE.md + tag

Mirror Sprint 47-50 doc structure. Cover: cleanup items closed, audit log shipped, channel archival shipped, what's still deferred to Sprint 52+.

```bash
git tag s51-phase-c-done
git tag s51-complete
```

---

## Self-review

**Spec coverage:**

| Spec requirement | Tasks |
|---|---|
| workspace_audit_log schema | A1 |
| Db.audit_log + list_audit_log | A2 |
| Instrument 14 event kinds | A3, A4 (delete), A5 (leave), A6 (archive/unarchive), A7 (auto_paused) |
| DELETE /workspaces/{id} | A4 |
| POST /workspaces/{id}/leave | A5 |
| POST /channels/{id}/archive + unarchive | A6 |
| Db.delete_persistent_agent archives channel | A7 |
| GET /workspaces/{id}/audit-log | A8 |
| Phase A smoke | A9-A10 |
| api.dart additions | B1 |
| AuditLogScreen | B2 |
| Wire Leave/Delete in settings | B3 |
| Archive context menu | B4 |
| Archived channels section | B5 |
| Remove _ServerRail | B6 |
| Remove broken widget_test | B7 |
| Phase B smoke | B8 |
| Image bump | C1 |
| Deploy + smoke | C2 |
| Completion doc | C3 |

All covered.

**Placeholder scan:** A9-A10 are described at the right level (no full code needed for a smoke test); B-phase tasks are summarized following the established Sprint 47-50 patterns. Implementers can refer to the matching prior-sprint task patterns.

**Type consistency:** `actor_kind` = `'human' | 'tally' | 'system'`. `kind` field in audit_log = one of 14 string constants. `target_kind` = `'workspace' | 'member' | 'channel' | 'persistent_agent' | null`.

Plan ready to execute.
