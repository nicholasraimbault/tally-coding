# services/orchestrator/tally_orchestrator/notifications.py
"""Sprint 46: notification rules + push fan-out.

Doorbell pattern: push payloads never carry content.  We send empty
signals; the client fetches actual notification rows over
authenticated TLS.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import random
import time
from typing import TYPE_CHECKING

import httpx

if TYPE_CHECKING:
    from .service import Db

logger = logging.getLogger("tally.notifications")

_ACTIVE_WS: dict[str, list] = {}


def register_websocket(user_id: str, ws) -> None:
    _ACTIVE_WS.setdefault(user_id, []).append(ws)


def unregister_websocket(user_id: str, ws) -> None:
    lst = _ACTIVE_WS.get(user_id) or []
    try:
        lst.remove(ws)
    except ValueError:
        pass
    if not lst and user_id in _ACTIVE_WS:
        del _ACTIVE_WS[user_id]


def active_websockets_for_user(user_id: str) -> list:
    return list(_ACTIVE_WS.get(user_id) or [])


def insert_notification(db: "Db", user_id: str, *, kind: str, severity: str = "info",
                        payload: dict | None = None, rule_id: int | None = None) -> int:
    """Insert one notification row; returns its id."""
    cur = db._conn.execute(
        "INSERT INTO notifications "
        "(user_id, rule_id, kind, severity, payload_json, created_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (user_id, rule_id, kind, severity, json.dumps(payload or {}), time.time()),
    )
    # cur.lastrowid is `int | None` per sqlite3 typing, but is always an
    # int after a successful INSERT with a ROWID/AUTOINCREMENT PK.
    return int(cur.lastrowid or 0)


def list_notifications(db: "Db", user_id: str, *, limit: int = 50,
                       since_id: int | None = None, include_dismissed: bool = False) -> list[dict]:
    where = ["user_id=?"]
    params: list = [user_id]
    if since_id is not None:
        where.append("id > ?")
        params.append(since_id)
    if not include_dismissed:
        where.append("dismissed_at IS NULL")
    params.append(limit)
    rows = db._conn.execute(
        f"SELECT id, user_id, rule_id, kind, severity, payload_json, "
        f"created_at, dismissed_at FROM notifications "
        f"WHERE {' AND '.join(where)} ORDER BY created_at DESC LIMIT ?",
        params,
    ).fetchall()
    return [
        {"id": r[0], "user_id": r[1], "rule_id": r[2], "kind": r[3],
         "severity": r[4], "payload_json": r[5],
         "created_at": r[6], "dismissed_at": r[7]}
        for r in rows
    ]


def dismiss_notification(db: "Db", user_id: str, notification_id: int) -> bool:
    cur = db._conn.execute(
        "UPDATE notifications SET dismissed_at=? "
        "WHERE id=? AND user_id=? AND dismissed_at IS NULL",
        (time.time(), notification_id, user_id),
    )
    return cur.rowcount > 0


def seed_default_rules(db: "Db", user_id: str, *, plan: str) -> None:
    """Free + Mode 3 users get no defaults. Paid tiers get period_pct=80 + 100."""
    if plan == "free":
        return
    quota = db.get_or_create_quota(user_id)
    if int(quota.get("auto_recharge_mode") or 0) == 3:
        return
    existing = db._conn.execute(
        "SELECT COUNT(*) FROM notification_rules WHERE user_id=? AND kind='period_pct'",
        (user_id,),
    ).fetchone()
    if int(existing[0]) > 0:
        return
    now = time.time()
    for threshold in (80, 100):
        db._conn.execute(
            "INSERT INTO notification_rules "
            "(user_id, kind, threshold, enabled, created_at) "
            "VALUES (?, 'period_pct', ?, 1, ?)",
            (user_id, threshold, now),
        )


def evaluate_rules_for_cost_event(db: "Db", user_id: str) -> list[dict]:
    """Fire rules once per period.  Returns list of fired notifications."""
    from .service import QUOTA_PLANS
    quota = db.get_or_create_quota(user_id)
    plan = QUOTA_PLANS.get(quota["plan"], QUOTA_PLANS["free"])
    used = db.credits_used_this_period(user_id, quota["period_start"])
    included = max(1, int(plan["included_credits"]))
    pct = (used * 100) // included
    fired: list[dict] = []
    rules = db._conn.execute(
        "SELECT id, kind, threshold, last_fired_at FROM notification_rules "
        "WHERE user_id=? AND enabled=1",
        (user_id,),
    ).fetchall()
    now = time.time()
    for rid, kind, threshold, last_fired_at in rules:
        # Per-rule-kind idempotency window: period_pct resets at billing
        # period rollover (30d); daily/weekly reset on their own clocks.
        if kind == "period_pct":
            if last_fired_at is not None and last_fired_at >= quota["period_start"]:
                continue
        elif kind == "daily_amount":
            if last_fired_at is not None and last_fired_at >= (now - 86400):
                continue
        elif kind == "weekly_amount":
            if last_fired_at is not None and last_fired_at >= (now - 7 * 86400):
                continue
        if kind == "period_pct" and pct >= int(threshold):
            nid = insert_notification(db, user_id, kind="period_pct_crossed",
                severity="warning" if int(threshold) >= 100 else "info",
                payload={"threshold_pct": int(threshold), "used_credits": used,
                         "included_credits": included},
                rule_id=rid)
            db._conn.execute("UPDATE notification_rules SET last_fired_at=? WHERE id=?",
                (time.time(), rid))
            fired.append({"id": nid, "kind": "period_pct_crossed", "threshold": int(threshold)})
        elif kind == "daily_amount":
            day_used = db.credits_used_in_window(user_id, now - 86400)
            if day_used >= int(threshold):
                nid = insert_notification(db, user_id, kind="daily_amount_reached",
                    severity="info", payload={"threshold": int(threshold), "used": day_used},
                    rule_id=rid)
                db._conn.execute("UPDATE notification_rules SET last_fired_at=? WHERE id=?",
                    (time.time(), rid))
                fired.append({"id": nid, "kind": "daily_amount_reached"})
        elif kind == "weekly_amount":
            week_used = db.credits_used_in_window(user_id, now - 7 * 86400)
            if week_used >= int(threshold):
                nid = insert_notification(db, user_id, kind="weekly_amount_reached",
                    severity="info", payload={"threshold": int(threshold), "used": week_used},
                    rule_id=rid)
                db._conn.execute("UPDATE notification_rules SET last_fired_at=? WHERE id=?",
                    (time.time(), rid))
                fired.append({"id": nid, "kind": "weekly_amount_reached"})
    return fired


async def fan_out_push(db: "Db", user_id: str, notification_id: int) -> None:
    """Doorbell: jitter, WS broadcast, UnifiedPush wake."""
    max_jitter = float(os.environ.get("TALLY_PUSH_JITTER_MAX_S", "5"))
    await asyncio.sleep(random.uniform(0, max_jitter))
    for ws in active_websockets_for_user(user_id):
        try:
            await ws.send_json({"type": "new_notification", "id": notification_id})
        except Exception as exc:
            logger.warning("ws send failed for user=%s: %s", user_id, exc)
    devices = db._conn.execute(
        "SELECT provider, endpoint_url FROM push_devices WHERE user_id=? AND enabled=1",
        (user_id,),
    ).fetchall()
    for provider, endpoint in devices:
        if provider == "unifiedpush" and endpoint:
            try:
                async with httpx.AsyncClient(timeout=5.0) as cli:
                    await cli.post(endpoint, content=b"")
                db._conn.execute(
                    "UPDATE push_devices SET last_seen_at=? WHERE user_id=? AND endpoint_url=?",
                    (time.time(), user_id, endpoint),
                )
            except Exception as exc:
                logger.warning("unifiedpush POST failed for %s: %s", endpoint, exc)


async def emit_notification(db: "Db", user_id: str, *, kind: str, severity: str = "info",
                            payload: dict | None = None, rule_id: int | None = None) -> int:
    """Insert + fan-out in one call."""
    nid = insert_notification(db, user_id, kind=kind, severity=severity, payload=payload, rule_id=rule_id)
    asyncio.create_task(fan_out_push(db, user_id, nid))
    return nid


async def emit_escalation_push(
    db: "Db",
    *,
    user_id: str,
    escalation_message_id: int,
    channel_id: int,
    payload: dict,
) -> None:
    """B4: fan-out a push for an escalation, carrying the full payload.

    Unlike the existing doorbell push (which sends empty content and has the
    client fetch), escalation pushes encode question + quick_reply_options
    directly into the push body. This lets the OS render inline action buttons
    without requiring the app to be open.

    'Open' is always appended as the last action so the user can always deep-link
    to the long-term channel.

    The push body is JSON:
        {
          "type": "escalation",
          "escalation_message_id": int,
          "channel_id": int,
          "question": str,
          "quick_reply_options": ["Option A", "Option B", ..., "Open"],
        }
    """
    quick_replies = list(payload.get("quick_reply_options") or [])
    if "Open" not in quick_replies:
        quick_replies.append("Open")

    push_body = json.dumps({
        "type": "escalation",
        "escalation_message_id": escalation_message_id,
        "channel_id": channel_id,
        "question": payload.get("question") or "",
        "quick_reply_options": quick_replies,
    }).encode()

    # WebSocket broadcast (best-effort, app may be in foreground).
    for ws in active_websockets_for_user(user_id):
        try:
            await ws.send_json({
                "type": "new_escalation",
                "escalation_message_id": escalation_message_id,
                "channel_id": channel_id,
            })
        except Exception as exc:
            logger.warning("ws escalation send failed for user=%s: %s", user_id, exc)

    # UnifiedPush / push devices (app may be closed).
    devices = db._conn.execute(
        "SELECT provider, endpoint_url FROM push_devices WHERE user_id=? AND enabled=1",
        (user_id,),
    ).fetchall()
    for provider, endpoint in devices:
        if provider == "unifiedpush" and endpoint:
            try:
                async with httpx.AsyncClient(timeout=5.0) as cli:
                    await cli.post(endpoint, content=push_body)
                db._conn.execute(
                    "UPDATE push_devices SET last_seen_at=? WHERE user_id=? AND endpoint_url=?",
                    (time.time(), user_id, endpoint),
                )
            except Exception as exc:
                logger.warning("unifiedpush escalation POST failed for %s: %s", endpoint, exc)
