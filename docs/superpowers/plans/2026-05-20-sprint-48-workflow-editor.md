# Sprint 48 — Workflow editor + pre-dispatch team confirm — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace immediate dispatch with a `team_proposal` card in #general (Approve / Edit / Cancel); ship a native node-based workflow editor (vyuh_node_flow) for the Edit path; teach the orchestrator a nodes+edges executor with edge conditions.

**Architecture:** Backend keeps the architect, defers dispatch, adds 3 task-lifecycle endpoints + a `nodes_v1` executor. Flutter adds a `TeamProposalCard` (drops into the Sprint 47 `MessageFeed`) + a full-screen `WorkflowEditorScreen` (vyuh_node_flow). Existing `team_builder.dart` (Sprint 30) goes away.

**Tech Stack:** Python 3.12 / FastAPI / SQLite (orchestrator), Flutter / vyuh_node_flow 0.27.3 / MIT (app), Docker / Phala CVM (deploy).

**Resolved open questions from spec stage:**
- **Approve idempotency:** Approve returns 409 on repeat — UI greys the button on first success to prevent double-tap.
- **Architect cost on Cancel:** No refund — architect spend is sunk on POST /tasks. Matches Sprint 46 no-refunds-on-cancelled-work policy.
- **Trigger node:** Sprint 48 palette is Agent + Output only. Trigger lands in Sprint 49 with persistent agents.

---

## Phase A — Backend (11 tasks, ~20h)

### Task A1: tasks status enum: `proposed` + `cancelled`

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — quota/status filter code paths
- Create: `services/orchestrator/tests/test_task_status_enum.py`

- [ ] **Step 1: Write the failing test**

Create `services/orchestrator/tests/test_task_status_enum.py`:

```python
"""Sprint 48: task status enum allows 'proposed' and 'cancelled'."""
from tally_orchestrator.service import Db, TASK_STATUS_TERMINAL, TASK_STATUS_COUNTS_AGAINST_QUOTA


def test_terminal_statuses_include_cancelled():
    assert "cancelled" in TASK_STATUS_TERMINAL
    assert "completed" in TASK_STATUS_TERMINAL
    assert "failed" in TASK_STATUS_TERMINAL


def test_proposed_is_not_terminal():
    """proposed is a pre-dispatch state — terminal=False."""
    assert "proposed" not in TASK_STATUS_TERMINAL


def test_proposed_does_not_count_against_quota(db: Db):
    """Status='proposed' tasks don't burn quota."""
    assert "proposed" not in TASK_STATUS_COUNTS_AGAINST_QUOTA


def test_cancelled_does_not_count_against_quota(db: Db):
    assert "cancelled" not in TASK_STATUS_COUNTS_AGAINST_QUOTA
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_task_status_enum.py -v
```

Expected: 4 FAILs (`ImportError`, names not exported).

- [ ] **Step 3: Define the constants in service.py**

Near the top of `service.py` (search for existing task status constants; if none, add near the imports), define:

```python
# Sprint 48: task lifecycle statuses
TASK_STATUS_TERMINAL = frozenset({"completed", "failed", "aborted", "aborted_cost_cap", "period_cap_reached", "cancelled"})
TASK_STATUS_COUNTS_AGAINST_QUOTA = frozenset({"pending", "running", "completed", "failed", "aborted", "aborted_cost_cap", "period_cap_reached"})
```

If these constants already exist (search first), EXTEND them — don't redefine.

- [ ] **Step 4: Audit existing code that filters by status**

```bash
grep -n "status='pending'\|status=\"pending\"\|status IN\|WHERE.*status" services/orchestrator/tally_orchestrator/service.py | head -20
```

For each place that checks `status='pending'` to mean "task is dispatchable", confirm it still does the right thing after this change (proposed should NOT be dispatched by the worker poller). The worker poller (`Orchestrator._advance_task` and friends) selects `status='pending'` to find dispatchable tasks — that's still correct since proposed tasks aren't pending.

For quota-counting code, ensure it uses `TASK_STATUS_COUNTS_AGAINST_QUOTA`.

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/test_task_status_enum.py -v
```

Expected: 4 PASS.

Also run the full suite to make sure existing tests aren't broken:

```bash
cd services/orchestrator && uv run pytest tests/ -q
```

Expected: 110+ tests, no regressions.

- [ ] **Step 6: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_task_status_enum.py
git commit -m "[s48] task status enum: add proposed + cancelled"
```

### Task A2: team_spec_compat.normalize() helper

**Files:**
- Create: `services/orchestrator/tally_orchestrator/team_spec_compat.py`
- Create: `services/orchestrator/tests/test_team_spec_compat.py`

- [ ] **Step 1: Write the failing tests**

Create `services/orchestrator/tests/test_team_spec_compat.py`:

```python
"""Sprint 48: flat team_spec → nodes_v1 conversion."""
import pytest
from tally_orchestrator.team_spec_compat import normalize, is_nodes_v1


def test_is_nodes_v1_detects_format():
    assert is_nodes_v1({"nodes": [], "edges": []}) is True
    assert is_nodes_v1({"agents": [], "stages": []}) is False
    assert is_nodes_v1({}) is False


def test_normalize_passes_through_nodes_v1():
    spec = {"nodes": [{"id": "n1", "kind": "agent", "role": "Coder"}], "edges": [], "format": "nodes_v1"}
    assert normalize(spec) == spec


def test_normalize_flat_single_agent():
    flat = {"agents": [{"role": "Coder", "spec": "do x"}], "stages": [[0]], "workflow": "sequential"}
    result = normalize(flat)
    assert result["format"] == "nodes_v1"
    assert len(result["nodes"]) == 2  # 1 agent + 1 output
    assert result["nodes"][0]["kind"] == "agent"
    assert result["nodes"][0]["role"] == "Coder"
    assert result["nodes"][1]["kind"] == "output"
    assert len(result["edges"]) == 1
    assert result["edges"][0]["from"] == "s0a0"
    assert result["edges"][0]["to"] == "out"


def test_normalize_flat_sequential():
    flat = {
        "agents": [{"role": "Coder", "spec": "a"}, {"role": "Reviewer", "spec": "b"}],
        "stages": [[0], [1]],
        "workflow": "sequential",
    }
    result = normalize(flat)
    assert len(result["nodes"]) == 3  # 2 agents + output
    # Edges: s0a0 -> s1a0 -> out
    edge_pairs = {(e["from"], e["to"]) for e in result["edges"]}
    assert ("s0a0", "s1a0") in edge_pairs
    assert ("s1a0", "out") in edge_pairs


def test_normalize_flat_parallel_within_stage():
    flat = {
        "agents": [{"role": "Coder"}, {"role": "Tester"}, {"role": "Reviewer"}],
        "stages": [[0, 1], [2]],
        "workflow": "sequential",
    }
    result = normalize(flat)
    edge_pairs = {(e["from"], e["to"]) for e in result["edges"]}
    # Stage 0 has 2 agents in parallel (no edges between them)
    # Both stage-0 agents feed stage-1's lone agent
    assert ("s0a0", "s1a0") in edge_pairs
    assert ("s0a1", "s1a0") in edge_pairs
    # Stage-1 agent feeds output
    assert ("s1a0", "out") in edge_pairs
    # No edge between s0a0 and s0a1 (parallel within stage)
    assert ("s0a0", "s0a1") not in edge_pairs
    assert ("s0a1", "s0a0") not in edge_pairs


def test_normalize_preserves_agent_fields():
    flat = {
        "agents": [{"role": "Coder", "model": "llama-3", "spec": "do x", "worker_affinity": "tee"}],
        "stages": [[0]],
        "workflow": "sequential",
    }
    result = normalize(flat)
    n = result["nodes"][0]
    assert n["role"] == "Coder"
    assert n["model"] == "llama-3"
    assert n["spec"] == "do x"
    assert n["worker_affinity"] == "tee"
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_team_spec_compat.py -v
```

Expected: 6 FAILs (`ModuleNotFoundError`).

- [ ] **Step 3: Implement**

Create `services/orchestrator/tally_orchestrator/team_spec_compat.py`:

```python
"""Sprint 48: bidirectional compatibility between flat team_spec (Sprint
22-29) and nodes_v1 team_spec (Sprint 48+).

Flat form:
  {"agents": [...], "stages": [[idx,...], ...], "workflow": "sequential"}

Nodes_v1 form:
  {"nodes": [...], "edges": [...], "format": "nodes_v1"}

The orchestrator's executor handles both formats by checking `format`.
On read, flat specs are converted on-the-fly via `normalize()`.  The
conversion is NOT persisted in Sprint 48; Sprint 49 will add a one-time
backfill that persists nodes_v1.
"""
from __future__ import annotations

from typing import Any


def is_nodes_v1(spec: dict[str, Any]) -> bool:
    """True if `spec` is already in nodes_v1 form."""
    return "nodes" in spec and isinstance(spec.get("nodes"), list)


def normalize(spec: dict[str, Any]) -> dict[str, Any]:
    """Return a nodes_v1 representation of `spec`.

    Passes through if already nodes_v1.  Converts flat form by mapping
    each stage's agents to nodes and connecting consecutive stages with
    'always' edges.  Agents within a stage have NO edges between them
    (parallel-by-default in the new executor).
    """
    if is_nodes_v1(spec):
        return spec
    nodes: list[dict[str, Any]] = []
    edges: list[dict[str, Any]] = []
    stages = spec.get("stages", [])
    agents = spec.get("agents", [])
    # Build nodes per (stage, position).
    for i, stage in enumerate(stages):
        for j, agent_idx in enumerate(stage):
            agent = agents[agent_idx] if 0 <= agent_idx < len(agents) else {}
            node: dict[str, Any] = {"id": f"s{i}a{j}", "kind": "agent"}
            for field in ("role", "model", "spec", "worker_affinity"):
                if field in agent and agent[field] not in (None, ""):
                    node[field] = agent[field]
            nodes.append(node)
    # Edges: every agent in stage i+1 takes input from every agent in stage i.
    for i in range(len(stages) - 1):
        for j_src, _ in enumerate(stages[i]):
            for j_dst, _ in enumerate(stages[i + 1]):
                edges.append({"from": f"s{i}a{j_src}", "to": f"s{i+1}a{j_dst}"})
    # Append a single output node fed by the last stage.
    nodes.append({"id": "out", "kind": "output"})
    if stages:
        for j_src, _ in enumerate(stages[-1]):
            edges.append({"from": f"s{len(stages)-1}a{j_src}", "to": "out"})
    return {"nodes": nodes, "edges": edges, "format": "nodes_v1"}
```

- [ ] **Step 4: Verify passing**

```bash
cd services/orchestrator && uv run pytest tests/test_team_spec_compat.py -v
```

Expected: 6 PASS.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/team_spec_compat.py services/orchestrator/tests/test_team_spec_compat.py
git commit -m "[s48] team_spec_compat: flat -> nodes_v1 normalizer"
```

### Task A3: agents.iteration_idx column for back-edge tracking

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — Db.__init__ migration block

- [ ] **Step 1: Write the failing test**

Append to `services/orchestrator/tests/test_workspace_schema.py`:

```python
def test_agents_iteration_idx_column(db: Db):
    """Sprint 48: agents.iteration_idx column exists (back-edge cycle tracker)."""
    cols = {row[1] for row in db._conn.execute("PRAGMA table_info(agents)").fetchall()}
    assert "iteration_idx" in cols
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_schema.py::test_agents_iteration_idx_column -v
```

Expected: FAIL.

- [ ] **Step 3: Add migration in Db.__init__**

Near the other `ALTER TABLE agents` migrations (the Sprint 47 `last_user_msg_ts` block is the most recent one — `service.py` around the lines that look like `ALTER TABLE agents ADD COLUMN last_user_msg_ts`), add:

```python
        try:
            self._conn.execute(
                "ALTER TABLE agents ADD COLUMN iteration_idx INTEGER NOT NULL DEFAULT 0"
            )
        except sqlite3.OperationalError:
            pass  # column already exists
```

- [ ] **Step 4: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_schema.py -v
```

Expected: all PASS (15+ from prior tasks + 1 new).

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_workspace_schema.py
git commit -m "[s48] agents: iteration_idx column for back-edge cycle tracking"
```

### Task A4: Db.approve_task() — move channel creation out of create_task

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — split `Db.create_task` + add `Db.approve_task`
- Append: `services/orchestrator/tests/test_workspace_schema.py`

- [ ] **Step 1: Write the failing test**

Append to `services/orchestrator/tests/test_workspace_schema.py`:

```python
def test_create_task_proposed_no_channel(db: Db):
    """Sprint 48: create_task with status='proposed' (default) creates NO task channel."""
    task_id = db.create_task("test", team_spec={"agents": [{"role": "Coder"}]}, user_id="admin")
    row = db._conn.execute(
        "SELECT id FROM channels WHERE task_id=?", (task_id,)
    ).fetchone()
    assert row is None, "task channel should not exist until approve_task"


def test_approve_task_creates_channel(db: Db):
    """Sprint 48: approve_task transitions status + creates the task channel + owner channel_member."""
    task_id = db.create_task("test", team_spec={"agents": [{"role": "Coder"}]}, user_id="admin")
    db.approve_task(task_id)
    # Status flipped
    status = db._conn.execute("SELECT status FROM tasks WHERE id=?", (task_id,)).fetchone()[0]
    assert status == "pending"
    # Channel exists
    row = db._conn.execute(
        "SELECT id, kind FROM channels WHERE task_id=?", (task_id,)
    ).fetchone()
    assert row is not None
    assert row[1] == "task"
    # Channel member exists for the owner
    mrow = db._conn.execute(
        "SELECT user_id FROM channel_members cm JOIN channels c ON cm.channel_id=c.id "
        "WHERE c.task_id=?", (task_id,)
    ).fetchone()
    assert mrow is not None
    assert mrow[0] == "admin"
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_schema.py::test_create_task_proposed_no_channel tests/test_workspace_schema.py::test_approve_task_creates_channel -v
```

Expected: 2 FAILs.

- [ ] **Step 3: Refactor Db.create_task + add Db.approve_task**

In `service.py`:

**(a)** Update `Db.create_task` signature to add `status: str = "proposed"`:

```python
    def create_task(self, description: str, *, team_spec: dict | None = None, user_id: str | None = None, status: str = "proposed") -> str:
```

**(b)** Update the existing `INSERT INTO tasks (...) VALUES (...)` line within `create_task` to use `status` instead of hardcoded `'pending'`. Search for the existing INSERT in `create_task` and use the `status` parameter value.

**(c)** REMOVE the Sprint 47 A12 channel-insert block at the end of `create_task`. (It's the block that does `INSERT INTO channels ... kind='task' ...` and the following `INSERT INTO channel_members ...`.)

**(d)** Add a new method `Db.approve_task`:

```python
    def approve_task(self, task_id: str) -> None:
        """Sprint 48: transition a proposed task to pending + create its
        channel + owner channel_member.  Idempotent: returns silently
        if the task isn't in 'proposed' state.
        """
        row = self._conn.execute(
            "SELECT status, user_id, created_at FROM tasks WHERE id=?",
            (task_id,),
        ).fetchone()
        if row is None or row[0] != "proposed":
            return
        _, user_id, created_at = row
        user_id = user_id or "admin"
        # Transition status
        self._conn.execute(
            "UPDATE tasks SET status='pending', updated_at=? WHERE id=?",
            (time.time(), task_id),
        )
        # Insert task channel + owner channel_member (moved from create_task)
        ws_row = self._conn.execute(
            "SELECT id FROM workspaces WHERE owner_user_id=?", (user_id,)
        ).fetchone()
        if ws_row is not None:
            ch_cur = self._conn.execute(
                "INSERT INTO channels (workspace_id, kind, name, task_id, created_at) "
                "VALUES (?, 'task', ?, ?, ?)",
                (ws_row[0], f"task-{task_id[:8]}", task_id, time.time()),
            )
            self._conn.execute(
                "INSERT INTO channel_members (channel_id, member_kind, user_id, joined_at) "
                "VALUES (?, 'human', ?, ?)",
                (ch_cur.lastrowid, user_id, time.time()),
            )
```

**Note on backfill compat:** The Sprint 47 `_backfill_workspaces_and_channels` still scans `tasks` and creates task channels for any task that doesn't have one. Tasks in `status='proposed'` would also get backfilled channels on next Db open — which is wrong. Modify the backfill query to filter:

```python
        task_rows = self._conn.execute(
            "SELECT t.id, t.user_id, t.status, t.created_at, t.updated_at "
            "FROM tasks t LEFT JOIN channels c ON c.task_id=t.id "
            "WHERE c.id IS NULL AND t.status NOT IN ('proposed', 'cancelled')"
        ).fetchall()
```

(Add the `AND t.status NOT IN (...)` filter to the existing query — search `_backfill_workspaces_and_channels` for the `LEFT JOIN channels c ON c.task_id=t.id` query.)

- [ ] **Step 4: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_schema.py -v
```

Expected: all PASS (including the 2 new tests).

Also: the prior tests `test_new_task_creates_task_channel` and `test_new_task_creates_task_channel_member` (Sprint 47 A12) WILL fail now because they expect the channel to exist inline after `create_task`. **Update those tests** to call `approve_task(task_id)` between `create_task` and the channel assertion:

```python
def test_new_task_creates_task_channel(db: Db):
    """When a task is approved, an immediate task channel is inserted."""
    task_id = db.create_task("test", team_spec={"agents":[{"role":"Coder"}]}, user_id="admin")
    db.approve_task(task_id)
    row = db._conn.execute(
        "SELECT id, kind FROM channels WHERE task_id=?", (task_id,)
    ).fetchone()
    assert row is not None
    assert row[1] == "task"


def test_new_task_creates_task_channel_member(db: Db):
    """The task owner is auto-joined to the task channel on approve."""
    task_id = db.create_task("test", team_spec={"agents": [{"role": "Coder"}]}, user_id="admin")
    db.approve_task(task_id)
    row = db._conn.execute(
        "SELECT cm.user_id FROM channel_members cm "
        "JOIN channels c ON cm.channel_id=c.id "
        "WHERE c.task_id=? AND cm.member_kind='human'",
        (task_id,),
    ).fetchone()
    assert row is not None
    assert row[0] == "admin"
```

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_workspace_schema.py
git commit -m "[s48] Db.approve_task: split channel creation out of create_task; defer until approve"
```

### Task A5: insert_team_proposal_message helper + messages.kind extension

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/channels.py` — add `insert_team_proposal_message`
- Create: `services/orchestrator/tests/test_team_proposal_message.py`

- [ ] **Step 1: Write the failing test**

Create `services/orchestrator/tests/test_team_proposal_message.py`:

```python
"""Sprint 48: team_proposal messages."""
import json
from tally_orchestrator.service import Db
from tally_orchestrator.channels import insert_team_proposal_message


def test_insert_team_proposal_message(db: Db):
    """Inserts a kind='team_proposal' message in the user's #general channel."""
    task_id = db.create_task("build a sorter", team_spec={"agents": [{"role": "Coder"}]}, user_id="admin")
    msg_id = insert_team_proposal_message(
        db,
        task_id=task_id,
        user_id="admin",
        description="build a sorter",
        team_spec={"nodes": [{"id": "n1", "kind": "agent", "role": "Coder"}], "edges": [], "format": "nodes_v1"},
    )
    assert msg_id > 0
    row = db._conn.execute(
        "SELECT kind, payload_json, author_kind FROM messages WHERE id=?", (msg_id,)
    ).fetchone()
    assert row[0] == "team_proposal"
    assert row[2] == "tally"
    payload = json.loads(row[1])
    assert payload["task_id"] == task_id
    assert payload["description"] == "build a sorter"
    assert payload["team_spec"]["nodes"][0]["role"] == "Coder"
    assert {opt["value"] for opt in payload["options"]} == {"approve", "edit", "cancel"}


def test_insert_team_proposal_message_no_general_channel_returns_zero(db: Db):
    """If the user has no workspace (impossible in real flow but defensive), returns 0."""
    # Insert a task for a user we'll then NOT backfill
    db._conn.execute(
        "DELETE FROM workspaces WHERE owner_user_id='ghost'"
    )
    db._conn.execute(
        "DELETE FROM channels WHERE workspace_id NOT IN (SELECT id FROM workspaces)"
    )
    msg_id = insert_team_proposal_message(
        db, task_id="t", user_id="ghost", description="x", team_spec={},
    )
    assert msg_id == 0
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_team_proposal_message.py -v
```

Expected: 2 FAILs.

- [ ] **Step 3: Implement**

In `services/orchestrator/tally_orchestrator/channels.py`, append:

```python
def insert_team_proposal_message(
    db: "Db",
    *,
    task_id: str,
    user_id: str,
    description: str,
    team_spec: dict,
) -> int:
    """Sprint 48: insert a kind='team_proposal' message in the user's
    #general channel with the architect's proposed team_spec.  Returns
    the new message_id, or 0 if the user has no #general channel."""
    row = db._conn.execute(
        "SELECT c.id FROM channels c JOIN workspaces w ON c.workspace_id=w.id "
        "WHERE w.owner_user_id=? AND c.kind='general' LIMIT 1",
        (user_id,),
    ).fetchone()
    if row is None:
        return 0
    channel_id = int(row[0])
    payload = {
        "task_id": task_id,
        "description": description,
        "team_spec": team_spec,
        "options": [
            {"value": "approve", "label": "Approve & dispatch"},
            {"value": "edit", "label": "Edit in builder"},
            {"value": "cancel", "label": "Cancel"},
        ],
    }
    return insert_message(
        db,
        channel_id=channel_id,
        author_kind="tally",
        kind="team_proposal",
        payload=payload,
    )
```

- [ ] **Step 4: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_team_proposal_message.py -v
```

Expected: 2 PASS.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/channels.py services/orchestrator/tests/test_team_proposal_message.py
git commit -m "[s48] channels: insert_team_proposal_message helper"
```

### Task A6: POST /tasks: defer dispatch behind team_proposal

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — POST /tasks handler

- [ ] **Step 1: Find the existing handler**

```bash
grep -n "@app.post(\"/tasks\")\|def create_task_route\|def submit_task" services/orchestrator/tally_orchestrator/service.py | head
```

Identify the handler that today calls the architect + dispatches. Read its body fully before modifying.

- [ ] **Step 2: Write the failing test**

Create `services/orchestrator/tests/test_task_approval_flow.py`:

```python
"""Sprint 48: POST /tasks returns status='proposed' + inserts team_proposal message."""
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


def test_post_tasks_returns_proposed_status(client):
    r = client.post("/tasks", json={"description": "build a sorter"})
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "proposed"
    assert "task_id" in body or "id" in body
    assert "team_spec" in body


def test_post_tasks_inserts_team_proposal_message(client):
    import tally_orchestrator.service as svc
    r = client.post("/tasks", json={"description": "build a sorter"})
    task_id = r.json().get("task_id") or r.json().get("id")
    # Find the team_proposal message in admin's #general
    db = svc.state["db"]
    row = db._conn.execute(
        "SELECT m.kind, m.payload_json FROM messages m "
        "JOIN channels c ON m.channel_id=c.id "
        "JOIN workspaces w ON c.workspace_id=w.id "
        "WHERE w.owner_user_id='admin' AND c.kind='general' "
        "AND m.kind='team_proposal' ORDER BY m.id DESC LIMIT 1"
    ).fetchone()
    assert row is not None
    assert row[0] == "team_proposal"
    payload = json.loads(row[1])
    assert payload["task_id"] == task_id
    assert "team_spec" in payload


def test_post_tasks_no_dispatch_yet(client):
    """Status='proposed' means no agent has been dispatched."""
    import tally_orchestrator.service as svc
    r = client.post("/tasks", json={"description": "x"})
    task_id = r.json().get("task_id") or r.json().get("id")
    db = svc.state["db"]
    # No agents row inserted (architect runs but dispatch is deferred)
    cnt = db._conn.execute(
        "SELECT COUNT(*) FROM agents WHERE task_id=?", (task_id,)
    ).fetchone()[0]
    assert cnt == 0, f"expected no dispatched agents while proposed; got {cnt}"
```

- [ ] **Step 3: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_task_approval_flow.py -v
```

Expected: 3 FAILs.

- [ ] **Step 4: Modify POST /tasks handler**

Locate the handler (`grep -n "@app.post(\"/tasks\")"` from Step 1). Adapt this template — your existing handler likely has cost-check + quota plumbing that must stay. Apply ONLY these surgical changes:

- After the architect runs and `team_spec` is produced, change the `Db.create_task` call to use `status='proposed'` (default per A4).
- REMOVE the immediate dispatch trigger (the line that publishes/enqueues for the worker poller — search for `_dispatch_agent`, `state["bus"].publish`, or similar).
- After the `Db.create_task` call returns `task_id`, insert the team_proposal message:

```python
        from .channels import insert_team_proposal_message
        insert_team_proposal_message(
            db,
            task_id=task_id,
            user_id=user.id,
            description=description,
            team_spec=team_spec,
        )
        # Broadcast via WebSocket — the existing _broadcast_new_message handles this
        # since the message was inserted into the user's #general channel.
```

The `_broadcast_new_message` placeholder is wired in Sprint 47 A10. Since `insert_team_proposal_message` calls `insert_message` (which doesn't broadcast on its own — the route layer does), we need to either:

(a) call `_broadcast_new_message` directly after the helper, OR
(b) make `insert_message` always broadcast.

For Sprint 48, prefer (a) to keep `insert_message` pure:

```python
        msg_id = insert_team_proposal_message(...)
        if msg_id > 0:
            # Find the channel_id for the broadcast
            row = db._conn.execute(
                "SELECT channel_id FROM messages WHERE id=?", (msg_id,)
            ).fetchone()
            if row:
                t = asyncio.create_task(_broadcast_new_message(row[0], msg_id))
                _background_tasks.add(t)
                t.add_done_callback(_background_tasks.discard)
```

Return shape: include `task_id`, `team_spec`, `status='proposed'`. If the existing response shape differs, ADAPT — don't break existing API contracts.

- [ ] **Step 5: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_task_approval_flow.py tests/ -q
```

Expected: 3 new PASS + no regressions in existing tests. Existing tests that submit a task and expect immediate dispatch WILL fail — review each:

- If the test asserts `status='pending'` immediately after POST /tasks, update to `status='proposed'`.
- If the test expects agents to be dispatched immediately, add an `approve_task` call between POST /tasks and the agent assertion (the test can call `db.approve_task` directly, OR call `POST /tasks/{id}/approve` once that route exists in A7).

Document any test changes in the commit message.

- [ ] **Step 6: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_task_approval_flow.py services/orchestrator/tests/  # any updated existing tests
git commit -m "[s48] POST /tasks: defer dispatch; insert team_proposal in #general"
```

### Task A7: POST /tasks/{id}/approve route

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Append: `services/orchestrator/tests/test_task_approval_flow.py`

- [ ] **Step 1: Append failing tests**

Append to `services/orchestrator/tests/test_task_approval_flow.py`:

```python
def test_approve_transitions_to_pending(client):
    import tally_orchestrator.service as svc
    r = client.post("/tasks", json={"description": "x"})
    task_id = r.json().get("task_id") or r.json().get("id")
    r2 = client.post(f"/tasks/{task_id}/approve")
    assert r2.status_code == 200
    db = svc.state["db"]
    status = db._conn.execute("SELECT status FROM tasks WHERE id=?", (task_id,)).fetchone()[0]
    assert status == "pending"


def test_approve_creates_task_channel(client):
    import tally_orchestrator.service as svc
    r = client.post("/tasks", json={"description": "x"})
    task_id = r.json().get("task_id") or r.json().get("id")
    db = svc.state["db"]
    # No task channel before approve
    pre = db._conn.execute("SELECT id FROM channels WHERE task_id=?", (task_id,)).fetchone()
    assert pre is None
    # Approve
    client.post(f"/tasks/{task_id}/approve")
    post = db._conn.execute("SELECT id, kind FROM channels WHERE task_id=?", (task_id,)).fetchone()
    assert post is not None
    assert post[1] == "task"


def test_approve_returns_409_on_repeat(client):
    r = client.post("/tasks", json={"description": "x"})
    task_id = r.json().get("task_id") or r.json().get("id")
    r1 = client.post(f"/tasks/{task_id}/approve")
    assert r1.status_code == 200
    r2 = client.post(f"/tasks/{task_id}/approve")
    assert r2.status_code == 409  # already non-proposed


def test_approve_non_owner_returns_403(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    r = client.post("/tasks", json={"description": "x"})
    task_id = r.json().get("task_id") or r.json().get("id")
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="stranger", source="clerk", plan="free", email="s@x.com",
    )
    r2 = client.post(f"/tasks/{task_id}/approve")
    assert r2.status_code == 403


def test_approve_unknown_task_returns_404(client):
    r = client.post("/tasks/nonexistent/approve")
    assert r.status_code == 404
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_task_approval_flow.py -v -k approve
```

Expected: 5 FAILs (route doesn't exist).

- [ ] **Step 3: Add the route**

In `service.py`, near other `/tasks/...` routes (search `@app.post("/tasks"`), add:

```python
@app.post("/tasks/{task_id}/approve")
async def approve_task_route(
    task_id: str,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 48: transition a proposed task to pending + dispatch.
    Owner-only.  409 on repeat (status already non-proposed)."""
    db: Db = state["db"]
    row = db._conn.execute(
        "SELECT user_id, status FROM tasks WHERE id=?", (task_id,)
    ).fetchone()
    if row is None:
        raise HTTPException(404, "task not found")
    owner, status = row
    if owner != user.id:
        raise HTTPException(403, "only the task owner can approve")
    if status != "proposed":
        raise HTTPException(409, f"task is not in 'proposed' state (current: {status})")
    db.approve_task(task_id)
    # Trigger dispatch — kick the orchestrator's poller.  The poller already
    # picks up status='pending' on its next tick; we explicitly wake it here.
    orch = state.get("orch")
    if orch is not None:
        asyncio.create_task(orch._kick_poller())
    # Return the updated task row
    new_row = db._conn.execute(
        "SELECT id, status, team_spec FROM tasks WHERE id=?", (task_id,)
    ).fetchone()
    return {
        "id": new_row[0],
        "status": new_row[1],
        "team_spec": json.loads(new_row[2]) if new_row[2] else None,
    }
```

**Note on the orchestrator kick:** if the orchestrator doesn't have a `_kick_poller` method, the worker poller will still pick the task up on its next tick (default ~1s). The kick is an optimization.  Verify: `grep -n "_kick_poller\|_poll_interval\|def _run" service.py`.  If no kick method exists, omit the `asyncio.create_task(orch._kick_poller())` line.

- [ ] **Step 4: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_task_approval_flow.py -v
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_task_approval_flow.py
git commit -m "[s48] POST /tasks/{id}/approve — flip proposed -> pending + create channel"
```

### Task A8: PATCH /tasks/{id}/team_spec route

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Append: `services/orchestrator/tests/test_task_approval_flow.py`

- [ ] **Step 1: Append failing tests**

Append to `services/orchestrator/tests/test_task_approval_flow.py`:

```python
def test_patch_team_spec_updates(client):
    import tally_orchestrator.service as svc
    import json as _json
    r = client.post("/tasks", json={"description": "x"})
    task_id = r.json().get("task_id") or r.json().get("id")
    new_spec = {"nodes": [{"id": "n1", "kind": "agent", "role": "Tester"}], "edges": [], "format": "nodes_v1"}
    r2 = client.patch(f"/tasks/{task_id}/team_spec", json={"team_spec": new_spec})
    assert r2.status_code == 200
    db = svc.state["db"]
    stored = _json.loads(db._conn.execute("SELECT team_spec FROM tasks WHERE id=?", (task_id,)).fetchone()[0])
    assert stored["nodes"][0]["role"] == "Tester"


def test_patch_team_spec_409_after_approve(client):
    r = client.post("/tasks", json={"description": "x"})
    task_id = r.json().get("task_id") or r.json().get("id")
    client.post(f"/tasks/{task_id}/approve")
    r2 = client.patch(f"/tasks/{task_id}/team_spec", json={"team_spec": {"nodes": [], "edges": []}})
    assert r2.status_code == 409


def test_patch_team_spec_non_owner_returns_403(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    r = client.post("/tasks", json={"description": "x"})
    task_id = r.json().get("task_id") or r.json().get("id")
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="stranger", source="clerk", plan="free", email="s@x.com",
    )
    r2 = client.patch(f"/tasks/{task_id}/team_spec", json={"team_spec": {"nodes": [], "edges": []}})
    assert r2.status_code == 403
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_task_approval_flow.py -v -k patch_team_spec
```

Expected: 3 FAILs.

- [ ] **Step 3: Add Pydantic model + route**

In `service.py`, add the request model near the other models added in Sprint 47 (`ChannelMemberRoleOverrideRequest` etc.):

```python
class TaskTeamSpecPatchRequest(BaseModel):
    team_spec: dict
```

Then add the route near the other `/tasks/...` routes:

```python
@app.patch("/tasks/{task_id}/team_spec")
async def patch_task_team_spec(
    task_id: str,
    body: TaskTeamSpecPatchRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 48: update a proposed task's team_spec.  Owner-only.
    409 if task is no longer in 'proposed' state.  Re-broadcasts the
    team_proposal message so other clients see the updated spec."""
    db: Db = state["db"]
    row = db._conn.execute(
        "SELECT user_id, status FROM tasks WHERE id=?", (task_id,)
    ).fetchone()
    if row is None:
        raise HTTPException(404, "task not found")
    owner, status = row
    if owner != user.id:
        raise HTTPException(403, "only the task owner can edit the team_spec")
    if status != "proposed":
        raise HTTPException(409, f"task is not editable (status: {status})")
    db._conn.execute(
        "UPDATE tasks SET team_spec=?, updated_at=? WHERE id=?",
        (json.dumps(body.team_spec), time.time(), task_id),
    )
    # Update the team_proposal message's payload too (re-broadcasts via WS)
    msg_row = db._conn.execute(
        "SELECT m.id, m.channel_id, m.payload_json FROM messages m "
        "JOIN channels c ON m.channel_id=c.id "
        "JOIN workspaces w ON c.workspace_id=w.id "
        "WHERE w.owner_user_id=? AND c.kind='general' "
        "AND m.kind='team_proposal' AND json_extract(m.payload_json, '$.task_id')=? "
        "ORDER BY m.id DESC LIMIT 1",
        (user.id, task_id),
    ).fetchone()
    if msg_row is not None:
        msg_id, channel_id, payload_json = msg_row
        payload = json.loads(payload_json)
        payload["team_spec"] = body.team_spec
        db._conn.execute(
            "UPDATE messages SET payload_json=?, edited_at=? WHERE id=?",
            (json.dumps(payload), time.time(), msg_id),
        )
        # Fan out via WebSocket — clients will refetch the message
        t = asyncio.create_task(_broadcast_new_message(channel_id, msg_id))
        _background_tasks.add(t)
        t.add_done_callback(_background_tasks.discard)
    return {"id": task_id, "status": status, "team_spec": body.team_spec}
```

- [ ] **Step 4: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_task_approval_flow.py -v
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_task_approval_flow.py
git commit -m "[s48] PATCH /tasks/{id}/team_spec — owner-only, proposed-only"
```

### Task A9: POST /tasks/{id}/cancel route

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Append: `services/orchestrator/tests/test_task_approval_flow.py`

- [ ] **Step 1: Append failing tests**

```python
def test_cancel_proposed_task(client):
    import tally_orchestrator.service as svc
    r = client.post("/tasks", json={"description": "x"})
    task_id = r.json().get("task_id") or r.json().get("id")
    r2 = client.post(f"/tasks/{task_id}/cancel")
    assert r2.status_code == 200
    db = svc.state["db"]
    status = db._conn.execute("SELECT status FROM tasks WHERE id=?", (task_id,)).fetchone()[0]
    assert status == "cancelled"


def test_cancel_409_after_approve(client):
    r = client.post("/tasks", json={"description": "x"})
    task_id = r.json().get("task_id") or r.json().get("id")
    client.post(f"/tasks/{task_id}/approve")
    r2 = client.post(f"/tasks/{task_id}/cancel")
    assert r2.status_code == 409


def test_cancel_non_owner_returns_403(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    r = client.post("/tasks", json={"description": "x"})
    task_id = r.json().get("task_id") or r.json().get("id")
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="stranger", source="clerk", plan="free", email="s@x.com",
    )
    r2 = client.post(f"/tasks/{task_id}/cancel")
    assert r2.status_code == 403
```

- [ ] **Step 2: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_task_approval_flow.py -v -k cancel
```

Expected: 3 FAILs.

- [ ] **Step 3: Add route**

```python
@app.post("/tasks/{task_id}/cancel")
async def cancel_task_route(
    task_id: str,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 48: cancel a proposed task.  Owner-only.  Updates the
    team_proposal message to mark it cancelled (UI greys buttons)."""
    db: Db = state["db"]
    row = db._conn.execute(
        "SELECT user_id, status FROM tasks WHERE id=?", (task_id,)
    ).fetchone()
    if row is None:
        raise HTTPException(404, "task not found")
    owner, status = row
    if owner != user.id:
        raise HTTPException(403, "only the task owner can cancel")
    if status != "proposed":
        raise HTTPException(409, f"only proposed tasks can be cancelled (current: {status})")
    db._conn.execute(
        "UPDATE tasks SET status='cancelled', updated_at=? WHERE id=?",
        (time.time(), task_id),
    )
    # Mark the team_proposal message as cancelled (UI hint)
    msg_row = db._conn.execute(
        "SELECT m.id, m.channel_id, m.payload_json FROM messages m "
        "JOIN channels c ON m.channel_id=c.id "
        "JOIN workspaces w ON c.workspace_id=w.id "
        "WHERE w.owner_user_id=? AND c.kind='general' "
        "AND m.kind='team_proposal' AND json_extract(m.payload_json, '$.task_id')=? "
        "ORDER BY m.id DESC LIMIT 1",
        (user.id, task_id),
    ).fetchone()
    if msg_row is not None:
        msg_id, channel_id, payload_json = msg_row
        payload = json.loads(payload_json)
        payload["cancelled"] = True
        db._conn.execute(
            "UPDATE messages SET payload_json=?, edited_at=? WHERE id=?",
            (json.dumps(payload), time.time(), msg_id),
        )
        t = asyncio.create_task(_broadcast_new_message(channel_id, msg_id))
        _background_tasks.add(t)
        t.add_done_callback(_background_tasks.discard)
    return {"id": task_id, "status": "cancelled"}
```

- [ ] **Step 4: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_task_approval_flow.py -v
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_task_approval_flow.py
git commit -m "[s48] POST /tasks/{id}/cancel — terminal cancellation of proposed task"
```

### Task A10: Workflow executor — nodes_v1 mode

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — `Orchestrator._advance_task`
- Create: `services/orchestrator/tests/test_workflow_executor_nodes_v1.py`

- [ ] **Step 1: Inspect existing executor**

```bash
grep -n "def _advance_task\|stages\[" services/orchestrator/tally_orchestrator/service.py | head -10
```

Read the existing `_advance_task` to understand its shape. Key existing pieces to preserve:
- `team_spec.get("stages")` flat mode loop
- `mark_agent_completed`, `mark_agent_failed`, `set_task_worker`
- Per-stage parallel dispatch + barrier-style wait

- [ ] **Step 2: Write the failing tests**

Create `services/orchestrator/tests/test_workflow_executor_nodes_v1.py`:

```python
"""Sprint 48: workflow executor in nodes_v1 mode.

These are pure unit tests against the graph-traversal logic — they don't
spin up real workers."""
from tally_orchestrator.team_spec_compat import is_nodes_v1


def test_nodes_v1_entry_points_are_no_incoming_edge():
    """Nodes with no incoming edges are the entry set (dispatched first)."""
    from tally_orchestrator.service import _nodes_v1_entry_nodes
    spec = {
        "nodes": [{"id": "n1"}, {"id": "n2"}, {"id": "out"}],
        "edges": [{"from": "n1", "to": "n2"}, {"from": "n2", "to": "out"}],
    }
    entries = _nodes_v1_entry_nodes(spec)
    assert entries == {"n1"}


def test_nodes_v1_two_entries_parallel():
    from tally_orchestrator.service import _nodes_v1_entry_nodes
    spec = {
        "nodes": [{"id": "a"}, {"id": "b"}, {"id": "out"}],
        "edges": [{"from": "a", "to": "out"}, {"from": "b", "to": "out"}],
    }
    entries = _nodes_v1_entry_nodes(spec)
    assert entries == {"a", "b"}


def test_nodes_v1_next_ready_after_completion():
    """After 'n1' completes successfully, 'n2' is ready (if edge condition matches)."""
    from tally_orchestrator.service import _nodes_v1_next_ready
    spec = {
        "nodes": [{"id": "n1"}, {"id": "n2"}, {"id": "out"}],
        "edges": [
            {"from": "n1", "to": "n2", "condition": "if_succeeded"},
            {"from": "n2", "to": "out"},
        ],
    }
    completed = {"n1": "succeeded"}
    ready = _nodes_v1_next_ready(spec, completed)
    assert "n2" in ready


def test_nodes_v1_skip_failed_branch():
    """if_succeeded edge from a failed node doesn't fire."""
    from tally_orchestrator.service import _nodes_v1_next_ready
    spec = {
        "nodes": [{"id": "n1"}, {"id": "n2"}, {"id": "out"}],
        "edges": [
            {"from": "n1", "to": "n2", "condition": "if_succeeded"},
            {"from": "n2", "to": "out"},
        ],
    }
    completed = {"n1": "failed"}
    ready = _nodes_v1_next_ready(spec, completed)
    assert "n2" not in ready


def test_nodes_v1_if_failed_fires():
    """if_failed edge from a failed node fires (loop/fallback semantic)."""
    from tally_orchestrator.service import _nodes_v1_next_ready
    spec = {
        "nodes": [{"id": "n1"}, {"id": "fallback"}],
        "edges": [
            {"from": "n1", "to": "fallback", "condition": "if_failed"},
        ],
    }
    completed = {"n1": "failed"}
    ready = _nodes_v1_next_ready(spec, completed)
    assert "fallback" in ready
```

- [ ] **Step 3: Verify failing**

```bash
cd services/orchestrator && uv run pytest tests/test_workflow_executor_nodes_v1.py -v
```

Expected: 5 FAILs.

- [ ] **Step 4: Add the graph-traversal helpers + executor branch**

In `service.py`, add module-level pure helpers (near `team_spec_compat` import region or near other top-level helpers):

```python
def _nodes_v1_entry_nodes(spec: dict) -> set[str]:
    """Return the set of node ids with no incoming edge (entry points)."""
    all_ids = {n["id"] for n in spec.get("nodes", [])}
    targets = {e["to"] for e in spec.get("edges", [])}
    return all_ids - targets


def _nodes_v1_next_ready(spec: dict, completed: dict[str, str]) -> set[str]:
    """Return node ids that are NOT yet completed but whose required incoming
    edges have fired given the `completed` map {node_id: 'succeeded'|'failed'}.

    An edge "fires" when its `from` is in `completed` and its `condition`
    matches.  A node becomes ready when ALL its incoming edges have fired
    (AND semantics across incoming edges).
    """
    ready: set[str] = set()
    completed_ids = set(completed.keys())
    for node in spec.get("nodes", []):
        nid = node["id"]
        if nid in completed_ids:
            continue
        incoming = [e for e in spec.get("edges", []) if e["to"] == nid]
        if not incoming:
            continue  # entry node — caller handles separately
        all_fired = True
        for edge in incoming:
            src = edge["from"]
            if src not in completed:
                all_fired = False
                break
            condition = edge.get("condition", "always")
            src_status = completed[src]
            if condition == "always":
                pass
            elif condition == "if_succeeded" and src_status != "succeeded":
                all_fired = False
                break
            elif condition == "if_failed" and src_status != "failed":
                all_fired = False
                break
            elif condition == "if_returned":
                # Sprint 48 parses but doesn't evaluate yet (deferred)
                all_fired = False
                break
        if all_fired:
            ready.add(nid)
    return ready
```

Then in `_advance_task`, find the block that branches on `team_spec`. Add at the top of `_advance_task`:

```python
        from .team_spec_compat import is_nodes_v1, normalize
        # Sprint 48: normalize flat -> nodes_v1 on the fly
        spec = task.get("team_spec") or {}
        if not is_nodes_v1(spec):
            # Existing flat-mode executor path — keep as-is for backward compat
            ... (existing code unchanged)
            return
        # Sprint 48 nodes_v1 executor path
        ... (new graph traversal — dispatch entry nodes if none dispatched yet;
             otherwise check completed agents and dispatch next-ready nodes)
```

The full new branch follows the same shape as the flat-mode branch — read which `agents` rows already exist for this task, compute completed map, compute next ready set, dispatch each new ready node as an `INSERT INTO agents` + dispatch trigger. The full code is too long for this plan; the implementer should adapt the existing flat-mode dispatch logic to the new entry/ready computation.

**For Sprint 48 SCOPE:** the nodes_v1 executor only needs to handle linear and parallel-fan-out cases. Loop/back-edges with `max_iterations` are not exercised by the editor yet (no UI for them). The implementer can add a TODO for max_iterations and dispatch acyclically.

- [ ] **Step 5: Verify**

```bash
cd services/orchestrator && uv run pytest tests/test_workflow_executor_nodes_v1.py -v
```

Expected: 5 PASS.

Then full suite:

```bash
cd services/orchestrator && uv run pytest tests/ -q
```

Expected: no regressions.

- [ ] **Step 6: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_workflow_executor_nodes_v1.py
git commit -m "[s48] executor: nodes_v1 graph traversal (entries + edge conditions)"
```

### Task A11: Phase A smoke test

**Files:** none to write — verify full backend works end-to-end.

- [ ] **Step 1: Run the full pytest suite**

```bash
cd services/orchestrator && uv run pytest tests/ -v 2>&1 | tail -20
```

Expected: all PASS (~125 tests = Sprint 47's 110 + ~15 new).

- [ ] **Step 2: Local boot + curl smoke**

```bash
cd services/orchestrator && rm -f /tmp/s48-smoke.db && TALLY_API_TOKEN=smoke ORCH_DB_PATH=/tmp/s48-smoke.db TALLY_REDPILL_KEY="" TALLY_TEST_MODE=1 uv run uvicorn tally_orchestrator.service:app --port 8118 &
sleep 5
# 1. Submit a task — should return status='proposed' + insert team_proposal
TASK=$(curl -sX POST -H "Authorization: Bearer smoke" -H "content-type: application/json" \
  -d '{"description":"test task"}' http://localhost:8118/tasks | python3 -c "import json,sys;print(json.load(sys.stdin).get('task_id') or json.load(sys.stdin).get('id'))")
echo "task_id: $TASK"
# 2. Verify team_proposal in #general
curl -s -H "Authorization: Bearer smoke" "http://localhost:8118/channels/1/messages" | python3 -c "import json,sys;d=json.load(sys.stdin); [print(m['kind'], json.loads(m['payload_json']).get('task_id')) for m in d['messages']]"
# 3. Approve
curl -sX POST -H "Authorization: Bearer smoke" "http://localhost:8118/tasks/$TASK/approve" | python3 -m json.tool
# 4. Verify task channel appears
curl -s -H "Authorization: Bearer smoke" "http://localhost:8118/channels?workspace_id=1" | python3 -c "import json,sys;d=json.load(sys.stdin); [print(c['kind'], c['task_id']) for c in d['channels'] if c['kind']=='task']"
kill %1
```

Expected: each step returns 200 with the right shape.

- [ ] **Step 3: Tag Phase A**

```bash
git tag s48-phase-a-done
```

---

## Phase B — Frontend (8 tasks, ~25h)

### Task B1: api.dart additions

**Files:**
- Modify: `tally_coding_app/lib/api.dart`
- Create: `tally_coding_app/test/api_tasks_approval_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tally_coding_app/api.dart';

void main() {
  test('approveTask POSTs /tasks/{id}/approve', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/tasks/abc/approve');
      expect(req.method, 'POST');
      return http.Response('{"id":"abc","status":"pending"}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.approveTask(taskId: 'abc');
    expect(out['status'], 'pending');
  });

  test('updateTaskTeamSpec PATCHes /tasks/{id}/team_spec', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/tasks/abc/team_spec');
      expect(req.method, 'PATCH');
      return http.Response('{"id":"abc","status":"proposed","team_spec":{"nodes":[],"edges":[]}}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.updateTaskTeamSpec(taskId: 'abc', teamSpec: {'nodes':[],'edges':[]});
    expect(out['status'], 'proposed');
  });

  test('cancelTask POSTs /tasks/{id}/cancel', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/tasks/abc/cancel');
      expect(req.method, 'POST');
      return http.Response('{"id":"abc","status":"cancelled"}', 200, headers: {'content-type':'application/json'});
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.cancelTask(taskId: 'abc');
    expect(out['status'], 'cancelled');
  });
}
```

- [ ] **Step 2: Verify failing**

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter test test/api_tasks_approval_test.dart
```

Expected: 3 FAILs.

- [ ] **Step 3: Add methods to TallyOrchClient**

Before `void close()`:

```dart
  // ── Sprint 48: task lifecycle ────────────────────────────────────────────

  Future<Map<String, dynamic>> approveTask({required String taskId}) async {
    final resp = await _http.post(
      baseUrl.resolve('/tasks/$taskId/approve'),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) {
      throw Exception('POST /tasks/$taskId/approve ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<Map<String, dynamic>> updateTaskTeamSpec({
    required String taskId,
    required Map<String, dynamic> teamSpec,
  }) async {
    final resp = await _http.patch(
      baseUrl.resolve('/tasks/$taskId/team_spec'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode({'team_spec': teamSpec}),
    );
    if (resp.statusCode != 200) {
      throw Exception('PATCH /tasks/$taskId/team_spec ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<Map<String, dynamic>> cancelTask({required String taskId}) async {
    final resp = await _http.post(
      baseUrl.resolve('/tasks/$taskId/cancel'),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) {
      throw Exception('POST /tasks/$taskId/cancel ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }
```

- [ ] **Step 4: Verify**

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter test test/api_tasks_approval_test.dart
```

Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/api.dart tally_coding_app/test/api_tasks_approval_test.dart
git commit -m "[s48] api.dart: approveTask, updateTaskTeamSpec, cancelTask"
```

### Task B2: TeamProposalCard widget

**Files:**
- Create: `tally_coding_app/lib/widgets/team_proposal_card.dart`
- Create: `tally_coding_app/test/team_proposal_card_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/team_proposal_card.dart';

void main() {
  testWidgets('renders description, team summary, 3 buttons', (tester) async {
    final msg = {
      'id': 1, 'channel_id': 1, 'author_kind': 'tally',
      'kind': 'team_proposal',
      'payload_json': jsonEncode({
        'task_id': 'abc',
        'description': 'build a sorter',
        'team_spec': {
          'nodes': [
            {'id': 'n1', 'kind': 'agent', 'role': 'Coder'},
            {'id': 'n2', 'kind': 'agent', 'role': 'Tester'},
          ],
          'edges': [],
        },
        'options': [
          {'value': 'approve', 'label': 'Approve & dispatch'},
          {'value': 'edit', 'label': 'Edit in builder'},
          {'value': 'cancel', 'label': 'Cancel'},
        ],
      }),
      'created_at': 1700000000.0,
    };
    String? clicked;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      TeamProposalCard(message: msg, onAction: (v) => clicked = v),
    )));
    expect(find.textContaining('build a sorter'), findsOneWidget);
    expect(find.textContaining('Coder'), findsOneWidget);
    expect(find.textContaining('Tester'), findsOneWidget);
    expect(find.text('Approve & dispatch'), findsOneWidget);
    expect(find.text('Edit in builder'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    await tester.tap(find.text('Approve & dispatch'));
    await tester.pumpAndSettle();
    expect(clicked, 'approve');
  });

  testWidgets('greys buttons when cancelled', (tester) async {
    final msg = {
      'id': 1, 'channel_id': 1, 'author_kind': 'tally',
      'kind': 'team_proposal',
      'payload_json': jsonEncode({
        'task_id': 'abc', 'description': 'x',
        'team_spec': {'nodes': [], 'edges': []},
        'options': [{'value':'approve','label':'Approve'}],
        'cancelled': true,
      }),
      'created_at': 1700000000.0,
    };
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      TeamProposalCard(message: msg, onAction: (v) {}),
    )));
    expect(find.textContaining('cancelled'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Verify failing**

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter test test/team_proposal_card_test.dart
```

Expected: 2 FAILs.

- [ ] **Step 3: Create the widget**

```dart
// tally_coding_app/lib/widgets/team_proposal_card.dart
import 'dart:convert';
import 'package:flutter/material.dart';

class TeamProposalCard extends StatelessWidget {
  final Map<String, dynamic> message;
  final void Function(String action) onAction;
  const TeamProposalCard({super.key, required this.message, required this.onAction});

  Map<String, dynamic> _payload() {
    try {
      return Map<String, dynamic>.from(jsonDecode(message['payload_json'] as String));
    } catch (_) { return const {}; }
  }

  String _teamSummary(Map<String, dynamic> teamSpec) {
    final nodes = (teamSpec['nodes'] as List?) ?? const [];
    final roles = nodes
      .where((n) => n is Map && n['kind'] == 'agent')
      .map((n) => (n as Map)['role']?.toString() ?? 'Agent')
      .toList();
    if (roles.isEmpty) return 'No agents';
    return roles.join(' → ');
  }

  @override
  Widget build(BuildContext context) {
    final payload = _payload();
    final description = (payload['description'] as String?) ?? '';
    final teamSpec = Map<String, dynamic>.from(payload['team_spec'] ?? {});
    final options = (payload['options'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    final cancelled = (payload['cancelled'] as bool?) ?? false;
    final approved = (payload['approved'] as bool?) ?? false;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E3A2F),
        border: const Border(left: BorderSide(color: Color(0xFF3BA55D), width: 3)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Tally proposes a team', style: TextStyle(color: Color(0xFF3BA55D), fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(description, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          Text('Team: ${_teamSummary(teamSpec)}', style: const TextStyle(fontSize: 12, color: Color(0xFF949BA4))),
          const SizedBox(height: 10),
          if (cancelled)
            const Text('cancelled', style: TextStyle(color: Color(0xFF949BA4), fontStyle: FontStyle.italic))
          else if (approved)
            const Text('approved', style: TextStyle(color: Color(0xFF3BA55D), fontStyle: FontStyle.italic))
          else
            Wrap(
              spacing: 8,
              children: [
                for (final opt in options)
                  ElevatedButton(
                    onPressed: () => onAction(opt['value'] as String),
                    child: Text(opt['label'] as String),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Verify**

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter test test/team_proposal_card_test.dart
```

Expected: 2 PASS.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/widgets/team_proposal_card.dart tally_coding_app/test/team_proposal_card_test.dart
git commit -m "[s48] TeamProposalCard: Tally team proposal with 3-button action"
```

### Task B3: MessageFeed dispatch to TeamProposalCard

**Files:**
- Modify: `tally_coding_app/lib/widgets/message_feed.dart`
- Append: `tally_coding_app/test/message_feed_test.dart`

- [ ] **Step 1: Append failing test**

```dart
testWidgets('renders team_proposal message via TeamProposalCard', (tester) async {
  final messages = [
    {
      'id': 1, 'channel_id': 1, 'author_kind': 'tally',
      'kind': 'team_proposal',
      'payload_json': jsonEncode({
        'task_id': 'abc', 'description': 'build it',
        'team_spec': {'nodes': [{'id':'n1','kind':'agent','role':'Coder'}], 'edges':[]},
        'options': [{'value':'approve','label':'Approve'}, {'value':'edit','label':'Edit'}, {'value':'cancel','label':'Cancel'}],
      }),
      'created_at': 1700000000.0,
    },
  ];
  String? clicked;
  await tester.pumpWidget(MaterialApp(home: Scaffold(body:
    MessageFeed(
      messages: messages,
      onAnswerPrompt: (_, __) {},
      onTeamProposalAction: (taskId, action) => clicked = '$taskId:$action',
    ),
  )));
  expect(find.textContaining('build it'), findsOneWidget);
  await tester.tap(find.text('Approve'));
  await tester.pumpAndSettle();
  expect(clicked, 'abc:approve');
});
```

- [ ] **Step 2: Verify failing**

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter test test/message_feed_test.dart
```

Expected: FAIL (`onTeamProposalAction` not defined; `team_proposal` not dispatched).

- [ ] **Step 3: Modify `MessageFeed`**

Update the widget constructor to add `onTeamProposalAction`:

```dart
class MessageFeed extends StatelessWidget {
  final List<Map<String, dynamic>> messages;
  final void Function(int messageId, String answerValue) onAnswerPrompt;
  /// Sprint 48: callback when a team_proposal action is clicked.
  /// Receives (taskId, action) where action is 'approve' | 'edit' | 'cancel'.
  final void Function(String taskId, String action)? onTeamProposalAction;
  const MessageFeed({
    super.key,
    required this.messages,
    required this.onAnswerPrompt,
    this.onTeamProposalAction,
  });
```

Add import:
```dart
import 'team_proposal_card.dart';
```

In `itemBuilder`, add a new branch:

```dart
        if (kind == 'team_proposal') {
          return TeamProposalCard(
            message: m,
            onAction: (action) {
              if (onTeamProposalAction == null) return;
              try {
                final payload = jsonDecode(m['payload_json'] as String) as Map<String, dynamic>;
                final taskId = payload['task_id'] as String? ?? '';
                onTeamProposalAction!(taskId, action);
              } catch (_) {}
            },
          );
        }
```

(Add `import 'dart:convert';` to the top of message_feed.dart if not already there.)

- [ ] **Step 4: Verify**

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter test test/message_feed_test.dart
```

Expected: all PASS (3 from Sprint 47 + 1 new).

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/widgets/message_feed.dart tally_coding_app/test/message_feed_test.dart
git commit -m "[s48] MessageFeed: dispatch kind='team_proposal' to TeamProposalCard"
```

### Task B4: Add vyuh_node_flow dependency + WorkflowEditorScreen scaffold

**Files:**
- Modify: `tally_coding_app/pubspec.yaml`
- Create: `tally_coding_app/lib/screens/workflow_editor.dart`

- [ ] **Step 1: Add the dependency**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app && /home/nick/.local/flutter/bin/flutter pub add vyuh_node_flow:^0.27.3
```

Verify `pubspec.yaml` got the entry (`/home/nick/.local/flutter/bin/flutter pub get` will run automatically).

- [ ] **Step 2: Create the screen scaffold**

Create `tally_coding_app/lib/screens/workflow_editor.dart`:

```dart
// tally_coding_app/lib/screens/workflow_editor.dart
//
// Sprint 48: workflow editor.  Opens with a team_spec (nodes_v1 form)
// pre-loaded; user can drag agent nodes from the left rail palette,
// edit per-node config, draw edges with conditions, and Save to
// PATCH /tasks/{id}/team_spec.  Save does NOT trigger dispatch — the
// user must Approve the proposal card in #general afterward.
import 'package:flutter/material.dart';
import '../api.dart';

class WorkflowEditorScreen extends StatefulWidget {
  final TallyOrchClient client;
  final String taskId;
  final Map<String, dynamic> initialTeamSpec;
  const WorkflowEditorScreen({
    super.key,
    required this.client,
    required this.taskId,
    required this.initialTeamSpec,
  });

  @override
  State<WorkflowEditorScreen> createState() => _WorkflowEditorScreenState();
}

class _WorkflowEditorScreenState extends State<WorkflowEditorScreen> {
  late Map<String, dynamic> _spec;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _spec = Map<String, dynamic>.from(widget.initialTeamSpec);
    _spec['nodes'] ??= [];
    _spec['edges'] ??= [];
    _spec['format'] = 'nodes_v1';
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.client.updateTaskTeamSpec(taskId: widget.taskId, teamSpec: _spec);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Edit team for ${widget.taskId.substring(0, 8)}'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save'),
          ),
        ],
      ),
      body: Row(
        children: [
          // Left rail: agent role palette (B5 fills in real roles)
          SizedBox(
            width: 200,
            child: Container(
              color: const Color(0xFF2B2D31),
              child: const _PalettePlaceholder(),
            ),
          ),
          // Center: vyuh_node_flow canvas (B5 wires in)
          Expanded(child: _CanvasPlaceholder(spec: _spec, onChange: (s) => setState(() => _spec = s))),
        ],
      ),
    );
  }
}

class _PalettePlaceholder extends StatelessWidget {
  const _PalettePlaceholder();
  @override
  Widget build(BuildContext context) {
    return const Center(child: Text('Palette\n(B5)', textAlign: TextAlign.center));
  }
}

class _CanvasPlaceholder extends StatelessWidget {
  final Map<String, dynamic> spec;
  final void Function(Map<String, dynamic>) onChange;
  const _CanvasPlaceholder({required this.spec, required this.onChange});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'Canvas placeholder.\nnodes: ${(spec['nodes'] as List?)?.length ?? 0}\nedges: ${(spec['edges'] as List?)?.length ?? 0}',
        textAlign: TextAlign.center,
      ),
    );
  }
}
```

This is a scaffold — Task B5 wires in `vyuh_node_flow`'s `FlowEditor` widget. The scaffold gets a `flutter analyze` pass.

- [ ] **Step 3: Compile-check**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app && /home/nick/.local/flutter/bin/flutter analyze lib/screens/workflow_editor.dart
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add tally_coding_app/pubspec.yaml tally_coding_app/pubspec.lock tally_coding_app/lib/screens/workflow_editor.dart
git commit -m "[s48] WorkflowEditorScreen: scaffold + vyuh_node_flow dependency"
```

### Task B5: WorkflowEditorScreen — wire vyuh_node_flow + palette + per-node config

**Files:**
- Modify: `tally_coding_app/lib/screens/workflow_editor.dart`

- [ ] **Step 1: Read vyuh_node_flow's API**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app && cat .dart_tool/pub-cache/hosted/pub.dev/vyuh_node_flow-*/lib/vyuh_node_flow.dart 2>/dev/null || find ~/.pub-cache -name "vyuh_node_flow*" -type d | head -3
```

Locate the package source. Read its main types: `FlowEditor`, `Node`, `Edge`, `NodeBuilder`, `Controller`, etc. Adapt the placeholder canvas in `workflow_editor.dart` to render an actual `FlowEditor` with:

- A `Controller<MyNodeData, MyEdgeData>` seeded from `widget.initialTeamSpec.nodes/edges`
- Node typed data `MyNodeData = {id, kind, role, model, spec, worker_affinity, tool_allowlist}`
- Edge typed data `MyEdgeData = {condition, max_iterations}`
- On change: serialize controller state back to `_spec` (the JSON we POST)

- [ ] **Step 2: Implement**

Replace `_CanvasPlaceholder` with a real `FlowEditor`. Add palette items: 2 entries (Agent, Output). Drag-from-palette adds nodes. Tap-on-node opens a `_NodeConfigDialog` showing fields (role dropdown, model text field, spec textarea, worker_affinity dropdown).

This is the highest-effort step in Sprint 48. Reserve ~8h. Implementer should:
- Read package docs/examples in pub-cache
- Build a minimal `FlowEditor` integration that round-trips `_spec` → controller → user edits → `_spec` JSON
- Skip per-edge config in B5 (B6 adds it)
- Skip tool_allowlist UI (defer; field accepts JSON string for now)

Test by `/home/nick/.local/flutter/bin/flutter run -d linux` (or web), open the editor with a fixture team_spec, drag a node, save, verify the PATCH request body in the network log.

- [ ] **Step 3: Compile-check + commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app && /home/nick/.local/flutter/bin/flutter analyze lib/screens/workflow_editor.dart
```

```bash
git add tally_coding_app/lib/screens/workflow_editor.dart
git commit -m "[s48] WorkflowEditorScreen: wire vyuh_node_flow + agent palette + per-node config"
```

### Task B6: Per-edge config (condition dropdown)

**Files:**
- Modify: `tally_coding_app/lib/screens/workflow_editor.dart`

- [ ] **Step 1: Add edge tap handler**

In `workflow_editor.dart`, the FlowEditor's `onEdgeTap` callback opens a `_EdgeConfigDialog` showing:

```dart
DropdownButtonFormField<String>(
  value: edge.condition ?? 'always',
  items: const [
    DropdownMenuItem(value: 'always', child: Text('Always')),
    DropdownMenuItem(value: 'if_succeeded', child: Text('If predecessor succeeded')),
    DropdownMenuItem(value: 'if_failed', child: Text('If predecessor failed')),
  ],
  onChanged: (v) => setState(() => edge.condition = v),
),
// max_iterations field (only show if edge.to is upstream of edge.from — back-edge)
```

Persist edge metadata in the `_spec['edges']` list on save.

- [ ] **Step 2: Compile-check + commit**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app && /home/nick/.local/flutter/bin/flutter analyze
```

```bash
git add tally_coding_app/lib/screens/workflow_editor.dart
git commit -m "[s48] WorkflowEditorScreen: per-edge condition + max_iterations"
```

### Task B7: Hook TeamProposalCard actions to task_channel + #general

**Files:**
- Modify: `tally_coding_app/lib/screens/task_channel.dart` (Sprint 47's MessageFeed mount)
- Modify: `tally_coding_app/lib/screens/discord_shell.dart` (#general view)

- [ ] **Step 1: Find where MessageFeed is mounted**

```bash
grep -n "MessageFeed(" /home/nick/Projects/pronoic/tally-coding/tally_coding_app/lib/screens/*.dart
```

Both task_channel.dart (already mounted from Sprint 47 B7) and discord_shell.dart's #general view (if it has one) mount MessageFeed.

- [ ] **Step 2: Add `onTeamProposalAction` handlers**

In #general's MessageFeed mount, add:

```dart
MessageFeed(
  messages: _messages,
  onAnswerPrompt: ...,
  onTeamProposalAction: (taskId, action) async {
    switch (action) {
      case 'approve':
        try {
          await widget.client.approveTask(taskId: taskId);
          if (mounted) {
            // Refresh feed to show updated card state
            await _loadMessages();
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Approve failed: $e')));
          }
        }
        break;
      case 'edit':
        // Fetch task to get current team_spec
        // (or: extract from the message payload directly)
        final payload = _findTeamProposalPayload(taskId);
        if (payload == null) return;
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => WorkflowEditorScreen(
            client: widget.client,
            taskId: taskId,
            initialTeamSpec: Map<String, dynamic>.from(payload['team_spec'] as Map),
          )),
        );
        if (mounted) await _loadMessages();
        break;
      case 'cancel':
        try {
          await widget.client.cancelTask(taskId: taskId);
          if (mounted) await _loadMessages();
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Cancel failed: $e')));
          }
        }
        break;
    }
  },
),
```

Helper:

```dart
Map<String, dynamic>? _findTeamProposalPayload(String taskId) {
  for (final m in _messages) {
    if (m['kind'] != 'team_proposal') continue;
    try {
      final p = jsonDecode(m['payload_json'] as String) as Map<String, dynamic>;
      if (p['task_id'] == taskId) return p;
    } catch (_) {}
  }
  return null;
}
```

(Add `import '../widgets/workflow_editor.dart';` if not present in discord_shell.dart.)

- [ ] **Step 3: Compile-check**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app && /home/nick/.local/flutter/bin/flutter analyze
```

Expected: no new errors.

- [ ] **Step 4: Commit**

```bash
git add tally_coding_app/lib/screens/discord_shell.dart tally_coding_app/lib/screens/task_channel.dart
git commit -m "[s48] discord_shell + task_channel: wire team_proposal actions to API + editor"
```

### Task B8: Remove team_builder.dart + nav cleanup

**Files:**
- Delete: `tally_coding_app/lib/screens/team_builder.dart`
- Modify: `tally_coding_app/lib/screens/discord_shell.dart`

- [ ] **Step 1: Find call sites**

```bash
grep -rn "team_builder\|TeamBuilderScreen" tally_coding_app/lib | head
```

Expected: 2 hits — `discord_shell.dart` import + navigation entry.

- [ ] **Step 2: Remove**

```bash
rm /home/nick/Projects/pronoic/tally-coding/tally_coding_app/lib/screens/team_builder.dart
```

In `discord_shell.dart`:
- Remove `import 'team_builder.dart';`
- Remove the line that pushes `TeamBuilderScreen(...)` (around line 175)
- If the ⚙ tile becomes orphaned (no other use), hide it for Sprint 48 (it ships back in Sprint 50 with the settings screen)

- [ ] **Step 3: Compile-check + analyze**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app && /home/nick/.local/flutter/bin/flutter analyze
```

Expected: no errors.

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app && /home/nick/.local/flutter/bin/flutter test
```

Expected: no NEW failures beyond the pre-existing `widget_test.dart` failure tracked from Sprint 47.

- [ ] **Step 4: Commit**

```bash
git add tally_coding_app/lib/screens/team_builder.dart tally_coding_app/lib/screens/discord_shell.dart
git commit -m "[s48] remove team_builder.dart (Sprint 30 kanban UI superseded by WorkflowEditorScreen)"
```

### Task B9: Phase B smoke

**Files:** none — verify integration.

- [ ] **Step 1: Run all flutter tests**

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter test 2>&1 | tail -5
```

Expected: all PASS except the pre-existing widget_test.dart failure.

- [ ] **Step 2: Boot the app locally + manual smoke**

```bash
cd /home/nick/Projects/pronoic/tally-coding/tally_coding_app && /home/nick/.local/flutter/bin/flutter run -d linux
```

(Or web; whichever is more convenient.)

Manual checklist:
- Submit a task via existing entry → see TeamProposalCard in #general
- Click Edit → editor opens with the team
- Drag an agent node onto canvas → save → return to #general
- Click Approve → see task channel appear in left rail
- Open task channel → see the new task running

- [ ] **Step 3: Tag**

```bash
git tag s48-phase-b-done
```

---

## Phase C — Deploy + sprint completion (3 tasks, ~5h)

### Task C1: Build + push tally-orch:v28

**Files:**
- Modify: `services/orchestrator/Dockerfile` — LABEL version
- Modify: `services/orchestrator/docker-compose.yml` — image tag

- [ ] **Step 1: Update LABEL**

In `services/orchestrator/Dockerfile`:

```
LABEL org.opencontainers.image.version=v28
LABEL org.opencontainers.image.description="Tally Coding orchestrator (Sprint 48: workflow editor + pre-dispatch team confirm)"
```

In `services/orchestrator/docker-compose.yml`:

```yaml
image: ghcr.io/nicholasraimbault/tally-orch:v28
```

- [ ] **Step 2: Build + push**

```bash
cd /home/nick/Projects/pronoic/tally-coding
/usr/bin/docker build -t ghcr.io/nicholasraimbault/tally-orch:v28 -f services/orchestrator/Dockerfile .
/usr/bin/docker push ghcr.io/nicholasraimbault/tally-orch:v28
```

- [ ] **Step 3: Commit**

```bash
git add services/orchestrator/Dockerfile services/orchestrator/docker-compose.yml
git commit -m "[s48] image: bump to v28"
```

### Task C2: Deploy to Phala + live smoke

- [ ] **Step 1: Phala roll**

```bash
cd /home/nick/Projects/pronoic/tally-coding/services/orchestrator
/home/nick/.npm-global/bin/phala deploy --cvm-id app_c3b5481b3f33551af6270a21145df613160bf063 --compose docker-compose.yml --env .env.prod --wait
```

Expected: ~60s, CVM ready.

- [ ] **Step 2: Live smoke**

```bash
export TT=$(grep -E "^TALLY_API_TOKEN=" /home/nick/Projects/pronoic/tally-coding/services/orchestrator/.env.prod | head -1 | cut -d= -f2-)
# 1. health
curl -s https://tally.pronoic.dev/health | jq .
# 2. submit task — expect status='proposed'
TASK=$(curl -sX POST -H "Authorization: Bearer $TT" -H "content-type: application/json" -d '{"description":"s48 smoke"}' https://tally.pronoic.dev/tasks | jq -r '.task_id // .id')
echo "task_id: $TASK"
# 3. team_proposal landed
curl -s -H "Authorization: Bearer $TT" "https://tally.pronoic.dev/channels?workspace_id=1" | jq '.channels[]|select(.kind=="general")|.id' | head -1
# (read messages via that channel id)
# 4. approve
curl -sX POST -H "Authorization: Bearer $TT" "https://tally.pronoic.dev/tasks/$TASK/approve" | jq .
# 5. task channel created
curl -s -H "Authorization: Bearer $TT" "https://tally.pronoic.dev/channels?workspace_id=1" | jq '[.channels[]|select(.task_id=="'$TASK'")]|length'
```

Expected: each step 200; final length == 1.

- [ ] **Step 3: Tag deploy**

```bash
git tag s48-deployed-v28
```

### Task C3: Sprint completion doc

**Files:**
- Create: `docs/SPRINT-48-COMPLETE.md`

- [ ] **Step 1: Write**

Follow the structure of `docs/SPRINT-47-COMPLETE.md`. Cover: backend changes (status enum, team_spec_compat, endpoints, executor), frontend changes (TeamProposalCard, WorkflowEditorScreen, team_builder removal), deploy details, deferred items.

- [ ] **Step 2: Commit + tag**

```bash
git add docs/SPRINT-48-COMPLETE.md
git commit -m "[s48] sprint completion doc"
git tag s48-phase-c-done
git tag s48-complete
```

---

## Self-review

**1. Spec coverage:**

| Spec requirement | Tasks |
|---|---|
| `team_spec` dual-format parser | A2 |
| `proposed` + `cancelled` statuses | A1, A4 |
| Defer dispatch behind team_proposal | A6 |
| POST /tasks/{id}/approve | A7 |
| PATCH /tasks/{id}/team_spec | A8 |
| POST /tasks/{id}/cancel | A9 |
| `nodes_v1` workflow executor | A10 |
| `messages.kind='team_proposal'` + insert helper | A5 |
| api.dart additions | B1 |
| TeamProposalCard widget | B2 |
| MessageFeed dispatch | B3 |
| WorkflowEditorScreen (vyuh_node_flow) | B4, B5, B6 |
| Hook actions in #general | B7 |
| Remove team_builder.dart | B8 |
| Deploy v28 | C1, C2 |
| Completion doc | C3 |

All spec items covered.

**2. Placeholder scan:** No TBDs.  A10 has a known-deferred area (max_iterations in nodes_v1 executor — parser accepts but executor doesn't cycle).  A5 + B5 have full code or explicit "implementer should adapt" guidance.

**3. Type consistency:** Verified — `team_spec.format='nodes_v1'`, `messages.kind='team_proposal'`, `tasks.status` enum extensions, `agents.iteration_idx` column.  `TeamProposalCard` action values (approve / edit / cancel) match the route names.

Plan ready to execute.
