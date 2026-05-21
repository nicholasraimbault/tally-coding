# Sprint 50 — Workspace finale — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the 4 UI subsystems that complete the holistic Discord-shaped vision — custom channels, multi-workspace switching, agent tool allowlist UI, and 4-tier workspace role management. Closes Sprints 47-50.

**Architecture:** Backend adds 10 routes (workspace CRUD + member CRUD + custom-channel CRUD), plus one idempotent migration (`workspaces.deleted_at`) and one orchestrator tweak (tool allowlist intersection). Flutter adds a `WorkspaceContext` provider, server rail with workspace icons, `WorkspaceSettingsScreen`, `NewChannelModal`, tool-allowlist FilterChips inside the existing node config dialog, and rewires Sprint 49's hardcoded `workspace_id: 1` to read from the provider.

**Tech Stack:** Python 3.12 / FastAPI / SQLite (orchestrator), Flutter 3.44 / Dart 3.12 / `shared_preferences` for persistent active-workspace state, no new third-party Python deps, no new Dart deps.

**Resolved open questions:** All 5 decisions locked in [`docs/superpowers/specs/2026-05-21-sprint-50-workspace-finale-design.md`](../specs/2026-05-21-sprint-50-workspace-finale-design.md).

**Reminder from Sprint 49 deploy:** Any new Python dep must be added to `services/orchestrator/Dockerfile`'s inline `pip install` list (not just `pyproject.toml`). Sprint 50 has no new deps — verify on review.

---

## Phase A — Backend (13 tasks, ~20h)

### Task A1: workspaces.deleted_at column migration

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — `Db.__init__` migration block
- Create: `services/orchestrator/tests/test_workspace_deleted_at_migration.py`

- [ ] **Step 1: Write the failing test**

```python
"""Sprint 50: workspaces.deleted_at column."""
from tally_orchestrator.service import Db


def test_workspaces_deleted_at_column(db: Db):
    cols = {r[1] for r in db._conn.execute("PRAGMA table_info(workspaces)").fetchall()}
    assert "deleted_at" in cols
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_deleted_at_migration.py -v
```

Expected: 1 FAIL.

- [ ] **Step 3: Add migration**

Find the existing `ALTER TABLE workspaces` block (if any) or the broader ALTER TABLE region in `Db.__init__`. Add:

```python
        try:
            self._conn.execute("ALTER TABLE workspaces ADD COLUMN deleted_at REAL")
        except sqlite3.OperationalError:
            pass  # column already exists
```

- [ ] **Step 4: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_deleted_at_migration.py -v
cd services/orchestrator && uv run pytest tests/ -q
```

Expected: 1 PASS + no regressions.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_workspace_deleted_at_migration.py
git commit -m "[s50] workspaces: deleted_at column (soft-delete support)"
```

### Task A2: Db.create_workspace explicit method

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — `Db` class
- Create: `services/orchestrator/tests/test_workspace_crud.py`

- [ ] **Step 1: Write the failing tests**

```python
"""Sprint 50: workspace CRUD helpers."""
from tally_orchestrator.service import Db


def test_create_workspace_returns_id(db: Db):
    wid = db.create_workspace(name="My Team", owner_user_id="alice")
    assert isinstance(wid, int) and wid > 0


def test_create_workspace_creates_general_and_backlog(db: Db):
    wid = db.create_workspace(name="My Team", owner_user_id="alice")
    kinds = {r[0] for r in db._conn.execute(
        "SELECT kind FROM channels WHERE workspace_id=?", (wid,)
    ).fetchall()}
    assert {"general", "backlog"}.issubset(kinds)


def test_create_workspace_adds_owner_and_tally_workspace_members(db: Db):
    wid = db.create_workspace(name="My Team", owner_user_id="alice")
    rows = db._conn.execute(
        "SELECT member_kind, user_id, role FROM workspace_members WHERE workspace_id=?", (wid,)
    ).fetchall()
    member_set = {(m, u, r) for m, u, r in rows}
    assert ("human", "alice", "owner") in member_set
    assert any(m == "tally" for m, _, _ in member_set)


def test_create_workspace_adds_tally_to_general_and_backlog(db: Db):
    wid = db.create_workspace(name="My Team", owner_user_id="alice")
    for kind in ("general", "backlog"):
        ch_id = db._conn.execute(
            "SELECT id FROM channels WHERE workspace_id=? AND kind=?", (wid, kind)
        ).fetchone()[0]
        members = {r[0] for r in db._conn.execute(
            "SELECT member_kind FROM channel_members WHERE channel_id=?", (ch_id,)
        ).fetchall()}
        assert "human" in members
        assert "tally" in members
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_crud.py -v
```

Expected: 4 FAILs.

- [ ] **Step 3: Add `Db.create_workspace`**

In `service.py`, near the Sprint 47 backfill helper:

```python
    def create_workspace(self, *, name: str, owner_user_id: str, plan_slug: str = "free") -> int:
        """Sprint 50: create a workspace + owner + Tally workspace_members
        + #general / #backlog channels + Tally as channel_member of each.
        Mirrors what the Sprint 47 backfill does for a single user."""
        now = time.time()
        cur = self._conn.execute(
            "INSERT INTO workspaces (name, owner_user_id, plan_slug, created_at) "
            "VALUES (?, ?, ?, ?)",
            (name, owner_user_id, plan_slug, now),
        )
        ws_id = int(cur.lastrowid or 0)
        # Owner workspace_member
        self._conn.execute(
            "INSERT INTO workspace_members (workspace_id, member_kind, user_id, role, joined_at) "
            "VALUES (?, 'human', ?, 'owner', ?)",
            (ws_id, owner_user_id, now),
        )
        # Tally workspace_member
        self._conn.execute(
            "INSERT INTO workspace_members (workspace_id, member_kind, user_id, role, joined_at) "
            "VALUES (?, 'tally', NULL, 'tally', ?)",
            (ws_id, now),
        )
        # general + backlog channels with owner + Tally as members
        for kind in ("general", "backlog"):
            ch_cur = self._conn.execute(
                "INSERT INTO channels (workspace_id, kind, name, created_at) "
                "VALUES (?, ?, ?, ?)",
                (ws_id, kind, kind, now),
            )
            ch_id = int(ch_cur.lastrowid or 0)
            self._conn.execute(
                "INSERT INTO channel_members (channel_id, member_kind, user_id, joined_at) "
                "VALUES (?, 'human', ?, ?)",
                (ch_id, owner_user_id, now),
            )
            self._conn.execute(
                "INSERT INTO channel_members (channel_id, member_kind, user_id, joined_at) "
                "VALUES (?, 'tally', NULL, ?)",
                (ch_id, now),
            )
        return ws_id
```

- [ ] **Step 4: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_crud.py -v
cd services/orchestrator && uv run pytest tests/ -q
```

Expected: 4 PASS + no regressions.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_workspace_crud.py
git commit -m "[s50] Db.create_workspace: explicit method (mirrors backfill for one user)"
```

### Task A3: POST /workspaces route + 20-cap

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Append: `services/orchestrator/tests/test_workspace_crud.py`

- [ ] **Step 1: Append failing tests**

```python
import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch, tmp_db_path):
    monkeypatch.setenv("ORCH_DB_PATH", tmp_db_path)
    monkeypatch.setenv("TALLY_API_TOKEN", "test-token")
    monkeypatch.setenv("TALLY_REDPILL_KEY", "")
    monkeypatch.setenv("TALLY_TEST_MODE", "1")
    import importlib, tally_orchestrator.service as svc
    importlib.reload(svc)
    svc.state["pool_ready"] = True
    from tally_orchestrator.clerk_auth import User as ClerkUser
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="admin", source="admin", plan="unlimited", email="admin@x.com",
    )
    yield TestClient(svc.app)
    svc.app.dependency_overrides.clear()


def test_post_workspace_returns_id(client):
    r = client.post("/workspaces", json={"name": "My New Workspace"})
    assert r.status_code == 200
    body = r.json()
    assert body["name"] == "My New Workspace"
    assert body["id"] > 0
    assert body.get("role") == "owner"


def test_post_workspace_creates_general_backlog(client):
    import tally_orchestrator.service as svc
    r = client.post("/workspaces", json={"name": "W"})
    wid = r.json()["id"]
    db = svc.state["db"]
    kinds = {row[0] for row in db._conn.execute(
        "SELECT kind FROM channels WHERE workspace_id=?", (wid,)
    ).fetchall()}
    assert {"general", "backlog"}.issubset(kinds)


def test_post_workspace_enforces_20_cap(client):
    # Create 19 (admin already has 1 from backfill, so 19 more = 20 total)
    for i in range(19):
        r = client.post("/workspaces", json={"name": f"W{i}"})
        assert r.status_code == 200
    # 21st should fail
    r = client.post("/workspaces", json={"name": "21st"})
    assert r.status_code == 429
    body = r.json()
    assert body["detail"]["error"] == "workspace_limit"
    assert body["detail"]["limit"] == 20
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_crud.py -v -k post_workspace
```

Expected: 3 FAILs.

- [ ] **Step 3: Add Pydantic model + route**

Near other Pydantic request models in `service.py`:

```python
class WorkspaceCreateRequest(BaseModel):
    name: str
```

Add the route:

```python
@app.post("/workspaces")
async def create_workspace_route(
    body: WorkspaceCreateRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 50: create a workspace owned by the caller.
    Enforces 20-per-user soft cap (429 workspace_limit)."""
    db: Db = state["db"]
    existing = db._conn.execute(
        "SELECT COUNT(*) FROM workspaces WHERE owner_user_id=? AND deleted_at IS NULL",
        (user.id,),
    ).fetchone()[0]
    if existing >= 20:
        raise HTTPException(429, {"error": "workspace_limit", "limit": 20, "current": existing})
    name = body.name.strip()
    if not name:
        raise HTTPException(400, "workspace name required")
    wid = db.create_workspace(name=name, owner_user_id=user.id)
    return {"id": wid, "name": name, "role": "owner"}
```

- [ ] **Step 4: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_crud.py -v
cd services/orchestrator && uv run pytest tests/ -q
```

Expected: 7 PASS in workspace_crud + no regressions.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_workspace_crud.py
git commit -m "[s50] POST /workspaces — create + 20-per-user soft cap"
```

### Task A4: GET /me/workspaces route

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Append: `services/orchestrator/tests/test_workspace_crud.py`

- [ ] **Step 1: Append failing tests**

```python
def test_get_me_workspaces_returns_caller_memberships(client):
    # Admin has 1 from backfill; create 2 more
    client.post("/workspaces", json={"name": "W2"})
    client.post("/workspaces", json={"name": "W3"})
    r = client.get("/me/workspaces")
    assert r.status_code == 200
    body = r.json()
    assert len(body["workspaces"]) == 3
    names = {w["name"] for w in body["workspaces"]}
    assert "W2" in names
    assert "W3" in names
    # Each row has role + id
    assert all("role" in w and "id" in w for w in body["workspaces"])


def test_get_me_workspaces_skips_deleted(client):
    import tally_orchestrator.service as svc
    r = client.post("/workspaces", json={"name": "deleted-soon"})
    wid = r.json()["id"]
    svc.state["db"]._conn.execute(
        "UPDATE workspaces SET deleted_at=? WHERE id=?", (1.0, wid)
    )
    r = client.get("/me/workspaces")
    assert not any(w["id"] == wid for w in r.json()["workspaces"])
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_crud.py -v -k me_workspaces
```

Expected: 2 FAILs.

- [ ] **Step 3: Add route**

```python
@app.get("/me/workspaces")
async def list_my_workspaces(
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 50: list all workspaces the caller is a member of."""
    db: Db = state["db"]
    rows = db._conn.execute(
        "SELECT w.id, w.name, wm.role, w.created_at "
        "FROM workspaces w JOIN workspace_members wm ON wm.workspace_id=w.id "
        "WHERE wm.user_id=? AND wm.member_kind='human' "
        "AND w.deleted_at IS NULL "
        "ORDER BY w.created_at ASC",
        (user.id,),
    ).fetchall()
    return {
        "workspaces": [
            {"id": r[0], "name": r[1], "role": r[2], "created_at": r[3]}
            for r in rows
        ],
    }
```

- [ ] **Step 4: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_crud.py -v
```

Expected: 9 PASS.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_workspace_crud.py
git commit -m "[s50] GET /me/workspaces — list caller's memberships, skip deleted"
```

### Task A5: PATCH /workspaces/{id} branding

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Create: `services/orchestrator/tests/test_workspace_settings.py`

- [ ] **Step 1: Write failing tests**

```python
"""Sprint 50: PATCH /workspaces/{id} for branding/settings."""
import json
import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch, tmp_db_path):
    # ... same fixture pattern as test_workspace_crud.py ...


def test_patch_workspace_merges_settings(client):
    import tally_orchestrator.service as svc
    r = client.post("/workspaces", json={"name": "x"})
    wid = r.json()["id"]
    r2 = client.patch(f"/workspaces/{wid}", json={"name": "renamed", "settings": {"icon_url": "https://x/y.png"}})
    assert r2.status_code == 200
    db = svc.state["db"]
    row = db._conn.execute(
        "SELECT name, settings_json FROM workspaces WHERE id=?", (wid,)
    ).fetchone()
    assert row[0] == "renamed"
    settings = json.loads(row[1])
    assert settings["icon_url"] == "https://x/y.png"


def test_patch_workspace_non_owner_returns_403(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    r = client.post("/workspaces", json={"name": "x"})
    wid = r.json()["id"]
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="stranger", source="clerk", plan="free", email="s@x.com",
    )
    r2 = client.patch(f"/workspaces/{wid}", json={"name": "hacked"})
    assert r2.status_code == 403
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_settings.py -v
```

Expected: 2 FAILs.

- [ ] **Step 3: Add Pydantic model + route**

```python
class WorkspacePatchRequest(BaseModel):
    name: str | None = None
    settings: dict | None = None


@app.patch("/workspaces/{wid}")
async def patch_workspace_route(
    wid: int,
    body: WorkspacePatchRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 50: update workspace name and/or merge settings_json. Owner-only."""
    db: Db = state["db"]
    row = db._conn.execute(
        "SELECT owner_user_id, name, settings_json FROM workspaces WHERE id=? AND deleted_at IS NULL",
        (wid,),
    ).fetchone()
    if row is None:
        raise HTTPException(404, "workspace not found")
    owner, current_name, current_settings = row
    if owner != user.id:
        raise HTTPException(403, "owner only")
    sets: list[str] = []
    params: list = []
    if body.name is not None:
        sets.append("name=?")
        params.append(body.name.strip())
    if body.settings is not None:
        merged = json.loads(current_settings or "{}")
        merged.update(body.settings)
        sets.append("settings_json=?")
        params.append(json.dumps(merged))
    if not sets:
        return {"id": wid, "name": current_name}
    params.append(wid)
    db._conn.execute(f"UPDATE workspaces SET {', '.join(sets)} WHERE id=?", tuple(params))
    return {"id": wid}
```

- [ ] **Step 4: Verify + commit**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_settings.py -v
```

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_workspace_settings.py
git commit -m "[s50] PATCH /workspaces/{id} — name + settings_json JSON-merge"
```

### Task A6: Db member helpers (list/add/update_role/remove)

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Create: `services/orchestrator/tests/test_workspace_members.py`

- [ ] **Step 1: Write failing tests**

```python
"""Sprint 50: Db helpers for workspace_members management."""
from tally_orchestrator.service import Db


def test_list_workspace_members(db: Db):
    wid = db.create_workspace(name="x", owner_user_id="alice")
    members = db.list_workspace_members(workspace_id=wid)
    user_ids = {m["user_id"] for m in members if m["member_kind"] == "human"}
    assert "alice" in user_ids


def test_add_workspace_member(db: Db):
    wid = db.create_workspace(name="x", owner_user_id="alice")
    db.add_workspace_member(workspace_id=wid, user_id="bob", role="member")
    members = db.list_workspace_members(workspace_id=wid)
    bobs = [m for m in members if m.get("user_id") == "bob"]
    assert len(bobs) == 1
    assert bobs[0]["role"] == "member"


def test_update_workspace_member_role(db: Db):
    wid = db.create_workspace(name="x", owner_user_id="alice")
    db.add_workspace_member(workspace_id=wid, user_id="bob", role="member")
    db.update_workspace_member_role(workspace_id=wid, user_id="bob", role="admin")
    members = db.list_workspace_members(workspace_id=wid)
    assert next(m for m in members if m["user_id"] == "bob")["role"] == "admin"


def test_remove_workspace_member(db: Db):
    wid = db.create_workspace(name="x", owner_user_id="alice")
    db.add_workspace_member(workspace_id=wid, user_id="bob", role="member")
    db.remove_workspace_member(workspace_id=wid, user_id="bob")
    members = db.list_workspace_members(workspace_id=wid)
    assert all(m.get("user_id") != "bob" for m in members)
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_members.py -v
```

Expected: 4 FAILs.

- [ ] **Step 3: Implement helpers**

```python
    def list_workspace_members(self, *, workspace_id: int) -> list[dict]:
        """Sprint 50: list all members of a workspace."""
        rows = self._conn.execute(
            "SELECT id, member_kind, user_id, persistent_agent_id, role, joined_at "
            "FROM workspace_members WHERE workspace_id=? ORDER BY joined_at ASC",
            (workspace_id,),
        ).fetchall()
        return [
            {
                "id": r[0],
                "member_kind": r[1],
                "user_id": r[2],
                "persistent_agent_id": r[3],
                "role": r[4],
                "joined_at": r[5],
            }
            for r in rows
        ]

    def add_workspace_member(
        self, *, workspace_id: int, user_id: str, role: str
    ) -> None:
        """Sprint 50: add a human user as a workspace_member.
        Idempotent: silent if (workspace_id, user_id) already exists."""
        existing = self._conn.execute(
            "SELECT 1 FROM workspace_members "
            "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
            (workspace_id, user_id),
        ).fetchone()
        if existing:
            return
        self._conn.execute(
            "INSERT INTO workspace_members "
            "(workspace_id, member_kind, user_id, role, joined_at) "
            "VALUES (?, 'human', ?, ?, ?)",
            (workspace_id, user_id, role, time.time()),
        )

    def update_workspace_member_role(
        self, *, workspace_id: int, user_id: str, role: str
    ) -> bool:
        """Sprint 50: change a human member's role.  Returns True if a
        row was updated."""
        cur = self._conn.execute(
            "UPDATE workspace_members SET role=? "
            "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
            (role, workspace_id, user_id),
        )
        return cur.rowcount > 0

    def remove_workspace_member(self, *, workspace_id: int, user_id: str) -> bool:
        """Sprint 50: remove a human member.  Returns True if a row was deleted."""
        cur = self._conn.execute(
            "DELETE FROM workspace_members "
            "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
            (workspace_id, user_id),
        )
        return cur.rowcount > 0
```

- [ ] **Step 4: Verify + commit**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_members.py -v
```

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_workspace_members.py
git commit -m "[s50] Db: list/add/update_role/remove workspace_member helpers"
```

### Task A7: GET /workspaces/{id}/members route

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Append: `services/orchestrator/tests/test_workspace_members.py`

- [ ] **Step 1: Append failing tests**

```python
import pytest
from fastapi.testclient import TestClient
# ... same client fixture pattern ...


def test_get_workspace_members_returns_list(client):
    r = client.get("/workspaces/1/members")
    assert r.status_code == 200
    body = r.json()
    assert "members" in body
    assert any(m["user_id"] == "admin" for m in body["members"] if m["member_kind"] == "human")


def test_get_workspace_members_non_member_returns_empty(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="stranger", source="clerk", plan="free", email="s@x.com",
    )
    r = client.get("/workspaces/1/members")
    assert r.status_code == 200
    assert r.json()["members"] == []
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_members.py -v -k "get_workspace_members"
```

Expected: 2 FAILs.

- [ ] **Step 3: Add route**

```python
@app.get("/workspaces/{wid}/members")
async def list_workspace_members_route(
    wid: int,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 50: list workspace_members.  Member-only access."""
    db: Db = state["db"]
    is_member = db._conn.execute(
        "SELECT 1 FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human' LIMIT 1",
        (wid, user.id),
    ).fetchone()
    if not is_member:
        return {"members": []}
    return {"members": db.list_workspace_members(workspace_id=wid)}
```

- [ ] **Step 4: Verify + commit**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_members.py -v
```

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_workspace_members.py
git commit -m "[s50] GET /workspaces/{id}/members — member-only access"
```

### Task A8: POST /workspaces/{id}/members (invite)

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Append: `services/orchestrator/tests/test_workspace_members.py`

- [ ] **Step 1: Append failing tests**

```python
def test_post_workspace_members_admin_can_invite(client):
    # admin is owner of workspace 1 from backfill
    r = client.post("/workspaces/1/members", json={"user_id": "bob", "role": "member"})
    assert r.status_code == 200
    members = client.get("/workspaces/1/members").json()["members"]
    assert any(m["user_id"] == "bob" for m in members)


def test_post_workspace_members_non_admin_returns_403(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    # add bob as 'member' role
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "member"})
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="bob", source="clerk", plan="free", email="b@x.com",
    )
    r = client.post("/workspaces/1/members", json={"user_id": "charlie", "role": "member"})
    assert r.status_code == 403


def test_post_workspace_members_invalid_role_returns_400(client):
    r = client.post("/workspaces/1/members", json={"user_id": "bob", "role": "superuser"})
    assert r.status_code == 400
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_members.py -v -k "post_workspace_members"
```

Expected: 3 FAILs.

- [ ] **Step 3: Add Pydantic model + route**

```python
_VALID_WORKSPACE_ROLES = {"owner", "admin", "manager", "member"}


class WorkspaceMemberInviteRequest(BaseModel):
    user_id: str
    role: str


@app.post("/workspaces/{wid}/members")
async def invite_workspace_member_route(
    wid: int,
    body: WorkspaceMemberInviteRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 50: invite a human to a workspace.  Admin+ only.
    Sprint 50 trusts the caller's user_id (no Clerk roundtrip)."""
    if body.role not in _VALID_WORKSPACE_ROLES:
        raise HTTPException(400, f"invalid role: {body.role}")
    if body.role == "owner":
        raise HTTPException(400, "cannot invite as owner; transfer ownership is Sprint 51")
    db: Db = state["db"]
    caller = db._conn.execute(
        "SELECT role FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (wid, user.id),
    ).fetchone()
    if caller is None:
        raise HTTPException(403, "not a member of this workspace")
    if caller[0] not in ("owner", "admin"):
        raise HTTPException(403, "admin+ only")
    db.add_workspace_member(workspace_id=wid, user_id=body.user_id, role=body.role)
    return {"ok": True, "workspace_id": wid, "user_id": body.user_id, "role": body.role}
```

- [ ] **Step 4: Verify + commit**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_members.py -v
```

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_workspace_members.py
git commit -m "[s50] POST /workspaces/{id}/members — admin+ invite, role whitelist"
```

### Task A9: DELETE /workspaces/{id}/members/{user_id}

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Append: `services/orchestrator/tests/test_workspace_members.py`

- [ ] **Step 1: Append failing tests**

```python
def test_delete_workspace_member_admin_can_remove(client):
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "member"})
    r = client.delete("/workspaces/1/members/bob")
    assert r.status_code == 200
    members = client.get("/workspaces/1/members").json()["members"]
    assert not any(m["user_id"] == "bob" for m in members)


def test_delete_workspace_member_cannot_remove_owner(client):
    r = client.delete("/workspaces/1/members/admin")
    assert r.status_code == 400


def test_delete_workspace_member_non_admin_403(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "member"})
    client.post("/workspaces/1/members", json={"user_id": "charlie", "role": "member"})
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="bob", source="clerk", plan="free", email="b@x.com",
    )
    r = client.delete("/workspaces/1/members/charlie")
    assert r.status_code == 403
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_members.py -v -k "delete_workspace_member"
```

Expected: 3 FAILs.

- [ ] **Step 3: Add route**

```python
@app.delete("/workspaces/{wid}/members/{target_user_id}")
async def remove_workspace_member_route(
    wid: int,
    target_user_id: str,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 50: remove a human member.  Admin+ only.  Cannot remove owner."""
    db: Db = state["db"]
    target = db._conn.execute(
        "SELECT role FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (wid, target_user_id),
    ).fetchone()
    if target is None:
        raise HTTPException(404, "member not found")
    if target[0] == "owner":
        raise HTTPException(400, "cannot remove the workspace owner")
    caller = db._conn.execute(
        "SELECT role FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (wid, user.id),
    ).fetchone()
    if caller is None or caller[0] not in ("owner", "admin"):
        raise HTTPException(403, "admin+ only")
    db.remove_workspace_member(workspace_id=wid, user_id=target_user_id)
    return {"ok": True}
```

- [ ] **Step 4: Verify + commit**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_members.py -v
```

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_workspace_members.py
git commit -m "[s50] DELETE /workspaces/{id}/members/{user} — admin+ only, owner protected"
```

### Task A10: PATCH /workspaces/{id}/members/{user_id} (role change)

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Append: `services/orchestrator/tests/test_workspace_members.py`

- [ ] **Step 1: Append failing tests**

```python
def test_patch_member_role_owner_can_change_any(client):
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "member"})
    r = client.patch("/workspaces/1/members/bob", json={"role": "admin"})
    assert r.status_code == 200
    members = client.get("/workspaces/1/members").json()["members"]
    assert next(m for m in members if m["user_id"] == "bob")["role"] == "admin"


def test_patch_member_role_admin_cannot_demote_owner(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "admin"})
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="bob", source="clerk", plan="free", email="b@x.com",
    )
    r = client.patch("/workspaces/1/members/admin", json={"role": "member"})
    # Bob (admin) trying to change admin user's role: 403 (only owner can change owner)
    assert r.status_code == 403


def test_patch_member_role_cannot_set_owner(client):
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "member"})
    r = client.patch("/workspaces/1/members/bob", json={"role": "owner"})
    assert r.status_code == 400  # ownership transfer is Sprint 51


def test_patch_member_role_invalid_returns_400(client):
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "member"})
    r = client.patch("/workspaces/1/members/bob", json={"role": "superuser"})
    assert r.status_code == 400
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_members.py -v -k "patch_member_role"
```

Expected: 4 FAILs.

- [ ] **Step 3: Add route**

```python
class WorkspaceMemberRolePatchRequest(BaseModel):
    role: str


@app.patch("/workspaces/{wid}/members/{target_user_id}")
async def patch_workspace_member_role_route(
    wid: int,
    target_user_id: str,
    body: WorkspaceMemberRolePatchRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 50: change a member's role.
    - Owner can change any role (except cannot promote anyone to owner)
    - Admin can change Manager/Member roles
    - Cannot set role to/from 'owner' (transfer is Sprint 51)
    """
    if body.role not in _VALID_WORKSPACE_ROLES:
        raise HTTPException(400, f"invalid role: {body.role}")
    if body.role == "owner":
        raise HTTPException(400, "ownership transfer is Sprint 51")
    db: Db = state["db"]
    target = db._conn.execute(
        "SELECT role FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (wid, target_user_id),
    ).fetchone()
    if target is None:
        raise HTTPException(404, "member not found")
    if target[0] == "owner":
        raise HTTPException(400, "cannot change the owner's role")
    caller = db._conn.execute(
        "SELECT role FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (wid, user.id),
    ).fetchone()
    if caller is None:
        raise HTTPException(403, "not a workspace member")
    if caller[0] not in ("owner", "admin"):
        raise HTTPException(403, "admin+ only")
    # Admin can only change Manager/Member roles
    if caller[0] == "admin" and target[0] not in ("manager", "member"):
        raise HTTPException(403, "admin can only change manager/member roles")
    if not db.update_workspace_member_role(workspace_id=wid, user_id=target_user_id, role=body.role):
        raise HTTPException(404, "member not found")
    return {"ok": True, "role": body.role}
```

- [ ] **Step 4: Verify + commit**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_members.py -v
```

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_workspace_members.py
git commit -m "[s50] PATCH /workspaces/{id}/members/{user} — owner/admin role change matrix"
```

### Task A11: POST /channels (custom) + channel_member CRUD

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Create: `services/orchestrator/tests/test_custom_channels.py`

- [ ] **Step 1: Write failing tests**

```python
"""Sprint 50: custom channel creation + channel_member CRUD."""
import pytest
from fastapi.testclient import TestClient
# ... client fixture pattern ...


def test_post_custom_channel_returns_id(client):
    r = client.post("/channels", json={
        "workspace_id": 1, "kind": "custom", "name": "code-review",
        "members": [{"kind": "human", "id": "admin"}, {"kind": "tally"}],
    })
    assert r.status_code == 200
    body = r.json()
    assert body["kind"] == "custom"
    assert body["name"] == "code-review"


def test_post_custom_channel_inserts_all_members(client):
    import tally_orchestrator.service as svc
    pa = client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "linter", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
    })
    pid = pa.json()["id"]
    r = client.post("/channels", json={
        "workspace_id": 1, "kind": "custom", "name": "ops",
        "members": [
            {"kind": "human", "id": "admin"},
            {"kind": "tally"},
            {"kind": "persistent_agent", "id": str(pid)},
        ],
    })
    ch_id = r.json()["id"]
    db = svc.state["db"]
    members = db._conn.execute(
        "SELECT member_kind, user_id, persistent_agent_id FROM channel_members WHERE channel_id=?",
        (ch_id,),
    ).fetchall()
    kinds = {m[0] for m in members}
    assert kinds == {"human", "tally", "persistent_agent"}


def test_post_custom_channel_non_admin_returns_403(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "member"})
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="bob", source="clerk", plan="free", email="b@x.com",
    )
    r = client.post("/channels", json={
        "workspace_id": 1, "kind": "custom", "name": "x", "members": [],
    })
    assert r.status_code == 403


def test_add_channel_member(client):
    r = client.post("/channels", json={
        "workspace_id": 1, "kind": "custom", "name": "x",
        "members": [{"kind": "human", "id": "admin"}],
    })
    ch_id = r.json()["id"]
    r2 = client.post(f"/channels/{ch_id}/members", json={"member_kind": "human", "user_id": "bob"})
    assert r2.status_code == 200


def test_remove_channel_member(client):
    r = client.post("/channels", json={
        "workspace_id": 1, "kind": "custom", "name": "x",
        "members": [{"kind": "human", "id": "admin"}, {"kind": "human", "id": "bob"}],
    })
    ch_id = r.json()["id"]
    r2 = client.delete(f"/channels/{ch_id}/members/bob")
    assert r2.status_code == 200
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_custom_channels.py -v
```

Expected: 5 FAILs.

- [ ] **Step 3: Add Pydantic models + 3 routes**

```python
class ChannelMemberSpec(BaseModel):
    kind: str   # 'human' | 'tally' | 'persistent_agent'
    id: str | None = None  # user_id or persistent_agent_id; null for tally


class CustomChannelCreateRequest(BaseModel):
    workspace_id: int
    kind: str  # must be 'custom' in Sprint 50
    name: str
    members: list[ChannelMemberSpec]


class ChannelMemberAddRequest(BaseModel):
    member_kind: str
    user_id: str | None = None
    persistent_agent_id: int | None = None


@app.post("/channels")
async def create_custom_channel_route(
    body: CustomChannelCreateRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 50: create a custom channel.  Admin+ only."""
    if body.kind != "custom":
        raise HTTPException(400, f"Sprint 50 only supports kind='custom'; got {body.kind}")
    db: Db = state["db"]
    caller = db._conn.execute(
        "SELECT role FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (body.workspace_id, user.id),
    ).fetchone()
    if caller is None or caller[0] not in ("owner", "admin"):
        raise HTTPException(403, "admin+ only")
    name = body.name.strip()
    if not name:
        raise HTTPException(400, "name required")
    now = time.time()
    cur = db._conn.execute(
        "INSERT INTO channels (workspace_id, kind, name, created_at) "
        "VALUES (?, 'custom', ?, ?)",
        (body.workspace_id, name, now),
    )
    ch_id = int(cur.lastrowid or 0)
    for m in body.members:
        if m.kind == "human":
            db._conn.execute(
                "INSERT INTO channel_members (channel_id, member_kind, user_id, joined_at) "
                "VALUES (?, 'human', ?, ?)",
                (ch_id, m.id, now),
            )
        elif m.kind == "tally":
            db._conn.execute(
                "INSERT INTO channel_members (channel_id, member_kind, user_id, joined_at) "
                "VALUES (?, 'tally', NULL, ?)",
                (ch_id, now),
            )
        elif m.kind == "persistent_agent":
            pa_id = int(m.id) if m.id else None
            db._conn.execute(
                "INSERT INTO channel_members (channel_id, member_kind, persistent_agent_id, joined_at) "
                "VALUES (?, 'persistent_agent', ?, ?)",
                (ch_id, pa_id, now),
            )
    from .channels import resolve_channel
    return resolve_channel(db, ch_id)


@app.post("/channels/{channel_id}/members")
async def add_channel_member_route(
    channel_id: int,
    body: ChannelMemberAddRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 50: add a member to a custom channel.  Admin+ only."""
    db: Db = state["db"]
    ch = db._conn.execute(
        "SELECT workspace_id, kind FROM channels WHERE id=? AND archived_at IS NULL",
        (channel_id,),
    ).fetchone()
    if ch is None:
        raise HTTPException(404, "channel not found")
    if ch[1] != "custom":
        raise HTTPException(400, "only custom channels can have members added directly")
    caller = db._conn.execute(
        "SELECT role FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (ch[0], user.id),
    ).fetchone()
    if caller is None or caller[0] not in ("owner", "admin"):
        raise HTTPException(403, "admin+ only")
    now = time.time()
    db._conn.execute(
        "INSERT INTO channel_members (channel_id, member_kind, user_id, persistent_agent_id, joined_at) "
        "VALUES (?, ?, ?, ?, ?)",
        (channel_id, body.member_kind, body.user_id, body.persistent_agent_id, now),
    )
    return {"ok": True}


@app.delete("/channels/{channel_id}/members/{target_user_id}")
async def remove_channel_member_route(
    channel_id: int,
    target_user_id: str,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 50: remove a member from a custom channel.  Admin+ only."""
    db: Db = state["db"]
    ch = db._conn.execute(
        "SELECT workspace_id, kind FROM channels WHERE id=?", (channel_id,),
    ).fetchone()
    if ch is None:
        raise HTTPException(404, "channel not found")
    if ch[1] != "custom":
        raise HTTPException(400, "only custom channels support member removal")
    caller = db._conn.execute(
        "SELECT role FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (ch[0], user.id),
    ).fetchone()
    if caller is None or caller[0] not in ("owner", "admin"):
        raise HTTPException(403, "admin+ only")
    cur = db._conn.execute(
        "DELETE FROM channel_members WHERE channel_id=? AND user_id=?",
        (channel_id, target_user_id),
    )
    if cur.rowcount == 0:
        raise HTTPException(404, "member not in channel")
    return {"ok": True}
```

- [ ] **Step 4: Verify + commit**

```bash
cd services/orchestrator && uv run pytest tests/test_custom_channels.py -v
cd services/orchestrator && uv run pytest tests/ -q
```

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_custom_channels.py
git commit -m "[s50] POST /channels (custom) + channel member add/remove routes"
```

### Task A12: Tool allowlist intersection in dispatch

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — `Orchestrator._dispatch_agent` (or wherever payload tools are set)
- Create: `services/orchestrator/tests/test_tool_allowlist.py`

- [ ] **Step 1: Inspect existing dispatch code**

```bash
grep -n "tools\|tool_allowlist\|role\.tools\|role_tools" services/orchestrator/tally_orchestrator/service.py | head -20
```

Find where `role.tools` is read and passed into the worker payload (Sprint 40 area).

- [ ] **Step 2: Write failing tests**

```python
"""Sprint 50: per-node tool_allowlist intersects with role.tools."""


def test_intersect_no_allowlist_returns_role_tools():
    from tally_orchestrator.service import _effective_tools_for_node
    assert _effective_tools_for_node(["a", "b", "c"], None) == ["a", "b", "c"]


def test_intersect_with_allowlist_returns_intersection():
    from tally_orchestrator.service import _effective_tools_for_node
    assert _effective_tools_for_node(["a", "b", "c"], ["b", "d"]) == ["b"]


def test_intersect_with_empty_allowlist_returns_empty():
    """An empty list (vs None) means 'no tools' — deliberate."""
    from tally_orchestrator.service import _effective_tools_for_node
    assert _effective_tools_for_node(["a", "b"], []) == []


def test_intersect_drops_unknown_allowlist_entries():
    from tally_orchestrator.service import _effective_tools_for_node
    assert _effective_tools_for_node(["a", "b"], ["b", "rogue_tool"]) == ["b"]
```

- [ ] **Step 3: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_tool_allowlist.py -v
```

Expected: 4 FAILs.

- [ ] **Step 4: Add the helper + wire into dispatch**

In `service.py`, add the pure helper:

```python
def _effective_tools_for_node(role_tools: list[str], node_allowlist: list[str] | None) -> list[str]:
    """Sprint 50: intersect a role's allowed tools with a node's
    optional allowlist.  None allowlist = use all role tools;
    [] allowlist = deliberately no tools."""
    if node_allowlist is None:
        return list(role_tools)
    return [t for t in role_tools if t in node_allowlist]
```

Wire into `_dispatch_agent` (find where `payload_obj["agent_spec"]["tools"] = ...` or similar is set; today probably `role.get("tools", [])`). Change to:

```python
        # Sprint 50: per-node tool allowlist intersects with role tools
        node_data = None
        if isinstance(team_spec.get("nodes"), list):
            for n in team_spec["nodes"]:
                if n.get("id") == agent.get("agent_idx_node_id"):
                    node_data = n
                    break
        node_allowlist = node_data.get("tool_allowlist") if node_data else None
        effective_tools = _effective_tools_for_node(role.get("tools", []), node_allowlist)
        # ... in the payload:
        "tools": effective_tools,
```

If the agent doesn't have a `node_id` (flat format / Sprint 47 path), just use `role.tools` directly.

NOTE: the exact wiring depends on the Sprint 48 executor implementation. Find the spot and adapt. The pure helper is the load-bearing primitive; full integration may need to map `agents.agent_idx` to a node in the nodes_v1 team_spec.

If full integration proves invasive, ship the pure helper + add a TODO in service.py for Sprint 51 to wire end-to-end. Mark as DONE_WITH_CONCERNS in your report.

- [ ] **Step 5: Verify pure helper passes**

```bash
cd services/orchestrator && uv run pytest tests/test_tool_allowlist.py -v
cd services/orchestrator && uv run pytest tests/ -q
```

Expected: 4 PASS + no regressions.

- [ ] **Step 6: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_tool_allowlist.py
git commit -m "[s50] dispatch: _effective_tools_for_node intersection helper + wire-in"
```

### Task A13: Phase A smoke + tag

- [ ] **Step 1: Full pytest sweep**

```bash
cd services/orchestrator && uv run pytest tests/ -v 2>&1 | tail -8
```

Expected: ~220 tests PASS.

- [ ] **Step 2: Local smoke**

```bash
cd services/orchestrator && rm -f /tmp/s50-smoke.db && TALLY_API_TOKEN=smoke ORCH_DB_PATH=/tmp/s50-smoke.db TALLY_REDPILL_KEY="" TALLY_TEST_MODE=1 uv run uvicorn tally_orchestrator.service:app --port 8118 &
sleep 5
# create workspace
W=$(curl -sX POST -H "Authorization: Bearer smoke" -H "content-type: application/json" -d '{"name":"smoke-ws"}' http://localhost:8118/workspaces | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")
echo "workspace_id: $W"
# list my workspaces
curl -s -H "Authorization: Bearer smoke" http://localhost:8118/me/workspaces | python3 -m json.tool
# invite bob
curl -sX POST -H "Authorization: Bearer smoke" -H "content-type: application/json" -d '{"user_id":"bob","role":"member"}' "http://localhost:8118/workspaces/$W/members" | python3 -m json.tool
# create custom channel
curl -sX POST -H "Authorization: Bearer smoke" -H "content-type: application/json" -d '{"workspace_id":'$W',"kind":"custom","name":"ops","members":[{"kind":"human","id":"admin"},{"kind":"tally"}]}' http://localhost:8118/channels | python3 -m json.tool
kill %1
```

- [ ] **Step 3: Tag**

```bash
git tag s50-phase-a-done
```

---

## Phase B — Frontend (10 tasks, ~35h)

### Task B1: api.dart additions (10 methods)

**Files:**
- Modify: `tally_coding_app/lib/api.dart`
- Create: `tally_coding_app/test/api_workspaces_test.dart`
- Create: `tally_coding_app/test/api_workspace_members_test.dart`
- Create: `tally_coding_app/test/api_custom_channel_test.dart`

- [ ] **Step 1: Write failing tests** (3 test files, mirroring Sprint 49 B1 pattern with MockClient assertions for path + method + response decoding)

Pattern (one test per method):

```dart
test('createWorkspace POSTs and returns row', () async {
  final mock = MockClient((req) async {
    expect(req.url.path, '/workspaces');
    expect(req.method, 'POST');
    return http.Response('{"id":7,"name":"My WS","role":"owner"}', 200, headers: {'content-type':'application/json'});
  });
  final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
  final out = await api.createWorkspace(name: 'My WS');
  expect(out['id'], 7);
});
```

Cover all 10 methods listed in §5 of the spec.

- [ ] **Step 2: Verify failing**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app && /home/nick/.local/flutter/bin/flutter test test/api_workspaces_test.dart test/api_workspace_members_test.dart test/api_custom_channel_test.dart
```

- [ ] **Step 3: Add methods to TallyOrchClient**

Append before `void close()` in `api.dart`:

```dart
  // ── Sprint 50: workspaces + workspace members + custom channels ─────────

  Future<Map<String, dynamic>> createWorkspace({required String name}) async {
    final resp = await _http.post(
      baseUrl.resolve('/workspaces'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode({'name': name}),
    );
    if (resp.statusCode != 200) throw Exception('POST /workspaces ${resp.statusCode}: ${resp.body}');
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<List<Map<String, dynamic>>> listMyWorkspaces() async {
    final resp = await _http.get(baseUrl.resolve('/me/workspaces'), headers: await _authHeaders);
    if (resp.statusCode != 200) throw Exception('GET /me/workspaces ${resp.statusCode}: ${resp.body}');
    return List<Map<String, dynamic>>.from(jsonDecode(resp.body)['workspaces'] as List);
  }

  Future<Map<String, dynamic>> updateWorkspace({required int id, required Map<String, dynamic> patch}) async {
    final resp = await _http.patch(
      baseUrl.resolve('/workspaces/$id'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode(patch),
    );
    if (resp.statusCode != 200) throw Exception('PATCH /workspaces/$id ${resp.statusCode}: ${resp.body}');
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<List<Map<String, dynamic>>> listWorkspaceMembers({required int workspaceId}) async {
    final resp = await _http.get(
      baseUrl.resolve('/workspaces/$workspaceId/members'),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) throw Exception('GET /workspaces/$workspaceId/members ${resp.statusCode}: ${resp.body}');
    return List<Map<String, dynamic>>.from(jsonDecode(resp.body)['members'] as List);
  }

  Future<Map<String, dynamic>> inviteWorkspaceMember({required int workspaceId, required String userId, required String role}) async {
    final resp = await _http.post(
      baseUrl.resolve('/workspaces/$workspaceId/members'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode({'user_id': userId, 'role': role}),
    );
    if (resp.statusCode != 200) throw Exception('POST /workspaces/$workspaceId/members ${resp.statusCode}: ${resp.body}');
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<void> removeWorkspaceMember({required int workspaceId, required String userId}) async {
    final resp = await _http.delete(
      baseUrl.resolve('/workspaces/$workspaceId/members/$userId'),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) throw Exception('DELETE workspace member ${resp.statusCode}: ${resp.body}');
  }

  Future<Map<String, dynamic>> updateWorkspaceMemberRole({required int workspaceId, required String userId, required String role}) async {
    final resp = await _http.patch(
      baseUrl.resolve('/workspaces/$workspaceId/members/$userId'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode({'role': role}),
    );
    if (resp.statusCode != 200) throw Exception('PATCH workspace member role ${resp.statusCode}: ${resp.body}');
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<Map<String, dynamic>> createCustomChannel({required int workspaceId, required String name, required List<Map<String, dynamic>> members}) async {
    final resp = await _http.post(
      baseUrl.resolve('/channels'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode({'workspace_id': workspaceId, 'kind': 'custom', 'name': name, 'members': members}),
    );
    if (resp.statusCode != 200) throw Exception('POST /channels ${resp.statusCode}: ${resp.body}');
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<Map<String, dynamic>> addChannelMember({required int channelId, required String memberKind, String? userId, int? persistentAgentId}) async {
    final body = {'member_kind': memberKind, if (userId != null) 'user_id': userId, if (persistentAgentId != null) 'persistent_agent_id': persistentAgentId};
    final resp = await _http.post(
      baseUrl.resolve('/channels/$channelId/members'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200) throw Exception('POST /channels/$channelId/members ${resp.statusCode}: ${resp.body}');
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<void> removeChannelMember({required int channelId, required String userId}) async {
    final resp = await _http.delete(
      baseUrl.resolve('/channels/$channelId/members/$userId'),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) throw Exception('DELETE channel member ${resp.statusCode}: ${resp.body}');
  }
```

- [ ] **Step 4: Verify**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app && /home/nick/.local/flutter/bin/flutter test
```

Expected: all new tests pass + no regressions.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/api.dart tally_coding_app/test/
git commit -m "[s50] api.dart: workspace CRUD + member CRUD + custom channel CRUD (10 methods)"
```

### Task B2: WorkspaceContext InheritedWidget

**Files:**
- Create: `tally_coding_app/lib/state/workspace_context.dart`
- Create: `tally_coding_app/test/workspace_context_test.dart`

- [ ] **Step 1: Write failing test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/state/workspace_context.dart';

void main() {
  testWidgets('WorkspaceContext.of returns the active workspace_id', (tester) async {
    int? activeId;
    await tester.pumpWidget(WorkspaceContext(
      activeWorkspaceId: 42,
      onChange: (_) {},
      child: Builder(builder: (ctx) {
        activeId = WorkspaceContext.of(ctx).activeWorkspaceId;
        return const SizedBox();
      }),
    ));
    expect(activeId, 42);
  });
}
```

- [ ] **Step 2: Verify failing**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app && /home/nick/.local/flutter/bin/flutter test test/workspace_context_test.dart
```

- [ ] **Step 3: Implement**

```dart
// tally_coding_app/lib/state/workspace_context.dart
//
// Sprint 50: active-workspace provider.  Set by main.dart after Clerk
// auth.  Read from screens that need the current workspace_id.
// Persisted in shared_preferences for cross-restart continuity.
import 'package:flutter/widgets.dart';

class WorkspaceContext extends InheritedWidget {
  final int activeWorkspaceId;
  final ValueChanged<int> onChange;
  const WorkspaceContext({
    super.key,
    required this.activeWorkspaceId,
    required this.onChange,
    required super.child,
  });

  static WorkspaceContext of(BuildContext context) {
    final ctx = context.dependOnInheritedWidgetOfExactType<WorkspaceContext>();
    assert(ctx != null, 'No WorkspaceContext in tree');
    return ctx!;
  }

  @override
  bool updateShouldNotify(WorkspaceContext old) =>
      old.activeWorkspaceId != activeWorkspaceId;
}
```

- [ ] **Step 4: Verify + commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app && /home/nick/.local/flutter/bin/flutter test test/workspace_context_test.dart
```

```bash
git add tally_coding_app/lib/state/workspace_context.dart tally_coding_app/test/workspace_context_test.dart
git commit -m "[s50] WorkspaceContext InheritedWidget"
```

### Task B3: Refactor hardcoded workspace_id=1 + wire WorkspaceContext

**Files:**
- Modify: `tally_coding_app/lib/main.dart` — wrap MaterialApp.home in WorkspaceContext + load active id from shared_preferences
- Modify: many files that hardcode `workspace_id: 1`

- [ ] **Step 1: Find all hardcoded sites**

```bash
grep -rn "workspaceId: 1\|workspace_id.*: 1\|workspace_id=1" tally_coding_app/lib | head -30
```

This will list ~10-15 sites (general_channel.dart, task_channel.dart, discord_shell.dart, persistent_agents.dart, new_dm_modal.dart, etc.).

- [ ] **Step 2: Wire WorkspaceContext in main.dart**

```dart
// main.dart pseudocode
class _AppState extends State<App> {
  int _activeWorkspaceId = 1;
  
  @override
  void initState() {
    super.initState();
    _loadActiveWorkspace();
  }
  
  Future<void> _loadActiveWorkspace() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _activeWorkspaceId = prefs.getInt('active_workspace_id') ?? 1);
  }
  
  Future<void> _setActiveWorkspace(int id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('active_workspace_id', id);
    setState(() => _activeWorkspaceId = id);
  }
  
  @override
  Widget build(BuildContext context) {
    return WorkspaceContext(
      activeWorkspaceId: _activeWorkspaceId,
      onChange: _setActiveWorkspace,
      child: MaterialApp(home: ...),
    );
  }
}
```

Add `shared_preferences` to pubspec:

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app && /home/nick/.local/flutter/bin/flutter pub add shared_preferences
```

- [ ] **Step 3: Replace hardcoded sites**

For each `workspaceId: 1` hit from Step 1, change to `workspaceId: WorkspaceContext.of(context).activeWorkspaceId`.

This requires adding `import '../state/workspace_context.dart';` to each affected file.

For widgets that don't have direct `BuildContext` access (e.g., async helpers), pass workspace_id as a constructor field.

- [ ] **Step 4: Verify**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app && /home/nick/.local/flutter/bin/flutter analyze
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app && /home/nick/.local/flutter/bin/flutter test 2>&1 | tail -3
```

Expected: no new analyze errors; pre-existing test failure unchanged.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/
git commit -m "[s50] refactor: read active workspace_id from WorkspaceContext (was hardcoded 1)"
```

### Task B4: Server rail with workspace icons

**Files:**
- Create: `tally_coding_app/lib/widgets/server_rail.dart`
- Create: `tally_coding_app/test/server_rail_test.dart`
- Modify: `tally_coding_app/lib/screens/discord_shell.dart` — wire in the rail

- [ ] **Step 1: Write failing test**

```dart
testWidgets('ServerRail renders workspace icons from listMyWorkspaces', (tester) async {
  final mock = MockClient((req) async {
    expect(req.url.path, '/me/workspaces');
    return http.Response('{"workspaces":[{"id":1,"name":"Personal","role":"owner"},{"id":2,"name":"Team","role":"member"}]}', 200, headers: {'content-type':'application/json'});
  });
  await tester.pumpWidget(MaterialApp(home: Scaffold(body:
    ServerRail(client: TallyOrchClient(baseUrl: Uri.parse('http://t'), provider: () async => 't', client: mock), activeWorkspaceId: 1, onSelect: (_) {}),
  )));
  await tester.pumpAndSettle();
  expect(find.text('P'), findsOneWidget);  // first letter of "Personal"
  expect(find.text('T'), findsOneWidget);  // first letter of "Team"
});
```

- [ ] **Step 2: Implement `ServerRail`**

```dart
// tally_coding_app/lib/widgets/server_rail.dart
import 'package:flutter/material.dart';
import '../api.dart';

class ServerRail extends StatefulWidget {
  final TallyOrchClient client;
  final int activeWorkspaceId;
  final ValueChanged<int> onSelect;
  const ServerRail({super.key, required this.client, required this.activeWorkspaceId, required this.onSelect});

  @override
  State<ServerRail> createState() => _ServerRailState();
}

class _ServerRailState extends State<ServerRail> {
  List<Map<String, dynamic>> _workspaces = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.client.listMyWorkspaces();
      if (!mounted) return;
      setState(() => _workspaces = list);
    } catch (_) {}
  }

  Future<void> _onCreate() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _CreateWorkspaceDialog(),
    );
    if (name == null || name.isEmpty) return;
    try {
      final ws = await widget.client.createWorkspace(name: name);
      widget.onSelect(ws['id'] as int);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Create failed: $e')));
    }
  }

  Widget _icon(Map<String, dynamic> ws) {
    final active = ws['id'] == widget.activeWorkspaceId;
    final name = ws['name'] as String? ?? '?';
    return InkWell(
      onTap: () => widget.onSelect(ws['id'] as int),
      child: Container(
        width: 42, height: 42,
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF5865F2) : const Color(0xFF2B2D31),
          borderRadius: BorderRadius.circular(active ? 12 : 21),
        ),
        alignment: Alignment.center,
        child: Text(name[0].toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 60,
      color: const Color(0xFF1A1B1E),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: [
          Container(
            width: 42, height: 42,
            decoration: const BoxDecoration(color: Color(0xFFF23F43), shape: BoxShape.circle),
            alignment: Alignment.center,
            child: const Text('T', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
          const Divider(color: Color(0xFF2E3035), height: 16),
          for (final ws in _workspaces) _icon(ws),
          const Spacer(),
          InkWell(
            onTap: _onCreate,
            child: Container(
              width: 42, height: 42,
              decoration: BoxDecoration(
                color: const Color(0xFF2B2D31),
                borderRadius: BorderRadius.circular(21),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.add, color: Color(0xFF3BA55D)),
            ),
          ),
        ],
      ),
    );
  }
}

class _CreateWorkspaceDialog extends StatefulWidget {
  @override
  State<_CreateWorkspaceDialog> createState() => _CreateWorkspaceDialogState();
}

class _CreateWorkspaceDialogState extends State<_CreateWorkspaceDialog> {
  final _ctrl = TextEditingController();
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New workspace'),
      content: TextField(
        controller: _ctrl,
        decoration: const InputDecoration(labelText: 'Workspace name'),
        autofocus: true,
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.of(context).pop(_ctrl.text.trim()), child: const Text('Create')),
      ],
    );
  }
}
```

- [ ] **Step 3: Wire ServerRail into discord_shell.dart**

Add the rail as the leftmost column before the channel rail. Pass `onSelect` to `WorkspaceContext.of(context).onChange`.

- [ ] **Step 4: Verify + commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app && /home/nick/.local/flutter/bin/flutter test test/server_rail_test.dart
```

```bash
git add tally_coding_app/lib/widgets/server_rail.dart tally_coding_app/test/server_rail_test.dart tally_coding_app/lib/screens/discord_shell.dart
git commit -m "[s50] ServerRail: workspace icons + create dialog"
```

### Task B5: WorkspaceSettingsScreen

**Files:**
- Create: `tally_coding_app/lib/screens/workspace_settings.dart`
- Create: `tally_coding_app/test/workspace_settings_screen_test.dart`

- [ ] **Step 1: Sketch the 3 sections** (Branding / Members / Danger zone) per the spec. Implementation patterns mirror Sprint 49's PersistentAgentsScreen.

- [ ] **Step 2: Implement** + **commit**.

Effort budget: ~8h. The implementer should write 1-2 widget tests per section (3-6 total). Section structure:

```dart
class WorkspaceSettingsScreen extends StatefulWidget {
  final TallyOrchClient client;
  final int workspaceId;
  // ...
}

// _BrandingSection: name TextField, icon URL TextField, "Save" button → updateWorkspace
// _MembersSection: ListView of members, each with role dropdown (disabled per permission matrix), + Invite button
// _DangerZone: "Leave workspace" / "Delete workspace" buttons with confirmation dialog
```

Reference Sprint 49 B3 PersistentAgentsScreen for State + ListView + action menu patterns.

```bash
git add tally_coding_app/lib/screens/workspace_settings.dart tally_coding_app/test/workspace_settings_screen_test.dart
git commit -m "[s50] WorkspaceSettingsScreen: branding + members + danger zone"
```

### Task B6: NewChannelModal

**Files:**
- Create: `tally_coding_app/lib/widgets/new_channel_modal.dart`
- Create: `tally_coding_app/test/new_channel_modal_test.dart`

- [ ] **Step 1: Write the modal** mirroring Sprint 49's `NewDmModal` (3 chip groups: Humans / Tally / Persistent agents instead of 3 tabs). Submit → `createCustomChannel` → return channel dict.

```dart
class NewChannelModal extends StatefulWidget {
  final TallyOrchClient client;
  final int workspaceId;
  // ...
  // 3 chip-group selectors + name TextField + Create button
}
```

- [ ] **Step 2: Verify + commit**

```bash
git add tally_coding_app/lib/widgets/new_channel_modal.dart tally_coding_app/test/new_channel_modal_test.dart
git commit -m "[s50] NewChannelModal: custom channel creation with mixed-kind member picker"
```

### Task B7: Channels category in channel rail + Settings entry point

**Files:**
- Modify: `tally_coding_app/lib/screens/discord_shell.dart`

- [ ] Add "Channels" category at the top of the rail (before TASKS), listing `kind='custom'` channels + a "+ New channel" tile that opens `NewChannelModal`.

- [ ] Add a gear icon at the bottom of the channel rail (or top-right of the workspace header) that opens `WorkspaceSettingsScreen`.

- [ ] **Commit**:

```bash
git add tally_coding_app/lib/screens/discord_shell.dart
git commit -m "[s50] channel rail: Channels category + settings entry point"
```

### Task B8: Tool allowlist FilterChips in _NodeConfigDialog

**Files:**
- Modify: `tally_coding_app/lib/screens/workflow_editor.dart` — extend `_NodeConfigDialog`
- Append: `tally_coding_app/test/`

- [ ] Find `_NodeConfigDialog` (Sprint 48 B5). Add a "Tools" section below the spec TextField when kind='agent':

```dart
// Hardcoded for Sprint 50 (Sprint 51+ can fetch via GET /agent-roles/{role})
const _toolsByRole = {
  'Coder': ['create_file', 'edit_file', 'shell', 'browse_web'],
  'Reviewer': ['read_file', 'comment', 'approve'],
  'Tester': ['read_file', 'shell', 'pytest'],
  'Architect': ['read_file', 'edit_file', 'plan'],
  'Solo Coder': ['create_file', 'edit_file', 'shell', 'browse_web', 'pytest'],
};

// In _NodeConfigDialog state:
Set<String> _selectedTools = {};  // initialized from data.toolAllowlist or all role tools

// In build:
const Text('Tools', style: TextStyle(fontWeight: FontWeight.bold)),
Wrap(
  spacing: 8,
  children: [
    for (final tool in _toolsByRole[_role] ?? [])
      FilterChip(
        label: Text(tool),
        selected: _selectedTools.contains(tool),
        onSelected: (s) {
          setState(() {
            if (s) _selectedTools.add(tool);
            else _selectedTools.remove(tool);
          });
        },
      ),
  ],
),
```

On Save, write `_selectedTools.toList()` into `data.toolAllowlist`. If the list equals all role tools, omit the field (= "all tools" semantics).

`_AgentNodeData` gains a `toolAllowlist: List<String>?` field. `_specToNodes` and `_controllerToSpec` extended to serialize.

- [ ] **Commit**:

```bash
git add tally_coding_app/lib/screens/workflow_editor.dart tally_coding_app/test/
git commit -m "[s50] WorkflowEditorScreen: per-node tool allowlist FilterChips"
```

### Task B9: NewDmModal People tab — real members

**Files:**
- Modify: `tally_coding_app/lib/widgets/new_dm_modal.dart`

- [ ] Replace the hardcoded admin entry with `listWorkspaceMembers(workspaceId: widget.workspaceId)` + filter `member_kind='human'`. Keep the same UI shape (ListTile rows).

- [ ] **Commit**:

```bash
git add tally_coding_app/lib/widgets/new_dm_modal.dart
git commit -m "[s50] NewDmModal: People tab fetches real workspace members"
```

### Task B10: Phase B smoke + tag

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app && /home/nick/.local/flutter/bin/flutter analyze 2>&1 | tail -3
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app && /home/nick/.local/flutter/bin/flutter test 2>&1 | tail -5
```

Expected: pre-existing widget_test.dart fail; everything else passes.

```bash
git tag s50-phase-b-done
```

---

## Phase C — Deploy + sprint completion (3 tasks, ~5h)

### Task C1: Build + push tally-orch:v30

- [ ] Update Dockerfile LABEL to `v30` + Sprint 50 description.
- [ ] Update docker-compose image to `:v30`.
- [ ] **No new pip install entries needed** — Sprint 50 has no new Python deps.
- [ ] `docker build` + `docker push`.
- [ ] Commit:

```bash
git commit -m "[s50] image: bump to v30"
```

### Task C2: Phala deploy v30 + live smoke

```bash
cd services/orchestrator && /home/nick/.npm-global/bin/phala deploy --cvm-id app_c3b5481b3f33551af6270a21145df613160bf063 --compose docker-compose.yml --env .env.prod --wait
```

Live smoke against `tally.pronoic.dev`:
- `POST /workspaces {"name":"prod smoke"}` → 200
- `GET /me/workspaces` → 2 entries (existing + new)
- `POST /workspaces/{new}/members {"user_id":"bob","role":"member"}` → 200
- `POST /channels {"workspace_id":<new>,"kind":"custom",...}` → 200

```bash
git tag s50-deployed-v30
```

### Task C3: SPRINT-50-COMPLETE.md + tag

Write the completion doc matching Sprints 47-49's structure. Mark this as "closes the Discord-shaped workspace vision (sprints 47-50)".

```bash
git add docs/SPRINT-50-COMPLETE.md
git commit -m "[s50] sprint completion doc"
git tag s50-phase-c-done
git tag s50-complete
```

---

## Self-review

**Spec coverage:**

| Spec requirement | Tasks |
|---|---|
| workspaces.deleted_at | A1 |
| Db.create_workspace | A2 |
| POST /workspaces + 20-cap | A3 |
| GET /me/workspaces | A4 |
| PATCH /workspaces/{id} | A5 |
| Db member helpers | A6 |
| GET /workspaces/{id}/members | A7 |
| POST /workspaces/{id}/members | A8 |
| DELETE /workspaces/{id}/members/{u} | A9 |
| PATCH /workspaces/{id}/members/{u} | A10 |
| POST /channels (custom) + channel_member CRUD | A11 |
| Tool allowlist intersection | A12 |
| api.dart 10 methods | B1 |
| WorkspaceContext provider | B2 |
| workspace_id refactor | B3 |
| ServerRail | B4 |
| WorkspaceSettingsScreen | B5 |
| NewChannelModal | B6 |
| Channels category + settings entry | B7 |
| Tool allowlist FilterChips | B8 |
| NewDmModal real members | B9 |
| Phase B smoke + tag | B10 |
| Image bump | C1 |
| Deploy + smoke | C2 |
| Completion doc | C3 |

All spec items covered.

**Placeholder scan:** B5 / B6 / B8 sections describe the structure rather than provide full code, because they're large UI files following established patterns from prior sprints. Implementer is expected to use Sprint 49's PersistentAgentsScreen / NewDmModal / WorkflowEditorScreen as templates. This is acceptable because the patterns are well-established by Sprint 49; full inline code would triple the plan size with copy-paste from existing files.

**Type consistency:** `member_kind` strings are `'human' | 'tally' | 'persistent_agent'` throughout. Roles are `'owner' | 'admin' | 'manager' | 'member'` throughout. `workspace_id` is int. `user_id` is string.

Plan ready to execute.
