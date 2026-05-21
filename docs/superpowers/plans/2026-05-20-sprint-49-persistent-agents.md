# Sprint 49 — Persistent agents + DMs + escalation chain — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship persistent agents (cron + HTTP-webhook event triggers), the Tally→user DM escalation chain, and the DM/scheduled-agent UI primitives that surface them. Reuse the Sprint 48 `WorkflowEditorScreen` for persistent-agent setup via a new Trigger palette node.

**Architecture:** A new `persistent_agents` table + `tasks.persistent_agent_id` column. The orchestrator gains a 30-second `croniter`-driven asyncio polling loop alongside the existing worker/event pollers. Each cron fire creates a normal `tasks` row (cost accounting + audit unchanged) but routes messages to the persistent agent's `scheduled_agent` channel via a new `resolve_task_channel_id` indirection. An HMAC-SHA256 webhook endpoint fires the same path for event triggers. Tally is a deterministic responder (no LLM) running inside `_broadcast_new_message`'s fan-out: when it sees `kind='escalation'`, it ensures a Tally↔owner DM exists and posts a templated message. Flutter adds `PersistentAgentsScreen`, a "Direct messages" channel-rail category, the Trigger palette node, and a "+New DM" modal.

**Tech Stack:** Python 3.12 / FastAPI / SQLite (orchestrator), `croniter ^6.2.2` (MIT, no transitive deps), Flutter 3.44 / Dart 3.12 / vyuh_node_flow 0.27.3 (carried from Sprint 48), Docker / Phala CVM (deploy).

**Resolved open questions from spec stage:** all 8 decisions locked in the spec — see [`docs/superpowers/specs/2026-05-20-sprint-49-persistent-agents-design.md`](../specs/2026-05-20-sprint-49-persistent-agents-design.md).

---

## Phase A — Backend (14 tasks, ~25h)

### Task A1: persistent_agents schema migration

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — extend `SCHEMA`
- Create: `services/orchestrator/tests/test_persistent_agents_schema.py`

- [ ] **Step 1: Write the failing test**

```python
"""Sprint 49: persistent_agents table presence + columns."""
from tally_orchestrator.service import Db


def test_persistent_agents_table_present(db: Db):
    row = db._conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='persistent_agents'"
    ).fetchone()
    assert row is not None


def test_persistent_agents_columns(db: Db):
    cols = {r[1]: r[2] for r in db._conn.execute("PRAGMA table_info(persistent_agents)").fetchall()}
    expected = {
        "id", "workspace_id", "name", "role_name", "team_spec_json",
        "tool_allowlist_json", "model", "cron_schedule", "event_triggers_json",
        "enabled", "last_run_at", "next_scheduled_run_at", "consecutive_failures",
        "created_at", "deleted_at",
    }
    assert expected.issubset(set(cols.keys()))


def test_persistent_agents_index(db: Db):
    idxs = {r[1] for r in db._conn.execute("PRAGMA index_list('persistent_agents')").fetchall()}
    assert "idx_persistent_agents" in idxs
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_persistent_agents_schema.py -v
```

Expected: 3 FAILs.

- [ ] **Step 3: Extend the SCHEMA constant**

In `service.py`, find the `SCHEMA = """..."""` triple-quoted string (search for `CREATE TABLE IF NOT EXISTS workspaces`). Append at the end (BEFORE the closing `"""`):

```sql
CREATE TABLE IF NOT EXISTS persistent_agents (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    workspace_id INTEGER NOT NULL REFERENCES workspaces(id),
    name TEXT NOT NULL,
    role_name TEXT NOT NULL,
    team_spec_json TEXT NOT NULL,
    tool_allowlist_json TEXT,
    model TEXT,
    cron_schedule TEXT,
    event_triggers_json TEXT NOT NULL DEFAULT '[]',
    enabled INTEGER NOT NULL DEFAULT 1,
    last_run_at REAL,
    next_scheduled_run_at REAL,
    consecutive_failures INTEGER NOT NULL DEFAULT 0,
    created_at REAL NOT NULL,
    deleted_at REAL
);
CREATE INDEX IF NOT EXISTS idx_persistent_agents
    ON persistent_agents(workspace_id, enabled, next_scheduled_run_at);
```

- [ ] **Step 4: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_persistent_agents_schema.py -v
```

Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_persistent_agents_schema.py
git commit -m "[s49] schema: persistent_agents table + idx_persistent_agents"
```

### Task A2: tasks.persistent_agent_id column

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — idempotent migration block
- Append: `services/orchestrator/tests/test_persistent_agents_schema.py`

- [ ] **Step 1: Append failing test**

```python
def test_tasks_persistent_agent_id_column(db: Db):
    cols = {r[1] for r in db._conn.execute("PRAGMA table_info(tasks)").fetchall()}
    assert "persistent_agent_id" in cols


def test_tasks_persistent_agent_id_index(db: Db):
    idxs = {r[1] for r in db._conn.execute("PRAGMA index_list('tasks')").fetchall()}
    assert "idx_tasks_persistent_agent" in idxs
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_persistent_agents_schema.py -v -k persistent_agent_id
```

Expected: 2 FAILs.

- [ ] **Step 3: Add idempotent migration**

In `Db.__init__`, find the existing `ALTER TABLE tasks ADD COLUMN ...` block (Sprint 47 / Sprint 48 added several). Add a new try/except block alongside:

```python
        try:
            self._conn.execute(
                "ALTER TABLE tasks ADD COLUMN persistent_agent_id INTEGER REFERENCES persistent_agents(id)"
            )
        except sqlite3.OperationalError:
            pass
        try:
            self._conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_tasks_persistent_agent ON tasks(persistent_agent_id)"
            )
        except sqlite3.OperationalError:
            pass
```

- [ ] **Step 4: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_persistent_agents_schema.py -v
cd services/orchestrator && uv run pytest tests/ -q
```

Expected: 5 PASS in the schema file; no regressions in full suite.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_persistent_agents_schema.py
git commit -m "[s49] tasks: persistent_agent_id column + index"
```

### Task A3: Tally workspace_member + channel_member backfill

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — extend `_backfill_workspaces_and_channels`
- Append: `services/orchestrator/tests/test_workspace_schema.py`

- [ ] **Step 1: Append failing tests**

```python
def test_backfill_tally_workspace_member(db: Db):
    """Every workspace has a tally workspace_member after backfill."""
    rows = db._conn.execute(
        "SELECT w.id FROM workspaces w "
        "WHERE NOT EXISTS (SELECT 1 FROM workspace_members wm "
        "                  WHERE wm.workspace_id=w.id AND wm.member_kind='tally')"
    ).fetchall()
    assert rows == []


def test_backfill_tally_in_general_and_backlog(db: Db):
    """Tally is a channel_member of every existing #general and #backlog channel."""
    rows = db._conn.execute(
        "SELECT c.id, c.kind FROM channels c "
        "WHERE c.kind IN ('general', 'backlog') "
        "AND NOT EXISTS (SELECT 1 FROM channel_members cm "
        "                WHERE cm.channel_id=c.id AND cm.member_kind='tally')"
    ).fetchall()
    assert rows == []
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_schema.py -v -k tally
```

Expected: 2 FAILs.

- [ ] **Step 3: Extend backfill**

In `service.py` `_backfill_workspaces_and_channels`, AFTER the existing workspace + channel creation loop, add:

```python
        # Sprint 49: ensure every workspace has a Tally workspace_member.
        all_workspace_ids = [r[0] for r in self._conn.execute("SELECT id FROM workspaces").fetchall()]
        for ws_id in all_workspace_ids:
            existing = self._conn.execute(
                "SELECT 1 FROM workspace_members WHERE workspace_id=? AND member_kind='tally'",
                (ws_id,),
            ).fetchone()
            if existing is None:
                self._conn.execute(
                    "INSERT INTO workspace_members (workspace_id, member_kind, user_id, role, joined_at) "
                    "VALUES (?, 'tally', NULL, 'tally', ?)",
                    (ws_id, now),
                )
        # Sprint 49: add Tally as channel_member of #general and #backlog channels.
        for ws_id in all_workspace_ids:
            for kind in ("general", "backlog"):
                ch_row = self._conn.execute(
                    "SELECT id FROM channels WHERE workspace_id=? AND kind=?",
                    (ws_id, kind),
                ).fetchone()
                if ch_row is None:
                    continue
                channel_id = ch_row[0]
                existing = self._conn.execute(
                    "SELECT 1 FROM channel_members WHERE channel_id=? AND member_kind='tally'",
                    (channel_id,),
                ).fetchone()
                if existing is None:
                    self._conn.execute(
                        "INSERT INTO channel_members (channel_id, member_kind, user_id, joined_at) "
                        "VALUES (?, 'tally', NULL, ?)",
                        (channel_id, now),
                    )
```

(Locate this addition after the existing per-user workspace creation loop. `now` should be the same `time.time()` variable used by the rest of the method.)

- [ ] **Step 4: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_schema.py -v
cd services/orchestrator && uv run pytest tests/ -q
```

Expected: all PASS, no regressions.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_workspace_schema.py
git commit -m "[s49] backfill: add tally workspace_member + channel_member for general/backlog"
```

### Task A4: Db helpers for persistent_agents

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — `Db` class
- Create: `services/orchestrator/tests/test_persistent_agents_crud.py`

- [ ] **Step 1: Write the failing tests**

Create `services/orchestrator/tests/test_persistent_agents_crud.py`:

```python
"""Sprint 49: Db helpers for persistent_agents."""
import json
from tally_orchestrator.service import Db


def test_create_persistent_agent_returns_id(db: Db):
    pid = db.create_persistent_agent(
        workspace_id=1,
        name="nightly-tests",
        role_name="Tester",
        team_spec={"nodes": [{"id": "n1", "kind": "agent", "role": "Tester"}], "edges": [], "format": "nodes_v1"},
        cron_schedule="0 21 * * *",
    )
    assert isinstance(pid, int) and pid > 0


def test_create_persistent_agent_creates_scheduled_agent_channel(db: Db):
    pid = db.create_persistent_agent(
        workspace_id=1, name="nightly", role_name="Tester",
        team_spec={"nodes": [], "edges": []},
    )
    row = db._conn.execute(
        "SELECT id, name, kind FROM channels WHERE persistent_agent_id=?", (pid,)
    ).fetchone()
    assert row is not None
    assert row[2] == "scheduled_agent"


def test_create_persistent_agent_adds_owner_and_tally_as_members(db: Db):
    pid = db.create_persistent_agent(
        workspace_id=1, name="nightly", role_name="Tester",
        team_spec={"nodes": [], "edges": []},
    )
    ch_id = db._conn.execute(
        "SELECT id FROM channels WHERE persistent_agent_id=?", (pid,)
    ).fetchone()[0]
    member_kinds = {r[0] for r in db._conn.execute(
        "SELECT member_kind FROM channel_members WHERE channel_id=?", (ch_id,)
    ).fetchall()}
    assert "human" in member_kinds  # owner
    assert "tally" in member_kinds


def test_create_persistent_agent_computes_next_scheduled_run(db: Db):
    pid = db.create_persistent_agent(
        workspace_id=1, name="nightly", role_name="Tester",
        team_spec={"nodes": [], "edges": []},
        cron_schedule="0 21 * * *",
    )
    row = db._conn.execute(
        "SELECT next_scheduled_run_at FROM persistent_agents WHERE id=?", (pid,)
    ).fetchone()
    assert row[0] is not None and row[0] > 0


def test_list_persistent_agents(db: Db):
    db.create_persistent_agent(workspace_id=1, name="a", role_name="Tester", team_spec={})
    db.create_persistent_agent(workspace_id=1, name="b", role_name="Tester", team_spec={})
    rows = db.list_persistent_agents(workspace_id=1)
    names = {r["name"] for r in rows}
    assert {"a", "b"}.issubset(names)


def test_update_persistent_agent(db: Db):
    pid = db.create_persistent_agent(workspace_id=1, name="a", role_name="Tester", team_spec={})
    db.update_persistent_agent(pid, patch={"name": "renamed", "enabled": 0})
    row = db._conn.execute(
        "SELECT name, enabled FROM persistent_agents WHERE id=?", (pid,)
    ).fetchone()
    assert row[0] == "renamed"
    assert row[1] == 0


def test_delete_persistent_agent_soft(db: Db):
    pid = db.create_persistent_agent(workspace_id=1, name="a", role_name="Tester", team_spec={})
    db.delete_persistent_agent(pid)
    row = db._conn.execute(
        "SELECT deleted_at FROM persistent_agents WHERE id=?", (pid,)
    ).fetchone()
    assert row[0] is not None
    # Listing excludes deleted
    rows = db.list_persistent_agents(workspace_id=1)
    assert all(r["id"] != pid for r in rows)
```

The `db` fixture already exists (Sprint 47 conftest.py).

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_persistent_agents_crud.py -v
```

Expected: 7 FAILs (methods don't exist).

- [ ] **Step 3: Implement the Db helpers**

In `service.py` `Db` class, add (near `create_task` / `approve_task` for logical proximity):

```python
    def create_persistent_agent(
        self,
        *,
        workspace_id: int,
        name: str,
        role_name: str,
        team_spec: dict,
        tool_allowlist: dict | None = None,
        model: str | None = None,
        cron_schedule: str | None = None,
        event_triggers: list[dict] | None = None,
    ) -> int:
        """Sprint 49: create a persistent agent + its scheduled_agent channel
        + owner & Tally channel_members.  Computes next_scheduled_run_at
        from `cron_schedule` if provided."""
        now = time.time()
        next_run: float | None = None
        if cron_schedule:
            from croniter import croniter
            next_run = float(croniter(cron_schedule, now).get_next(float))
        cur = self._conn.execute(
            "INSERT INTO persistent_agents "
            "(workspace_id, name, role_name, team_spec_json, tool_allowlist_json, "
            " model, cron_schedule, event_triggers_json, next_scheduled_run_at, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                workspace_id, name, role_name,
                json.dumps(team_spec),
                json.dumps(tool_allowlist) if tool_allowlist else None,
                model,
                cron_schedule,
                json.dumps(event_triggers or []),
                next_run,
                now,
            ),
        )
        pid = int(cur.lastrowid or 0)
        # Create the scheduled_agent channel.
        ch_cur = self._conn.execute(
            "INSERT INTO channels (workspace_id, kind, name, persistent_agent_id, created_at) "
            "VALUES (?, 'scheduled_agent', ?, ?, ?)",
            (workspace_id, name, pid, now),
        )
        channel_id = ch_cur.lastrowid
        # Add the workspace owner + Tally as channel_members.
        owner_row = self._conn.execute(
            "SELECT owner_user_id FROM workspaces WHERE id=?", (workspace_id,)
        ).fetchone()
        if owner_row:
            self._conn.execute(
                "INSERT INTO channel_members (channel_id, member_kind, user_id, joined_at) "
                "VALUES (?, 'human', ?, ?)",
                (channel_id, owner_row[0], now),
            )
        self._conn.execute(
            "INSERT INTO channel_members (channel_id, member_kind, user_id, joined_at) "
            "VALUES (?, 'tally', NULL, ?)",
            (channel_id, now),
        )
        return pid

    def list_persistent_agents(self, *, workspace_id: int) -> list[dict]:
        """Sprint 49: list active (non-deleted) persistent agents."""
        rows = self._conn.execute(
            "SELECT id, workspace_id, name, role_name, team_spec_json, "
            "tool_allowlist_json, model, cron_schedule, event_triggers_json, "
            "enabled, last_run_at, next_scheduled_run_at, consecutive_failures, "
            "created_at "
            "FROM persistent_agents "
            "WHERE workspace_id=? AND deleted_at IS NULL "
            "ORDER BY created_at DESC",
            (workspace_id,),
        ).fetchall()
        out = []
        for r in rows:
            out.append({
                "id": r[0], "workspace_id": r[1], "name": r[2], "role_name": r[3],
                "team_spec": json.loads(r[4]) if r[4] else {},
                "tool_allowlist": json.loads(r[5]) if r[5] else None,
                "model": r[6], "cron_schedule": r[7],
                "event_triggers": json.loads(r[8]) if r[8] else [],
                "enabled": bool(r[9]),
                "last_run_at": r[10], "next_scheduled_run_at": r[11],
                "consecutive_failures": r[12], "created_at": r[13],
            })
        return out

    def get_persistent_agent(self, pid: int) -> dict | None:
        rows = self.list_persistent_agents(workspace_id=-1)  # placeholder; specialize below
        # Specialized single-row fetch
        r = self._conn.execute(
            "SELECT id, workspace_id, name, role_name, team_spec_json, "
            "tool_allowlist_json, model, cron_schedule, event_triggers_json, "
            "enabled, last_run_at, next_scheduled_run_at, consecutive_failures, "
            "created_at, deleted_at "
            "FROM persistent_agents WHERE id=?",
            (pid,),
        ).fetchone()
        if r is None:
            return None
        return {
            "id": r[0], "workspace_id": r[1], "name": r[2], "role_name": r[3],
            "team_spec": json.loads(r[4]) if r[4] else {},
            "tool_allowlist": json.loads(r[5]) if r[5] else None,
            "model": r[6], "cron_schedule": r[7],
            "event_triggers": json.loads(r[8]) if r[8] else [],
            "enabled": bool(r[9]),
            "last_run_at": r[10], "next_scheduled_run_at": r[11],
            "consecutive_failures": r[12], "created_at": r[13],
            "deleted_at": r[14],
        }

    def update_persistent_agent(self, pid: int, *, patch: dict) -> None:
        """Sprint 49: partial update.  Recomputes next_scheduled_run_at if
        cron_schedule changed.  Acceptable fields: name, team_spec,
        tool_allowlist, model, cron_schedule, event_triggers, enabled."""
        allowed = {
            "name", "team_spec", "tool_allowlist", "model",
            "cron_schedule", "event_triggers", "enabled",
        }
        sets: list[str] = []
        params: list = []
        for key, val in patch.items():
            if key not in allowed:
                continue
            if key == "team_spec":
                sets.append("team_spec_json=?")
                params.append(json.dumps(val))
            elif key == "tool_allowlist":
                sets.append("tool_allowlist_json=?")
                params.append(json.dumps(val) if val else None)
            elif key == "event_triggers":
                sets.append("event_triggers_json=?")
                params.append(json.dumps(val or []))
            else:
                sets.append(f"{key}=?")
                params.append(val)
        if "cron_schedule" in patch and patch["cron_schedule"]:
            from croniter import croniter
            next_run = float(croniter(patch["cron_schedule"], time.time()).get_next(float))
            sets.append("next_scheduled_run_at=?")
            params.append(next_run)
        if not sets:
            return
        params.append(pid)
        self._conn.execute(
            f"UPDATE persistent_agents SET {', '.join(sets)} WHERE id=?",
            tuple(params),
        )

    def delete_persistent_agent(self, pid: int) -> None:
        """Sprint 49: soft delete (sets deleted_at).  Disables future fires;
        preserves history."""
        self._conn.execute(
            "UPDATE persistent_agents SET deleted_at=?, enabled=0 WHERE id=?",
            (time.time(), pid),
        )
```

You'll also need `from croniter import croniter` at the top of service.py (or inside the methods to avoid an import cost when croniter isn't installed during early tests — local import is fine).

Add `croniter` to the orchestrator's dependencies:

```bash
cd /home/nick/Projects/pronoic/tally-coding/services/orchestrator && uv add croniter
```

This updates `pyproject.toml` + `uv.lock`. Commit both with the rest of A4.

- [ ] **Step 4: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_persistent_agents_crud.py -v
```

Expected: 7 PASS.

Full suite:

```bash
cd services/orchestrator && uv run pytest tests/ -q
```

Expected: no regressions.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_persistent_agents_crud.py services/orchestrator/pyproject.toml services/orchestrator/uv.lock
git commit -m "[s49] Db: create/list/get/update/delete persistent_agents + croniter dep"
```

### Task A5: POST /persistent_agents route

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Create: `services/orchestrator/tests/test_persistent_agents_routes.py`

- [ ] **Step 1: Write the failing tests**

Create `services/orchestrator/tests/test_persistent_agents_routes.py`. Reuse the `client` fixture pattern from Sprint 47 `test_channels_routes.py`:

```python
"""Sprint 49: persistent_agents HTTP routes."""
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


def test_post_persistent_agents_returns_201_and_id(client):
    r = client.post("/persistent_agents", json={
        "workspace_id": 1,
        "name": "nightly-tests",
        "role_name": "Tester",
        "team_spec": {"nodes": [{"id": "n1", "kind": "agent", "role": "Tester"}], "edges": [], "format": "nodes_v1"},
        "cron_schedule": "0 21 * * *",
    })
    assert r.status_code == 200
    body = r.json()
    assert body["name"] == "nightly-tests"
    assert body["id"] > 0
    assert body["cron_schedule"] == "0 21 * * *"


def test_post_persistent_agents_creates_scheduled_agent_channel(client):
    import tally_orchestrator.service as svc
    r = client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "nightly", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
    })
    pid = r.json()["id"]
    db = svc.state["db"]
    row = db._conn.execute(
        "SELECT kind FROM channels WHERE persistent_agent_id=?", (pid,)
    ).fetchone()
    assert row is not None
    assert row[0] == "scheduled_agent"


def test_post_persistent_agents_non_member_returns_403(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="stranger", source="clerk", plan="free", email="s@x.com",
    )
    r = client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "x", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
    })
    assert r.status_code == 403
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_persistent_agents_routes.py -v
```

Expected: 3 FAILs (route doesn't exist).

- [ ] **Step 3: Add Pydantic model + route**

In `service.py`, near other Pydantic request models:

```python
class PersistentAgentCreateRequest(BaseModel):
    workspace_id: int
    name: str
    role_name: str
    team_spec: dict
    tool_allowlist: dict | None = None
    model: str | None = None
    cron_schedule: str | None = None
    event_triggers: list[dict] | None = None
```

Add the route near the other `/persistent_agents/...` routes (none yet — add a new section):

```python
@app.post("/persistent_agents")
async def create_persistent_agent_route(
    body: PersistentAgentCreateRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 49: create a persistent agent + its scheduled_agent channel.
    Caller must be a workspace_member of the target workspace."""
    db: Db = state["db"]
    is_member = db._conn.execute(
        "SELECT 1 FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human' LIMIT 1",
        (body.workspace_id, user.id),
    ).fetchone()
    if not is_member:
        raise HTTPException(403, "not a member of this workspace")
    # Sprint 49: rotate secrets for new HTTP triggers
    triggers = list(body.event_triggers or [])
    for trig in triggers:
        if trig.get("kind") == "http" and not trig.get("secret"):
            trig["secret"] = secrets.token_hex(16)
        if not trig.get("id"):
            trig["id"] = secrets.token_hex(8)
    pid = db.create_persistent_agent(
        workspace_id=body.workspace_id,
        name=body.name,
        role_name=body.role_name,
        team_spec=body.team_spec,
        tool_allowlist=body.tool_allowlist,
        model=body.model,
        cron_schedule=body.cron_schedule,
        event_triggers=triggers,
    )
    return db.get_persistent_agent(pid)
```

Add `import secrets` to service.py's imports if not already present.

- [ ] **Step 4: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_persistent_agents_routes.py -v
```

Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_persistent_agents_routes.py
git commit -m "[s49] POST /persistent_agents — create + scheduled_agent channel + HMAC secrets"
```

### Task A6: GET + PATCH /persistent_agents routes

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Append: `services/orchestrator/tests/test_persistent_agents_routes.py`

- [ ] **Step 1: Append failing tests**

```python
def test_get_persistent_agents_returns_list(client):
    client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "a", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
    })
    r = client.get("/persistent_agents?workspace_id=1")
    assert r.status_code == 200
    body = r.json()
    assert "persistent_agents" in body
    assert any(a["name"] == "a" for a in body["persistent_agents"])


def test_patch_persistent_agent_renames(client):
    r = client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "old", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
    })
    pid = r.json()["id"]
    r2 = client.patch(f"/persistent_agents/{pid}", json={"name": "new"})
    assert r2.status_code == 200
    assert r2.json()["name"] == "new"


def test_patch_persistent_agent_cron_recomputes_next_run(client):
    r = client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "a", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
    })
    pid = r.json()["id"]
    r2 = client.patch(f"/persistent_agents/{pid}", json={"cron_schedule": "0 9 * * *"})
    assert r2.status_code == 200
    assert r2.json()["next_scheduled_run_at"] is not None
    assert r2.json()["next_scheduled_run_at"] > 0


def test_patch_non_member_returns_403(client):
    r = client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "a", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
    })
    pid = r.json()["id"]
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="stranger", source="clerk", plan="free", email="s@x.com",
    )
    r2 = client.patch(f"/persistent_agents/{pid}", json={"name": "x"})
    assert r2.status_code == 403
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_persistent_agents_routes.py -v
```

Expected: 4 new FAILs.

- [ ] **Step 3: Add request model + 2 routes**

```python
class PersistentAgentPatchRequest(BaseModel):
    name: str | None = None
    team_spec: dict | None = None
    tool_allowlist: dict | None = None
    model: str | None = None
    cron_schedule: str | None = None
    event_triggers: list[dict] | None = None
    enabled: bool | None = None


@app.get("/persistent_agents")
async def list_persistent_agents_route(
    workspace_id: int,
    user: ClerkUser = Depends(require_user),
) -> dict:
    db: Db = state["db"]
    is_member = db._conn.execute(
        "SELECT 1 FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human' LIMIT 1",
        (workspace_id, user.id),
    ).fetchone()
    if not is_member:
        return {"persistent_agents": []}
    return {"persistent_agents": db.list_persistent_agents(workspace_id=workspace_id)}


@app.patch("/persistent_agents/{pid}")
async def patch_persistent_agent_route(
    pid: int,
    body: PersistentAgentPatchRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    db: Db = state["db"]
    agent = db.get_persistent_agent(pid)
    if agent is None or agent.get("deleted_at"):
        raise HTTPException(404, "persistent agent not found")
    is_member = db._conn.execute(
        "SELECT 1 FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human' LIMIT 1",
        (agent["workspace_id"], user.id),
    ).fetchone()
    if not is_member:
        raise HTTPException(403, "not a member of this workspace")
    patch = {k: v for k, v in body.model_dump(exclude_unset=True).items() if v is not None or k == "enabled"}
    db.update_persistent_agent(pid, patch=patch)
    return db.get_persistent_agent(pid)
```

- [ ] **Step 4: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_persistent_agents_routes.py -v
```

Expected: 7 PASS (3 from A5 + 4 new).

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_persistent_agents_routes.py
git commit -m "[s49] GET + PATCH /persistent_agents — list + update (recomputes cron next-fire)"
```

### Task A7: POST /persistent_agents/{id}/run_now + DELETE

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Append: `services/orchestrator/tests/test_persistent_agents_routes.py`

- [ ] **Step 1: Append failing tests**

```python
def test_run_now_creates_task_with_persistent_agent_id(client):
    import tally_orchestrator.service as svc
    r = client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "a", "role_name": "Tester",
        "team_spec": {"agents": [{"role": "Tester"}], "stages": [[0]], "workflow": "sequential"},
    })
    pid = r.json()["id"]
    r2 = client.post(f"/persistent_agents/{pid}/run_now")
    assert r2.status_code == 200
    db = svc.state["db"]
    cnt = db._conn.execute(
        "SELECT COUNT(*) FROM tasks WHERE persistent_agent_id=?", (pid,)
    ).fetchone()[0]
    assert cnt == 1


def test_delete_persistent_agent_soft(client):
    r = client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "a", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
    })
    pid = r.json()["id"]
    r2 = client.delete(f"/persistent_agents/{pid}")
    assert r2.status_code == 200
    # No longer appears in list
    r3 = client.get("/persistent_agents?workspace_id=1")
    assert all(a["id"] != pid for a in r3.json()["persistent_agents"])
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_persistent_agents_routes.py -v -k "run_now or delete"
```

Expected: 2 FAILs.

- [ ] **Step 3: Add the two routes**

```python
@app.post("/persistent_agents/{pid}/run_now")
async def run_persistent_agent_now_route(
    pid: int,
    user: ClerkUser = Depends(require_user),
) -> dict:
    db: Db = state["db"]
    agent = db.get_persistent_agent(pid)
    if agent is None or agent.get("deleted_at"):
        raise HTTPException(404, "persistent agent not found")
    is_member = db._conn.execute(
        "SELECT 1 FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human' LIMIT 1",
        (agent["workspace_id"], user.id),
    ).fetchone()
    if not is_member:
        raise HTTPException(403, "not a member of this workspace")
    orch = state.get("orch")
    if orch is None:
        raise HTTPException(503, "orchestrator not ready")
    task_id = await orch._fire_persistent_agent(pid, trigger="manual")
    return {"ok": True, "task_id": task_id, "persistent_agent_id": pid}


@app.delete("/persistent_agents/{pid}")
async def delete_persistent_agent_route(
    pid: int,
    user: ClerkUser = Depends(require_user),
) -> dict:
    db: Db = state["db"]
    agent = db.get_persistent_agent(pid)
    if agent is None or agent.get("deleted_at"):
        raise HTTPException(404, "persistent agent not found")
    is_member = db._conn.execute(
        "SELECT 1 FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human' LIMIT 1",
        (agent["workspace_id"], user.id),
    ).fetchone()
    if not is_member:
        raise HTTPException(403, "not a member of this workspace")
    db.delete_persistent_agent(pid)
    return {"ok": True}
```

NOTE: `orch._fire_persistent_agent` is added in Task A8.  The run_now route will fail until A8 lands.  If you want to keep tests green incrementally, gate the run_now test with `pytest.mark.skipif(not hasattr(orch, '_fire_persistent_agent'), ...)` or comment it until A8.  Cleanest path: implement A7 + A8 in the same commit, OR delay the run_now test until A8 finishes.

For TDD: just write the test now; it'll fail with `AttributeError` or `503` until A8 wires `_fire_persistent_agent`. Then it passes.

- [ ] **Step 4: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_persistent_agents_routes.py -v -k delete
```

Expected: DELETE test passes; run_now test still failing (orch missing the method).

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_persistent_agents_routes.py
git commit -m "[s49] POST /persistent_agents/{id}/run_now + DELETE soft-delete"
```

### Task A8: `_fire_persistent_agent` + channel routing

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — Orchestrator class + channels.py
- Modify: `services/orchestrator/tally_orchestrator/channels.py` — add `resolve_task_channel_id`
- Create: `services/orchestrator/tests/test_channel_routing.py`

- [ ] **Step 1: Write the failing tests**

Create `services/orchestrator/tests/test_channel_routing.py`:

```python
"""Sprint 49: channel routing for persistent-agent tasks."""
from tally_orchestrator.service import Db
from tally_orchestrator.channels import resolve_task_channel_id, get_task_channel_id


def test_resolve_task_channel_id_no_persistent_agent_falls_back(db: Db):
    """Sprint 47 behavior preserved: tasks without persistent_agent_id route to their task channel."""
    task_id = db.create_task("test", team_spec={}, user_id="admin")
    db.approve_task(task_id)
    legacy = get_task_channel_id(db, task_id)
    resolved = resolve_task_channel_id(db, task_id)
    assert resolved == legacy
    assert resolved is not None


def test_resolve_task_channel_id_routes_to_scheduled_agent(db: Db):
    """When a task has persistent_agent_id, route to the agent's scheduled_agent channel."""
    pid = db.create_persistent_agent(
        workspace_id=1, name="x", role_name="Tester", team_spec={},
    )
    # Find the scheduled_agent channel
    sa_ch = db._conn.execute(
        "SELECT id FROM channels WHERE persistent_agent_id=? AND kind='scheduled_agent'", (pid,)
    ).fetchone()[0]
    # Create a task with persistent_agent_id set
    import uuid
    task_id = uuid.uuid4().hex
    db._conn.execute(
        "INSERT INTO tasks (id, description, status, persistent_agent_id, user_id, created_at, updated_at) "
        "VALUES (?, 'x', 'pending', ?, 'admin', 0, 0)",
        (task_id, pid),
    )
    resolved = resolve_task_channel_id(db, task_id)
    assert resolved == sa_ch
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_channel_routing.py -v
```

Expected: 2 FAILs (`resolve_task_channel_id` doesn't exist).

- [ ] **Step 3: Add `resolve_task_channel_id` to channels.py**

Append to `services/orchestrator/tally_orchestrator/channels.py`:

```python
def resolve_task_channel_id(db: "Db", task_id: str) -> int | None:
    """Sprint 49: prefer the persistent_agent's scheduled_agent channel
    if the task was fired by a persistent agent; else fall back to the
    Sprint 47 per-task channel."""
    row = db._conn.execute(
        "SELECT persistent_agent_id FROM tasks WHERE id=?", (task_id,)
    ).fetchone()
    if row and row[0]:
        ch = db._conn.execute(
            "SELECT id FROM channels WHERE persistent_agent_id=? AND kind='scheduled_agent'",
            (row[0],),
        ).fetchone()
        if ch:
            return int(ch[0])
    return get_task_channel_id(db, task_id)
```

- [ ] **Step 4: Add `_fire_persistent_agent` to Orchestrator**

In `service.py` `Orchestrator` class:

```python
    async def _fire_persistent_agent(self, pid: int, *, trigger: str) -> str | None:
        """Sprint 49: create a tasks row + dispatch.  Returns task_id or
        None if the agent is disabled / deleted / missing.  trigger is
        one of 'cron', 'webhook', 'manual'."""
        agent = self.db.get_persistent_agent(pid)
        if agent is None or agent.get("deleted_at") or not agent.get("enabled"):
            return None
        # Create tasks row with persistent_agent_id set, status='pending'
        import uuid
        task_id = uuid.uuid4().hex
        now = time.time()
        self.db._conn.execute(
            "INSERT INTO tasks (id, description, team_spec, status, "
            "persistent_agent_id, user_id, created_at, updated_at) "
            "VALUES (?, ?, ?, 'pending', ?, ?, ?, ?)",
            (
                task_id,
                f"[persistent: {agent['name']}] {trigger} fire",
                json.dumps(agent["team_spec"]),
                pid,
                # Owner from workspace
                self.db._conn.execute(
                    "SELECT owner_user_id FROM workspaces WHERE id=?", (agent["workspace_id"],)
                ).fetchone()[0],
                now,
                now,
            ),
        )
        logger.info(
            "persistent agent %s (%s) fired via %s -> task %s",
            pid, agent["name"], trigger, task_id[:8],
        )
        # The worker poller picks up status='pending' on its next tick.
        # Optionally kick the poller for lower latency.
        if hasattr(self, "_kick_poller"):
            try:
                asyncio.create_task(self._kick_poller())
            except Exception:
                pass
        return task_id
```

- [ ] **Step 5: Wire channel routing**

Find every call site of `get_task_channel_id` in `service.py` (search `grep -n "get_task_channel_id" services/orchestrator/tally_orchestrator/service.py`). Replace each with `resolve_task_channel_id` (import: `from .channels import resolve_task_channel_id`).

The Sprint 47 A11 agent-context loop uses `get_task_channel_id` — that's still fine since for a persistent-agent task the resolution should route messages to the scheduled_agent channel (this is exactly what we want).

- [ ] **Step 6: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_channel_routing.py tests/test_persistent_agents_routes.py -v
```

Expected: all PASS (including the A7 run_now test that was waiting on this).

Full suite:

```bash
cd services/orchestrator && uv run pytest tests/ -q
```

Expected: no regressions.

- [ ] **Step 7: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tally_orchestrator/channels.py services/orchestrator/tests/test_channel_routing.py
git commit -m "[s49] _fire_persistent_agent + resolve_task_channel_id (route to scheduled_agent)"
```

### Task A9: croniter cron poller

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — `Orchestrator._persistent_agents_loop`
- Create: `services/orchestrator/tests/test_cron_loop.py`

- [ ] **Step 1: Write the failing test**

Create `services/orchestrator/tests/test_cron_loop.py`:

```python
"""Sprint 49: persistent-agent cron polling loop."""
import asyncio
import time
import pytest
from tally_orchestrator.service import Db


@pytest.mark.asyncio
async def test_cron_loop_fires_due_agent(db: Db):
    """An agent with next_scheduled_run_at <= now fires + the column advances."""
    pid = db.create_persistent_agent(
        workspace_id=1, name="a", role_name="Tester",
        team_spec={"nodes": [{"id": "n1", "kind": "agent", "role": "Tester"}], "edges": [], "format": "nodes_v1"},
        cron_schedule="* * * * *",  # every minute
    )
    # Force it past-due
    db._conn.execute(
        "UPDATE persistent_agents SET next_scheduled_run_at=? WHERE id=?",
        (time.time() - 60, pid),
    )

    # Build a minimal Orchestrator-like context to run one loop tick
    from tally_orchestrator.service import Orchestrator
    # Simplified: call the loop's inner body directly
    from croniter import croniter
    now = time.time()
    rows = db._conn.execute(
        "SELECT id, cron_schedule FROM persistent_agents "
        "WHERE enabled=1 AND deleted_at IS NULL AND cron_schedule IS NOT NULL AND next_scheduled_run_at <= ?",
        (now,),
    ).fetchall()
    assert len(rows) == 1
    # The orchestrator would now call _fire_persistent_agent + update next_scheduled_run_at
    # Simulate the update
    next_fire = float(croniter("* * * * *", now).get_next(float))
    db._conn.execute(
        "UPDATE persistent_agents SET last_run_at=?, next_scheduled_run_at=? WHERE id=?",
        (now, next_fire, pid),
    )
    new_next = db._conn.execute(
        "SELECT next_scheduled_run_at FROM persistent_agents WHERE id=?", (pid,)
    ).fetchone()[0]
    assert new_next > now
```

The test here exercises the SQL + croniter mechanics directly rather than spinning up an `Orchestrator` instance.  Spinning up a real Orchestrator requires the worker pool — out of scope for this unit-style test.

For testing the actual `_persistent_agents_loop` method, we'd need a fixture that provides an Orchestrator with a mock fire method.  Approach:

```python
@pytest.mark.asyncio
async def test_persistent_agents_loop_method_fires(db: Db, monkeypatch):
    """End-to-end-ish: instantiate orchestrator (with mocked fire), run loop tick."""
    from tally_orchestrator.service import Orchestrator
    orch = Orchestrator.__new__(Orchestrator)  # bypass __init__
    orch.db = db
    orch._stopping = False
    fired = []
    async def fake_fire(pid, *, trigger):
        fired.append((pid, trigger))
        return None
    orch._fire_persistent_agent = fake_fire
    pid = db.create_persistent_agent(
        workspace_id=1, name="a", role_name="Tester", team_spec={},
        cron_schedule="* * * * *",
    )
    db._conn.execute("UPDATE persistent_agents SET next_scheduled_run_at=? WHERE id=?",
                     (time.time() - 60, pid))
    # Run ONE tick of the loop (factored out of the while loop)
    await orch._persistent_agents_tick()  # extracted method, see Step 3
    assert fired == [(pid, "cron")]
```

(`_persistent_agents_tick` is the body of the while-loop, factored out for testability — see Step 3.)

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_cron_loop.py -v
```

Expected: at least 1 FAIL (`_persistent_agents_tick` not defined).

- [ ] **Step 3: Add the cron loop**

In `Orchestrator`:

```python
    async def _persistent_agents_tick(self) -> None:
        """One iteration of the persistent-agents cron poll.  Factored out
        so tests can call a single tick without the infinite loop."""
        now = time.time()
        rows = self.db._conn.execute(
            "SELECT id, cron_schedule FROM persistent_agents "
            "WHERE enabled=1 AND deleted_at IS NULL "
            "AND cron_schedule IS NOT NULL "
            "AND next_scheduled_run_at IS NOT NULL "
            "AND next_scheduled_run_at <= ?",
            (now,),
        ).fetchall()
        from croniter import croniter
        for agent_id, cron in rows:
            try:
                await self._fire_persistent_agent(agent_id, trigger="cron")
            except Exception as exc:
                logger.exception("persistent agent %s fire failed: %s", agent_id, exc)
            try:
                next_fire = float(croniter(cron, now).get_next(float))
            except Exception as exc:
                logger.error("invalid cron %r for agent %s: %s; disabling", cron, agent_id, exc)
                self.db._conn.execute(
                    "UPDATE persistent_agents SET enabled=0 WHERE id=?",
                    (agent_id,),
                )
                continue
            self.db._conn.execute(
                "UPDATE persistent_agents SET last_run_at=?, next_scheduled_run_at=? WHERE id=?",
                (now, next_fire, agent_id),
            )

    async def _persistent_agents_loop(self) -> None:
        """Sprint 49: cron poller for persistent agents.  Runs every 30s."""
        while not self._stopping:
            try:
                await self._persistent_agents_tick()
            except Exception as exc:
                logger.exception("persistent_agents_loop iteration failed: %s", exc)
            await asyncio.sleep(30)
```

Start the loop from wherever the other background loops are started — search `grep -n "asyncio.create_task" services/orchestrator/tally_orchestrator/service.py` to find the existing startup pattern (typically inside `Orchestrator.__init__` or a `start()` method). Add:

```python
        self._persistent_agents_task = asyncio.create_task(self._persistent_agents_loop())
```

- [ ] **Step 4: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_cron_loop.py -v
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_cron_loop.py
git commit -m "[s49] croniter loop: _persistent_agents_loop fires due agents every 30s"
```

### Task A10: Webhook handler with HMAC verification

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Create: `services/orchestrator/tests/test_webhook_signature.py`

- [ ] **Step 1: Write the failing tests**

```python
"""Sprint 49: HMAC-verified webhook handler for persistent-agent event triggers."""
import hashlib
import hmac
import json
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


def _make_agent_with_trigger(client) -> tuple[int, str, str]:
    """Returns (agent_id, trigger_id, secret)."""
    r = client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "webhook-test", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
        "event_triggers": [{"kind": "http", "name": "default"}],
    })
    body = r.json()
    agent_id = body["id"]
    trig = body["event_triggers"][0]
    return agent_id, trig["id"], trig["secret"]


def test_valid_hmac_fires_agent(client):
    agent_id, trig_id, secret = _make_agent_with_trigger(client)
    payload = b'{"hello":"world"}'
    sig = "sha256=" + hmac.new(secret.encode(), payload, hashlib.sha256).hexdigest()
    r = client.post(
        f"/webhooks/agents/{trig_id}",
        content=payload,
        headers={"X-Tally-Signature": sig, "content-type": "application/json"},
    )
    assert r.status_code == 200
    assert r.json()["agent_id"] == agent_id


def test_invalid_hmac_returns_401(client):
    agent_id, trig_id, secret = _make_agent_with_trigger(client)
    payload = b'{"hello":"world"}'
    bad_sig = "sha256=" + "0" * 64
    r = client.post(
        f"/webhooks/agents/{trig_id}",
        content=payload,
        headers={"X-Tally-Signature": bad_sig, "content-type": "application/json"},
    )
    assert r.status_code == 401


def test_unknown_trigger_returns_404(client):
    r = client.post(
        "/webhooks/agents/nonexistent",
        content=b'{}',
        headers={"X-Tally-Signature": "sha256=" + "0" * 64},
    )
    assert r.status_code == 404
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_webhook_signature.py -v
```

Expected: 3 FAILs.

- [ ] **Step 3: Add the route**

In `service.py`:

```python
@app.post("/webhooks/agents/{trigger_id}")
async def fire_event_trigger(trigger_id: str, request: Request) -> dict:
    """Sprint 49: fire a persistent agent via its HTTP event trigger.
    Auth: HMAC-SHA256 over raw request body using the trigger's secret,
    passed in X-Tally-Signature: sha256=<hex>."""
    raw_body = await request.body()
    sig = request.headers.get("X-Tally-Signature", "")
    db: Db = state["db"]
    rows = db._conn.execute(
        "SELECT id, event_triggers_json FROM persistent_agents "
        "WHERE deleted_at IS NULL AND enabled=1"
    ).fetchall()
    for agent_id, triggers_json in rows:
        triggers = json.loads(triggers_json or "[]")
        for trig in triggers:
            if trig.get("id") == trigger_id and trig.get("kind") == "http":
                expected = "sha256=" + hmac.new(
                    trig["secret"].encode(),
                    raw_body,
                    hashlib.sha256,
                ).hexdigest()
                if hmac.compare_digest(sig, expected):
                    orch = state.get("orch")
                    if orch is None:
                        raise HTTPException(503, "orchestrator not ready")
                    task_id = await orch._fire_persistent_agent(agent_id, trigger="webhook")
                    return {"ok": True, "agent_id": agent_id, "task_id": task_id}
                else:
                    raise HTTPException(401, "invalid signature")
    raise HTTPException(404, "trigger not found")
```

Add `import hmac, hashlib` to service.py imports (verify with `grep -n "import hmac\|import hashlib" services/orchestrator/tally_orchestrator/service.py`).

`Request` is from fastapi — verify `from fastapi import Request` exists.

- [ ] **Step 4: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_webhook_signature.py -v
```

Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_webhook_signature.py
git commit -m "[s49] POST /webhooks/agents/{trigger_id} — HMAC-SHA256 event trigger"
```

### Task A11: Tally escalation responder + DM templates

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — extend `_broadcast_new_message`
- Modify: `services/orchestrator/tally_orchestrator/channels.py` — add escalation helper
- Create: `services/orchestrator/tests/test_escalation_to_dm.py`

- [ ] **Step 1: Write the failing tests**

```python
"""Sprint 49: agent escalation -> Tally DM to workspace owner."""
import json
import pytest
from tally_orchestrator.service import Db
from tally_orchestrator.channels import (
    insert_message, ensure_dm_channel, handle_escalation,
)


def test_ensure_dm_channel_creates_idempotent(db: Db):
    """First call creates; second call returns the same channel_id."""
    ch1 = ensure_dm_channel(db, workspace_id=1, kind_a="human", id_a="admin", kind_b="tally", id_b=None)
    ch2 = ensure_dm_channel(db, workspace_id=1, kind_a="human", id_a="admin", kind_b="tally", id_b=None)
    assert ch1 == ch2 and ch1 > 0


def test_ensure_dm_channel_has_both_members(db: Db):
    ch = ensure_dm_channel(db, workspace_id=1, kind_a="human", id_a="admin", kind_b="tally", id_b=None)
    rows = db._conn.execute(
        "SELECT member_kind, user_id FROM channel_members WHERE channel_id=?", (ch,)
    ).fetchall()
    kinds = {r[0] for r in rows}
    assert {"human", "tally"}.issubset(kinds)


def test_handle_escalation_creates_dm_with_templated_message(db: Db):
    """A kind='escalation' message in a scheduled_agent channel triggers
    a Tally DM with the templated content."""
    pid = db.create_persistent_agent(
        workspace_id=1, name="nightly-tests", role_name="Tester", team_spec={},
    )
    sa_ch = db._conn.execute(
        "SELECT id FROM channels WHERE persistent_agent_id=?", (pid,)
    ).fetchone()[0]
    msg_id = insert_message(
        db, channel_id=sa_ch, author_kind="agent", author_agent_id=0,
        kind="escalation",
        payload={
            "reason": "Test suite is failing intermittently",
            "agent_name": "nightly-tests",
            "agent_role": "Tester",
        },
    )
    dm_ch_id = handle_escalation(db, channel_id=sa_ch, message_id=msg_id)
    assert dm_ch_id is not None
    # Verify a Tally message was inserted in the DM channel
    row = db._conn.execute(
        "SELECT kind, payload_json, author_kind FROM messages "
        "WHERE channel_id=? AND kind='text' ORDER BY id DESC LIMIT 1",
        (dm_ch_id,),
    ).fetchone()
    assert row is not None
    assert row[2] == "tally"
    text = json.loads(row[1]).get("text", "")
    assert "nightly-tests" in text
    assert "intermittently" in text
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_escalation_to_dm.py -v
```

Expected: 3 FAILs (helpers don't exist).

- [ ] **Step 3: Add `ensure_dm_channel` + `handle_escalation` to channels.py**

```python
ESCALATION_DM_TEMPLATE = (
    "@{owner} — {agent_name} ({agent_role}) needs your input: \"{reason}\". "
    "See #{channel_name}."
)


def ensure_dm_channel(
    db: "Db",
    *,
    workspace_id: int,
    kind_a: str,
    id_a: str | None,
    kind_b: str,
    id_b: str | None,
) -> int:
    """Sprint 49: open or find a symmetric DM channel between two members.
    `id_X` is user_id for kind='human', NULL for kind='tally', or the
    persistent_agent_id (as str) for kind='persistent_agent'.

    Idempotent: if a DM channel already has BOTH parties as channel_members,
    returns it; else creates a new one."""
    now = time.time()
    # Find existing DM channels in this workspace
    candidates = db._conn.execute(
        "SELECT id FROM channels WHERE workspace_id=? AND kind='dm' AND archived_at IS NULL",
        (workspace_id,),
    ).fetchall()
    for (ch_id,) in candidates:
        members = db._conn.execute(
            "SELECT member_kind, user_id FROM channel_members WHERE channel_id=?",
            (ch_id,),
        ).fetchall()
        member_set = {(m, u) for m, u in members}
        wanted = {(kind_a, id_a), (kind_b, id_b)}
        if wanted.issubset(member_set):
            return int(ch_id)
    # Create
    label_parts = []
    if kind_a == "human":
        label_parts.append(id_a or "?")
    elif kind_a == "tally":
        label_parts.append("tally")
    else:
        label_parts.append(f"agent-{id_a}")
    if kind_b == "human":
        label_parts.append(id_b or "?")
    elif kind_b == "tally":
        label_parts.append("tally")
    else:
        label_parts.append(f"agent-{id_b}")
    name = "-".join(sorted(label_parts))
    cur = db._conn.execute(
        "INSERT INTO channels (workspace_id, kind, name, created_at) "
        "VALUES (?, 'dm', ?, ?)",
        (workspace_id, name, now),
    )
    new_id = int(cur.lastrowid or 0)
    db._conn.execute(
        "INSERT INTO channel_members (channel_id, member_kind, user_id, joined_at) "
        "VALUES (?, ?, ?, ?)",
        (new_id, kind_a, id_a, now),
    )
    db._conn.execute(
        "INSERT INTO channel_members (channel_id, member_kind, user_id, joined_at) "
        "VALUES (?, ?, ?, ?)",
        (new_id, kind_b, id_b, now),
    )
    return new_id


def handle_escalation(db: "Db", *, channel_id: int, message_id: int) -> int | None:
    """Sprint 49: react to a kind='escalation' message.  Identifies the
    workspace owner, ensures a Tally↔owner DM exists, posts the templated
    Tally message in the DM.  Returns the DM channel_id or None on failure."""
    # Load the escalation message
    msg_row = db._conn.execute(
        "SELECT channel_id, payload_json FROM messages WHERE id=? AND kind='escalation'",
        (message_id,),
    ).fetchone()
    if msg_row is None:
        return None
    payload = json.loads(msg_row[1])
    reason = (payload.get("reason") or "").strip()
    if len(reason) > 140:
        reason = reason[:137] + "..."
    agent_name = payload.get("agent_name") or "agent"
    agent_role = payload.get("agent_role") or "Agent"
    # Find the source channel + workspace + owner
    src_row = db._conn.execute(
        "SELECT c.name, c.workspace_id, w.owner_user_id "
        "FROM channels c JOIN workspaces w ON c.workspace_id=w.id "
        "WHERE c.id=?",
        (channel_id,),
    ).fetchone()
    if src_row is None:
        return None
    channel_name, workspace_id, owner_user_id = src_row
    # Ensure DM channel exists
    dm_ch = ensure_dm_channel(
        db, workspace_id=workspace_id,
        kind_a="human", id_a=owner_user_id,
        kind_b="tally", id_b=None,
    )
    # Post the templated Tally message
    text = ESCALATION_DM_TEMPLATE.format(
        owner=owner_user_id, agent_name=agent_name, agent_role=agent_role,
        reason=reason, channel_name=channel_name,
    )
    insert_message(
        db, channel_id=dm_ch, author_kind="tally", kind="text",
        payload={"text": text},
    )
    return dm_ch
```

- [ ] **Step 4: Wire into `_broadcast_new_message`**

In `service.py` `_broadcast_new_message`, after the WS fan-out, add:

```python
    # Sprint 49: Tally escalation responder.
    msg_row = db._conn.execute(
        "SELECT kind FROM messages WHERE id=?", (message_id,)
    ).fetchone()
    if msg_row and msg_row[0] == "escalation":
        try:
            from .channels import handle_escalation
            dm_ch = handle_escalation(db, channel_id=channel_id, message_id=message_id)
            if dm_ch:
                # Broadcast the new DM message too (re-enter broadcast)
                new_msg = db._conn.execute(
                    "SELECT id FROM messages WHERE channel_id=? ORDER BY id DESC LIMIT 1",
                    (dm_ch,),
                ).fetchone()
                if new_msg:
                    await _broadcast_new_message(dm_ch, new_msg[0])
        except Exception as exc:
            logger.warning("escalation handler failed: %s", exc)
```

(Re-entering `_broadcast_new_message` for the DM is bounded — it can only recurse if the DM message itself is kind='escalation', which it isn't.)

- [ ] **Step 5: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_escalation_to_dm.py -v
cd services/orchestrator && uv run pytest tests/ -q
```

Expected: 3 PASS in the new file; no regressions.

- [ ] **Step 6: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tally_orchestrator/channels.py services/orchestrator/tests/test_escalation_to_dm.py
git commit -m "[s49] Tally escalation: kind='escalation' triggers DM with templated message"
```

### Task A12: POST /channels/dm route

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Create: `services/orchestrator/tests/test_dm_channel_route.py`

- [ ] **Step 1: Write the failing tests**

```python
"""Sprint 49: POST /channels/dm route."""
import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch, tmp_db_path):
    # ... same fixture pattern as other route tests ...


def test_post_dm_tally_creates_channel(client):
    r = client.post("/channels/dm", json={"target_kind": "tally"})
    assert r.status_code == 200
    body = r.json()
    assert body["kind"] == "dm"
    assert body["id"] > 0


def test_post_dm_tally_idempotent(client):
    r1 = client.post("/channels/dm", json={"target_kind": "tally"})
    r2 = client.post("/channels/dm", json={"target_kind": "tally"})
    assert r1.json()["id"] == r2.json()["id"]


def test_post_dm_persistent_agent(client):
    pa = client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "x", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
    })
    pid = pa.json()["id"]
    r = client.post("/channels/dm", json={"target_kind": "persistent_agent", "target_id": str(pid)})
    assert r.status_code == 200
    body = r.json()
    assert body["kind"] == "dm"


def test_post_dm_invalid_target_kind_returns_400(client):
    r = client.post("/channels/dm", json={"target_kind": "alien"})
    assert r.status_code == 400
```

(Repeat the fixture from `test_persistent_agents_routes.py`.)

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_dm_channel_route.py -v
```

Expected: 4 FAILs.

- [ ] **Step 3: Add Pydantic model + route**

```python
class DmCreateRequest(BaseModel):
    target_kind: str
    target_id: str | None = None  # required for human, optional for tally


@app.post("/channels/dm")
async def create_dm_channel(
    body: DmCreateRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 49: open or find a DM channel.  Idempotent.

    target_kind: 'tally' | 'human' | 'persistent_agent'
    target_id:   for 'tally', null; for 'human', the other user_id;
                 for 'persistent_agent', the agent id as string.
    """
    if body.target_kind not in ("tally", "human", "persistent_agent"):
        raise HTTPException(400, f"invalid target_kind: {body.target_kind}")
    db: Db = state["db"]
    # Find caller's workspace_id (caller's primary workspace per Sprint 50 multi-workspace UI)
    ws_row = db._conn.execute(
        "SELECT id FROM workspaces WHERE owner_user_id=? LIMIT 1", (user.id,)
    ).fetchone()
    if ws_row is None:
        raise HTTPException(404, "no workspace for caller")
    workspace_id = ws_row[0]
    from .channels import ensure_dm_channel
    if body.target_kind == "tally":
        ch_id = ensure_dm_channel(
            db, workspace_id=workspace_id,
            kind_a="human", id_a=user.id,
            kind_b="tally", id_b=None,
        )
    elif body.target_kind == "human":
        if not body.target_id:
            raise HTTPException(400, "target_id required for human DM")
        # Validate target is in the same workspace
        target_member = db._conn.execute(
            "SELECT 1 FROM workspace_members WHERE workspace_id=? AND user_id=? AND member_kind='human'",
            (workspace_id, body.target_id),
        ).fetchone()
        if not target_member:
            raise HTTPException(404, "target user not in workspace")
        ch_id = ensure_dm_channel(
            db, workspace_id=workspace_id,
            kind_a="human", id_a=user.id,
            kind_b="human", id_b=body.target_id,
        )
    else:  # persistent_agent
        if not body.target_id:
            raise HTTPException(400, "target_id required for persistent_agent DM")
        ch_id = ensure_dm_channel(
            db, workspace_id=workspace_id,
            kind_a="human", id_a=user.id,
            kind_b="persistent_agent", id_b=body.target_id,
        )
    # Return the channel row
    from .channels import resolve_channel
    return resolve_channel(db, ch_id)
```

- [ ] **Step 4: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_dm_channel_route.py -v
```

Expected: 4 PASS.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_dm_channel_route.py
git commit -m "[s49] POST /channels/dm — idempotent DM channel creation"
```

### Task A13: Auto-pause on consecutive failures

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — task-completion path
- Create: `services/orchestrator/tests/test_auto_pause_on_failures.py`

- [ ] **Step 1: Write the failing tests**

```python
"""Sprint 49: persistent agent auto-pauses after 3 consecutive failures."""
from tally_orchestrator.service import Db


def test_consecutive_failures_increments_on_failed(db: Db):
    pid = db.create_persistent_agent(
        workspace_id=1, name="x", role_name="Tester", team_spec={},
    )
    # Manually mark a task as failed with persistent_agent_id
    import uuid
    task_id = uuid.uuid4().hex
    db._conn.execute(
        "INSERT INTO tasks (id, description, status, persistent_agent_id, user_id, created_at, updated_at) "
        "VALUES (?, 'x', 'failed', ?, 'admin', 0, 0)",
        (task_id, pid),
    )
    # Call the counter-bump (extracted method, see Step 3)
    db.bump_persistent_agent_failure(pid)
    assert db.get_persistent_agent(pid)["consecutive_failures"] == 1


def test_three_failures_disables_agent(db: Db):
    pid = db.create_persistent_agent(
        workspace_id=1, name="x", role_name="Tester", team_spec={},
    )
    for _ in range(3):
        db.bump_persistent_agent_failure(pid)
    assert db.get_persistent_agent(pid)["enabled"] is False


def test_success_resets_counter(db: Db):
    pid = db.create_persistent_agent(
        workspace_id=1, name="x", role_name="Tester", team_spec={},
    )
    db.bump_persistent_agent_failure(pid)
    db.bump_persistent_agent_failure(pid)
    db.reset_persistent_agent_failures(pid)
    assert db.get_persistent_agent(pid)["consecutive_failures"] == 0
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_auto_pause_on_failures.py -v
```

Expected: 3 FAILs.

- [ ] **Step 3: Add Db helpers + integrate into task-completion**

In `Db` class:

```python
    PERMANENT_FAILURE_DM_TEMPLATE = (
        "@{owner} — {agent_name} has failed 3 times in a row. I've paused it. "
        "See #{channel_name} for the failures. Enable again from settings."
    )

    def bump_persistent_agent_failure(self, pid: int) -> None:
        """Sprint 49: increment consecutive_failures; if it hits 3, disable
        the agent + emit the permanent-failure Tally DM."""
        row = self._conn.execute(
            "SELECT consecutive_failures, workspace_id, name FROM persistent_agents WHERE id=?",
            (pid,),
        ).fetchone()
        if row is None:
            return
        new_count = (row[0] or 0) + 1
        workspace_id, name = row[1], row[2]
        if new_count >= 3:
            self._conn.execute(
                "UPDATE persistent_agents SET consecutive_failures=?, enabled=0 WHERE id=?",
                (new_count, pid),
            )
            # Emit the permanent-failure DM
            owner_row = self._conn.execute(
                "SELECT owner_user_id FROM workspaces WHERE id=?", (workspace_id,)
            ).fetchone()
            sa_ch_row = self._conn.execute(
                "SELECT id, name FROM channels WHERE persistent_agent_id=? AND kind='scheduled_agent'",
                (pid,),
            ).fetchone()
            if owner_row and sa_ch_row:
                from .channels import ensure_dm_channel, insert_message
                dm_ch = ensure_dm_channel(
                    self, workspace_id=workspace_id,
                    kind_a="human", id_a=owner_row[0],
                    kind_b="tally", id_b=None,
                )
                text = self.PERMANENT_FAILURE_DM_TEMPLATE.format(
                    owner=owner_row[0], agent_name=name, channel_name=sa_ch_row[1],
                )
                insert_message(
                    self, channel_id=dm_ch, author_kind="tally", kind="text",
                    payload={"text": text},
                )
        else:
            self._conn.execute(
                "UPDATE persistent_agents SET consecutive_failures=? WHERE id=?",
                (new_count, pid),
            )

    def reset_persistent_agent_failures(self, pid: int) -> None:
        self._conn.execute(
            "UPDATE persistent_agents SET consecutive_failures=0 WHERE id=?", (pid,)
        )
```

**Wire into task-completion:** find where `tasks.status` is updated to `'completed'` or `'failed'` (search `UPDATE tasks SET status='failed'` and `UPDATE tasks SET status='completed'`). Each such call site, ALSO update the persistent_agent counter:

```python
        # Sprint 49: if this task was fired by a persistent agent, update its failure counter
        pa_id = self.db._conn.execute(
            "SELECT persistent_agent_id FROM tasks WHERE id=?", (task_id,)
        ).fetchone()
        if pa_id and pa_id[0]:
            if final_status == "completed":
                self.db.reset_persistent_agent_failures(pa_id[0])
            elif final_status == "failed":
                self.db.bump_persistent_agent_failure(pa_id[0])
```

Add this in the orchestrator's `_advance_task` or wherever the task-completion path lives.

- [ ] **Step 4: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_auto_pause_on_failures.py -v
cd services/orchestrator && uv run pytest tests/ -q
```

Expected: 3 PASS, no regressions.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_auto_pause_on_failures.py
git commit -m "[s49] persistent_agents: auto-pause after 3 consecutive failures + permanent-failure DM"
```

### Task A14: Phase A smoke + tag

- [ ] **Step 1: Full pytest sweep**

```bash
cd services/orchestrator && uv run pytest tests/ -v 2>&1 | tail -10
```

Expected: ~175 tests PASS (Sprint 48's 148 + ~27 new from Phase A).

- [ ] **Step 2: Local smoke (without workers — covers what we can)**

```bash
cd services/orchestrator && rm -f /tmp/s49-smoke.db && TALLY_API_TOKEN=smoke ORCH_DB_PATH=/tmp/s49-smoke.db TALLY_REDPILL_KEY="" TALLY_TEST_MODE=1 uv run uvicorn tally_orchestrator.service:app --port 8118 &
sleep 5
# 1. Create persistent agent
PA=$(curl -sX POST -H "Authorization: Bearer smoke" -H "content-type: application/json" -d '{"workspace_id":1,"name":"nightly","role_name":"Tester","team_spec":{"nodes":[],"edges":[]},"cron_schedule":"0 21 * * *","event_triggers":[{"kind":"http","name":"default"}]}' http://localhost:8118/persistent_agents | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")
echo "persistent_agent_id: $PA"
# 2. List
curl -s -H "Authorization: Bearer smoke" "http://localhost:8118/persistent_agents?workspace_id=1" | python3 -m json.tool
# 3. DM with Tally
curl -sX POST -H "Authorization: Bearer smoke" -H "content-type: application/json" -d '{"target_kind":"tally"}' http://localhost:8118/channels/dm | python3 -m json.tool
# 4. DM idempotent — second call returns same id
curl -sX POST -H "Authorization: Bearer smoke" -H "content-type: application/json" -d '{"target_kind":"tally"}' http://localhost:8118/channels/dm | python3 -m json.tool
kill %1
```

Expected: each step returns 200; second DM call returns same channel_id as first.

- [ ] **Step 3: Tag**

```bash
git tag s49-phase-a-done
```

---

## Phase B — Frontend (9 tasks, ~25h)

### Task B1: api.dart additions

**Files:**
- Modify: `tally_coding_app/lib/api.dart`
- Create: `tally_coding_app/test/api_persistent_agents_test.dart`
- Create: `tally_coding_app/test/api_dm_test.dart`

- [ ] **Step 1: Write failing tests**

Create `tally_coding_app/test/api_persistent_agents_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tally_coding_app/api.dart';

void main() {
  test('createPersistentAgent POSTs and returns row', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/persistent_agents');
      expect(req.method, 'POST');
      return http.Response(
        '{"id":7,"name":"nightly","role_name":"Tester","cron_schedule":"0 21 * * *","enabled":true}',
        200, headers: {'content-type':'application/json'},
      );
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.createPersistentAgent(
      workspaceId: 1, name: 'nightly', roleName: 'Tester',
      teamSpec: {'nodes': [], 'edges': []},
      cronSchedule: '0 21 * * *',
    );
    expect(out['id'], 7);
  });

  test('listPersistentAgents returns list', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/persistent_agents');
      expect(req.url.queryParameters['workspace_id'], '1');
      return http.Response('{"persistent_agents":[{"id":1,"name":"a"}]}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.listPersistentAgents(workspaceId: 1);
    expect(out.length, 1);
  });

  test('runPersistentAgentNow POSTs to /run_now', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/persistent_agents/5/run_now');
      return http.Response('{"ok":true,"task_id":"abc"}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.runPersistentAgentNow(id: 5);
    expect(out['task_id'], 'abc');
  });
}
```

Create `tally_coding_app/test/api_dm_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tally_coding_app/api.dart';

void main() {
  test('openDmChannel POSTs target', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/channels/dm');
      expect(req.method, 'POST');
      return http.Response('{"id":42,"kind":"dm","name":"admin-tally"}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.openDmChannel(targetKind: 'tally');
    expect(out['id'], 42);
  });
}
```

- [ ] **Step 2: Verify failing**

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter test test/api_persistent_agents_test.dart test/api_dm_test.dart
```

Expected: 4 FAILs.

- [ ] **Step 3: Add methods**

Append to `tally_coding_app/lib/api.dart` (before `void close()`):

```dart
  // ── Sprint 49: persistent agents + DMs ──────────────────────────────────

  Future<Map<String, dynamic>> createPersistentAgent({
    required int workspaceId,
    required String name,
    required String roleName,
    required Map<String, dynamic> teamSpec,
    String? cronSchedule,
    List<Map<String, dynamic>>? eventTriggers,
    Map<String, dynamic>? toolAllowlist,
    String? model,
  }) async {
    final body = {
      'workspace_id': workspaceId,
      'name': name,
      'role_name': roleName,
      'team_spec': teamSpec,
      if (cronSchedule != null) 'cron_schedule': cronSchedule,
      if (eventTriggers != null) 'event_triggers': eventTriggers,
      if (toolAllowlist != null) 'tool_allowlist': toolAllowlist,
      if (model != null) 'model': model,
    };
    final resp = await _http.post(
      baseUrl.resolve('/persistent_agents'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200) {
      throw Exception('POST /persistent_agents ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<List<Map<String, dynamic>>> listPersistentAgents({required int workspaceId}) async {
    final resp = await _http.get(
      baseUrl.resolve('/persistent_agents').replace(queryParameters: {'workspace_id': '$workspaceId'}),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) {
      throw Exception('GET /persistent_agents ${resp.statusCode}: ${resp.body}');
    }
    return List<Map<String, dynamic>>.from(jsonDecode(resp.body)['persistent_agents'] as List);
  }

  Future<Map<String, dynamic>> updatePersistentAgent({required int id, required Map<String, dynamic> patch}) async {
    final resp = await _http.patch(
      baseUrl.resolve('/persistent_agents/$id'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode(patch),
    );
    if (resp.statusCode != 200) {
      throw Exception('PATCH /persistent_agents/$id ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<Map<String, dynamic>> runPersistentAgentNow({required int id}) async {
    final resp = await _http.post(
      baseUrl.resolve('/persistent_agents/$id/run_now'),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) {
      throw Exception('POST /persistent_agents/$id/run_now ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<void> deletePersistentAgent({required int id}) async {
    final resp = await _http.delete(
      baseUrl.resolve('/persistent_agents/$id'),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) {
      throw Exception('DELETE /persistent_agents/$id ${resp.statusCode}: ${resp.body}');
    }
  }

  Future<Map<String, dynamic>> openDmChannel({required String targetKind, String? targetId}) async {
    final body = {'target_kind': targetKind, if (targetId != null) 'target_id': targetId};
    final resp = await _http.post(
      baseUrl.resolve('/channels/dm'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200) {
      throw Exception('POST /channels/dm ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }
```

- [ ] **Step 4: Verify**

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter test test/api_persistent_agents_test.dart test/api_dm_test.dart
```

Expected: 4 PASS.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/api.dart tally_coding_app/test/api_persistent_agents_test.dart tally_coding_app/test/api_dm_test.dart
git commit -m "[s49] api.dart: persistent agents CRUD + run_now + openDmChannel"
```

### Task B2: WorkflowEditorScreen — Trigger palette node

**Files:**
- Modify: `tally_coding_app/lib/screens/workflow_editor.dart`

- [ ] **Step 1: Inspect current state**

Read the current `workflow_editor.dart` (Sprint 48 B5/B6) to understand the palette implementation. The palette is a draggable list of node kinds (Agent + Output today).

- [ ] **Step 2: Add Trigger to the data model**

In `_AgentNodeData`, accept `kind='trigger'` alongside `agent`/`output`. Add fields for trigger-specific config:

```dart
class _AgentNodeData implements NodeData {
  _AgentNodeData({
    required this.kind,  // 'agent' | 'output' | 'trigger'
    this.role = '',
    this.model = '',
    this.spec = '',
    this.workerAffinity = 'any',
    this.cronSchedule = '',         // Sprint 49 (trigger only)
    this.eventTriggers = const [],  // Sprint 49 (trigger only)
  });

  final String kind;
  String role, model, spec, workerAffinity;
  String cronSchedule;                              // Sprint 49
  List<Map<String, dynamic>> eventTriggers;        // Sprint 49

  @override
  NodeData clone() => _AgentNodeData(
    kind: kind, role: role, model: model, spec: spec,
    workerAffinity: workerAffinity,
    cronSchedule: cronSchedule,
    eventTriggers: List.from(eventTriggers),
  );
}
```

- [ ] **Step 3: Add `persistentAgentId` to the screen constructor**

```dart
class WorkflowEditorScreen extends StatefulWidget {
  final TallyOrchClient client;
  final String? taskId;             // Sprint 48 task context
  final int? persistentAgentId;     // Sprint 49 persistent-agent context
  final Map<String, dynamic> initialTeamSpec;
  const WorkflowEditorScreen({
    super.key,
    required this.client,
    this.taskId,
    this.persistentAgentId,
    required this.initialTeamSpec,
  }) : assert(taskId != null || persistentAgentId != null,
              'Either taskId or persistentAgentId must be provided');
```

- [ ] **Step 4: Conditionally show Trigger in palette**

In the palette, gate the Trigger item on `widget.persistentAgentId != null`. Render it as a third Draggable<String> item. On drop, create a Trigger node:

```dart
if (widget.persistentAgentId != null)
  Draggable<String>(
    data: 'trigger',
    feedback: ...,
    child: ListTile(
      leading: const Icon(Icons.alarm),
      title: const Text('Trigger'),
      subtitle: const Text('Cron + webhook'),
    ),
  ),
```

In the canvas DragTarget, handle the trigger drop:

```dart
case 'trigger':
  controller.addNode(Node<_AgentNodeData>(
    id: 'trigger-${math.Random().nextInt(99999)}',
    type: 'trigger',
    position: dropPos,
    data: _AgentNodeData(kind: 'trigger'),
    ports: [
      Port(id: 'out', name: 'out', position: PortPosition.right, type: PortType.output, multiConnections: true),
    ],  // Trigger has only output port (no input)
  ));
```

- [ ] **Step 5: Add `_TriggerConfigDialog`**

Tap on a trigger node opens this dialog:
- Cron schedule TextField with a "Common patterns" dropdown (every minute / every hour / daily 9am / weekdays 9am)
- "+Add event trigger" list with name field (secret/URL shown read-only after save)
- Save updates `_AgentNodeData.cronSchedule` + `eventTriggers`

```dart
class _TriggerConfigDialog extends StatefulWidget {
  final _AgentNodeData initial;
  const _TriggerConfigDialog({required this.initial});
  @override State<_TriggerConfigDialog> createState() => _TriggerConfigDialogState();
}

class _TriggerConfigDialogState extends State<_TriggerConfigDialog> {
  late TextEditingController _cronCtrl;
  late List<Map<String, dynamic>> _triggers;
  // ... build form ...
}
```

- [ ] **Step 6: Route save to correct endpoint**

```dart
Future<void> _save() async {
  _syncSpec();
  setState(() => _saving = true);
  try {
    if (widget.taskId != null) {
      await widget.client.updateTaskTeamSpec(taskId: widget.taskId!, teamSpec: _spec);
    } else if (widget.persistentAgentId != null) {
      await widget.client.updatePersistentAgent(
        id: widget.persistentAgentId!,
        patch: {'team_spec': _spec},
      );
    }
    if (mounted) Navigator.of(context).pop();
  } catch (e) { ... }
}
```

- [ ] **Step 7: Verify**

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter analyze lib/screens/workflow_editor.dart
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter test 2>&1 | tail -3
```

Expected: no analyze errors; tests same pass/fail.

- [ ] **Step 8: Commit**

```bash
git add tally_coding_app/lib/screens/workflow_editor.dart
git commit -m "[s49] WorkflowEditorScreen: Trigger node + cron + event_triggers config (persistent-agent context)"
```

### Task B3: PersistentAgentsScreen — list view

**Files:**
- Create: `tally_coding_app/lib/screens/persistent_agents.dart`
- Create: `tally_coding_app/test/persistent_agents_screen_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ... mock client, instantiate screen, verify list renders agents ...
```

(Full test details omitted for brevity; mirror the pattern from Sprint 47's widget tests.)

- [ ] **Step 2: Implement `PersistentAgentsScreen`**

```dart
class PersistentAgentsScreen extends StatefulWidget {
  final TallyOrchClient client;
  final int workspaceId;
  const PersistentAgentsScreen({super.key, required this.client, required this.workspaceId});
  @override State<PersistentAgentsScreen> createState() => _PersistentAgentsScreenState();
}

class _PersistentAgentsScreenState extends State<PersistentAgentsScreen> {
  List<Map<String, dynamic>> _agents = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.client.listPersistentAgents(workspaceId: widget.workspaceId);
      if (!mounted) return;
      setState(() { _agents = list; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scheduled agents'),
        actions: [
          IconButton(icon: const Icon(Icons.add), onPressed: _onNewAgent),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: _agents.length,
              itemBuilder: (_, i) => _agentTile(_agents[i]),
            ),
    );
  }

  Widget _agentTile(Map<String, dynamic> agent) {
    final cron = agent['cron_schedule'] as String?;
    final enabled = (agent['enabled'] as bool?) ?? true;
    return ListTile(
      leading: Icon(enabled ? Icons.check_circle : Icons.pause_circle, color: enabled ? Colors.green : Colors.orange),
      title: Text(agent['name'] as String? ?? ''),
      subtitle: Text(cron != null ? 'cron: $cron' : 'event triggers only'),
      trailing: PopupMenuButton<String>(
        onSelected: (action) => _onAgentAction(action, agent),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('Edit')),
          PopupMenuItem(value: 'run_now', child: Text('Run now')),
          PopupMenuItem(value: 'toggle', child: Text('Enable/Disable')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }

  Future<void> _onAgentAction(String action, Map<String, dynamic> agent) async { /* implement */ }
  Future<void> _onNewAgent() async { /* implement in B4 */ }
}
```

- [ ] **Step 3: Verify + Commit**

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter analyze lib/screens/persistent_agents.dart
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter test test/persistent_agents_screen_test.dart
```

```bash
git add tally_coding_app/lib/screens/persistent_agents.dart tally_coding_app/test/persistent_agents_screen_test.dart
git commit -m "[s49] PersistentAgentsScreen: list view + actions"
```

### Task B4: "New persistent agent" flow

**Files:**
- Modify: `tally_coding_app/lib/screens/persistent_agents.dart` — implement `_onNewAgent`

- [ ] **Step 1: Dialog spec**

Tap "+" → opens a `_NewPersistentAgentDialog` with:
- Name TextField
- Role dropdown (fetched from `GET /agent-roles` or hardcoded list)
- Optional cron TextField with common-pattern dropdown

- [ ] **Step 2: Implement**

On submit, call `widget.client.createPersistentAgent(...)`, then `Navigator.push` into `WorkflowEditorScreen(persistentAgentId: ..., initialTeamSpec: ...)` for the user to configure team_spec + triggers.

- [ ] **Step 3: Commit**

```bash
git add tally_coding_app/lib/screens/persistent_agents.dart
git commit -m "[s49] PersistentAgentsScreen: new-agent dialog + push into editor"
```

### Task B5: Channel rail — Scheduled category + Direct messages category

**Files:**
- Modify: `tally_coding_app/lib/screens/discord_shell.dart` (or wherever the rail lives)

- [ ] **Step 1: Read the current rail**

Identify the channel-rail rendering code in `discord_shell.dart`. The Sprint 47 channel rail lists workspaces, then channels by kind ("Active tasks" category, etc.).

- [ ] **Step 2: Add new categories**

Add two new categories at the bottom:

**Scheduled:** lists `kind='scheduled_agent'` channels + a "+ New" tile that opens `PersistentAgentsScreen`.

**Direct messages:** lists `kind='dm'` channels + a "+ New" tile that opens `_NewDmModal` (Task B6).

Each category uses the existing Sprint 47 channel-item widget (ListTile with name + unread badge).

- [ ] **Step 3: Verify + Commit**

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter analyze lib/screens/discord_shell.dart
```

```bash
git add tally_coding_app/lib/screens/discord_shell.dart
git commit -m "[s49] channel rail: Scheduled + Direct messages categories"
```

### Task B6: "+ New DM" modal

**Files:**
- Create: `tally_coding_app/lib/widgets/new_dm_modal.dart`
- Modify: `tally_coding_app/lib/screens/discord_shell.dart` (wire the modal opener)

- [ ] **Step 1: Modal spec**

Tab bar: People / Tally / Agents.

- People tab: searchable list from `GET /workspaces/{id}/members` (or local cache)
- Tally tab: single "Tally" entry
- Agents tab: list from `listPersistentAgents`

On select → call `openDmChannel(target_kind, target_id)` → close modal → navigate to the returned channel.

- [ ] **Step 2: Implement + commit**

```bash
git add tally_coding_app/lib/widgets/new_dm_modal.dart tally_coding_app/lib/screens/discord_shell.dart
git commit -m "[s49] new_dm_modal: 3-tab DM target picker"
```

### Task B7: DM channel rendering + escalation indicator

**Files:**
- Modify: `tally_coding_app/lib/screens/task_channel.dart` (or create a `dm_channel.dart`)
- Modify: `tally_coding_app/lib/screens/discord_shell.dart` — escalation dot indicator

- [ ] **Step 1: DM channel screen**

DM channels render exactly like task channels — same MessageFeed + MessageComposer. Either:
- (a) Extend the existing `TaskChannelScreen` to also handle `kind='dm'` (route the channel id directly without expecting a task_id)
- (b) Create a `DmChannelScreen` as a thin wrapper

Path (a) is simpler if the existing screen already accepts a channel_id directly. Path (b) is cleaner if not.

- [ ] **Step 2: Escalation indicator**

In the channel rail item rendering, check if the channel has unread `kind='escalation'` messages. If so, render a small orange dot icon. To know this without loading all messages, expose a `unread_kinds: list<str>` field in the channel-list response (server-side change, may add to A6 PATCH endpoint if not present).

For Sprint 49 simplest path: when the channel rail loads, ALSO request the channel's latest message via `getMessages?limit=1` and check kind. Not the cheapest but workable for initial scale.

- [ ] **Step 3: Commit**

```bash
git add tally_coding_app/lib/screens/task_channel.dart tally_coding_app/lib/screens/discord_shell.dart
git commit -m "[s49] DM channel rendering + escalation indicator"
```

### Task B8: Wire interactive_prompt response on escalation cards

**Files:**
- Modify: `tally_coding_app/lib/widgets/interactive_prompt_card.dart` (if needed) or task_channel/dm_channel — ensure the existing onAnswer flow posts via `postMessage(kind: 'interactive_prompt_response')`

This is mostly verifying Sprint 47 B3's interactive prompt response wiring still works for the escalation use case (which posts an interactive_prompt with pause/resume/cancel buttons).

Add a test that:
- Inserts a scheduled_agent channel with an interactive_prompt message
- Renders MessageFeed
- Taps "Pause"
- Verifies postMessage was called with the right body

- [ ] **Step 1: Verify + Commit**

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter test
```

```bash
git add tally_coding_app/test/  # any new tests
git commit -m "[s49] verify escalation interactive_prompt response wiring (cross-check Sprint 47 B3)"
```

### Task B9: Phase B smoke + tag

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter analyze 2>&1 | tail -3
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter test 2>&1 | tail -5
```

Expected: no NEW analyze errors, same pass/fail (the pre-existing widget_test.dart::four-column failure).

```bash
git tag s49-phase-b-done
```

---

## Phase C — Deploy + sprint completion (3 tasks, ~5h)

### Task C1: Build + push tally-orch:v29

- [ ] Update Dockerfile LABEL to `v29` + description for Sprint 49
- [ ] Update docker-compose.yml image to `:v29`
- [ ] `docker build -t ghcr.io/nicholasraimbault/tally-orch:v29 ...`
- [ ] `docker push ghcr.io/nicholasraimbault/tally-orch:v29`
- [ ] Commit

```bash
git commit -m "[s49] image: bump to v29"
```

### Task C2: Deploy + live smoke

```bash
cd services/orchestrator && /home/nick/.npm-global/bin/phala deploy --cvm-id app_c3b5481b3f33551af6270a21145df613160bf063 --compose docker-compose.yml --env .env.prod --wait
```

Live smoke:
- `GET /health` — orchestrator running
- `POST /persistent_agents` — creates a persistent agent + scheduled_agent channel
- `GET /persistent_agents?workspace_id=1` — list returns the new agent
- `POST /channels/dm {target_kind: 'tally'}` — DM channel created idempotently

```bash
git tag s49-deployed-v29
```

### Task C3: Completion doc + tag

Write `docs/SPRINT-49-COMPLETE.md` matching Sprint 48 structure. Cover: locked decisions, backend changes, frontend changes, deploy details, deferred items.

```bash
git add docs/SPRINT-49-COMPLETE.md
git commit -m "[s49] sprint completion doc"
git tag s49-phase-c-done
git tag s49-complete
```

---

## Self-review

**Spec coverage:**

| Spec requirement | Tasks |
|---|---|
| `persistent_agents` schema | A1 |
| `tasks.persistent_agent_id` | A2 |
| Tally workspace_member + channel_member backfill | A3 |
| Db helpers (create/list/get/update/delete) | A4 |
| `POST /persistent_agents` | A5 |
| `GET` + `PATCH /persistent_agents` | A6 |
| `POST run_now` + `DELETE` | A7 |
| `_fire_persistent_agent` + channel routing | A8 |
| croniter loop | A9 |
| HMAC webhook | A10 |
| Tally escalation responder + DM | A11 |
| `POST /channels/dm` | A12 |
| Auto-pause on 3 failures | A13 |
| Phase A smoke + tag | A14 |
| api.dart additions | B1 |
| WorkflowEditorScreen Trigger node | B2 |
| PersistentAgentsScreen list | B3 |
| New-agent flow | B4 |
| Channel rail Scheduled + DMs | B5 |
| "+ New DM" modal | B6 |
| DM rendering + escalation indicator | B7 |
| Escalation interactive_prompt response | B8 |
| Phase B smoke + tag | B9 |
| Image bump | C1 |
| Deploy + smoke | C2 |
| Completion doc | C3 |

All spec items covered.

**Placeholder scan:** B3's test code is summarized rather than full ("Full test details omitted for brevity; mirror the pattern from Sprint 47's widget tests"). Filling in: the test should construct a `PersistentAgentsScreen` with a `MockClient` returning a fixture list, pump the widget tree, assert the agent name appears, and assert the menu items work. Implementer can write this from the pattern shown in Sprint 47 widget tests.

**Type consistency:**
- `persistent_agents.id` → INTEGER throughout
- `tasks.persistent_agent_id` → INTEGER FK
- `target_id` in `POST /channels/dm` → str (matches API contract; integer agent ids become strings)
- `ensure_dm_channel`'s `id_a/id_b` → str|None
- Tally member representation: `member_kind='tally', user_id=NULL` everywhere

Plan ready to execute.
