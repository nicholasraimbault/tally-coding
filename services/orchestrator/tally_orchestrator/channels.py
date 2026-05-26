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


# ── Sprint 49: escalation helpers ─────────────────────────────────────────────

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

    Idempotent: if a DM already exists with BOTH parties as channel_members,
    returns it; else creates a new one.

    Example::

        ch = ensure_dm_channel(
            db, workspace_id=1,
            kind_a="human", id_a="alice",
            kind_b="tally", id_b=None,
        )
    """
    now = time.time()
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
    # Create a new DM channel.
    def _label(kind: str, ident: str | None) -> str:
        if kind == "human":
            return ident or "?"
        if kind == "tally":
            return "tally"
        return f"agent-{ident}"
    name = "-".join(sorted([_label(kind_a, id_a), _label(kind_b, id_b)]))
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
    """Sprint 49: react to a kind='escalation' message.

    Identifies the workspace owner, ensures a Tally↔owner DM channel exists,
    and posts a templated message in it.  Returns the DM channel_id, or None
    if the message_id doesn't point to an escalation message or the source
    channel's workspace can't be resolved.

    Example::

        dm_ch = handle_escalation(db, channel_id=sa_ch, message_id=msg_id)
    """
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
    src_row = db._conn.execute(
        "SELECT c.name, c.workspace_id, w.owner_user_id "
        "FROM channels c JOIN workspaces w ON c.workspace_id=w.id "
        "WHERE c.id=?",
        (channel_id,),
    ).fetchone()
    if src_row is None:
        return None
    channel_name, workspace_id, owner_user_id = src_row
    dm_ch = ensure_dm_channel(
        db, workspace_id=workspace_id,
        kind_a="human", id_a=owner_user_id,
        kind_b="tally", id_b=None,
    )
    text = ESCALATION_DM_TEMPLATE.format(
        owner=owner_user_id, agent_name=agent_name, agent_role=agent_role,
        reason=reason, channel_name=channel_name,
    )
    insert_message(
        db, channel_id=dm_ch, author_kind="tally", kind="text",
        payload={"text": text},
    )
    return dm_ch


# ── B4: long-term channel escalation routing ──────────────────────────────────


def get_workspace_escalation_channel_id(db: "Db", *, workspace_id: int) -> int | None:
    """Return the channel_id that escalations should be routed to for a workspace.

    Resolution order:
    1. workspaces.settings_json["escalation_channel_id"] if set and channel exists.
    2. The workspace's #general channel (kind='general').
    3. None if neither exists.

    Example::

        ch = get_workspace_escalation_channel_id(db, workspace_id=1)
    """
    # Try settings_json override first.
    row = db._conn.execute(
        "SELECT settings_json FROM workspaces WHERE id=? AND deleted_at IS NULL",
        (workspace_id,),
    ).fetchone()
    if row:
        try:
            settings = json.loads(row[0] or "{}")
            override_id = settings.get("escalation_channel_id")
            if override_id:
                exists = db._conn.execute(
                    "SELECT 1 FROM channels WHERE id=? AND archived_at IS NULL",
                    (int(override_id),),
                ).fetchone()
                if exists:
                    return int(override_id)
        except (TypeError, ValueError, KeyError):
            pass
    # Fall back to #general.
    gen = db._conn.execute(
        "SELECT id FROM channels WHERE workspace_id=? AND kind='general' "
        "AND archived_at IS NULL LIMIT 1",
        (workspace_id,),
    ).fetchone()
    return int(gen[0]) if gen else None


def route_escalation_to_long_term_channel(
    db: "Db",
    *,
    task_channel_id: int,
    message_id: int,
) -> tuple[int, int] | None:
    """B4: route a kind='escalation' message from a task channel to the workspace's
    long-term escalation channel (default #general).

    Inserts a new kind='escalation' message authored by 'tally' in the long-term
    channel with structured payload:
        {
          "question": str,
          "quick_reply_options": list[str],
          "task_id": str,
          "task_name": str,
          "source_channel_id": int,
          "source_message_id": int,
          "queue_position": int,
        }

    Returns (long_term_channel_id, new_message_id) on success, None if the
    source message is not an escalation or workspace cannot be resolved.

    Example::

        result = route_escalation_to_long_term_channel(
            db, task_channel_id=task_ch, message_id=msg_id
        )
    """
    msg_row = db._conn.execute(
        "SELECT channel_id, kind, payload_json FROM messages WHERE id=? AND kind='escalation'",
        (message_id,),
    ).fetchone()
    if msg_row is None:
        return None

    payload = json.loads(msg_row[2] or "{}")

    # Resolve workspace + owner from the task channel.
    src_row = db._conn.execute(
        "SELECT c.workspace_id, c.task_id, c.name, w.owner_user_id "
        "FROM channels c JOIN workspaces w ON c.workspace_id=w.id "
        "WHERE c.id=?",
        (task_channel_id,),
    ).fetchone()
    if src_row is None:
        return None
    workspace_id, task_id, channel_name, _owner = src_row

    lt_channel_id = get_workspace_escalation_channel_id(db, workspace_id=workspace_id)
    if lt_channel_id is None:
        return None

    # Count pending escalations ahead in this channel for queue_position.
    pending_count = db._conn.execute(
        "SELECT COUNT(*) FROM messages "
        "WHERE channel_id=? AND kind='escalation' AND edited_at IS NULL",
        (lt_channel_id,),
    ).fetchone()
    queue_position = int(pending_count[0] or 0) + 1

    task_name = channel_name  # channel name mirrors task description (truncated)
    new_payload = {
        "question": payload.get("question") or payload.get("reason") or "Agent needs input.",
        "quick_reply_options": payload.get("quick_reply_options") or [],
        "task_id": task_id or "",
        "task_name": task_name,
        "source_channel_id": task_channel_id,
        "source_message_id": message_id,
        "queue_position": queue_position,
    }
    new_msg_id = insert_message(
        db,
        channel_id=lt_channel_id,
        author_kind="tally",
        kind="escalation",
        payload=new_payload,
    )
    return lt_channel_id, new_msg_id
