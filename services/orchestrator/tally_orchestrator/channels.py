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

    `limit` is clamped to [1, 200] regardless of caller input.
    """
    limit = min(max(1, limit), 200)
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
    Messages without a text payload key are skipped.
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
            payload = json.loads(payload_json) if payload_json else {}
        except (TypeError, ValueError):
            payload = {}
        text = payload.get("text", "")
        if text:
            out.append({
                "text": text,
                "author_user_id": author_user_id,
                "created_at": created_at,
            })
    return out
