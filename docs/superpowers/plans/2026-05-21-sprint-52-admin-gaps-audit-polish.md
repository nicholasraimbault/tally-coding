# Sprint 52 — Admin gaps + audit log polish — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** Ship ownership transfer + Clerk-validated invites + audit log filter/export/prune. Close 5 deferred items from Sprints 50-51.

**Architecture:** Backend adds 4 new routes (transfer-ownership, audit-log/export, audit-log/prune) + extends 2 existing routes (POST /workspaces/{id}/members for Clerk validation; GET /audit-log for filter params) + 1 helper (`_validate_clerk_user`). Flutter adds transfer ownership dialog, audit log filter bar, CSV export preview dialog, and prune button.

**Tech Stack:** No new Python deps (`httpx` already used; `csv` is stdlib). No new Dart deps (`Clipboard` is core Flutter).

---

## Phase A — Backend (8 tasks, ~20h)

### Task A1: POST /workspaces/{id}/transfer-ownership

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Create: `services/orchestrator/tests/test_workspace_ownership_transfer.py`

- [ ] **Step 1: Write failing tests**

```python
"""Sprint 52: workspace ownership transfer."""
import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch, tmp_db_path):
    # ... copy fixture from test_workspace_crud.py ...


def test_owner_can_transfer_to_existing_member(client):
    import tally_orchestrator.service as svc
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "member"})
    r = client.post("/workspaces/1/transfer-ownership", json={"new_owner_user_id": "bob"})
    assert r.status_code == 200
    db = svc.state["db"]
    # workspaces.owner_user_id updated
    owner = db._conn.execute("SELECT owner_user_id FROM workspaces WHERE id=1").fetchone()[0]
    assert owner == "bob"
    # bob is now 'owner' in workspace_members
    bob_role = db._conn.execute(
        "SELECT role FROM workspace_members WHERE workspace_id=1 AND user_id='bob'"
    ).fetchone()[0]
    assert bob_role == "owner"
    # admin (old owner) demoted to 'admin'
    admin_role = db._conn.execute(
        "SELECT role FROM workspace_members WHERE workspace_id=1 AND user_id='admin'"
    ).fetchone()[0]
    assert admin_role == "admin"


def test_transfer_to_non_member_returns_404(client):
    r = client.post("/workspaces/1/transfer-ownership", json={"new_owner_user_id": "nobody"})
    assert r.status_code == 404


def test_non_owner_returns_403(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "member"})
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="bob", source="clerk", plan="free", email="b@x.com",
    )
    r = client.post("/workspaces/1/transfer-ownership", json={"new_owner_user_id": "bob"})
    assert r.status_code == 403


def test_self_transfer_returns_400(client):
    r = client.post("/workspaces/1/transfer-ownership", json={"new_owner_user_id": "admin"})
    assert r.status_code == 400


def test_transfer_emits_audit(client):
    import tally_orchestrator.service as svc
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "member"})
    client.post("/workspaces/1/transfer-ownership", json={"new_owner_user_id": "bob"})
    db = svc.state["db"]
    row = db._conn.execute(
        "SELECT kind FROM workspace_audit_log "
        "WHERE workspace_id=1 AND kind='workspace_ownership_transferred' "
        "ORDER BY id DESC LIMIT 1"
    ).fetchone()
    assert row is not None
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_ownership_transfer.py -v
```

Expected: 5 FAILs.

- [ ] **Step 3: Add route**

In `service.py`, near the Sprint 50/51 `/workspaces/{wid}/...` routes:

```python
class WorkspaceOwnershipTransferRequest(BaseModel):
    new_owner_user_id: str


@app.post("/workspaces/{wid}/transfer-ownership")
async def transfer_workspace_ownership_route(
    wid: int,
    body: WorkspaceOwnershipTransferRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 52: transfer workspace ownership.  Owner-only.  Old owner
    auto-demoted to admin.  Target must be an existing workspace_member."""
    db: Db = state["db"]
    row = db._conn.execute(
        "SELECT owner_user_id FROM workspaces WHERE id=? AND deleted_at IS NULL",
        (wid,),
    ).fetchone()
    if row is None:
        raise HTTPException(404, "workspace not found")
    if row[0] != user.id:
        raise HTTPException(403, "only the owner can transfer ownership")
    if body.new_owner_user_id == user.id:
        raise HTTPException(400, "cannot transfer to yourself")
    target = db._conn.execute(
        "SELECT role FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (wid, body.new_owner_user_id),
    ).fetchone()
    if target is None:
        raise HTTPException(404, "target user is not a member of this workspace")
    # Atomic transfer
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

- [ ] **Step 4: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_ownership_transfer.py -v
cd services/orchestrator && uv run pytest tests/ -q
```

Expected: 5 PASS + no regressions.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_workspace_ownership_transfer.py
git commit -m "[s52] POST /workspaces/{id}/transfer-ownership — owner-only, atomic, audited"
```

### Task A2: Clerk validation helper

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Create: `services/orchestrator/tests/test_clerk_validation.py`

- [ ] **Step 1: Write failing tests**

```python
"""Sprint 52: Clerk user validation helper."""
import pytest
from unittest.mock import AsyncMock, patch


@pytest.mark.asyncio
async def test_validate_skip_when_unset(monkeypatch):
    from tally_orchestrator.service import _validate_clerk_user
    monkeypatch.delenv("CLERK_SECRET_KEY", raising=False)
    result = await _validate_clerk_user("user_123")
    assert result is None


@pytest.mark.asyncio
async def test_validate_200_returns_true(monkeypatch):
    from tally_orchestrator.service import _validate_clerk_user
    monkeypatch.setenv("CLERK_SECRET_KEY", "sk_test_xxx")

    class FakeResp:
        status_code = 200

    class FakeClient:
        async def __aenter__(self): return self
        async def __aexit__(self, *a): return False
        async def get(self, url, headers=None):
            return FakeResp()

    with patch("httpx.AsyncClient", return_value=FakeClient()):
        result = await _validate_clerk_user("user_123")
    assert result is True


@pytest.mark.asyncio
async def test_validate_404_returns_false(monkeypatch):
    from tally_orchestrator.service import _validate_clerk_user
    monkeypatch.setenv("CLERK_SECRET_KEY", "sk_test_xxx")

    class FakeResp:
        status_code = 404

    class FakeClient:
        async def __aenter__(self): return self
        async def __aexit__(self, *a): return False
        async def get(self, url, headers=None):
            return FakeResp()

    with patch("httpx.AsyncClient", return_value=FakeClient()):
        result = await _validate_clerk_user("user_123")
    assert result is False


@pytest.mark.asyncio
async def test_validate_500_skips_gracefully(monkeypatch):
    from tally_orchestrator.service import _validate_clerk_user
    monkeypatch.setenv("CLERK_SECRET_KEY", "sk_test_xxx")

    class FakeResp:
        status_code = 500

    class FakeClient:
        async def __aenter__(self): return self
        async def __aexit__(self, *a): return False
        async def get(self, url, headers=None):
            return FakeResp()

    with patch("httpx.AsyncClient", return_value=FakeClient()):
        result = await _validate_clerk_user("user_123")
    assert result is None  # graceful skip on transient failure


@pytest.mark.asyncio
async def test_validate_exception_skips_gracefully(monkeypatch):
    from tally_orchestrator.service import _validate_clerk_user
    monkeypatch.setenv("CLERK_SECRET_KEY", "sk_test_xxx")

    class FailingClient:
        async def __aenter__(self): return self
        async def __aexit__(self, *a): return False
        async def get(self, url, headers=None):
            raise Exception("network down")

    with patch("httpx.AsyncClient", return_value=FailingClient()):
        result = await _validate_clerk_user("user_123")
    assert result is None
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_clerk_validation.py -v
```

Expected: 5 FAILs.

- [ ] **Step 3: Implement helper**

In `service.py` (near other module-level helpers):

```python
CLERK_API_BASE = "https://api.clerk.com/v1"
_CLERK_VALIDATE_TIMEOUT = httpx.Timeout(5.0)


async def _validate_clerk_user(user_id: str) -> bool | None:
    """Sprint 52: validate a user_id against Clerk's REST API.
    Returns:
      - True: user exists
      - False: user not found in Clerk (404)
      - None: validation skipped (Clerk not configured) OR Clerk API failed
              non-deterministically (network / 5xx)
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
        logger.warning("Clerk validation returned %s for %s; skipping", resp.status_code, user_id)
        return None
    except Exception as exc:
        logger.warning("Clerk validation failed for %s: %s; skipping", user_id, exc)
        return None
```

`httpx` is already a direct dep. `os` and `logger` are imported.

- [ ] **Step 4: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_clerk_validation.py -v
cd services/orchestrator && uv run pytest tests/ -q
```

Expected: 5 PASS + no regressions.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_clerk_validation.py
git commit -m "[s52] _validate_clerk_user helper — graceful fallback when CLERK_SECRET_KEY unset"
```

### Task A3: Wire Clerk validation into invite route

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — `invite_workspace_member_route`
- Append: `services/orchestrator/tests/test_clerk_validation.py`

- [ ] **Step 1: Append failing tests**

```python
@pytest.mark.asyncio
async def test_invite_route_404_when_clerk_says_not_found(client, monkeypatch):
    """Sprint 52: POST /workspaces/{id}/members returns 404 when Clerk reports the user doesn't exist."""
    monkeypatch.setenv("CLERK_SECRET_KEY", "sk_test_xxx")

    class FakeResp:
        status_code = 404

    class FakeClient:
        async def __aenter__(self): return self
        async def __aexit__(self, *a): return False
        async def get(self, url, headers=None):
            return FakeResp()

    with patch("httpx.AsyncClient", return_value=FakeClient()):
        r = client.post("/workspaces/1/members", json={"user_id": "user_fake", "role": "member"})
    assert r.status_code == 404
    body = r.json()
    assert body["detail"]["error"] == "user_not_found"
    assert body["detail"]["user_id"] == "user_fake"


def test_invite_route_succeeds_when_clerk_unset(client, monkeypatch):
    """Sprint 52: when CLERK_SECRET_KEY is unset, invite trusts the caller (existing Sprint 50 behavior)."""
    monkeypatch.delenv("CLERK_SECRET_KEY", raising=False)
    r = client.post("/workspaces/1/members", json={"user_id": "bob", "role": "member"})
    assert r.status_code == 200
```

(Reuse the `client` fixture pattern from `test_workspace_crud.py`.)

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_clerk_validation.py -v -k "invite_route"
```

Expected: 2 FAILs.

- [ ] **Step 3: Wire validation into the route**

Find `invite_workspace_member_route` (Sprint 50 A8). Add this BEFORE `db.add_workspace_member(...)`:

```python
    # Sprint 52: optional Clerk validation
    exists = await _validate_clerk_user(body.user_id)
    if exists is False:
        raise HTTPException(404, {"error": "user_not_found", "user_id": body.user_id})
```

The route is already `async def` (Sprint 50 made it async); no signature change needed.

- [ ] **Step 4: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_clerk_validation.py -v
cd services/orchestrator && uv run pytest tests/ -q
```

Expected: 7 PASS in test_clerk_validation.py; no regressions in full suite.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_clerk_validation.py
git commit -m "[s52] invite route: Clerk validation when CLERK_SECRET_KEY set"
```

### Task A4: Db.list_audit_log filter params

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — `Db.list_audit_log`
- Create: `services/orchestrator/tests/test_audit_log_filters.py`

- [ ] **Step 1: Write failing tests**

```python
"""Sprint 52: audit log filter params on list_audit_log helper."""
from tally_orchestrator.service import Db


def _seed(db: Db, workspace_id: int = 1) -> None:
    db.audit_log(workspace_id=workspace_id, actor_user_id="alice", kind="workspace_created", payload={})
    db.audit_log(workspace_id=workspace_id, actor_user_id="alice", kind="member_invited", payload={})
    db.audit_log(workspace_id=workspace_id, actor_user_id="bob", kind="channel_created", payload={})
    db.audit_log(workspace_id=workspace_id, actor_user_id="bob", kind="channel_archived", payload={})


def test_filter_by_kind(db: Db):
    _seed(db)
    rows = db.list_audit_log(workspace_id=1, kind="channel_created")
    assert len(rows) == 1
    assert rows[0]["kind"] == "channel_created"


def test_filter_by_actor(db: Db):
    _seed(db)
    rows = db.list_audit_log(workspace_id=1, actor_user_id="bob")
    assert len(rows) == 2
    assert all(r["actor_user_id"] == "bob" for r in rows)


def test_filter_combo_kind_and_actor(db: Db):
    _seed(db)
    rows = db.list_audit_log(workspace_id=1, kind="channel_archived", actor_user_id="bob")
    assert len(rows) == 1


def test_filter_since(db: Db):
    import time
    db.audit_log(workspace_id=1, actor_user_id="alice", kind="old", payload={})
    time.sleep(0.01)
    cutoff = time.time()
    time.sleep(0.01)
    db.audit_log(workspace_id=1, actor_user_id="alice", kind="new", payload={})
    rows = db.list_audit_log(workspace_id=1, since=cutoff)
    kinds = {r["kind"] for r in rows}
    assert "new" in kinds
    assert "old" not in kinds


def test_filter_until(db: Db):
    import time
    db.audit_log(workspace_id=1, actor_user_id="alice", kind="early", payload={})
    time.sleep(0.01)
    cutoff = time.time()
    time.sleep(0.01)
    db.audit_log(workspace_id=1, actor_user_id="alice", kind="late", payload={})
    rows = db.list_audit_log(workspace_id=1, until=cutoff)
    kinds = {r["kind"] for r in rows}
    assert "early" in kinds
    assert "late" not in kinds
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_audit_log_filters.py -v
```

Expected: 5 FAILs.

- [ ] **Step 3: Extend `Db.list_audit_log`**

Find the Sprint 51 implementation in `service.py`. Update the signature + WHERE clause:

```python
def list_audit_log(
    self,
    *,
    workspace_id: int,
    limit: int = 100,
    before_id: int | None = None,
    kind: str | None = None,
    actor_user_id: str | None = None,
    since: float | None = None,
    until: float | None = None,
) -> list[dict]:
    """Sprint 51 + 52: list audit log entries newest-first with keyset pagination
    + optional filters."""
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
cd services/orchestrator && uv run pytest tests/test_audit_log_filters.py -v
cd services/orchestrator && uv run pytest tests/ -q
```

Expected: 5 PASS + no regressions.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_audit_log_filters.py
git commit -m "[s52] Db.list_audit_log: filter by kind/actor/since/until"
```

### Task A5: GET /audit-log route filter params

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — Sprint 51 audit-log route
- Append: `services/orchestrator/tests/test_audit_log_route.py`

- [ ] **Step 1: Append failing tests**

```python
def test_get_audit_log_kind_filter(client):
    # Generate 3 events of different kinds
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "member"})  # member_invited
    client.delete("/workspaces/1/members/bob")  # member_removed
    r = client.post("/channels", json={"workspace_id": 1, "kind": "custom", "name": "x", "members": [{"kind": "human", "id": "admin"}]})  # channel_created
    r2 = client.get("/workspaces/1/audit-log?kind=channel_created")
    assert r2.status_code == 200
    entries = r2.json()["entries"]
    assert all(e["kind"] == "channel_created" for e in entries)


def test_get_audit_log_actor_filter(client):
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "member"})
    r = client.get("/workspaces/1/audit-log?actor_user_id=admin")
    assert r.status_code == 200
    entries = r.json()["entries"]
    assert all(e["actor_user_id"] == "admin" for e in entries)


def test_get_audit_log_since_until_filter(client):
    import tally_orchestrator.service as svc
    import time
    db = svc.state["db"]
    db.audit_log(workspace_id=1, actor_user_id="admin", kind="old_event", payload={})
    time.sleep(0.01)
    cutoff = time.time()
    time.sleep(0.01)
    db.audit_log(workspace_id=1, actor_user_id="admin", kind="new_event", payload={})
    r = client.get(f"/workspaces/1/audit-log?since={cutoff}")
    assert r.status_code == 200
    kinds = {e["kind"] for e in r.json()["entries"]}
    assert "new_event" in kinds
    assert "old_event" not in kinds
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_audit_log_route.py -v -k "kind_filter or actor_filter or since_until"
```

Expected: 3 FAILs.

- [ ] **Step 3: Update route**

Find `get_workspace_audit_log_route` (Sprint 51 A8). Update signature + body:

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
    db: Db = state["db"]
    caller = db._conn.execute(
        "SELECT role FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (wid, user.id),
    ).fetchone()
    if caller is None or caller[0] not in ("owner", "admin"):
        raise HTTPException(403, "owner+admin only")
    return {"entries": db.list_audit_log(
        workspace_id=wid, limit=limit, before_id=before_id,
        kind=kind, actor_user_id=actor_user_id, since=since, until=until,
    )}
```

- [ ] **Step 4: Verify + commit**

```bash
cd services/orchestrator && uv run pytest tests/test_audit_log_route.py -v
```

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_audit_log_route.py
git commit -m "[s52] GET /audit-log: kind/actor/since/until filter query params"
```

### Task A6: GET /audit-log/export CSV route

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Create: `services/orchestrator/tests/test_audit_log_export.py`

- [ ] **Step 1: Write failing tests**

```python
"""Sprint 52: CSV export of audit log."""
import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch, tmp_db_path):
    # ... copy fixture ...


def test_export_returns_csv(client):
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "member"})
    r = client.get("/workspaces/1/audit-log/export")
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("text/csv")
    assert "filename=" in r.headers.get("content-disposition", "")
    # First line is header
    lines = r.text.splitlines()
    assert "id" in lines[0]
    assert "kind" in lines[0]
    # At least one data row
    assert len(lines) >= 2


def test_export_applies_kind_filter(client):
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "member"})
    client.delete("/workspaces/1/members/bob")
    r = client.get("/workspaces/1/audit-log/export?kind=member_removed")
    lines = r.text.splitlines()
    # header + 1 row (just the member_removed event)
    assert len(lines) == 2
    assert "member_removed" in lines[1]


def test_export_non_admin_returns_403(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "manager"})
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="bob", source="clerk", plan="free", email="b@x.com",
    )
    r = client.get("/workspaces/1/audit-log/export")
    assert r.status_code == 403
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_audit_log_export.py -v
```

Expected: 3 FAILs.

- [ ] **Step 3: Add route**

In `service.py`, near the GET /audit-log route. Add the import (`from fastapi import Response`) if not present.

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
    import csv as _csv
    import io
    buf = io.StringIO()
    writer = _csv.writer(buf, quoting=_csv.QUOTE_ALL)
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

`Response` is in `fastapi.responses` — verify the import.

- [ ] **Step 4: Verify + commit**

```bash
cd services/orchestrator && uv run pytest tests/test_audit_log_export.py -v
```

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_audit_log_export.py
git commit -m "[s52] GET /audit-log/export — CSV with filter params, 10k row cap"
```

### Task A7: POST /audit-log/prune route

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Create: `services/orchestrator/tests/test_audit_log_prune.py`

- [ ] **Step 1: Write failing tests**

```python
"""Sprint 52: audit log prune."""
import pytest
import time
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch, tmp_db_path):
    # ... copy fixture ...


def test_prune_deletes_old_entries(client):
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    # Inject an old audit row (40 days ago)
    old_ts = time.time() - (40 * 86400)
    db._conn.execute(
        "INSERT INTO workspace_audit_log "
        "(workspace_id, actor_user_id, actor_kind, kind, target_kind, target_id, payload_json, created_at) "
        "VALUES (?, ?, 'human', ?, NULL, NULL, '{}', ?)",
        (1, "admin", "old_event", old_ts),
    )
    # Prune anything older than 30 days
    r = client.post("/workspaces/1/audit-log/prune", json={"older_than_days": 30})
    assert r.status_code == 200
    assert r.json()["deleted"] >= 1


def test_prune_below_30_days_returns_400(client):
    r = client.post("/workspaces/1/audit-log/prune", json={"older_than_days": 29})
    assert r.status_code == 400


def test_prune_emits_audit(client):
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    client.post("/workspaces/1/audit-log/prune", json={"older_than_days": 30})
    row = db._conn.execute(
        "SELECT kind FROM workspace_audit_log "
        "WHERE workspace_id=1 AND kind='audit_log_pruned' ORDER BY id DESC LIMIT 1"
    ).fetchone()
    assert row is not None


def test_prune_non_admin_returns_403(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "manager"})
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="bob", source="clerk", plan="free", email="b@x.com",
    )
    r = client.post("/workspaces/1/audit-log/prune", json={"older_than_days": 30})
    assert r.status_code == 403
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_audit_log_prune.py -v
```

Expected: 4 FAILs.

- [ ] **Step 3: Add Pydantic model + route**

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
    try:
        db.audit_log(
            workspace_id=wid, actor_user_id=user.id,
            kind="audit_log_pruned",
            payload={"deleted": deleted, "older_than_days": body.older_than_days},
        )
    except Exception as exc:
        logger.warning("audit_log audit_log_pruned failed: %s", exc)
    return {"ok": True, "deleted": deleted}
```

- [ ] **Step 4: Verify + commit**

```bash
cd services/orchestrator && uv run pytest tests/test_audit_log_prune.py -v
```

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_audit_log_prune.py
git commit -m "[s52] POST /audit-log/prune — admin+ only, 30-day floor, emits audit_log_pruned"
```

### Task A8: Phase A smoke + tag

- [ ] **Step 1: Full pytest sweep**

```bash
cd services/orchestrator && uv run pytest tests/ -q
```

Expected: ~300 tests PASS.

- [ ] **Step 2: Local smoke**

```bash
cd services/orchestrator && rm -f /tmp/s52-smoke.db && TALLY_API_TOKEN=smoke ORCH_DB_PATH=/tmp/s52-smoke.db TALLY_REDPILL_KEY="" TALLY_TEST_MODE=1 uv run uvicorn tally_orchestrator.service:app --port 8118 &
sleep 5

# 1. Invite + transfer ownership
curl -sX POST -H "Authorization: Bearer smoke" -H "content-type: application/json" -d '{"user_id":"bob","role":"member"}' http://localhost:8118/workspaces/1/members
curl -sX POST -H "Authorization: Bearer smoke" -H "content-type: application/json" -d '{"new_owner_user_id":"bob"}' http://localhost:8118/workspaces/1/transfer-ownership | python3 -m json.tool

# 2. Audit log filter
curl -s -H "Authorization: Bearer smoke" "http://localhost:8118/workspaces/1/audit-log?kind=member_invited" | python3 -m json.tool

# 3. Export CSV
curl -s -H "Authorization: Bearer smoke" "http://localhost:8118/workspaces/1/audit-log/export" | head -5

# 4. Prune
curl -sX POST -H "Authorization: Bearer smoke" -H "content-type: application/json" -d '{"older_than_days":30}' http://localhost:8118/workspaces/1/audit-log/prune | python3 -m json.tool

kill %1
```

- [ ] **Step 3: Tag**

```bash
git tag s52-phase-a-done
```

---

## Phase B — Frontend (6 tasks, ~15h)

### Task B1: api.dart additions

**Files:**
- Modify: `tally_coding_app/lib/api.dart`
- Create: `tally_coding_app/test/api_ownership_transfer_test.dart`
- Create: `tally_coding_app/test/api_audit_log_filters_test.dart`
- Create: `tally_coding_app/test/api_audit_export_prune_test.dart`

Methods to add (4 new + 1 extended):

```dart
Future<Map<String, dynamic>> transferOwnership({required int workspaceId, required String newOwnerUserId}) async {
  final resp = await _http.post(
    baseUrl.resolve('/workspaces/$workspaceId/transfer-ownership'),
    headers: {'content-type': 'application/json', ...(await _authHeaders)},
    body: jsonEncode({'new_owner_user_id': newOwnerUserId}),
  );
  if (resp.statusCode != 200) {
    throw Exception('POST transfer-ownership ${resp.statusCode}: ${resp.body}');
  }
  return Map<String, dynamic>.from(jsonDecode(resp.body));
}

// EXTEND existing listAuditLog with optional filter params:
Future<List<Map<String, dynamic>>> listAuditLog({
  required int workspaceId,
  int? beforeId,
  int limit = 100,
  String? kind,
  String? actorUserId,
  double? since,
  double? until,
}) async {
  final qs = <String, String>{'limit': '$limit'};
  if (beforeId != null) qs['before_id'] = '$beforeId';
  if (kind != null) qs['kind'] = kind;
  if (actorUserId != null) qs['actor_user_id'] = actorUserId;
  if (since != null) qs['since'] = '$since';
  if (until != null) qs['until'] = '$until';
  final resp = await _http.get(
    baseUrl.resolve('/workspaces/$workspaceId/audit-log').replace(queryParameters: qs),
    headers: await _authHeaders,
  );
  if (resp.statusCode != 200) {
    throw Exception('GET /workspaces/$workspaceId/audit-log ${resp.statusCode}: ${resp.body}');
  }
  return List<Map<String, dynamic>>.from(jsonDecode(resp.body)['entries'] as List);
}

Future<String> exportAuditLogCsv({
  required int workspaceId,
  String? kind,
  String? actorUserId,
  double? since,
  double? until,
}) async {
  final qs = <String, String>{};
  if (kind != null) qs['kind'] = kind;
  if (actorUserId != null) qs['actor_user_id'] = actorUserId;
  if (since != null) qs['since'] = '$since';
  if (until != null) qs['until'] = '$until';
  final resp = await _http.get(
    baseUrl.resolve('/workspaces/$workspaceId/audit-log/export').replace(queryParameters: qs),
    headers: await _authHeaders,
  );
  if (resp.statusCode != 200) {
    throw Exception('GET /audit-log/export ${resp.statusCode}: ${resp.body}');
  }
  return resp.body;
}

Future<Map<String, dynamic>> pruneAuditLog({required int workspaceId, required int olderThanDays}) async {
  final resp = await _http.post(
    baseUrl.resolve('/workspaces/$workspaceId/audit-log/prune'),
    headers: {'content-type': 'application/json', ...(await _authHeaders)},
    body: jsonEncode({'older_than_days': olderThanDays}),
  );
  if (resp.statusCode != 200) {
    throw Exception('POST /audit-log/prune ${resp.statusCode}: ${resp.body}');
  }
  return Map<String, dynamic>.from(jsonDecode(resp.body));
}
```

(Replace the existing `listAuditLog` body — don't add a duplicate.)

Write 4-5 mock-HTTP tests across the 3 test files. Same MockClient pattern as Sprint 51 B1.

Commit: `[s52] api.dart: transferOwnership + listAuditLog filters + exportAuditLogCsv + pruneAuditLog`

### Task B2: WorkspaceSettingsScreen — Transfer ownership button

**Files:**
- Modify: `tally_coding_app/lib/screens/workspace_settings.dart`
- Append: `tally_coding_app/test/workspace_settings_screen_test.dart`

In the Danger zone section, ABOVE the existing Leave/Delete buttons, add (Owner only):

```dart
if (widget.callerRole == 'owner')
  Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: ElevatedButton(
      onPressed: _onTransferOwnership,
      style: ElevatedButton.styleFrom(backgroundColor: Colors.purple),
      child: const Text('Transfer ownership'),
    ),
  ),
```

Add the method:

```dart
Future<void> _onTransferOwnership() async {
  final eligible = _members
    .where((m) => m['member_kind'] == 'human' && m['user_id'] != _callerOrOwnerUserId())
    .toList();
  if (eligible.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No eligible recipients')));
    return;
  }
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  final newOwner = await showDialog<String>(
    context: context,
    builder: (_) => _TransferOwnershipDialog(members: eligible),
  );
  if (newOwner == null) return;
  try {
    await widget.client.transferOwnership(workspaceId: widget.workspaceId, newOwnerUserId: newOwner);
    if (mounted) {
      messenger.showSnackBar(const SnackBar(content: Text('Ownership transferred')));
      navigator.pop();  // close settings; rail refreshes on resume
    }
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Transfer failed: $e')));
  }
}

String _callerOrOwnerUserId() {
  // owner is the workspace_member with role='owner'
  final owner = _members.firstWhere(
    (m) => m['role'] == 'owner' && m['member_kind'] == 'human',
    orElse: () => const {},
  );
  return owner['user_id'] as String? ?? '';
}
```

Add `_TransferOwnershipDialog`:

```dart
class _TransferOwnershipDialog extends StatefulWidget {
  final List<Map<String, dynamic>> members;
  const _TransferOwnershipDialog({required this.members});
  @override
  State<_TransferOwnershipDialog> createState() => _TransferOwnershipDialogState();
}

class _TransferOwnershipDialogState extends State<_TransferOwnershipDialog> {
  String? _selected;
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Transfer ownership'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('You will be demoted to admin. This cannot be undone (the new owner can transfer back).'),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _selected,
            decoration: const InputDecoration(labelText: 'New owner'),
            items: [
              for (final m in widget.members)
                DropdownMenuItem(value: m['user_id'] as String, child: Text('${m['user_id']} (${m['role']})')),
            ],
            onChanged: (v) => setState(() => _selected = v),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        TextButton(
          onPressed: _selected == null ? null : () => Navigator.of(context).pop(_selected),
          child: const Text('Transfer'),
        ),
      ],
    );
  }
}
```

Widget test: append to `workspace_settings_screen_test.dart`:

```dart
testWidgets('owner sees Transfer ownership button', (tester) async {
  // ... mock client + pump WorkspaceSettingsScreen with callerRole='owner' ...
  expect(find.text('Transfer ownership', skipOffstage: false), findsOneWidget);
});
```

Commit: `[s52] WorkspaceSettingsScreen: Transfer ownership dialog (owner-only)`

### Task B3: AuditLogScreen — filter bar

**Files:**
- Modify: `tally_coding_app/lib/screens/audit_log.dart`
- Create: `tally_coding_app/test/audit_log_screen_filters_test.dart`

Add filter state fields to `_AuditLogScreenState`:

```dart
String? _kindFilter;
String _actorFilter = '';
double? _sinceFilter;
double? _untilFilter;
final _actorCtrl = TextEditingController();
bool _filtersExpanded = false;
```

Add an `ExpansionTile` above the ListView with the filter UI:

```dart
ExpansionTile(
  title: const Text('Filters'),
  initiallyExpanded: _filtersExpanded,
  children: [
    Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          DropdownButtonFormField<String>(
            initialValue: _kindFilter,
            decoration: const InputDecoration(labelText: 'Kind'),
            items: [
              const DropdownMenuItem(value: null, child: Text('Any')),
              for (final k in _allKinds)
                DropdownMenuItem(value: k, child: Text(k)),
            ],
            onChanged: (v) => setState(() => _kindFilter = v),
          ),
          TextField(
            controller: _actorCtrl,
            decoration: const InputDecoration(labelText: 'Actor user_id'),
            onChanged: (v) => setState(() => _actorFilter = v.trim()),
          ),
          // Optional: date pickers for since/until (or just leave the fields and let
          // the user enter a Unix timestamp for Sprint 52 simplicity)
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () {
                  setState(() {
                    _kindFilter = null;
                    _actorFilter = '';
                    _actorCtrl.clear();
                    _sinceFilter = null;
                    _untilFilter = null;
                  });
                  _loadFirst();
                },
                child: const Text('Clear'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _loadFirst,  // re-loads with current filter state
                child: const Text('Apply'),
              ),
            ],
          ),
        ],
      ),
    ),
  ],
),
```

`_allKinds` is a const list of the 15 known audit kinds.

Update `_loadFirst` + `_loadMore` to pass the filter state:

```dart
final page = await widget.client.listAuditLog(
  workspaceId: widget.workspaceId,
  limit: _pageSize,
  kind: _kindFilter,
  actorUserId: _actorFilter.isEmpty ? null : _actorFilter,
  since: _sinceFilter,
  until: _untilFilter,
);
```

Widget test in `audit_log_screen_filters_test.dart`:

```dart
testWidgets('selecting kind filter and applying reloads with kind param', (tester) async {
  String? receivedKind;
  final mock = MockClient((req) async {
    receivedKind = req.url.queryParameters['kind'];
    return http.Response('{"entries":[]}', 200, headers: {'content-type':'application/json'});
  });
  // ... pump AuditLogScreen ... expand filters ... select kind ... tap Apply ...
  await tester.pumpAndSettle();
  expect(receivedKind, 'channel_archived');
});
```

Commit: `[s52] AuditLogScreen: filter bar (kind/actor/since/until)`

### Task B4: Export CSV button + preview dialog

**Files:**
- Modify: `tally_coding_app/lib/screens/audit_log.dart`
- Append: `tally_coding_app/test/audit_log_screen_filters_test.dart`

Add an `IconButton(Icons.download)` in the AppBar actions:

```dart
IconButton(
  icon: const Icon(Icons.download),
  tooltip: 'Export CSV',
  onPressed: _onExport,
),
```

Method:

```dart
Future<void> _onExport() async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final csv = await widget.client.exportAuditLogCsv(
      workspaceId: widget.workspaceId,
      kind: _kindFilter,
      actorUserId: _actorFilter.isEmpty ? null : _actorFilter,
      since: _sinceFilter,
      until: _untilFilter,
    );
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _ExportPreviewDialog(csv: csv),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
  }
}
```

Dialog:

```dart
class _ExportPreviewDialog extends StatelessWidget {
  final String csv;
  const _ExportPreviewDialog({required this.csv});
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Export preview'),
      content: SizedBox(
        width: 600,
        height: 400,
        child: SingleChildScrollView(
          child: SelectableText(csv, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: csv));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
            }
          },
          child: const Text('Copy to clipboard'),
        ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
      ],
    );
  }
}
```

Add `import 'package:flutter/services.dart';` for `Clipboard`.

Commit: `[s52] AuditLogScreen: Export CSV button + preview dialog with copy-to-clipboard`

### Task B5: Prune button

**Files:**
- Modify: `tally_coding_app/lib/screens/audit_log.dart`

Add `callerRole: String` to the constructor. Add a `PopupMenuButton` in AppBar:

```dart
PopupMenuButton<String>(
  itemBuilder: (_) => [
    if (widget.callerRole == 'owner' || widget.callerRole == 'admin')
      const PopupMenuItem(value: 'prune', child: Text('Prune older entries…')),
  ],
  onSelected: (action) async {
    if (action != 'prune') return;
    final days = await showDialog<int>(
      context: context,
      builder: (_) => _PruneDialog(),
    );
    if (days == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await widget.client.pruneAuditLog(workspaceId: widget.workspaceId, olderThanDays: days);
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('Pruned ${result['deleted']} entries')));
        _loadFirst();
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Prune failed: $e')));
    }
  },
),
```

`_PruneDialog`:

```dart
class _PruneDialog extends StatefulWidget {
  @override
  State<_PruneDialog> createState() => _PruneDialogState();
}

class _PruneDialogState extends State<_PruneDialog> {
  final _ctrl = TextEditingController(text: '90');
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Prune audit log'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Delete audit entries older than N days.  Minimum: 30 days.'),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            decoration: const InputDecoration(labelText: 'Older than (days)'),
            keyboardType: TextInputType.number,
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        TextButton(
          onPressed: () {
            final n = int.tryParse(_ctrl.text.trim());
            if (n == null || n < 30) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Must be >= 30')));
              return;
            }
            Navigator.of(context).pop(n);
          },
          child: const Text('Prune'),
        ),
      ],
    );
  }
}
```

In `WorkspaceSettingsScreen` (B2), pass `callerRole` when pushing AuditLogScreen.

Commit: `[s52] AuditLogScreen: Prune button (owner+admin) + dialog with 30-day floor`

### Task B6: Phase B smoke + tag

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter analyze
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter test
```

Expected: all PASS.

```bash
git tag s52-phase-b-done
```

---

## Phase C — Deploy + sprint completion (3 tasks, ~5h)

### Task C1: Build + push tally-orch:v32

- [ ] Bump Dockerfile LABEL to v32 + Sprint 52 description
- [ ] Bump docker-compose image to `:v32`
- [ ] No new pip deps (httpx + csv already present)
- [ ] `docker build` + `docker push`
- [ ] Commit: `[s52] image: bump to v32`

### Task C2: Phala deploy v32 + live smoke

```bash
cd services/orchestrator && /home/nick/.npm-global/bin/phala deploy --cvm-id app_c3b5481b3f33551af6270a21145df613160bf063 --compose docker-compose.yml --env .env.prod --wait
```

Live smoke:
- POST /workspaces (smoke ws) → POST /workspaces/{id}/members invite → POST /workspaces/{id}/transfer-ownership → verify GET /me/workspaces shows the new owner relationship
- GET /workspaces/1/audit-log?kind=workspace_ownership_transferred → returns the transfer event
- GET /workspaces/1/audit-log/export → CSV with proper headers
- POST /workspaces/1/audit-log/prune {"older_than_days": 365} → returns deleted count (likely 0 on a fresh DB)

```bash
git tag s52-deployed-v32
```

### Task C3: SPRINT-52-COMPLETE.md + tag

Write `docs/SPRINT-52-COMPLETE.md` matching Sprint 47-51 structure. Cover ownership transfer + Clerk validation + audit log filter/export/prune. Note: Clerk validation is dormant on production (CLERK_SECRET_KEY isn't set there yet) — operators can enable it later via .env.prod.

```bash
git add docs/SPRINT-52-COMPLETE.md
git commit -m "[s52] sprint completion doc"
git tag s52-phase-c-done
git tag s52-complete
```

---

## Self-review

**Spec coverage:**

| Spec requirement | Tasks |
|---|---|
| POST /workspaces/{id}/transfer-ownership | A1 |
| _validate_clerk_user helper | A2 |
| Invite route Clerk validation | A3 |
| Db.list_audit_log filters | A4 |
| GET /audit-log filter params | A5 |
| GET /audit-log/export CSV | A6 |
| POST /audit-log/prune | A7 |
| Phase A smoke | A8 |
| api.dart 4 methods | B1 |
| Transfer ownership UI | B2 |
| Audit log filter bar | B3 |
| Export CSV preview dialog | B4 |
| Prune button | B5 |
| Phase B smoke | B6 |
| Image bump + deploy + completion doc | C1-C3 |

All covered.

**Placeholder scan:** B-phase tasks B2-B5 are summarized at the dialog/method level rather than full file inclusions, following the established Sprint 49-51 pattern. Implementers follow Sprint 51 B3/B5 (WorkspaceSettingsScreen edits) and Sprint 51 B2 (AuditLogScreen edits) as templates.

**Type consistency:** `older_than_days: int >= 30`. `since` / `until` are float Unix timestamps. `kind` filter is exact string match (no LIKE). `callerRole` field passed through to AuditLogScreen for prune visibility gating.

Plan ready to execute.
