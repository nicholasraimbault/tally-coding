# Sprint 47 — Chat Foundation + Permission Groundwork Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make task channels real bidirectional chat (users intervene mid-task, agents see user messages on their next LLM turn) and land the workspace/permission/messages schema that sprints 48-50 stack on.

**Architecture:** Additive SQLite schema migration adds 5 tables (`workspaces`, `workspace_members`, `channels`, `channel_members`, `messages`). 6 new REST routes + 1 new WebSocket event type extend the existing FastAPI surface. The orchestrator's per-agent context loop is extended to prepend new channel messages to each LLM turn so user-typed text reaches running agents. Flutter's task_channel.dart event-stream renderer is replaced with a real chat feed (bubbles + composer + WebSocket live updates).

**Tech Stack:** Python 3.12 (FastAPI, sqlite3, httpx, websockets), Flutter 3.6+ (web_socket_channel for client-side WS — already in pubspec from Sprint 46). Single Phala TDX CVM image `tally-orch:v27` deploys the orchestrator.

---

## Scope check

This is one focused sprint covering one sub-project from the Sprints 47-50 design (`docs/superpowers/specs/2026-05-20-discord-shaped-workspace-design.md`). Subsequent sprints (workflow editor, persistent agents, custom channels) are separate plans.

## File structure

### Files to create

```
services/orchestrator/tally_orchestrator/channels.py          ~200 lines  Channel/message domain logic + permission resolution
services/orchestrator/tests/test_workspace_schema.py          ~60 lines   Schema + backfill verification
services/orchestrator/tests/test_channels_db.py               ~120 lines  Db method tests
services/orchestrator/tests/test_messages_routes.py           ~150 lines  POST/GET/PATCH /channels/{id}/messages
services/orchestrator/tests/test_channels_routes.py           ~100 lines  GET /channels + member CRUD
services/orchestrator/tests/test_permission_middleware.py     ~80 lines   Role resolution unit tests
services/orchestrator/tests/test_agent_context_inclusion.py   ~70 lines   Agent-sees-user-message integration
services/orchestrator/tests/test_message_ws.py                ~80 lines   WebSocket new_message event delivery

tally_coding_app/lib/widgets/message_feed.dart                ~250 lines  Scrollable chat bubble list
tally_coding_app/lib/widgets/message_composer.dart            ~120 lines  TextField + send button
tally_coding_app/lib/widgets/message_bubble.dart              ~150 lines  Single message rendering (author/kind aware)
tally_coding_app/lib/widgets/interactive_prompt_card.dart     ~100 lines  Renders kind=interactive_prompt with action buttons
tally_coding_app/lib/services/channel_ws.dart                 ~130 lines  WebSocket subscription helper for new_message events
tally_coding_app/test/message_feed_test.dart                  ~80 lines
tally_coding_app/test/message_composer_test.dart              ~60 lines
tally_coding_app/test/interactive_prompt_card_test.dart       ~70 lines
```

### Files to modify

```
services/orchestrator/tally_orchestrator/service.py           SCHEMA additions, Db methods, 6 new routes, WebSocket event handler extension, agent context inclusion in _record_architect_cost + _handle_result_event paths
services/orchestrator/tally_orchestrator/architect.py         No changes (Tally tools added in Sprint 48, not 47)
services/orchestrator/Dockerfile                              Bump version label to v27

tally_coding_app/lib/api.dart                                 ~8 new methods (listChannels, getMessages, postMessage, patchMessage, postChannelRead, patchChannelMemberRoleOverride, subscribeToChannel, helper types)
tally_coding_app/lib/screens/task_channel.dart                Replace event-stream renderer with MessageFeedWidget; subscribe to channel WebSocket; cap-abort dialog + cost ticker continue to render from Sprint 46
tally_coding_app/lib/widgets/channel_header.dart              Extend to show member avatars + settings cog

docs/SPRINT-47-COMPLETE.md                                    New
```

---

## Phase A — Orchestrator backend (12 tasks, ~25h)

### Task A1: Schema migration — 5 new tables

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` SCHEMA constant (~line 77) + Db.__init__ (~line 540)
- Create: `services/orchestrator/tests/test_workspace_schema.py`

- [ ] **Step 1: Write the failing test**

Create `services/orchestrator/tests/test_workspace_schema.py`:

```python
"""Sprint 47: schema migration adds 5 chat-foundation tables."""
from tally_orchestrator.service import Db


def test_workspace_tables_present(db: Db):
    names = {row[0] for row in db._conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table'"
    )}
    assert {
        "workspaces",
        "workspace_members",
        "channels",
        "channel_members",
        "messages",
    }.issubset(names)


def test_workspaces_columns(db: Db):
    cols = {row[1] for row in db._conn.execute("PRAGMA table_info(workspaces)")}
    assert {"id", "name", "owner_user_id", "plan_slug", "created_at", "settings_json"}.issubset(cols)


def test_workspace_members_columns(db: Db):
    cols = {row[1] for row in db._conn.execute("PRAGMA table_info(workspace_members)")}
    assert {"id", "workspace_id", "member_kind", "user_id", "persistent_agent_id", "role", "joined_at"}.issubset(cols)


def test_channels_columns(db: Db):
    cols = {row[1] for row in db._conn.execute("PRAGMA table_info(channels)")}
    assert {"id", "workspace_id", "kind", "name", "task_id", "persistent_agent_id", "auto_jump_in_for_tally", "created_at", "archived_at"}.issubset(cols)


def test_channel_members_columns(db: Db):
    cols = {row[1] for row in db._conn.execute("PRAGMA table_info(channel_members)")}
    assert {"id", "channel_id", "member_kind", "user_id", "persistent_agent_id", "task_agent_id", "role_override", "joined_at", "last_read_message_id"}.issubset(cols)


def test_messages_columns(db: Db):
    cols = {row[1] for row in db._conn.execute("PRAGMA table_info(messages)")}
    assert {"id", "channel_id", "author_kind", "author_user_id", "author_agent_id", "kind", "payload_json", "reply_to_id", "created_at", "edited_at"}.issubset(cols)


def test_migration_idempotent(tmp_db_path: str):
    """Opening the same DB twice doesn't error on duplicate-table."""
    Db(tmp_db_path)
    Db(tmp_db_path)
    Db(tmp_db_path)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_schema.py -v
```

Expected: 7 FAILs (tables don't exist).

- [ ] **Step 3: Add 5 new tables to SCHEMA constant**

In `service.py` SCHEMA block, append BEFORE the closing `"""`:

```sql
CREATE TABLE IF NOT EXISTS workspaces (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    owner_user_id TEXT NOT NULL,
    plan_slug TEXT NOT NULL DEFAULT 'free',
    stripe_customer_id TEXT,
    created_at REAL NOT NULL,
    settings_json TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_workspaces_owner ON workspaces(owner_user_id);

CREATE TABLE IF NOT EXISTS workspace_members (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    workspace_id INTEGER NOT NULL,
    member_kind TEXT NOT NULL,
    user_id TEXT,
    persistent_agent_id INTEGER,
    role TEXT NOT NULL,
    joined_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_workspace_members ON workspace_members(workspace_id, role);
CREATE INDEX IF NOT EXISTS idx_workspace_members_user ON workspace_members(user_id, workspace_id);

CREATE TABLE IF NOT EXISTS channels (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    workspace_id INTEGER NOT NULL,
    kind TEXT NOT NULL,
    name TEXT NOT NULL,
    task_id TEXT,
    persistent_agent_id INTEGER,
    auto_jump_in_for_tally INTEGER NOT NULL DEFAULT 0,
    created_at REAL NOT NULL,
    archived_at REAL
);
CREATE INDEX IF NOT EXISTS idx_channels_ws ON channels(workspace_id, kind, archived_at);
CREATE INDEX IF NOT EXISTS idx_channels_task ON channels(task_id) WHERE task_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS channel_members (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    channel_id INTEGER NOT NULL,
    member_kind TEXT NOT NULL,
    user_id TEXT,
    persistent_agent_id INTEGER,
    task_agent_id INTEGER,
    role_override TEXT,
    joined_at REAL NOT NULL,
    last_read_message_id INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_channel_members ON channel_members(channel_id);
CREATE INDEX IF NOT EXISTS idx_channel_members_user ON channel_members(user_id, channel_id);

CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    channel_id INTEGER NOT NULL,
    author_kind TEXT NOT NULL,
    author_user_id TEXT,
    author_agent_id INTEGER,
    kind TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    reply_to_id INTEGER,
    created_at REAL NOT NULL,
    edited_at REAL
);
CREATE INDEX IF NOT EXISTS idx_messages_channel ON messages(channel_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_messages_channel_id_desc ON messages(channel_id, id DESC);
```

`CREATE TABLE IF NOT EXISTS` makes these idempotent. No try/except blocks needed.

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_schema.py -v
```

Expected: 7 PASS.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_workspace_schema.py
git commit -m "[s47] schema: workspaces, workspace_members, channels, channel_members, messages"
```

### Task A2: Backfill default workspace + admin membership + per-task channels

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — Db.__init__ adds backfill block

- [ ] **Step 1: Write the failing test**

Append to `services/orchestrator/tests/test_workspace_schema.py`:

```python
def test_backfill_admin_workspace_created(db: Db):
    """On first Db init, admin user gets a default workspace + owner membership."""
    rows = db._conn.execute(
        "SELECT id, name, owner_user_id FROM workspaces WHERE owner_user_id='admin'"
    ).fetchall()
    assert len(rows) == 1, f"expected 1 admin workspace, got {len(rows)}"
    ws_id, ws_name, owner = rows[0]
    assert owner == "admin"
    assert "admin" in ws_name.lower()

    members = db._conn.execute(
        "SELECT user_id, role FROM workspace_members "
        "WHERE workspace_id=? AND member_kind='human'",
        (ws_id,),
    ).fetchall()
    assert (("admin", "owner")) in [tuple(m) for m in members]


def test_backfill_creates_general_channel(db: Db):
    """Admin workspace gets an auto-created #general channel."""
    rows = db._conn.execute(
        "SELECT c.id, c.name, c.kind FROM channels c "
        "JOIN workspaces w ON c.workspace_id=w.id "
        "WHERE w.owner_user_id='admin' AND c.kind='general'"
    ).fetchall()
    assert len(rows) == 1


def test_backfill_existing_tasks_get_channels(db: Db):
    """Every existing tasks row gets a channels row of kind='task'."""
    # Pre-create some tasks (simulating real prod state)
    db.create_task("test task 1", team_spec=None, user_id="admin")
    db.create_task("test task 2", team_spec=None, user_id="admin")
    # Re-open Db to trigger backfill on the now-populated tasks table
    db.__class__(db.path)  # second open

    cnt = db._conn.execute("SELECT COUNT(*) FROM channels WHERE kind='task'").fetchone()[0]
    tasks_cnt = db._conn.execute("SELECT COUNT(*) FROM tasks").fetchone()[0]
    assert cnt == tasks_cnt, f"expected one channel per task; got {cnt} channels for {tasks_cnt} tasks"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_schema.py::test_backfill_admin_workspace_created -v
```

Expected: FAIL (no backfill yet; the admin workspace isn't auto-created).

- [ ] **Step 3: Add backfill block to Db.__init__**

In `service.py` `Db.__init__`, after the existing migration ALTER blocks and BEFORE `self._seed_agent_roles()`, add:

```python
        # Sprint 47: backfill workspaces + channels for pre-existing data.
        # Idempotent — only creates rows when they're missing.
        self._backfill_workspaces_and_channels()
```

Then add the method (placed near `_seed_agent_roles`):

```python
    def _backfill_workspaces_and_channels(self) -> None:
        """Sprint 47: ensure every distinct user_id in tasks/quotas has a
        workspace + owner membership + a #general channel + a #backlog
        channel.  Then ensure every existing task has a `task` channel.
        Idempotent: safe to run on every Db open."""
        now = time.time()
        # 1. Discover distinct user_ids that need a workspace.  Sources:
        #    - tasks.user_id (Sprint 32+)
        #    - quotas.user_id (Sprint 33+)
        #    Default user_id 'admin' always gets one (so admin smoke tests
        #    work on a fresh empty DB).
        users = {row[0] for row in self._conn.execute(
            "SELECT DISTINCT user_id FROM tasks WHERE user_id IS NOT NULL"
        )}
        users.update(row[0] for row in self._conn.execute(
            "SELECT DISTINCT user_id FROM quotas WHERE user_id IS NOT NULL"
        ))
        users.add("admin")
        # 2. For each user_id without a workspace, create one + owner membership + general/backlog channels.
        for user_id in users:
            existing = self._conn.execute(
                "SELECT id FROM workspaces WHERE owner_user_id=?", (user_id,)
            ).fetchone()
            if existing:
                continue
            cur = self._conn.execute(
                "INSERT INTO workspaces (name, owner_user_id, plan_slug, created_at) "
                "VALUES (?, ?, ?, ?)",
                (f"{user_id}'s workspace", user_id, "unlimited" if user_id == "admin" else "free", now),
            )
            ws_id = cur.lastrowid
            self._conn.execute(
                "INSERT INTO workspace_members (workspace_id, member_kind, user_id, role, joined_at) "
                "VALUES (?, 'human', ?, 'owner', ?)",
                (ws_id, user_id, now),
            )
            for kind, name in (("general", "general"), ("backlog", "backlog")):
                ch_cur = self._conn.execute(
                    "INSERT INTO channels (workspace_id, kind, name, created_at) "
                    "VALUES (?, ?, ?, ?)",
                    (ws_id, kind, name, now),
                )
                self._conn.execute(
                    "INSERT INTO channel_members (channel_id, member_kind, user_id, joined_at) "
                    "VALUES (?, 'human', ?, ?)",
                    (ch_cur.lastrowid, user_id, now),
                )
        # 3. For each existing task row without a task channel, create one.
        task_rows = self._conn.execute(
            "SELECT t.id, t.user_id, t.status, t.created_at, t.updated_at "
            "FROM tasks t LEFT JOIN channels c ON c.task_id=t.id "
            "WHERE c.id IS NULL"
        ).fetchall()
        for task_id, user_id, status, created_at, updated_at in task_rows:
            user_id = user_id or "admin"
            ws_row = self._conn.execute(
                "SELECT id FROM workspaces WHERE owner_user_id=?", (user_id,)
            ).fetchone()
            if ws_row is None:
                continue  # shouldn't happen given step 2 ran first
            archived_at = updated_at if status in ("completed", "failed") else None
            self._conn.execute(
                "INSERT INTO channels (workspace_id, kind, name, task_id, created_at, archived_at) "
                "VALUES (?, 'task', ?, ?, ?, ?)",
                (ws_row[0], f"task-{task_id[:8]}", task_id, created_at, archived_at),
            )
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_schema.py -v
```

Expected: 10 PASS.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_workspace_schema.py
git commit -m "[s47] backfill: workspaces + general/backlog channels + task channels for existing data"
```

### Task A3: New `channels.py` module — permission resolution + Db method helpers

**Files:**
- Create: `services/orchestrator/tally_orchestrator/channels.py`
- Create: `services/orchestrator/tests/test_permission_middleware.py`

- [ ] **Step 1: Write the failing tests**

Create `services/orchestrator/tests/test_permission_middleware.py`:

```python
"""Sprint 47: role resolution + permission predicates."""
from tally_orchestrator.channels import (
    resolve_effective_role,
    can_post_in_channel,
    can_dispatch_task,
    can_manage_members,
)


def test_owner_resolution_no_override(db):
    db._conn.execute("INSERT INTO workspaces (name, owner_user_id, plan_slug, created_at) VALUES ('w', 'u1', 'free', 0)")
    ws_id = db._conn.execute("SELECT id FROM workspaces WHERE owner_user_id='u1'").fetchone()[0]
    db._conn.execute("INSERT INTO workspace_members (workspace_id, member_kind, user_id, role, joined_at) VALUES (?, 'human', 'u1', 'owner', 0)", (ws_id,))
    db._conn.execute("INSERT INTO channels (workspace_id, kind, name, created_at) VALUES (?, 'general', 'general', 0)", (ws_id,))
    ch_id = db._conn.execute("SELECT id FROM channels WHERE workspace_id=?", (ws_id,)).fetchone()[0]
    db._conn.execute("INSERT INTO channel_members (channel_id, member_kind, user_id, joined_at) VALUES (?, 'human', 'u1', 0)", (ch_id,))

    role = resolve_effective_role(db, channel_id=ch_id, user_id="u1")
    assert role == "owner"


def test_channel_override_promotes_member(db):
    db._conn.execute("INSERT INTO workspaces (name, owner_user_id, plan_slug, created_at) VALUES ('w', 'u1', 'free', 0)")
    ws_id = db._conn.execute("SELECT id FROM workspaces").fetchone()[0]
    db._conn.execute("INSERT INTO workspace_members (workspace_id, member_kind, user_id, role, joined_at) VALUES (?, 'human', 'u2', 'member', 0)", (ws_id,))
    db._conn.execute("INSERT INTO channels (workspace_id, kind, name, created_at) VALUES (?, 'custom', 'sec', 0)", (ws_id,))
    ch_id = db._conn.execute("SELECT id FROM channels").fetchone()[0]
    db._conn.execute("INSERT INTO channel_members (channel_id, member_kind, user_id, role_override, joined_at) VALUES (?, 'human', 'u2', 'channel_admin', 0)", (ch_id,))

    role = resolve_effective_role(db, channel_id=ch_id, user_id="u2")
    assert role == "channel_admin"


def test_non_member_resolution_none(db):
    db._conn.execute("INSERT INTO workspaces (name, owner_user_id, plan_slug, created_at) VALUES ('w', 'u1', 'free', 0)")
    ws_id = db._conn.execute("SELECT id FROM workspaces").fetchone()[0]
    db._conn.execute("INSERT INTO channels (workspace_id, kind, name, created_at) VALUES (?, 'general', 'g', 0)", (ws_id,))
    ch_id = db._conn.execute("SELECT id FROM channels").fetchone()[0]

    role = resolve_effective_role(db, channel_id=ch_id, user_id="stranger")
    assert role is None


def test_can_post_member_yes_read_only_no(db):
    assert can_post_in_channel("owner") is True
    assert can_post_in_channel("admin") is True
    assert can_post_in_channel("manager") is True
    assert can_post_in_channel("member") is True
    assert can_post_in_channel("channel_admin") is True
    assert can_post_in_channel("read_only") is False
    assert can_post_in_channel(None) is False


def test_can_dispatch_task_member_or_above(db):
    assert can_dispatch_task("owner") is True
    assert can_dispatch_task("admin") is True
    assert can_dispatch_task("manager") is True
    assert can_dispatch_task("member") is True
    assert can_dispatch_task("read_only") is False
    assert can_dispatch_task(None) is False


def test_can_manage_members_admin_only(db):
    assert can_manage_members("owner") is True
    assert can_manage_members("admin") is True
    assert can_manage_members("manager") is False
    assert can_manage_members("member") is False
    assert can_manage_members("channel_admin") is False
    assert can_manage_members(None) is False
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_permission_middleware.py -v
```

Expected: 6 FAILs (module doesn't exist).

- [ ] **Step 3: Write `channels.py`**

```python
# services/orchestrator/tally_orchestrator/channels.py
"""Sprint 47: channel/message domain logic + permission resolution.

Permission model (per `docs/superpowers/specs/2026-05-20-discord-shaped-workspace-design.md`
§"Permission model"):

- `workspace_members.role` is workspace-wide; values: owner, admin, manager, member,
  tally, agent.
- `channel_members.role_override` overrides for that channel; values include
  channel_admin and read_only in addition to the workspace roles.
- Effective role for `(channel_id, user_id)` is the override if set, else the
  workspace role.
- Permission predicates (`can_post_in_channel`, `can_dispatch_task`, etc.) take
  the effective role and return bool.

Non-member access returns None (caller maps to 403).
"""
from __future__ import annotations

import json
import time
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .service import Db


def resolve_effective_role(db: "Db", *, channel_id: int, user_id: str) -> str | None:
    """Return the effective role for (user, channel) or None if not a member.

    Resolution order:
      1. channel_members.role_override if set
      2. workspace_members.role otherwise
      3. None if no membership exists
    """
    # First: does the user have a channel_member row?
    row = db._conn.execute(
        "SELECT cm.role_override, c.workspace_id "
        "FROM channel_members cm JOIN channels c ON cm.channel_id=c.id "
        "WHERE cm.channel_id=? AND cm.user_id=?",
        (channel_id, user_id),
    ).fetchone()
    if row is None:
        return None
    role_override, ws_id = row
    if role_override:
        return role_override
    # Fall through to workspace role
    ws_role = db._conn.execute(
        "SELECT role FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (ws_id, user_id),
    ).fetchone()
    return ws_role[0] if ws_role else None


_POST_ALLOWED = {"owner", "admin", "manager", "member", "channel_admin", "tally", "agent"}
_DISPATCH_ALLOWED = {"owner", "admin", "manager", "member"}
_MANAGE_MEMBERS_ALLOWED = {"owner", "admin"}


def can_post_in_channel(role: str | None) -> bool:
    """True if a user with this role can POST messages in the channel."""
    return role in _POST_ALLOWED


def can_dispatch_task(role: str | None) -> bool:
    """True if a user with this role can dispatch a new task in #general."""
    return role in _DISPATCH_ALLOWED


def can_manage_members(role: str | None) -> bool:
    """True if a user with this role can invite/remove/role-override members."""
    return role in _MANAGE_MEMBERS_ALLOWED


def insert_message(
    db: "Db",
    *,
    channel_id: int,
    author_kind: str,
    author_user_id: str | None = None,
    author_agent_id: int | None = None,
    kind: str = "text",
    payload: dict | None = None,
    reply_to_id: int | None = None,
) -> int:
    """Insert a message row; return its id."""
    cur = db._conn.execute(
        "INSERT INTO messages "
        "(channel_id, author_kind, author_user_id, author_agent_id, kind, payload_json, reply_to_id, created_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (
            channel_id, author_kind, author_user_id, author_agent_id,
            kind, json.dumps(payload or {}), reply_to_id, time.time(),
        ),
    )
    return int(cur.lastrowid or 0)


def list_messages(
    db: "Db",
    *,
    channel_id: int,
    limit: int = 50,
    since_id: int | None = None,
) -> list[dict]:
    """Return recent messages in a channel, newest first.

    `since_id` (if given) returns only messages with id > since_id (used by
    clients catching up after WebSocket reconnect).
    """
    where = ["channel_id=?"]
    params: list = [channel_id]
    if since_id is not None:
        where.append("id > ?")
        params.append(since_id)
    params.append(limit)
    rows = db._conn.execute(
        f"SELECT id, channel_id, author_kind, author_user_id, author_agent_id, "
        f"kind, payload_json, reply_to_id, created_at, edited_at "
        f"FROM messages WHERE {' AND '.join(where)} ORDER BY id DESC LIMIT ?",
        params,
    ).fetchall()
    return [
        {
            "id": r[0], "channel_id": r[1], "author_kind": r[2],
            "author_user_id": r[3], "author_agent_id": r[4],
            "kind": r[5], "payload_json": r[6], "reply_to_id": r[7],
            "created_at": r[8], "edited_at": r[9],
        }
        for r in rows
    ]


def resolve_channel(db: "Db", channel_id: int) -> dict | None:
    """Return channel row as dict or None."""
    row = db._conn.execute(
        "SELECT id, workspace_id, kind, name, task_id, persistent_agent_id, "
        "auto_jump_in_for_tally, created_at, archived_at "
        "FROM channels WHERE id=?",
        (channel_id,),
    ).fetchone()
    if row is None:
        return None
    return {
        "id": row[0], "workspace_id": row[1], "kind": row[2], "name": row[3],
        "task_id": row[4], "persistent_agent_id": row[5],
        "auto_jump_in_for_tally": bool(row[6]),
        "created_at": row[7], "archived_at": row[8],
    }


def get_task_channel_id(db: "Db", task_id: str) -> int | None:
    """Lookup the channel_id for a given task_id (Sprint 47: per-task channels)."""
    row = db._conn.execute(
        "SELECT id FROM channels WHERE task_id=? AND kind='task' LIMIT 1",
        (task_id,),
    ).fetchone()
    return int(row[0]) if row else None
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/test_permission_middleware.py -v
```

Expected: 6 PASS.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/channels.py services/orchestrator/tests/test_permission_middleware.py
git commit -m "[s47] channels.py: role resolution + permission predicates + message helpers"
```

### Task A4: Pydantic models + GET /channels route

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — add request models near existing models + first route
- Create: `services/orchestrator/tests/test_channels_routes.py`

- [ ] **Step 1: Write the failing tests**

Create `services/orchestrator/tests/test_channels_routes.py`:

```python
"""Sprint 47: GET /channels + POST /channels/{id}/members routes."""
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


def test_list_channels_returns_general_and_backlog(client):
    r = client.get("/channels?workspace_id=1")
    assert r.status_code == 200
    body = r.json()
    kinds = {c["kind"] for c in body["channels"]}
    assert {"general", "backlog"}.issubset(kinds)


def test_list_channels_unknown_workspace_returns_empty(client):
    r = client.get("/channels?workspace_id=99999")
    assert r.status_code == 200
    assert r.json()["channels"] == []


def test_list_channels_filters_archived(client):
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    # Insert an archived task channel
    db._conn.execute(
        "INSERT INTO channels (workspace_id, kind, name, created_at, archived_at) "
        "VALUES (1, 'task', 'archived-task', 0, 100)"
    )
    r = client.get("/channels?workspace_id=1")
    assert r.status_code == 200
    archived = [c for c in r.json()["channels"] if c["archived_at"] is not None]
    assert len(archived) == 0  # filtered by default
    r2 = client.get("/channels?workspace_id=1&include_archived=true")
    assert r2.status_code == 200
    archived = [c for c in r2.json()["channels"] if c["archived_at"] is not None]
    assert len(archived) >= 1
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_channels_routes.py -v
```

Expected: 3 FAILs.

- [ ] **Step 3: Add Pydantic request models + GET /channels route**

In `service.py` near the existing request models (search for `class NotificationRuleRequest`), add:

```python
class ChannelMemberRoleOverrideRequest(BaseModel):
    role_override: str | None = None  # None to clear, or one of: channel_admin, read_only


class MessageCreateRequest(BaseModel):
    text: str | None = None
    kind: str = "text"  # text | interactive_prompt_response
    payload: dict | None = None
    reply_to_id: int | None = None


class MessagePatchRequest(BaseModel):
    text: str | None = None
    payload: dict | None = None
```

Then add the GET /channels route near the existing `/billing/credits` endpoint:

```python
@app.get("/channels")
async def list_workspace_channels(
    workspace_id: int,
    include_archived: bool = False,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 47: list channels in a workspace, filtered by the caller's
    visibility.  Only channels where the user is a `channel_members` row
    are returned (so private custom channels stay hidden)."""
    db: Db = state["db"]
    where = ["c.workspace_id=?"]
    params: list = [workspace_id]
    if not include_archived:
        where.append("c.archived_at IS NULL")
    # Filter to channels where the user is a member OR the channel is
    # a workspace-wide auto-channel (general / backlog).
    where.append(
        "(c.kind IN ('general', 'backlog') OR EXISTS ("
        "SELECT 1 FROM channel_members cm WHERE cm.channel_id=c.id AND cm.user_id=?))"
    )
    params.append(user.id)
    rows = db._conn.execute(
        f"SELECT c.id, c.workspace_id, c.kind, c.name, c.task_id, "
        f"c.persistent_agent_id, c.auto_jump_in_for_tally, "
        f"c.created_at, c.archived_at "
        f"FROM channels c WHERE {' AND '.join(where)} "
        f"ORDER BY c.created_at DESC",
        params,
    ).fetchall()
    return {
        "channels": [
            {
                "id": r[0], "workspace_id": r[1], "kind": r[2], "name": r[3],
                "task_id": r[4], "persistent_agent_id": r[5],
                "auto_jump_in_for_tally": bool(r[6]),
                "created_at": r[7], "archived_at": r[8],
            }
            for r in rows
        ],
    }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/test_channels_routes.py -v
```

Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_channels_routes.py
git commit -m "[s47] GET /channels — list workspace channels (member-scoped + archived filter)"
```

### Task A5: POST /channels/{id}/messages route

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Create: `services/orchestrator/tests/test_messages_routes.py`

- [ ] **Step 1: Write the failing tests**

Create `services/orchestrator/tests/test_messages_routes.py`:

```python
"""Sprint 47: POST /channels/{id}/messages route."""
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


def _admin_general_channel_id(svc) -> int:
    """Helper: lookup admin workspace's #general channel id."""
    db = svc.state["db"]
    return db._conn.execute(
        "SELECT c.id FROM channels c "
        "JOIN workspaces w ON c.workspace_id=w.id "
        "WHERE w.owner_user_id='admin' AND c.kind='general' LIMIT 1"
    ).fetchone()[0]


def test_post_message_owner_succeeds(client):
    import tally_orchestrator.service as svc
    ch_id = _admin_general_channel_id(svc)
    r = client.post(f"/channels/{ch_id}/messages", json={"text": "hello world"})
    assert r.status_code == 200
    body = r.json()
    assert body["channel_id"] == ch_id
    assert body["author_kind"] == "human"
    assert body["author_user_id"] == "admin"
    assert body["kind"] == "text"
    assert json.loads(body["payload_json"])["text"] == "hello world"


def test_post_message_non_member_returns_403(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    ch_id = _admin_general_channel_id(svc)
    # Override user to a stranger not in any workspace
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="stranger", source="clerk", plan="free", email="s@x.com",
    )
    r = client.post(f"/channels/{ch_id}/messages", json={"text": "hi"})
    assert r.status_code == 403
    assert "permission" in r.json()["detail"].lower() or "forbidden" in r.json()["detail"].lower()


def test_post_message_unknown_channel_returns_404(client):
    r = client.post("/channels/99999/messages", json={"text": "hi"})
    assert r.status_code == 404


def test_post_message_empty_text_returns_400(client):
    import tally_orchestrator.service as svc
    ch_id = _admin_general_channel_id(svc)
    r = client.post(f"/channels/{ch_id}/messages", json={"text": ""})
    assert r.status_code == 400


def test_post_message_text_persists_to_db(client):
    import tally_orchestrator.service as svc
    ch_id = _admin_general_channel_id(svc)
    r = client.post(f"/channels/{ch_id}/messages", json={"text": "persisted"})
    assert r.status_code == 200
    msg_id = r.json()["id"]
    row = svc.state["db"]._conn.execute(
        "SELECT payload_json FROM messages WHERE id=?", (msg_id,)
    ).fetchone()
    assert json.loads(row[0])["text"] == "persisted"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_messages_routes.py -v
```

Expected: 5 FAILs.

- [ ] **Step 3: Add POST /channels/{id}/messages route**

In `service.py` near the GET /channels route from Task A4, add:

```python
@app.post("/channels/{channel_id}/messages")
async def post_message(
    channel_id: int,
    body: MessageCreateRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 47: post a message in a channel.

    Permission: caller must have a role that returns True from
    `can_post_in_channel`.  Returns 403 for non-members or read-only.
    Returns 404 if channel doesn't exist.

    For `kind='text'`, body.text is the required content.
    """
    db: Db = state["db"]
    from .channels import (
        resolve_channel, resolve_effective_role, can_post_in_channel, insert_message,
    )
    if resolve_channel(db, channel_id) is None:
        raise HTTPException(404, f"channel {channel_id} not found")
    role = resolve_effective_role(db, channel_id=channel_id, user_id=user.id)
    if not can_post_in_channel(role):
        raise HTTPException(403, "permission denied — you are not a member of this channel or are read-only")
    text = (body.text or "").strip()
    if body.kind == "text" and not text:
        raise HTTPException(400, "text is required for kind=text")
    payload = dict(body.payload or {})
    if text:
        payload["text"] = text
    msg_id = insert_message(
        db,
        channel_id=channel_id,
        author_kind="human",
        author_user_id=user.id,
        kind=body.kind,
        payload=payload,
        reply_to_id=body.reply_to_id,
    )
    # Sprint 47: fan out via WebSocket (Task A10 wires this in)
    # For now, just return the new row
    row = db._conn.execute(
        "SELECT id, channel_id, author_kind, author_user_id, author_agent_id, "
        "kind, payload_json, reply_to_id, created_at, edited_at "
        "FROM messages WHERE id=?",
        (msg_id,),
    ).fetchone()
    # Sprint 47 Task A10 will broadcast over WebSocket here.
    asyncio.create_task(_broadcast_new_message(channel_id, msg_id))
    return {
        "id": row[0], "channel_id": row[1], "author_kind": row[2],
        "author_user_id": row[3], "author_agent_id": row[4],
        "kind": row[5], "payload_json": row[6], "reply_to_id": row[7],
        "created_at": row[8], "edited_at": row[9],
    }


async def _broadcast_new_message(channel_id: int, message_id: int) -> None:
    """Placeholder; Task A10 implements the WebSocket fan-out."""
    pass
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/test_messages_routes.py -v
```

Expected: 5 PASS.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_messages_routes.py
git commit -m "[s47] POST /channels/{id}/messages — role-gated message send"
```

### Task A6: GET /channels/{id}/messages route (paginated history)

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Append: `services/orchestrator/tests/test_messages_routes.py`

- [ ] **Step 1: Write the failing tests**

Append to `services/orchestrator/tests/test_messages_routes.py`:

```python
def test_get_messages_empty(client):
    import tally_orchestrator.service as svc
    ch_id = _admin_general_channel_id(svc)
    r = client.get(f"/channels/{ch_id}/messages")
    assert r.status_code == 200
    assert r.json() == {"messages": [], "channel_id": ch_id}


def test_get_messages_after_posts_in_reverse_chronological(client):
    import tally_orchestrator.service as svc
    ch_id = _admin_general_channel_id(svc)
    client.post(f"/channels/{ch_id}/messages", json={"text": "first"})
    client.post(f"/channels/{ch_id}/messages", json={"text": "second"})
    client.post(f"/channels/{ch_id}/messages", json={"text": "third"})

    r = client.get(f"/channels/{ch_id}/messages")
    assert r.status_code == 200
    msgs = r.json()["messages"]
    assert len(msgs) == 3
    # newest first
    texts = [json.loads(m["payload_json"])["text"] for m in msgs]
    assert texts == ["third", "second", "first"]


def test_get_messages_since_id(client):
    import tally_orchestrator.service as svc
    ch_id = _admin_general_channel_id(svc)
    r1 = client.post(f"/channels/{ch_id}/messages", json={"text": "a"})
    r2 = client.post(f"/channels/{ch_id}/messages", json={"text": "b"})
    r3 = client.post(f"/channels/{ch_id}/messages", json={"text": "c"})
    first_id = r1.json()["id"]

    r = client.get(f"/channels/{ch_id}/messages?since_id={first_id}")
    assert r.status_code == 200
    msgs = r.json()["messages"]
    assert len(msgs) == 2
    texts = sorted([json.loads(m["payload_json"])["text"] for m in msgs])
    assert texts == ["b", "c"]


def test_get_messages_non_member_returns_403(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    ch_id = _admin_general_channel_id(svc)
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="stranger", source="clerk", plan="free", email="s@x.com",
    )
    r = client.get(f"/channels/{ch_id}/messages")
    assert r.status_code == 403
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_messages_routes.py::test_get_messages_empty -v
```

Expected: FAIL (route doesn't exist).

- [ ] **Step 3: Add the GET route**

In `service.py`, near `post_message`, add:

```python
@app.get("/channels/{channel_id}/messages")
async def get_messages(
    channel_id: int,
    limit: int = 50,
    since_id: int | None = None,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 47: paginated message history.  Reverse chronological
    (newest first).  `since_id` returns messages with id > since_id
    (used by clients catching up after WebSocket reconnect)."""
    db: Db = state["db"]
    from .channels import resolve_channel, resolve_effective_role, list_messages
    if resolve_channel(db, channel_id) is None:
        raise HTTPException(404, f"channel {channel_id} not found")
    role = resolve_effective_role(db, channel_id=channel_id, user_id=user.id)
    if role is None:
        raise HTTPException(403, "permission denied — not a channel member")
    msgs = list_messages(db, channel_id=channel_id, limit=limit, since_id=since_id)
    return {"channel_id": channel_id, "messages": msgs}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/test_messages_routes.py -v
```

Expected: 9 PASS (5 from A5 + 4 new).

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_messages_routes.py
git commit -m "[s47] GET /channels/{id}/messages — paginated history with since_id"
```

### Task A7: PATCH /channels/{id}/messages/{message_id} (edit message)

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Append: `services/orchestrator/tests/test_messages_routes.py`

- [ ] **Step 1: Write the failing tests**

Append to `services/orchestrator/tests/test_messages_routes.py`:

```python
def test_patch_message_author_succeeds(client):
    import tally_orchestrator.service as svc
    ch_id = _admin_general_channel_id(svc)
    r = client.post(f"/channels/{ch_id}/messages", json={"text": "before"})
    msg_id = r.json()["id"]
    r2 = client.patch(f"/channels/{ch_id}/messages/{msg_id}", json={"text": "after"})
    assert r2.status_code == 200
    assert json.loads(r2.json()["payload_json"])["text"] == "after"
    assert r2.json()["edited_at"] is not None


def test_patch_message_non_author_returns_403(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    ch_id = _admin_general_channel_id(svc)
    r = client.post(f"/channels/{ch_id}/messages", json={"text": "by admin"})
    msg_id = r.json()["id"]
    # Switch to a different user
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="other", source="clerk", plan="free", email="o@x.com",
    )
    r2 = client.patch(f"/channels/{ch_id}/messages/{msg_id}", json={"text": "hacked"})
    assert r2.status_code == 403


def test_patch_unknown_message_returns_404(client):
    import tally_orchestrator.service as svc
    ch_id = _admin_general_channel_id(svc)
    r = client.patch(f"/channels/{ch_id}/messages/99999", json={"text": "x"})
    assert r.status_code == 404
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_messages_routes.py::test_patch_message_author_succeeds -v
```

Expected: FAIL.

- [ ] **Step 3: Add PATCH route**

```python
@app.patch("/channels/{channel_id}/messages/{message_id}")
async def patch_message(
    channel_id: int,
    message_id: int,
    body: MessagePatchRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 47: edit a message.  Author-only (admins cannot edit
    other users' messages; that would be a moderation concern out of
    scope for v1)."""
    db: Db = state["db"]
    row = db._conn.execute(
        "SELECT author_user_id, payload_json FROM messages "
        "WHERE id=? AND channel_id=?",
        (message_id, channel_id),
    ).fetchone()
    if row is None:
        raise HTTPException(404, "message not found")
    if row[0] != user.id:
        raise HTTPException(403, "only the author can edit a message")
    text = (body.text or "").strip()
    if not text and not body.payload:
        raise HTTPException(400, "nothing to update")
    payload = dict(body.payload) if body.payload else json.loads(row[1])
    if text:
        payload["text"] = text
    db._conn.execute(
        "UPDATE messages SET payload_json=?, edited_at=? WHERE id=?",
        (json.dumps(payload), time.time(), message_id),
    )
    new_row = db._conn.execute(
        "SELECT id, channel_id, author_kind, author_user_id, author_agent_id, "
        "kind, payload_json, reply_to_id, created_at, edited_at "
        "FROM messages WHERE id=?",
        (message_id,),
    ).fetchone()
    return {
        "id": new_row[0], "channel_id": new_row[1], "author_kind": new_row[2],
        "author_user_id": new_row[3], "author_agent_id": new_row[4],
        "kind": new_row[5], "payload_json": new_row[6], "reply_to_id": new_row[7],
        "created_at": new_row[8], "edited_at": new_row[9],
    }
```

`json` should already be imported in service.py; verify before adding.

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/test_messages_routes.py -v
```

Expected: 12 PASS.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_messages_routes.py
git commit -m "[s47] PATCH /channels/{id}/messages/{message_id} — author-only edit"
```

### Task A8: POST /channels/{id}/read (mark messages read)

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Append: `services/orchestrator/tests/test_channels_routes.py`

- [ ] **Step 1: Write the failing test**

Append to `services/orchestrator/tests/test_channels_routes.py`:

```python
def test_post_channel_read_updates_last_read(client):
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    ch_id = db._conn.execute(
        "SELECT c.id FROM channels c JOIN workspaces w ON c.workspace_id=w.id "
        "WHERE w.owner_user_id='admin' AND c.kind='general'"
    ).fetchone()[0]
    # Post some messages
    r1 = client.post(f"/channels/{ch_id}/messages", json={"text": "a"})
    r2 = client.post(f"/channels/{ch_id}/messages", json={"text": "b"})
    msg_id_b = r2.json()["id"]
    # Mark read up to msg_id_b
    r = client.post(f"/channels/{ch_id}/read", json={"last_read_message_id": msg_id_b})
    assert r.status_code == 200
    # Check the DB
    row = db._conn.execute(
        "SELECT last_read_message_id FROM channel_members WHERE channel_id=? AND user_id='admin'",
        (ch_id,),
    ).fetchone()
    assert row[0] == msg_id_b


def test_post_channel_read_non_member_returns_403(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    db = svc.state["db"]
    ch_id = db._conn.execute(
        "SELECT c.id FROM channels c JOIN workspaces w ON c.workspace_id=w.id "
        "WHERE w.owner_user_id='admin' AND c.kind='general'"
    ).fetchone()[0]
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="stranger", source="clerk", plan="free", email="s@x.com",
    )
    r = client.post(f"/channels/{ch_id}/read", json={"last_read_message_id": 1})
    assert r.status_code == 403
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_channels_routes.py::test_post_channel_read_updates_last_read -v
```

Expected: FAIL.

- [ ] **Step 3: Add request model + route**

In `service.py` near the Pydantic models, add:

```python
class ChannelReadRequest(BaseModel):
    last_read_message_id: int
```

Add the route near GET /channels:

```python
@app.post("/channels/{channel_id}/read")
async def post_channel_read(
    channel_id: int,
    body: ChannelReadRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 47: mark messages up to `last_read_message_id` as read for
    the caller in this channel.  Returns 403 if caller isn't a member."""
    db: Db = state["db"]
    from .channels import resolve_effective_role
    role = resolve_effective_role(db, channel_id=channel_id, user_id=user.id)
    if role is None:
        raise HTTPException(403, "permission denied")
    cur = db._conn.execute(
        "UPDATE channel_members SET last_read_message_id = MAX(last_read_message_id, ?) "
        "WHERE channel_id=? AND user_id=?",
        (body.last_read_message_id, channel_id, user.id),
    )
    return {"ok": True, "updated": cur.rowcount > 0}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/test_channels_routes.py -v
```

Expected: 5 PASS.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_channels_routes.py
git commit -m "[s47] POST /channels/{id}/read — update last_read_message_id for caller"
```

### Task A9: POST /channels/{id}/members/{user_id}/role_override

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py`
- Append: `services/orchestrator/tests/test_channels_routes.py`

- [ ] **Step 1: Write the failing tests**

Append to `services/orchestrator/tests/test_channels_routes.py`:

```python
def test_post_role_override_admin_can_set(client):
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    ch_id = db._conn.execute(
        "SELECT c.id FROM channels c JOIN workspaces w ON c.workspace_id=w.id "
        "WHERE w.owner_user_id='admin' AND c.kind='general'"
    ).fetchone()[0]
    # Insert another channel member to override
    db._conn.execute(
        "INSERT INTO channel_members (channel_id, member_kind, user_id, joined_at) "
        "VALUES (?, 'human', 'guest', 0)",
        (ch_id,),
    )
    # Caller (admin) sets guest's role_override
    r = client.post(
        f"/channels/{ch_id}/members/guest/role_override",
        json={"role_override": "read_only"},
    )
    assert r.status_code == 200
    row = db._conn.execute(
        "SELECT role_override FROM channel_members WHERE channel_id=? AND user_id='guest'",
        (ch_id,),
    ).fetchone()
    assert row[0] == "read_only"


def test_post_role_override_member_returns_403(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    db = svc.state["db"]
    ch_id = db._conn.execute(
        "SELECT c.id FROM channels c JOIN workspaces w ON c.workspace_id=w.id "
        "WHERE w.owner_user_id='admin' AND c.kind='general'"
    ).fetchone()[0]
    db._conn.execute(
        "INSERT INTO channel_members (channel_id, member_kind, user_id, joined_at) "
        "VALUES (?, 'human', 'guest', 0)",
        (ch_id,),
    )
    # Switch caller to a 'member' (not admin)
    ws_id = db._conn.execute(
        "SELECT id FROM workspaces WHERE owner_user_id='admin'"
    ).fetchone()[0]
    db._conn.execute(
        "INSERT INTO workspace_members (workspace_id, member_kind, user_id, role, joined_at) "
        "VALUES (?, 'human', 'plain', 'member', 0)",
        (ws_id,),
    )
    db._conn.execute(
        "INSERT INTO channel_members (channel_id, member_kind, user_id, joined_at) "
        "VALUES (?, 'human', 'plain', 0)",
        (ch_id,),
    )
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="plain", source="clerk", plan="free", email="p@x.com",
    )
    r = client.post(
        f"/channels/{ch_id}/members/guest/role_override",
        json={"role_override": "read_only"},
    )
    assert r.status_code == 403


def test_post_role_override_clear(client):
    """Setting role_override=null clears the override."""
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    ch_id = db._conn.execute(
        "SELECT c.id FROM channels c JOIN workspaces w ON c.workspace_id=w.id "
        "WHERE w.owner_user_id='admin' AND c.kind='general'"
    ).fetchone()[0]
    db._conn.execute(
        "INSERT INTO channel_members (channel_id, member_kind, user_id, role_override, joined_at) "
        "VALUES (?, 'human', 'guest', 'read_only', 0)",
        (ch_id,),
    )
    r = client.post(
        f"/channels/{ch_id}/members/guest/role_override",
        json={"role_override": None},
    )
    assert r.status_code == 200
    row = db._conn.execute(
        "SELECT role_override FROM channel_members WHERE channel_id=? AND user_id='guest'",
        (ch_id,),
    ).fetchone()
    assert row[0] is None
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_channels_routes.py::test_post_role_override_admin_can_set -v
```

Expected: FAIL.

- [ ] **Step 3: Add route**

```python
@app.post("/channels/{channel_id}/members/{target_user_id}/role_override")
async def post_channel_role_override(
    channel_id: int,
    target_user_id: str,
    body: ChannelMemberRoleOverrideRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 47: set a per-channel role override for `target_user_id`.

    Permission: caller must be workspace Admin or Owner (per
    `can_manage_members`).  Valid override values: channel_admin,
    read_only.  Pass null to clear.
    """
    db: Db = state["db"]
    from .channels import resolve_effective_role, can_manage_members
    caller_role = resolve_effective_role(db, channel_id=channel_id, user_id=user.id)
    if not can_manage_members(caller_role):
        raise HTTPException(403, "only Owner/Admin can set role overrides")
    if body.role_override is not None and body.role_override not in ("channel_admin", "read_only"):
        raise HTTPException(400, "role_override must be 'channel_admin', 'read_only', or null")
    cur = db._conn.execute(
        "UPDATE channel_members SET role_override=? "
        "WHERE channel_id=? AND user_id=?",
        (body.role_override, channel_id, target_user_id),
    )
    if cur.rowcount == 0:
        raise HTTPException(404, f"{target_user_id} is not a member of channel {channel_id}")
    return {"ok": True}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/test_channels_routes.py -v
```

Expected: 8 PASS.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_channels_routes.py
git commit -m "[s47] POST /channels/{id}/members/{user_id}/role_override — admin-only per-channel role override"
```

### Task A10: WebSocket extension — new_message event broadcast

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — extend `_broadcast_new_message` + the WS handler
- Create: `services/orchestrator/tests/test_message_ws.py`

- [ ] **Step 1: Write the failing test**

Create `services/orchestrator/tests/test_message_ws.py`:

```python
"""Sprint 47: WebSocket new_message event delivery."""
import asyncio
import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch, tmp_db_path):
    monkeypatch.setenv("ORCH_DB_PATH", tmp_db_path)
    monkeypatch.setenv("TALLY_API_TOKEN", "test-token")
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


def test_ws_receives_new_message_event(client):
    """Posting a message via REST → existing /ws/notifications subscribers
    see a `new_message` event with channel_id + message_id."""
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    ch_id = db._conn.execute(
        "SELECT c.id FROM channels c JOIN workspaces w ON c.workspace_id=w.id "
        "WHERE w.owner_user_id='admin' AND c.kind='general'"
    ).fetchone()[0]
    with client.websocket_connect("/ws/notifications?token=test-token") as ws:
        ws.receive_json()  # discard hello
        r = client.post(f"/channels/{ch_id}/messages", json={"text": "ws-test"})
        msg_id = r.json()["id"]
        # Read frames until we see new_message
        for _ in range(5):
            msg = ws.receive_json()
            if msg.get("type") == "new_message":
                assert msg["channel_id"] == ch_id
                assert msg["message_id"] == msg_id
                return
        pytest.fail("did not receive new_message event within 5 frames")
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_message_ws.py -v
```

Expected: FAIL (the placeholder `_broadcast_new_message` is empty).

- [ ] **Step 3: Implement the broadcast**

In `service.py` replace the placeholder `_broadcast_new_message` with:

```python
async def _broadcast_new_message(channel_id: int, message_id: int) -> None:
    """Sprint 47: send new_message events to every WebSocket subscribed
    to the user's notification feed where the user is a member of the
    channel.

    This re-uses the existing notifications WS registry from Sprint 46
    (`_ACTIVE_WS` in notifications.py) rather than introducing a new
    per-channel WebSocket type.  Frame shape:
        {"type": "new_message", "channel_id": int, "message_id": int}
    """
    from .notifications import _ACTIVE_WS
    db: Db = state["db"]
    # Find all user_ids who are members of this channel
    members = db._conn.execute(
        "SELECT DISTINCT user_id FROM channel_members "
        "WHERE channel_id=? AND user_id IS NOT NULL",
        (channel_id,),
    ).fetchall()
    user_ids = {m[0] for m in members}
    for user_id in user_ids:
        sockets = list(_ACTIVE_WS.get(user_id) or [])
        for ws in sockets:
            try:
                await ws.send_json({
                    "type": "new_message",
                    "channel_id": channel_id,
                    "message_id": message_id,
                })
            except Exception as exc:
                logger.warning("ws send_new_message failed for user=%s: %s", user_id, exc)
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/test_message_ws.py -v
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_message_ws.py
git commit -m "[s47] /ws/notifications: broadcast new_message events to channel members"
```

### Task A11: Agent context loop — user messages reach next LLM turn

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — Orchestrator._dispatch_agent path
- Create: `services/orchestrator/tests/test_agent_context_inclusion.py`

- [ ] **Step 1: Write the failing test**

Create `services/orchestrator/tests/test_agent_context_inclusion.py`:

```python
"""Sprint 47: agent context inclusion — user messages reach the agent's
next LLM turn via the orchestrator's dispatch path."""
import time
import json
from tally_orchestrator.service import Db
from tally_orchestrator.channels import (
    insert_message, get_task_channel_id,
)


def test_get_task_channel_id_after_backfill(db: Db):
    """A task created via the existing path gets a backfilled channel row."""
    task_id = db.create_task("test", team_spec={"agents": [{"role": "Coder"}]}, user_id="admin")
    # Re-init Db to trigger backfill
    db._backfill_workspaces_and_channels()
    ch_id = get_task_channel_id(db, task_id)
    assert ch_id is not None


def test_fetch_user_messages_since(db: Db):
    """Helper that returns user messages from a channel since a timestamp."""
    from tally_orchestrator.channels import fetch_user_messages_since
    task_id = db.create_task("test", team_spec={"agents": [{"role": "Coder"}]}, user_id="admin")
    db._backfill_workspaces_and_channels()
    ch_id = get_task_channel_id(db, task_id)
    assert ch_id is not None
    insert_message(db, channel_id=ch_id, author_kind="human", author_user_id="admin",
                   kind="text", payload={"text": "intervention 1"})
    insert_message(db, channel_id=ch_id, author_kind="agent", author_agent_id=1,
                   kind="text", payload={"text": "agent reply"})
    insert_message(db, channel_id=ch_id, author_kind="human", author_user_id="admin",
                   kind="text", payload={"text": "intervention 2"})
    user_msgs = fetch_user_messages_since(db, channel_id=ch_id, since_ts=0)
    assert len(user_msgs) == 2
    assert "intervention 1" in user_msgs[0]["text"]
    assert "intervention 2" in user_msgs[1]["text"]
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_agent_context_inclusion.py -v
```

Expected: 2 FAILs (fetch_user_messages_since not defined).

- [ ] **Step 3: Add helper to channels.py + wire into dispatch path**

In `channels.py` append:

```python
def fetch_user_messages_since(
    db: "Db",
    *,
    channel_id: int,
    since_ts: float,
) -> list[dict]:
    """Return user (human) messages in a channel posted after `since_ts`,
    chronological order.  Used by the orchestrator to inject user
    intervention into the agent's next LLM turn.

    Returns each as a dict with `text`, `author_user_id`, `created_at`.
    """
    rows = db._conn.execute(
        "SELECT payload_json, author_user_id, created_at FROM messages "
        "WHERE channel_id=? AND author_kind='human' AND created_at > ? "
        "ORDER BY created_at ASC",
        (channel_id, since_ts),
    ).fetchall()
    out: list[dict] = []
    for payload_json, author_user_id, created_at in rows:
        try:
            payload = json.loads(payload_json)
        except Exception:
            payload = {}
        text = payload.get("text", "")
        if text:
            out.append({
                "text": text,
                "author_user_id": author_user_id,
                "created_at": created_at,
            })
    return out
```

In `service.py` `Orchestrator._dispatch_agent` (search for `def _dispatch_agent`), find the place where the agent's prompt is constructed before being sent to the worker.  Before the worker call, add a check for new user messages in the task's channel and prepend them to the agent's spec context:

```python
        # Sprint 47: pull any user messages posted in the task channel
        # since the last agent step; prepend to this agent's spec so the
        # LLM sees them as teammate input.
        from .channels import get_task_channel_id, fetch_user_messages_since
        ch_id = get_task_channel_id(self.db, task_id)
        if ch_id is not None:
            since_ts = float(agent.get("last_user_msg_ts") or 0)
            user_msgs = fetch_user_messages_since(self.db, channel_id=ch_id, since_ts=since_ts)
            if user_msgs:
                intervention_block = "\n\n## User intervention (since last step)\n" + "\n".join(
                    f"- @{m['author_user_id']}: {m['text']}" for m in user_msgs
                )
                # Extend the agent's spec for this dispatch (one-shot)
                spec = (agent.get("spec") or "") + intervention_block
                agent = {**agent, "spec": spec, "last_user_msg_ts": user_msgs[-1]["created_at"]}
                # Persist the new last_user_msg_ts so the next step doesn't re-include
                self.db._conn.execute(
                    "UPDATE agents SET spec=? WHERE id=?", (spec, agent["id"]),
                )
```

(The exact placement depends on the current `_dispatch_agent` body — look for where the worker is called with the agent's spec text.  The block goes immediately before that call.)

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/test_agent_context_inclusion.py -v
```

Expected: 2 PASS.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/channels.py services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_agent_context_inclusion.py
git commit -m "[s47] agent dispatch: prepend new user messages from task channel to agent spec"
```

### Task A12: Hook task creation to also insert task channel row

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — POST /tasks handler
- Append: `services/orchestrator/tests/test_workspace_schema.py`

- [ ] **Step 1: Write the failing test**

Append to `services/orchestrator/tests/test_workspace_schema.py`:

```python
def test_new_task_creates_task_channel(db: Db):
    """When a task is created via Db.create_task, an immediate task channel
    is inserted (not waiting for next backfill cycle)."""
    task_id = db.create_task("test", team_spec={"agents":[{"role":"Coder"}]}, user_id="admin")
    # Channel should exist immediately
    row = db._conn.execute(
        "SELECT id, kind FROM channels WHERE task_id=?", (task_id,)
    ).fetchone()
    assert row is not None
    assert row[1] == "task"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_workspace_schema.py::test_new_task_creates_task_channel -v
```

Expected: FAIL (current `create_task` doesn't insert a channel).

- [ ] **Step 3: Modify Db.create_task to also insert the task channel**

In `service.py` `Db.create_task` method (search for `def create_task`), at the end of the method (after the task row is inserted and before returning the `task_id`), add:

```python
        # Sprint 47: create the task channel + the dispatcher's channel_member row.
        ws_row = self._conn.execute(
            "SELECT id FROM workspaces WHERE owner_user_id=?", (user_id or "admin",)
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
                (ch_cur.lastrowid, user_id or "admin", time.time()),
            )
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/ -v
```

Expected: all PASS (~38 tests including Sprint 46's 64 + Sprint 47's new ones).

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_workspace_schema.py
git commit -m "[s47] Db.create_task: insert task channel + dispatcher's channel_member row"
```

### Task A13: Phase A workspace smoke test

**Files:** None to write; full-suite verification.

- [ ] **Step 1: Run the full pytest suite**

```bash
cd services/orchestrator && uv run pytest tests/ -v 2>&1 | tail -10
```

Expected: all PASS (Sprint 46's 64 + ~26 new from Sprint 47 = ~90 tests).

- [ ] **Step 2: Boot locally + curl smoke**

```bash
cd services/orchestrator && TALLY_API_TOKEN=smoke ORCH_DB_PATH=/tmp/s47-smoke.db \
  TALLY_REDPILL_KEY="" TALLY_TEST_MODE=1 \
  uv run uvicorn tally_orchestrator.service:app --port 8118 &
sleep 5
# 1. Channel list
curl -s -H "Authorization: Bearer smoke" "http://localhost:8118/channels?workspace_id=1" | jq '.channels[] | {id, kind, name}'
# 2. Post message in general (find its id from above output)
GENERAL=$(curl -s -H "Authorization: Bearer smoke" "http://localhost:8118/channels?workspace_id=1" | jq -r '.channels[] | select(.kind=="general") | .id')
curl -sX POST -H "Authorization: Bearer smoke" -H "content-type: application/json" \
  -d '{"text":"hello from smoke"}' "http://localhost:8118/channels/$GENERAL/messages" | jq .
# 3. Fetch the message back
curl -s -H "Authorization: Bearer smoke" "http://localhost:8118/channels/$GENERAL/messages" | jq '.messages[0]'
kill %1
```

Expected: each curl returns 200 JSON with the right shape.

- [ ] **Step 3: Tag Phase A complete**

```bash
git tag s47-phase-a-done
```

---

## Phase B — Flutter (7 tasks, ~20h)

### Task B1: api.dart channel/message methods

**Files:**
- Modify: `tally_coding_app/lib/api.dart` — add ~7 new methods on `TallyOrchClient`
- Create: `tally_coding_app/test/api_channels_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `tally_coding_app/test/api_channels_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tally_coding_app/api.dart';

void main() {
  test('listChannels returns channels list', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/channels');
      expect(req.url.queryParameters['workspace_id'], '1');
      return http.Response(
        '{"channels":[{"id":1,"workspace_id":1,"kind":"general","name":"general","task_id":null,"persistent_agent_id":null,"auto_jump_in_for_tally":false,"created_at":0,"archived_at":null}]}',
        200, headers: {'content-type':'application/json'},
      );
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.listChannels(workspaceId: 1);
    expect(out.length, 1);
    expect(out[0]['kind'], 'general');
  });

  test('postMessage sends text + returns server row', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/channels/5/messages');
      expect(req.method, 'POST');
      return http.Response(
        '{"id":42,"channel_id":5,"author_kind":"human","author_user_id":"admin","author_agent_id":null,"kind":"text","payload_json":"{\\"text\\":\\"hi\\"}","reply_to_id":null,"created_at":1,"edited_at":null}',
        200, headers: {'content-type':'application/json'},
      );
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.postMessage(channelId: 5, text: 'hi');
    expect(out['id'], 42);
    expect(out['kind'], 'text');
  });

  test('getMessages with since_id passes through query', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/channels/5/messages');
      expect(req.url.queryParameters['since_id'], '100');
      return http.Response(
        '{"channel_id":5,"messages":[]}',
        200, headers: {'content-type':'application/json'},
      );
    });
    final api = TallyOrchClient(baseUrl: Uri.parse('http://test'), provider: () async => 't', client: mock);
    final out = await api.getMessages(channelId: 5, sinceId: 100);
    expect(out.length, 0);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter test test/api_channels_test.dart
```

Expected: 3 FAILs (methods not defined).

- [ ] **Step 3: Add methods to TallyOrchClient**

In `tally_coding_app/lib/api.dart`, append before `void close()`:

```dart
  // ── Sprint 47: channels + messages ──────────────────────────────────────

  Future<List<Map<String, dynamic>>> listChannels({
    required int workspaceId,
    bool includeArchived = false,
  }) async {
    final qs = {'workspace_id': '$workspaceId'};
    if (includeArchived) qs['include_archived'] = 'true';
    final resp = await _http.get(
      baseUrl.resolve('/channels').replace(queryParameters: qs),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) {
      throw Exception('GET /channels ${resp.statusCode}: ${resp.body}');
    }
    final body = Map<String, dynamic>.from(jsonDecode(resp.body));
    return List<Map<String, dynamic>>.from(body['channels'] as List);
  }

  Future<List<Map<String, dynamic>>> getMessages({
    required int channelId,
    int limit = 50,
    int? sinceId,
  }) async {
    final qs = <String, String>{'limit': '$limit'};
    if (sinceId != null) qs['since_id'] = '$sinceId';
    final resp = await _http.get(
      baseUrl.resolve('/channels/$channelId/messages').replace(queryParameters: qs),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) {
      throw Exception('GET /channels/$channelId/messages ${resp.statusCode}: ${resp.body}');
    }
    final body = Map<String, dynamic>.from(jsonDecode(resp.body));
    return List<Map<String, dynamic>>.from(body['messages'] as List);
  }

  Future<Map<String, dynamic>> postMessage({
    required int channelId,
    String? text,
    String kind = 'text',
    Map<String, dynamic>? payload,
    int? replyToId,
  }) async {
    final body = <String, dynamic>{'kind': kind};
    if (text != null) body['text'] = text;
    if (payload != null) body['payload'] = payload;
    if (replyToId != null) body['reply_to_id'] = replyToId;
    final resp = await _http.post(
      baseUrl.resolve('/channels/$channelId/messages'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200) {
      throw Exception('POST /channels/$channelId/messages ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<Map<String, dynamic>> patchMessage(
    int channelId,
    int messageId, {
    String? text,
    Map<String, dynamic>? payload,
  }) async {
    final body = <String, dynamic>{};
    if (text != null) body['text'] = text;
    if (payload != null) body['payload'] = payload;
    final resp = await _http.patch(
      baseUrl.resolve('/channels/$channelId/messages/$messageId'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200) {
      throw Exception('PATCH /channels/$channelId/messages/$messageId ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<void> postChannelRead({
    required int channelId,
    required int lastReadMessageId,
  }) async {
    final resp = await _http.post(
      baseUrl.resolve('/channels/$channelId/read'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode({'last_read_message_id': lastReadMessageId}),
    );
    if (resp.statusCode != 200) {
      throw Exception('POST /channels/$channelId/read ${resp.statusCode}');
    }
  }

  Future<void> setChannelMemberRoleOverride({
    required int channelId,
    required String targetUserId,
    String? roleOverride,
  }) async {
    final resp = await _http.post(
      baseUrl.resolve('/channels/$channelId/members/$targetUserId/role_override'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode({'role_override': roleOverride}),
    );
    if (resp.statusCode != 200) {
      throw Exception('POST role_override ${resp.statusCode}: ${resp.body}');
    }
  }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter test test/api_channels_test.dart
```

Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/api.dart tally_coding_app/test/api_channels_test.dart
git commit -m "[s47] api.dart: listChannels, getMessages, postMessage, patchMessage, channel read + role_override"
```

### Task B2: MessageBubble widget

**Files:**
- Create: `tally_coding_app/lib/widgets/message_bubble.dart`
- Create: `tally_coding_app/test/message_bubble_test.dart`

- [ ] **Step 1: Write the failing test**

Create `tally_coding_app/test/message_bubble_test.dart`:

```dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/message_bubble.dart';

void main() {
  testWidgets('renders human text message', (tester) async {
    final msg = {
      'id': 1,
      'channel_id': 1,
      'author_kind': 'human',
      'author_user_id': 'admin',
      'kind': 'text',
      'payload_json': jsonEncode({'text': 'hello world'}),
      'created_at': 1700000000.0,
      'edited_at': null,
    };
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageBubble(message: msg))));
    expect(find.textContaining('hello world'), findsOneWidget);
    expect(find.textContaining('admin'), findsOneWidget);
  });

  testWidgets('renders agent message with role-color', (tester) async {
    final msg = {
      'id': 2, 'channel_id': 1, 'author_kind': 'agent',
      'author_agent_id': 5, 'kind': 'text',
      'payload_json': jsonEncode({'text': 'on it', 'role': 'Coder'}),
      'created_at': 1700000001.0,
    };
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageBubble(message: msg))));
    expect(find.textContaining('on it'), findsOneWidget);
  });

  testWidgets('shows (edited) indicator when edited_at is set', (tester) async {
    final msg = {
      'id': 3, 'channel_id': 1, 'author_kind': 'human',
      'author_user_id': 'admin', 'kind': 'text',
      'payload_json': jsonEncode({'text': 'fixed typo'}),
      'created_at': 1700000000.0, 'edited_at': 1700000060.0,
    };
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageBubble(message: msg))));
    expect(find.textContaining('edited'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter test test/message_bubble_test.dart
```

Expected: 3 FAILs.

- [ ] **Step 3: Write `message_bubble.dart`**

```dart
// tally_coding_app/lib/widgets/message_bubble.dart
import 'dart:convert';
import 'package:flutter/material.dart';

class MessageBubble extends StatelessWidget {
  final Map<String, dynamic> message;
  const MessageBubble({super.key, required this.message});

  String get _authorLabel {
    final kind = message['author_kind'] as String? ?? '';
    if (kind == 'tally') return 'Tally';
    if (kind == 'system') return 'System';
    final agentId = message['author_agent_id'];
    if (kind == 'agent' && agentId != null) {
      final payload = _payload();
      return (payload['role'] as String?) ?? 'Agent';
    }
    return (message['author_user_id'] as String?) ?? 'unknown';
  }

  Color get _authorColor {
    final kind = message['author_kind'] as String? ?? '';
    switch (kind) {
      case 'tally':  return const Color(0xFFF23F43);
      case 'agent':  return const Color(0xFF3BA55D);
      case 'system': return const Color(0xFF949BA4);
      default:       return const Color(0xFF5865F2);
    }
  }

  Map<String, dynamic> _payload() {
    try {
      return Map<String, dynamic>.from(jsonDecode(message['payload_json'] as String));
    } catch (_) {
      return const {};
    }
  }

  String _formatTime(num ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final payload = _payload();
    final text = (payload['text'] as String?) ?? '';
    final createdAt = (message['created_at'] as num?) ?? 0;
    final editedAt = message['edited_at'] as num?;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(_authorLabel, style: TextStyle(fontWeight: FontWeight.bold, color: _authorColor)),
              const SizedBox(width: 8),
              Text(_formatTime(createdAt),
                style: const TextStyle(fontSize: 11, color: Color(0xFF949BA4))),
              if (editedAt != null) ...[
                const SizedBox(width: 6),
                const Text('(edited)', style: TextStyle(fontSize: 11, color: Color(0xFF949BA4))),
              ],
            ],
          ),
          if (text.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: SelectableText(text, style: const TextStyle(fontSize: 14)),
            ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter test test/message_bubble_test.dart
```

Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/widgets/message_bubble.dart tally_coding_app/test/message_bubble_test.dart
git commit -m "[s47] MessageBubble: author-color rendering + edited indicator"
```

### Task B3: InteractivePromptCard widget

**Files:**
- Create: `tally_coding_app/lib/widgets/interactive_prompt_card.dart`
- Create: `tally_coding_app/test/interactive_prompt_card_test.dart`

- [ ] **Step 1: Write the failing test**

Create `tally_coding_app/test/interactive_prompt_card_test.dart`:

```dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/interactive_prompt_card.dart';

void main() {
  testWidgets('renders prompt text + action buttons', (tester) async {
    final msg = {
      'id': 10, 'channel_id': 1, 'author_kind': 'agent',
      'kind': 'interactive_prompt',
      'payload_json': jsonEncode({
        'role': 'Reviewer',
        'prompt': 'Found a duplicate-key bug. Block, or note only?',
        'options': [
          {'value': 'block', 'label': 'Block'},
          {'value': 'note', 'label': 'Note only'},
        ],
      }),
      'created_at': 1700000000.0,
    };
    String? clicked;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      InteractivePromptCard(message: msg, onAnswer: (v) => clicked = v),
    )));
    expect(find.textContaining('duplicate-key'), findsOneWidget);
    expect(find.text('Block'), findsOneWidget);
    expect(find.text('Note only'), findsOneWidget);
    await tester.tap(find.text('Block'));
    await tester.pumpAndSettle();
    expect(clicked, 'block');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter test test/interactive_prompt_card_test.dart
```

Expected: FAIL.

- [ ] **Step 3: Write `interactive_prompt_card.dart`**

```dart
// tally_coding_app/lib/widgets/interactive_prompt_card.dart
import 'dart:convert';
import 'package:flutter/material.dart';

class InteractivePromptCard extends StatelessWidget {
  final Map<String, dynamic> message;
  final void Function(String value) onAnswer;
  const InteractivePromptCard({super.key, required this.message, required this.onAnswer});

  Map<String, dynamic> _payload() {
    try {
      return Map<String, dynamic>.from(jsonDecode(message['payload_json'] as String));
    } catch (_) { return const {}; }
  }

  @override
  Widget build(BuildContext context) {
    final payload = _payload();
    final role = (payload['role'] as String?) ?? 'Agent';
    final prompt = (payload['prompt'] as String?) ?? '';
    final options = (payload['options'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF3B2F1F),
        border: const Border(left: BorderSide(color: Color(0xFFF0B232), width: 3)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$role needs you', style: const TextStyle(color: Color(0xFFF0B232), fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(prompt, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final opt in options)
                ElevatedButton(
                  onPressed: () => onAnswer(opt['value'] as String),
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

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter test test/interactive_prompt_card_test.dart
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/widgets/interactive_prompt_card.dart tally_coding_app/test/interactive_prompt_card_test.dart
git commit -m "[s47] InteractivePromptCard: agent question with click-to-answer actions"
```

### Task B4: MessageFeed widget

**Files:**
- Create: `tally_coding_app/lib/widgets/message_feed.dart`
- Create: `tally_coding_app/test/message_feed_test.dart`

- [ ] **Step 1: Write the failing test**

Create `tally_coding_app/test/message_feed_test.dart`:

```dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/message_feed.dart';

void main() {
  testWidgets('renders multiple messages in reverse chronological order', (tester) async {
    final messages = [
      {
        'id': 3, 'channel_id': 1, 'author_kind': 'human',
        'author_user_id': 'admin', 'kind': 'text',
        'payload_json': jsonEncode({'text': 'third'}),
        'created_at': 1700000003.0,
      },
      {
        'id': 2, 'channel_id': 1, 'author_kind': 'agent',
        'kind': 'text',
        'payload_json': jsonEncode({'text': 'second', 'role': 'Coder'}),
        'created_at': 1700000002.0,
      },
      {
        'id': 1, 'channel_id': 1, 'author_kind': 'human',
        'author_user_id': 'admin', 'kind': 'text',
        'payload_json': jsonEncode({'text': 'first'}),
        'created_at': 1700000001.0,
      },
    ];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      MessageFeed(messages: messages, onAnswerPrompt: (mid, val) {}),
    )));
    expect(find.textContaining('first'), findsOneWidget);
    expect(find.textContaining('second'), findsOneWidget);
    expect(find.textContaining('third'), findsOneWidget);
  });

  testWidgets('renders empty state when no messages', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      MessageFeed(messages: const [], onAnswerPrompt: (m, v) {}),
    )));
    expect(find.textContaining('No messages yet'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter test test/message_feed_test.dart
```

Expected: 2 FAILs.

- [ ] **Step 3: Write `message_feed.dart`**

```dart
// tally_coding_app/lib/widgets/message_feed.dart
import 'package:flutter/material.dart';
import 'message_bubble.dart';
import 'interactive_prompt_card.dart';

class MessageFeed extends StatelessWidget {
  /// Messages in reverse chronological order (newest first).  The list is
  /// rendered with reverse:true so newest appears at the bottom (chat
  /// convention).
  final List<Map<String, dynamic>> messages;
  final void Function(int messageId, String answerValue) onAnswerPrompt;
  const MessageFeed({
    super.key,
    required this.messages,
    required this.onAnswerPrompt,
  });

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No messages yet. Type below to start the conversation.',
            style: TextStyle(color: Color(0xFF949BA4))),
        ),
      );
    }
    return ListView.builder(
      reverse: true,
      itemCount: messages.length,
      itemBuilder: (ctx, i) {
        final m = messages[i];
        final kind = m['kind'] as String? ?? 'text';
        if (kind == 'interactive_prompt') {
          return InteractivePromptCard(
            message: m,
            onAnswer: (val) => onAnswerPrompt(m['id'] as int, val),
          );
        }
        return MessageBubble(message: m);
      },
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter test test/message_feed_test.dart
```

Expected: 2 PASS.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/widgets/message_feed.dart tally_coding_app/test/message_feed_test.dart
git commit -m "[s47] MessageFeed: reverse-chronological scrollable list + interactive prompts"
```

### Task B5: MessageComposer widget

**Files:**
- Create: `tally_coding_app/lib/widgets/message_composer.dart`
- Create: `tally_coding_app/test/message_composer_test.dart`

- [ ] **Step 1: Write the failing test**

Create `tally_coding_app/test/message_composer_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/message_composer.dart';

void main() {
  testWidgets('sends text on enter + clears field', (tester) async {
    String? sent;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      MessageComposer(onSend: (text) async => sent = text, placeholder: 'Type...'),
    )));
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(sent, 'hello');
    // Field should be cleared after send
    expect(find.text('hello'), findsNothing);
  });

  testWidgets('does not send empty text', (tester) async {
    int sendCount = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      MessageComposer(onSend: (text) async { sendCount++; }, placeholder: ''),
    )));
    await tester.testTextInput.receiveAction(TextInputAction.send);
    expect(sendCount, 0);
  });

  testWidgets('send button triggers send', (tester) async {
    String? sent;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      MessageComposer(onSend: (t) async => sent = t, placeholder: ''),
    )));
    await tester.enterText(find.byType(TextField), 'via button');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(sent, 'via button');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter test test/message_composer_test.dart
```

Expected: 3 FAILs.

- [ ] **Step 3: Write `message_composer.dart`**

```dart
// tally_coding_app/lib/widgets/message_composer.dart
import 'package:flutter/material.dart';

class MessageComposer extends StatefulWidget {
  /// Async send hook; should return when the server accepted the message
  /// (or threw).  Composer remains interactive throughout.
  final Future<void> Function(String text) onSend;
  final String placeholder;
  const MessageComposer({super.key, required this.onSend, required this.placeholder});

  @override
  State<MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<MessageComposer> {
  final _ctrl = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.onSend(text);
      _ctrl.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Send failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _ctrl,
              enabled: !_sending,
              minLines: 1, maxLines: 5,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: widget.placeholder,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.send),
            onPressed: _sending ? null : _send,
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter test test/message_composer_test.dart
```

Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/widgets/message_composer.dart tally_coding_app/test/message_composer_test.dart
git commit -m "[s47] MessageComposer: TextField with send + enter-to-submit + busy state"
```

### Task B6: ChannelWs subscription helper

**Files:**
- Create: `tally_coding_app/lib/services/channel_ws.dart`

- [ ] **Step 1: Inspect the existing WebSocket client**

```bash
cat /home/nick/Projects/pronoic/tally-coding/tally_coding_app/lib/services/notifications_ws.dart | head -40
```

The existing `NotificationsWsClient` from Sprint 46 handles `new_notification` events and lives at `wsUrl?token=`.  Sprint 47 reuses that connection and extends `_handleMessage` to also recognize `new_message` events.

- [ ] **Step 2: Extend `notifications_ws.dart` to surface new_message events**

In `tally_coding_app/lib/services/notifications_ws.dart` find the `_handleMessage` method.  After the existing `new_notification` handling, add:

```dart
    if (msg['type'] == 'new_message') {
      onNewMessage?.call(msg['channel_id'] as int, msg['message_id'] as int);
      return;
    }
```

Add a new field on `NotificationsWsClient` at the top of the class:

```dart
  void Function(int channelId, int messageId)? onNewMessage;
```

- [ ] **Step 3: Smoke test compiles**

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter analyze lib/services/notifications_ws.dart
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add tally_coding_app/lib/services/notifications_ws.dart
git commit -m "[s47] NotificationsWsClient: surface new_message events via onNewMessage callback"
```

### Task B7: task_channel.dart — replace event renderer with MessageFeed

**Files:**
- Modify: `tally_coding_app/lib/screens/task_channel.dart`

- [ ] **Step 1: Read the current task_channel.dart**

```bash
wc -l /home/nick/Projects/pronoic/tally-coding/tally_coding_app/lib/screens/task_channel.dart
```

Expected: ~1243 lines.  We are replacing the body of the channel content but keeping the surrounding scaffold + cost ticker + cap-abort dialog from Sprint 46.

- [ ] **Step 2: Replace the event-stream feed with MessageFeed**

In `task_channel.dart`, find the existing widget tree that renders task events (search for `frame.data['status']` or the SSE event handling).  In the same widget, replace the event-list rendering with:

```dart
import '../widgets/message_feed.dart';
import '../widgets/message_composer.dart';

// In the state:
List<Map<String, dynamic>> _messages = [];
int _lastMessageId = 0;
int? _channelId;

@override
void initState() {
  super.initState();
  _resolveChannelAndLoad();
}

Future<void> _resolveChannelAndLoad() async {
  // The task channel's id is exposed via GET /tasks/{taskId} as part of the
  // task row (Sprint 47 extends this), OR via GET /channels?workspace_id=...
  // For simplicity, fetch all workspace channels and filter by task_id.
  // (Workspace id can be hardcoded to 1 during sprint 47 since multi-workspace
  // UI doesn't ship until Sprint 50; admin always uses workspace_id=1.)
  final channels = await widget.client.listChannels(workspaceId: 1);
  final mine = channels.firstWhere(
    (c) => c['task_id'] == widget.taskId,
    orElse: () => const {},
  );
  if (mine.isNotEmpty) {
    _channelId = mine['id'] as int;
    await _loadMessages();
    _subscribeToWs();
  }
}

Future<void> _loadMessages() async {
  if (_channelId == null) return;
  final msgs = await widget.client.getMessages(channelId: _channelId!);
  if (!mounted) return;
  setState(() {
    _messages = msgs;
    _lastMessageId = msgs.isNotEmpty ? (msgs.first['id'] as int) : 0;
  });
}

void _subscribeToWs() {
  widget.wsClient.onNewMessage = (channelId, messageId) async {
    if (channelId != _channelId) return;
    final newMsgs = await widget.client.getMessages(
      channelId: _channelId!, sinceId: _lastMessageId,
    );
    if (!mounted) return;
    setState(() {
      _messages = [...newMsgs, ..._messages];
      if (newMsgs.isNotEmpty) _lastMessageId = newMsgs.first['id'] as int;
    });
  };
}

Future<void> _send(String text) async {
  if (_channelId == null) return;
  await widget.client.postMessage(channelId: _channelId!, text: text);
  // Optimistic refresh — WS will deliver the message but we eagerly refresh
  // in case WS is slow/disconnected
  await _loadMessages();
}
```

In the widget tree, replace the event-list rendering block with:

```dart
Expanded(
  child: MessageFeed(
    messages: _messages,
    onAnswerPrompt: (messageId, value) async {
      if (_channelId == null) return;
      await widget.client.postMessage(
        channelId: _channelId!,
        kind: 'interactive_prompt_response',
        payload: {'reply_to_id': messageId, 'value': value},
      );
    },
  ),
),
MessageComposer(
  onSend: _send,
  placeholder: 'Message...',
),
```

The cost ticker chip + cap-abort dialog from Sprint 46 stay in the channel header — don't remove them.

Add `wsClient` to the screen's constructor parameters; passed in from `discord_shell.dart`'s `_SignedInShell` (existing `NotificationsWsClient` instance from Sprint 46).

- [ ] **Step 3: Run flutter analyze**

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter analyze lib/screens/task_channel.dart
```

Expected: no errors.

- [ ] **Step 4: Run flutter test (no regressions)**

```bash
cd tally_coding_app && /home/nick/.local/flutter/bin/flutter test
```

Expected: 14 widget tests pass (10 from before + 4 new from this sprint).

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/screens/task_channel.dart
git commit -m "[s47] task_channel.dart: replace SSE event renderer with MessageFeed + Composer + WS"
```

---

## Phase C — Deploy + sprint completion (3 tasks, ~5h)

### Task C1: Build + push tally-orch:v27

**Files:**
- Modify: `services/orchestrator/Dockerfile` — bump LABEL version
- Modify: `services/orchestrator/docker-compose.yml` — bump image tag

- [ ] **Step 1: Update Dockerfile label**

```bash
sed -i 's/image.version=v26/image.version=v27/' /home/nick/Projects/pronoic/tally-coding/services/orchestrator/Dockerfile
grep "image.version" /home/nick/Projects/pronoic/tally-coding/services/orchestrator/Dockerfile
```

Expected: `LABEL org.opencontainers.image.version=v27`.

- [ ] **Step 2: Build + push**

```bash
cd /home/nick/Projects/pronoic/tally-coding
/usr/bin/docker build -t ghcr.io/nicholasraimbault/tally-orch:v27 -f services/orchestrator/Dockerfile .
/usr/bin/docker push ghcr.io/nicholasraimbault/tally-orch:v27
```

Expected: build succeeds; push lands.

- [ ] **Step 3: Update compose tag**

In `services/orchestrator/docker-compose.yml`:

```yaml
image: ghcr.io/nicholasraimbault/tally-orch:v27
```

- [ ] **Step 4: Commit**

```bash
git add services/orchestrator/Dockerfile services/orchestrator/docker-compose.yml
git commit -m "[s47] image: bump to v27"
```

### Task C2: Deploy v27 to Phala + live smoke

**Files:** None to write; deploy + smoke.

- [ ] **Step 1: Phala roll**

```bash
cd /home/nick/Projects/pronoic/tally-coding/services/orchestrator
/home/nick/.npm-global/bin/phala deploy --cvm-id app_c3b5481b3f33551af6270a21145df613160bf063 --compose docker-compose.yml --env .env.prod --wait
```

Expected: ~60s rolling update; `CVM is ready`.

- [ ] **Step 2: Live smoke tests**

```bash
export TT=$(grep -E "^TALLY_API_TOKEN=" /home/nick/Projects/pronoic/tally-coding/services/orchestrator/.env.prod | head -1 | cut -d= -f2-)
# 1. health
curl -s https://tally.pronoic.dev/health | jq .
# 2. /channels — admin workspace exists
curl -s -H "Authorization: Bearer $TT" "https://tally.pronoic.dev/channels?workspace_id=1" | jq '.channels[] | {id,kind,name}'
# 3. Post a message in #general
GEN=$(curl -s -H "Authorization: Bearer $TT" "https://tally.pronoic.dev/channels?workspace_id=1" | jq -r '.channels[] | select(.kind=="general") | .id')
curl -sX POST -H "Authorization: Bearer $TT" -H "content-type: application/json" \
  -d '{"text":"s47 smoke"}' "https://tally.pronoic.dev/channels/$GEN/messages" | jq .
# 4. Read it back
curl -s -H "Authorization: Bearer $TT" "https://tally.pronoic.dev/channels/$GEN/messages" | jq '.messages[0]'
```

Expected: all 200, message round-trips.

- [ ] **Step 3: Tag deploy**

```bash
git tag s47-deployed-v27
git push origin s47-deployed-v27
```

### Task C3: Sprint completion doc

**Files:**
- Create: `docs/SPRINT-47-COMPLETE.md`

- [ ] **Step 1: Write completion doc**

```bash
cat > /home/nick/Projects/pronoic/tally-coding/docs/SPRINT-47-COMPLETE.md << 'EOF'
# Sprint 47 — Chat foundation + permission groundwork

**Status:** Complete + deployed (`tally-orch:v27`)
**Date:** 2026-05-?? → 2026-??-??
**Image:** `tally-orch:v27` on `tally.pronoic.dev`

## What shipped

### Schema (5 new tables)
- `workspaces`, `workspace_members`, `channels`, `channel_members`, `messages`
- Backfill: admin user → default workspace + owner membership; existing tasks → task channels.

### REST endpoints (6 new)
- `GET /channels?workspace_id=N&include_archived=bool` — list channels
- `GET /channels/{id}/messages?limit=N&since_id=N` — paginated history
- `POST /channels/{id}/messages` — role-gated send
- `PATCH /channels/{id}/messages/{message_id}` — author-only edit
- `POST /channels/{id}/read` — update last_read_message_id
- `POST /channels/{id}/members/{user_id}/role_override` — admin-only per-channel role override

### WebSocket extension
- Existing `/ws/notifications` adds `{"type":"new_message","channel_id":N,"message_id":N}` frames
  delivered to every WS subscriber who is a member of the channel.

### Orchestrator agent context inclusion
- When the orchestrator dispatches an agent's next step, it fetches any new user messages in
  the task channel since the agent's previous step and prepends them to the agent's spec as
  a "User intervention (since last step)" block. Agent sees the new messages in its next LLM turn.

### Flutter
- `task_channel.dart` event-stream renderer replaced by `MessageFeedWidget` + `MessageComposer`.
- New widgets: `MessageBubble`, `InteractivePromptCard`, `MessageFeed`, `MessageComposer`.
- Existing `NotificationsWsClient` extended with `onNewMessage` callback for live updates.
- Cost ticker chip + cap-abort dialog from Sprint 46 remain in the channel header.

### Testing
- Orchestrator: ~26 new pytest tests across schema, channels, messages, permission, agent context, websocket.
- Flutter: 4 new widget test files covering MessageBubble, MessageFeed, MessageComposer, InteractivePromptCard, api.dart additions.

## Deferred (for Sprint 48-50)
- Workflow editor (Sprint 48)
- Pre-dispatch confirm modal (Sprint 48)
- Persistent scheduled agents (Sprint 49)
- DMs UI (Sprint 49 — data model supports from Sprint 47)
- Custom channel creation (Sprint 50)
- Multi-workspace switching UI (Sprint 50)
- Agent tool allowlist UI (Sprint 50)

## References
- Spec: docs/superpowers/specs/2026-05-20-discord-shaped-workspace-design.md
- Plan: docs/superpowers/plans/2026-05-20-sprint-47-chat-foundation.md
EOF
```

- [ ] **Step 2: Commit + push**

```bash
git add docs/SPRINT-47-COMPLETE.md
git commit -m "[s47] sprint completion doc"
git push origin main
```

- [ ] **Step 3: Tag the milestone**

```bash
git tag s47-phase-c-done
git tag s47-complete
git push origin s47-phase-c-done s47-complete
```

---

## Self-review

**1. Spec coverage:**

| Spec requirement | Tasks covering it |
|---|---|
| 5 new schema tables | A1 |
| Backfill existing data | A2 |
| Permission middleware | A3 |
| GET /channels | A4 |
| POST /channels/{id}/messages | A5 |
| GET /channels/{id}/messages | A6 |
| PATCH /channels/{id}/messages/{id} | A7 |
| POST /channels/{id}/read | A8 |
| POST /channels/{id}/members/{id}/role_override | A9 |
| WebSocket new_message broadcast | A10 |
| Agent context inclusion | A11 |
| Db.create_task creates channel | A12 |
| Smoke + tag Phase A | A13 |
| api.dart additions | B1 |
| MessageBubble | B2 |
| InteractivePromptCard | B3 |
| MessageFeed | B4 |
| MessageComposer | B5 |
| ChannelWs subscription | B6 |
| task_channel.dart rewrite | B7 |
| Image build + push | C1 |
| Deploy + smoke | C2 |
| Completion doc | C3 |

All spec items covered.

**2. Placeholder scan:** No TBDs, no "implement later", no vague language. Each step has either exact code or exact commands.

**3. Type consistency:** Verified — `channel_members.user_id` resolution, `messages.payload_json` access via `jsonDecode`, `WebSocket` event shape `{type: "new_message", channel_id, message_id}` consistent across A10 (server emit) and B6 (client receive).

Plan ready to execute.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-05-20-sprint-47-chat-foundation.md`.** Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Same workflow as Sprints 46 + 46.5.

**2. Inline Execution** — Execute tasks in this session using `executing-plans`, batch with checkpoints for review.

**Which approach?**
