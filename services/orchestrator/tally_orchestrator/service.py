"""Tally orchestration service.

HTTP API around a single long-lived MLS session with a worker CVM.
Wake routing happens over Tally Workers; the wake payload is MLS ciphertext.

Bootstrap (once on startup):
  request_kp wake → receive worker's KeyPackage
  create_and_add → produce Welcome
  welcome wake → worker joins the group

Per-task:
  POST /tasks {"description": "..."}
    → enqueue in SQLite, return task_id immediately
  background processor:
    pending → encrypt → dispatch task:start wake → wait → decrypt → store result
  GET /tasks/{task_id} → status + result
  GET /tasks → list

The orchestrator handles tasks serially because MlsEngine's encrypt/decrypt
ratchet is sender-stateful — concurrent encryptions would corrupt state.
"""

from __future__ import annotations

import asyncio
import base64
import hmac
import json
import logging
import os
import secrets
import sqlite3
import time
import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel
from sse_starlette.sse import EventSourceResponse

from tally_coding_core.identity import bearer_from_pubkey, load_or_create_identity
from tally_coding_core.mls import MlsSession
from tally_coding_core.tally_workers import TallyWorkersClient

from .worker_pool import WorkerPool

logger = logging.getLogger("tally.orchestrator")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")

BOOTSTRAP_CONTEXT_ID = "mls:bootstrap"
TASK_CONTEXT_ID = "task:start"
EVENT_CONTEXT_ID = "task:event"
FS_LIST_CONTEXT_ID = "task:fs:list"
FS_READ_CONTEXT_ID = "task:fs:read"
SCHEMA = """
CREATE TABLE IF NOT EXISTS tasks (
    id              TEXT PRIMARY KEY,
    description     TEXT NOT NULL,
    status          TEXT NOT NULL,
    result_json     TEXT,
    error           TEXT,
    created_at      REAL NOT NULL,
    updated_at      REAL NOT NULL,
    worker_identity TEXT  -- which WorkerHandle ran this; null until dispatched
);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);

CREATE TABLE IF NOT EXISTS events (
    task_id      TEXT NOT NULL,
    seq          INTEGER NOT NULL,
    event_json   TEXT NOT NULL,
    received_at  REAL NOT NULL,
    PRIMARY KEY (task_id, seq)
);
CREATE INDEX IF NOT EXISTS idx_events_task ON events(task_id, received_at);

CREATE TABLE IF NOT EXISTS workers (
    cvm_id      TEXT PRIMARY KEY,
    app_id      TEXT,
    team_id     TEXT NOT NULL,
    identity    TEXT NOT NULL,
    status      TEXT NOT NULL,   -- 'active' or 'retired'
    created_at  REAL NOT NULL,
    retired_at  REAL
);
CREATE INDEX IF NOT EXISTS idx_workers_status ON workers(status);
"""


def b64url_no_pad(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def b64url_decode(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


class TaskSubmit(BaseModel):
    description: str


class TaskResponse(BaseModel):
    id: str
    description: str
    status: str
    result: dict | None = None
    error: str | None = None
    created_at: float
    updated_at: float


class Db:
    """Tiny synchronous SQLite wrapper. All access goes through this class."""

    def __init__(self, path: str) -> None:
        self.path = path
        self._conn = sqlite3.connect(path, isolation_level=None, check_same_thread=False)
        self._conn.executescript(SCHEMA)
        # Idempotent column-adds for upgrades from older DBs. SQLite has no
        # "ALTER TABLE ADD COLUMN IF NOT EXISTS"; catching the "duplicate
        # column" error is the canonical workaround.
        try:
            self._conn.execute("ALTER TABLE tasks ADD COLUMN worker_identity TEXT")
        except sqlite3.OperationalError:
            pass

    _TASK_COLS = "id, description, status, result_json, error, created_at, updated_at, worker_identity"

    def create_task(self, description: str) -> str:
        task_id = uuid.uuid4().hex
        now = time.time()
        self._conn.execute(
            "INSERT INTO tasks (id, description, status, created_at, updated_at) VALUES (?, ?, 'pending', ?, ?)",
            (task_id, description, now, now),
        )
        return task_id

    def get_task(self, task_id: str) -> dict | None:
        row = self._conn.execute(
            f"SELECT {self._TASK_COLS} FROM tasks WHERE id = ?", (task_id,),
        ).fetchone()
        return self._row_to_dict(row) if row else None

    def list_tasks(self, limit: int = 100) -> list[dict]:
        rows = self._conn.execute(
            f"SELECT {self._TASK_COLS} FROM tasks ORDER BY created_at DESC LIMIT ?", (limit,),
        ).fetchall()
        return [self._row_to_dict(r) for r in rows]

    def next_pending(self) -> dict | None:
        row = self._conn.execute(
            f"SELECT {self._TASK_COLS} FROM tasks WHERE status = 'pending' ORDER BY created_at LIMIT 1"
        ).fetchone()
        return self._row_to_dict(row) if row else None

    def set_task_worker(self, task_id: str, worker_identity: str) -> None:
        """Record which worker is handling this task; used later for fs:list/fs:read routing."""
        self._conn.execute(
            "UPDATE tasks SET worker_identity=? WHERE id=?",
            (worker_identity, task_id),
        )

    def get_task_worker(self, task_id: str) -> str | None:
        row = self._conn.execute(
            "SELECT worker_identity FROM tasks WHERE id=?", (task_id,),
        ).fetchone()
        return row[0] if row and row[0] else None

    def mark_running(self, task_id: str) -> None:
        self._conn.execute(
            "UPDATE tasks SET status='running', updated_at=? WHERE id=?",
            (time.time(), task_id),
        )

    def mark_completed(self, task_id: str, result: dict) -> None:
        self._conn.execute(
            "UPDATE tasks SET status='completed', result_json=?, updated_at=? WHERE id=?",
            (json.dumps(result), time.time(), task_id),
        )

    def mark_failed(self, task_id: str, error: str) -> None:
        self._conn.execute(
            "UPDATE tasks SET status='failed', error=?, updated_at=? WHERE id=?",
            (error, time.time(), task_id),
        )

    def recover_stuck_running(self, error: str) -> int:
        """Demote every status='running' row to status='failed' with the
        given error message. Called once at orchestrator startup to clear
        orphans left behind by a crash, OOM, or hard restart — the
        processor loop only considers status='pending' rows, so without
        this step the orphans would sit forever, invisible.

        Returns the number of rows demoted. Marking them failed rather
        than re-pending is intentional: a still-running worker on the
        other side might be mid-task; demoting to pending would cause
        a duplicate dispatch that races for the same `/workspace`. Users
        can resubmit explicitly if they want a retry."""
        now = time.time()
        cursor = self._conn.execute(
            "UPDATE tasks SET status='failed', error=?, updated_at=? WHERE status='running'",
            (error, now),
        )
        return cursor.rowcount or 0

    def insert_event(self, task_id: str, seq: int, event: dict) -> None:
        """Insert a streaming event from the worker. Idempotent on (task_id, seq)."""
        self._conn.execute(
            "INSERT OR IGNORE INTO events (task_id, seq, event_json, received_at) VALUES (?, ?, ?, ?)",
            (task_id, seq, json.dumps(event), time.time()),
        )

    # ── worker pool state ──────────────────────────────────────────────────

    def upsert_active_worker(
        self, *, cvm_id: str, app_id: str | None, team_id: str, identity: str
    ) -> None:
        # Only one 'active' worker at a time; demote any prior one first.
        self._conn.execute(
            "UPDATE workers SET status='retired', retired_at=? WHERE status='active'",
            (time.time(),),
        )
        self._conn.execute(
            "INSERT OR REPLACE INTO workers (cvm_id, app_id, team_id, identity, status, created_at) "
            "VALUES (?, ?, ?, ?, 'active', ?)",
            (cvm_id, app_id, team_id, identity, time.time()),
        )

    def get_active_worker(self) -> dict | None:
        row = self._conn.execute(
            "SELECT cvm_id, app_id, team_id, identity, status, created_at, retired_at "
            "FROM workers WHERE status = 'active' ORDER BY created_at DESC LIMIT 1"
        ).fetchone()
        if not row:
            return None
        return self._worker_row(row)

    def list_active_workers(self) -> list[dict]:
        """All active workers (sprint 14: pool may contain N>1)."""
        rows = self._conn.execute(
            "SELECT cvm_id, app_id, team_id, identity, status, created_at, retired_at "
            "FROM workers WHERE status = 'active' ORDER BY created_at"
        ).fetchall()
        return [self._worker_row(r) for r in rows]

    def add_active_worker(self, *, cvm_id: str, app_id: str | None, team_id: str, identity: str) -> None:
        """Insert a new active worker without retiring the existing ones (sprint 14)."""
        self._conn.execute(
            "INSERT OR REPLACE INTO workers (cvm_id, app_id, team_id, identity, status, created_at) "
            "VALUES (?, ?, ?, ?, 'active', ?)",
            (cvm_id, app_id, team_id, identity, time.time()),
        )

    @staticmethod
    def _worker_row(row: tuple) -> dict:
        return {
            "cvm_id": row[0], "app_id": row[1], "team_id": row[2], "identity": row[3],
            "status": row[4], "created_at": row[5], "retired_at": row[6],
        }

    def retire_worker(self, cvm_id: str) -> None:
        self._conn.execute(
            "UPDATE workers SET status='retired', retired_at=? WHERE cvm_id=?",
            (time.time(), cvm_id),
        )

    def list_events(self, task_id: str, since_seq: int = -1) -> list[dict]:
        rows = self._conn.execute(
            "SELECT seq, event_json, received_at FROM events "
            "WHERE task_id = ? AND seq > ? ORDER BY seq",
            (task_id, since_seq),
        ).fetchall()
        return [
            {"seq": r[0], "received_at": r[2], **json.loads(r[1])}
            for r in rows
        ]

    @staticmethod
    def _row_to_dict(row: tuple) -> dict:
        return {
            "id": row[0],
            "description": row[1],
            "status": row[2],
            "result": json.loads(row[3]) if row[3] else None,
            "error": row[4],
            "created_at": row[5],
            "updated_at": row[6],
            "worker_identity": row[7] if len(row) > 7 else None,
        }


class EventBus:
    """In-memory per-task subscriber lists, used to push events to SSE clients
    the moment they're persisted (instead of forcing the client to poll the DB).
    Subscriptions die when the asyncio Queue is GC'd or the endpoint cleans up
    explicitly in its finally block."""

    def __init__(self) -> None:
        self._subs: dict[str, list[asyncio.Queue]] = {}
        self._lock = asyncio.Lock()

    async def subscribe(self, task_id: str) -> asyncio.Queue:
        q: asyncio.Queue = asyncio.Queue(maxsize=1000)
        async with self._lock:
            self._subs.setdefault(task_id, []).append(q)
        return q

    async def unsubscribe(self, task_id: str, q: asyncio.Queue) -> None:
        async with self._lock:
            if task_id in self._subs:
                self._subs[task_id] = [x for x in self._subs[task_id] if x is not q]
                if not self._subs[task_id]:
                    del self._subs[task_id]

    async def publish(self, task_id: str, event: dict) -> None:
        async with self._lock:
            queues = list(self._subs.get(task_id, []))
        for q in queues:
            try:
                q.put_nowait(event)
            except asyncio.QueueFull:
                # Slow subscriber; drop to keep the bus responsive.
                logger.warning("dropped event for task %s subscriber (queue full)", task_id[:8])


from dataclasses import dataclass, field


@dataclass
class WorkerHandle:
    """One worker's view in the orchestrator: identity, MLS session, lock.
    The lock is held while a task is being dispatched against this worker —
    the MLS sender ratchet is single-writer, so concurrent encrypts would
    corrupt state. Concurrency comes from having N WorkerHandles."""
    identity: str
    team_id: str
    cvm_id: str
    app_id: str | None
    session: MlsSession
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    failures: int = 0  # consecutive task failures on this handle


class Orchestrator:
    """Pool of WorkerHandles. Concurrent task dispatch up to len(handles).

    Each handle owns one MLS group with one worker. The orchestrator itself
    has a single Ed25519 identity (the bearer that all workers dispatch
    events back to)."""

    def __init__(
        self,
        *,
        tally_url: str,
        identity_path: str,
        mls_state_base_dir: str,
        db: Db,
        event_bus: EventBus,
    ) -> None:
        self.tally_url = tally_url
        self.db = db
        self.event_bus = event_bus
        self.mls_state_base = Path(mls_state_base_dir)
        self.mls_state_base.mkdir(parents=True, exist_ok=True)
        _privkey, pubkey = load_or_create_identity(identity_path)
        self.pubkey = pubkey
        self.bearer = bearer_from_pubkey(pubkey)
        self.client = TallyWorkersClient(base_url=tally_url)
        self.handles: dict[str, WorkerHandle] = {}     # keyed by worker identity
        self.pollers: dict[str, asyncio.Task] = {}     # keyed by team_id
        self._auto_rotate_threshold = int(os.environ.get("TALLY_AUTO_ROTATE_THRESHOLD", "3"))
        self._rotating: set[str] = set()  # identities currently being rotated
        self._inflight_task_ids: set[str] = set()  # task IDs currently dispatched

    # ── handle lifecycle ──────────────────────────────────────────────────

    def _session_dir(self, team_id: str) -> Path:
        d = self.mls_state_base / f"team-{team_id}"
        d.mkdir(parents=True, exist_ok=True)
        return d

    def add_handle(self, *, team_id: str, worker_identity: str, cvm_id: str, app_id: str | None) -> WorkerHandle:
        """Construct a WorkerHandle (no bootstrap yet). Caller must call
        bootstrap_handle() before the handle is usable for tasks."""
        group_id = f"orch-worker-{team_id}".encode("utf-8")
        session = MlsSession(
            data_dir=str(self._session_dir(team_id)),
            identity=self.pubkey,
            group_id=group_id,
        )
        handle = WorkerHandle(
            identity=worker_identity, team_id=team_id, cvm_id=cvm_id,
            app_id=app_id, session=session,
        )
        self.handles[worker_identity] = handle
        return handle

    def bootstrap_handle(self, handle: WorkerHandle) -> None:
        """3-wake handshake against handle's worker. Also registers the
        orchestrator's bearer as the task:event handler in the worker's team
        so events route back through tally-workers correctly."""
        self.client.team_init(handle.team_id, bearer=self.bearer)
        self.client.register(handle.team_id, self.bearer, bearer=self.bearer, context_id=EVENT_CONTEXT_ID)
        logger.info("bootstrap[%s]: requesting worker key package", handle.identity[:8])
        kp_resp = self._dispatch_blocking(
            handle, context_id=BOOTSTRAP_CONTEXT_ID,
            payload=json.dumps({"phase": "request_kp"}).encode("utf-8"),
            timeout_seconds=60,
        )
        worker_kp = b64url_decode(json.loads(kp_resp.decode("utf-8"))["key_package"])
        welcome_bytes = None
        for attempt in range(6):
            try:
                welcome_bytes = handle.session.create_and_add(worker_kp)
                break
            except Exception as exc:
                if "InvalidLifetime" in str(exc) and attempt < 5:
                    logger.warning("bootstrap[%s] InvalidLifetime (attempt %d/6); sleeping 5s",
                                   handle.identity[:8], attempt + 1)
                    time.sleep(5)
                    continue
                raise
        if welcome_bytes is None:
            raise RuntimeError(f"create_and_add failed for worker {handle.identity[:12]}")
        ack = self._dispatch_blocking(
            handle, context_id=BOOTSTRAP_CONTEXT_ID,
            payload=json.dumps({"phase": "welcome", "welcome": b64url_no_pad(welcome_bytes)}).encode("utf-8"),
            timeout_seconds=60,
        )
        if not json.loads(ack.decode("utf-8")).get("ok"):
            raise RuntimeError(f"worker {handle.identity[:12]} rejected welcome")
        logger.info("bootstrap[%s]: MLS session established (team=%s)", handle.identity[:8], handle.team_id)

    def remove_handle(self, identity: str) -> WorkerHandle | None:
        """Drop a handle from the pool. Caller must stop its poller separately."""
        return self.handles.pop(identity, None)

    # ── dispatch ──────────────────────────────────────────────────────────

    def _dispatch_blocking(self, handle: WorkerHandle, *, context_id: str, payload: bytes, timeout_seconds: int) -> bytes:
        result = self.client.dispatch_wake(
            team_id=handle.team_id,
            target_identity=handle.identity,
            context_id=context_id,
            payload=b64url_no_pad(payload),
            timeout_seconds=timeout_seconds,
            bearer=self.bearer,
        )
        return b64url_decode(result["response"])

    async def acquire_idle(self, timeout: float = 60.0) -> WorkerHandle:
        """Wait up to `timeout` for any handle to be unlocked, then acquire it.
        Picks the first idle handle in dict-insertion order (no priority)."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for handle in list(self.handles.values()):
                if not handle.lock.locked():
                    try:
                        await asyncio.wait_for(handle.lock.acquire(), timeout=0.01)
                        return handle
                    except asyncio.TimeoutError:
                        continue
            await asyncio.sleep(0.5)
        raise TimeoutError(f"no idle worker available within {timeout}s")

    async def _publish_status(self, task_id: str, status: str, extra: dict | None = None) -> None:
        payload = {"task_id": task_id, "status": status, "ts": time.time()}
        if extra:
            payload.update(extra)
        await self.event_bus.publish(task_id, {"_kind": "status_change", **payload})

    async def process_task(self, task: dict) -> None:
        """Acquire an idle handle, encrypt+dispatch the task via that handle's
        MLS session, persist result, release. Failures bump the handle's
        failure counter; consecutive failures across the threshold trigger a
        per-handle rotation (other handles keep serving traffic)."""
        try:
            handle = await self.acquire_idle(timeout=int(os.environ.get("TALLY_ACQUIRE_TIMEOUT", "120")))
        except TimeoutError as exc:
            logger.error("task %s: no worker available within timeout", task["id"][:8])
            self.db.mark_failed(task["id"], str(exc))
            await self._publish_status(task["id"], "failed", {"error": str(exc)})
            return
        try:
            self.db.set_task_worker(task["id"], handle.identity)
            self.db.mark_running(task["id"])
            await self._publish_status(task["id"], "running")
            logger.info("running task %s on worker %s: %s",
                        task["id"][:8], handle.identity[:8], task["description"][:60])
            try:
                payload_obj = {
                    "task": task["description"],
                    "task_id": task["id"],
                    "orchestrator_bearer": self.bearer,
                }
                ciphertext = handle.session.encrypt(json.dumps(payload_obj).encode("utf-8"))
                response_bytes = await asyncio.to_thread(
                    self._dispatch_blocking, handle,
                    context_id=TASK_CONTEXT_ID,
                    payload=ciphertext,
                    timeout_seconds=int(os.environ.get("TALLY_TASK_DISPATCH_TIMEOUT", "300")),
                )
                response_plain = handle.session.decrypt(response_bytes).decode("utf-8")
                result = json.loads(response_plain)
                self.db.mark_completed(task["id"], result)
                await self._publish_status(task["id"], "completed", {"success": result.get("success")})
                logger.info("task %s completed on worker %s: success=%s",
                            task["id"][:8], handle.identity[:8], result.get("success"))
                handle.failures = 0
            except Exception as exc:
                logger.exception("task %s on worker %s failed", task["id"][:8], handle.identity[:8])
                self.db.mark_failed(task["id"], str(exc))
                await self._publish_status(task["id"], "failed", {"error": str(exc)})
                handle.failures += 1
                if handle.failures >= self._auto_rotate_threshold and handle.identity not in self._rotating:
                    logger.warning("auto-rotating worker %s after %d failures",
                                   handle.identity[:8], handle.failures)
                    self._rotating.add(handle.identity)
                    asyncio.create_task(self._rotate_handle(handle))
        finally:
            handle.lock.release()

    async def _rotate_handle(self, handle: WorkerHandle) -> WorkerHandle | None:
        """Replace one specific handle. Other handles keep serving traffic
        while this one is being swapped — no service exit needed.

        Returns the new handle on success, None on failure. Caller is
        responsible for adding/removing from self._rotating around the call."""
        pool: WorkerPool | None = state.get("worker_pool")
        if pool is None:
            logger.error("rotate requested but worker pool not initialised")
            self._rotating.discard(handle.identity)
            return None
        old_cvm = handle.cvm_id
        old_identity = handle.identity
        old_team = handle.team_id
        try:
            logger.info("rotate[%s]: provisioning replacement", old_identity[:8])
            new = await asyncio.to_thread(pool.provision)
            assert new.identity is not None
            self.db.add_active_worker(
                cvm_id=new.cvm_id, app_id=new.app_id,
                team_id=new.team_id, identity=new.identity,
            )
            self.db.retire_worker(old_cvm)
            replacement = self.add_handle(
                team_id=new.team_id, worker_identity=new.identity,
                cvm_id=new.cvm_id, app_id=new.app_id,
            )
            await asyncio.to_thread(self.bootstrap_handle, replacement)
            self.start_poller(replacement)
            self.stop_poller(old_team)
            self.remove_handle(old_identity)
            asyncio.create_task(asyncio.to_thread(pool.delete, old_cvm))
            logger.info("rotate[%s]: replaced by %s", old_identity[:8], new.identity[:8])
            return replacement
        except Exception:
            logger.exception("rotate[%s] failed; clearing flag", old_identity[:8])
            return None
        finally:
            self._rotating.discard(old_identity)

    async def scale_pool(self, target_size: int) -> dict:
        """Bring the pool to `target_size`. Returns identities added/removed.

        Scale-up provisions and bootstraps in parallel. Scale-down acquires
        each victim's lock before retiring it so an in-flight task isn't
        interrupted mid-dispatch. Victims are selected from the tail of
        insertion order (most-recently-added first)."""
        pool: WorkerPool | None = state.get("worker_pool")
        if pool is None:
            raise RuntimeError("worker pool not initialised")
        current = len(self.handles)
        added: list[str] = []
        removed: list[str] = []
        if target_size > current:
            n = target_size - current
            logger.info("scale: adding %d worker(s) serially (current=%d, target=%d)",
                        n, current, target_size)
            # Serial provisioning: see _resolve_pool for the Phala KMS
            # UNIQUE-on-address constraint that bites parallel deploys.
            for i in range(n):
                try:
                    r = await asyncio.to_thread(pool.provision)
                except Exception as exc:
                    logger.warning("scale: provision %d/%d failed: %s", i + 1, n, exc)
                    continue
                assert r.identity is not None
                self.db.add_active_worker(
                    cvm_id=r.cvm_id, app_id=r.app_id,
                    team_id=r.team_id, identity=r.identity,
                )
                handle = self.add_handle(
                    team_id=r.team_id, worker_identity=r.identity,
                    cvm_id=r.cvm_id, app_id=r.app_id,
                )
                try:
                    await asyncio.to_thread(self.bootstrap_handle, handle)
                    self.start_poller(handle)
                    added.append(r.identity)
                    logger.info("scale: worker %s online", r.identity[:8])
                except Exception as exc:
                    logger.warning("scale: bootstrap for %s failed: %s", r.identity[:12], exc)
                    self.remove_handle(r.identity)
                    self.db.retire_worker(r.cvm_id)
                    asyncio.create_task(asyncio.to_thread(pool.delete, r.cvm_id))
        elif target_size < current:
            n = current - target_size
            logger.info("scale: removing %d worker(s) (current=%d, target=%d)",
                        n, current, target_size)
            victims = list(self.handles.values())[-n:]
            for victim in victims:
                async with victim.lock:
                    self.stop_poller(victim.team_id)
                    self.remove_handle(victim.identity)
                    self.db.retire_worker(victim.cvm_id)
                    asyncio.create_task(asyncio.to_thread(pool.delete, victim.cvm_id))
                    removed.append(victim.identity)
                    logger.info("scale: worker %s retired", victim.identity[:8])
        return {"added": added, "removed": removed, "current": len(self.handles)}

    # ── workspace browse: route by task→worker mapping ────────────────────

    async def _dispatch_to_task_worker(
        self, *, task_id: str, context_id: str, payload_obj: dict, timeout: int
    ) -> dict:
        worker_identity = self.db.get_task_worker(task_id)
        if not worker_identity or worker_identity not in self.handles:
            return {"error": f"worker for task {task_id[:8]} unavailable (rotated or retired)"}
        handle = self.handles[worker_identity]
        async with handle.lock:
            payload = json.dumps(payload_obj).encode("utf-8")
            ciphertext = handle.session.encrypt(payload)
            resp = await asyncio.to_thread(
                self._dispatch_blocking, handle,
                context_id=context_id, payload=ciphertext, timeout_seconds=timeout,
            )
            return json.loads(handle.session.decrypt(resp).decode("utf-8"))

    async def list_workspace(self, task_id: str) -> dict:
        return await self._dispatch_to_task_worker(
            task_id=task_id, context_id=FS_LIST_CONTEXT_ID,
            payload_obj={"task_id": task_id}, timeout=30,
        )

    async def read_workspace_file(self, task_id: str, path: str) -> dict:
        return await self._dispatch_to_task_worker(
            task_id=task_id, context_id=FS_READ_CONTEXT_ID,
            payload_obj={"task_id": task_id, "path": path}, timeout=30,
        )

    # ── processor + event pollers ─────────────────────────────────────────

    async def run_processor_loop(self) -> None:
        """Pull pending tasks; spawn process_task as background tasks so the
        loop is non-blocking. Concurrency caps at len(self.handles) via the
        per-handle locks inside process_task.

        Tracks in-flight task ids so we don't re-dispatch the same pending
        row before the new background task has marked it `running` in the
        DB — without this guard the loop tail-spawns dozens of duplicate
        process_task coroutines for a single row in the first few ticks,
        each waiting on the same handle lock and pinning memory."""
        while True:
            # Cap concurrent dispatches at pool size — each process_task will
            # acquire one handle's lock, so spawning more than len(handles)
            # just produces coroutines waiting on acquire_idle.
            if len(self._inflight_task_ids) >= len(self.handles):
                await asyncio.sleep(0.5)
                continue
            task = self.db.next_pending()
            if task is None or task["id"] in self._inflight_task_ids:
                await asyncio.sleep(0.5)
                continue
            self._inflight_task_ids.add(task["id"])
            asyncio.create_task(self._wrap_process_task(task))

    async def _wrap_process_task(self, task: dict) -> None:
        try:
            await self.process_task(task)
        finally:
            self._inflight_task_ids.discard(task["id"])

    def start_poller(self, handle: WorkerHandle) -> None:
        """One event-poller asyncio task per worker team. Decodes the
        plaintext envelope, routes by worker_identity to the right handle's
        MLS session, persists the decrypted event, publishes to SSE."""
        team_id = handle.team_id

        async def _poll() -> None:
            while True:
                try:
                    resp = await asyncio.to_thread(
                        self.client.read_inbox,
                        team_id, self.bearer,
                        bearer=self.bearer, wait_seconds=15,
                    )
                except asyncio.CancelledError:
                    raise
                except Exception as exc:
                    logger.warning("inbox poll error (team=%s): %s; sleeping 2s", team_id, exc)
                    await asyncio.sleep(2)
                    continue
                for wake in resp.get("wakes", []):
                    wake_id = wake["wake_id"]
                    context_id = wake.get("context_id", "?")
                    try:
                        if context_id != EVENT_CONTEXT_ID:
                            logger.warning("unexpected wake context %s; ack+ignore", context_id)
                        else:
                            envelope_bytes = b64url_decode(wake["payload"])
                            envelope = json.loads(envelope_bytes.decode("utf-8"))
                            worker_identity = envelope["worker_identity"]
                            target = self.handles.get(worker_identity)
                            if target is None:
                                logger.warning("event from unknown worker %s; dropping",
                                               worker_identity[:12])
                            else:
                                ciphertext = b64url_decode(envelope["encrypted_b64"])
                                inner = json.loads(target.session.decrypt(ciphertext).decode("utf-8"))
                                self.db.insert_event(inner["task_id"], inner["seq"], inner["event"])
                                await self.event_bus.publish(
                                    inner["task_id"],
                                    {"seq": inner["seq"], "received_at": time.time(), **inner["event"]},
                                )
                    except Exception as exc:
                        # MLS decrypt failures are expected after an
                        # orchestrator restart: the worker's session
                        # state outlives the orchestrator's in-memory
                        # state, so any in-flight wake the worker sent
                        # against the previous ratchet position can't
                        # be decrypted by the newly-bootstrapped group.
                        # Ack and skip — subsequent wakes encrypted with
                        # the current ratchet will work fine.
                        is_mls = (
                            type(exc).__name__ in ("MlsError", "MlsSessionError")
                            or "MLS engine error" in str(exc)
                            or "CryptoProviderError" in str(exc)
                        )
                        if is_mls:
                            logger.warning(
                                "event decrypt failed for wake %s (likely stale session after restart); ack+skip",
                                wake_id[:8],
                            )
                        else:
                            logger.exception("event decode failed for wake %s: %s", wake_id[:8], exc)
                    finally:
                        await asyncio.to_thread(
                            self.client.complete_wake,
                            team_id, wake_id, b64url_no_pad(b"{}"), bearer=self.bearer,
                        )

        self.pollers[team_id] = asyncio.create_task(_poll(), name=f"poller-{team_id}")

    def stop_poller(self, team_id: str) -> None:
        task = self.pollers.pop(team_id, None)
        if task is not None:
            task.cancel()


# ─── FastAPI app ─────────────────────────────────────────────────────────────

state: dict[str, Any] = {}

# Bearer-token auth. Token comes from env TALLY_API_TOKEN; if absent, we
# generate a 32-byte random one at startup, persist it in the DB dir, and
# print it once. `auto_error=False` lets us return a JSON 401 ourselves
# instead of FastAPI's plain string.
_bearer = HTTPBearer(auto_error=False)


def _resolve_token(db_dir: Path) -> str:
    env_token = os.environ.get("TALLY_API_TOKEN", "").strip()
    if env_token:
        return env_token
    state_file = db_dir / "api_token.txt"
    if state_file.exists():
        return state_file.read_text().strip()
    token = secrets.token_urlsafe(32)
    state_file.write_text(token + "\n")
    state_file.chmod(0o600)
    logger.warning("auto-generated TALLY_API_TOKEN=%s (saved to %s)", token, state_file)
    return token


async def require_token(
    creds: HTTPAuthorizationCredentials | None = Depends(_bearer),
) -> None:
    """FastAPI dependency: 401s any request without a valid Bearer token."""
    expected: str = state.get("api_token", "")
    presented = creds.credentials if creds and creds.scheme.lower() == "bearer" else ""
    # hmac.compare_digest is constant-time vs short-circuit ==.
    if not expected or not presented or not hmac.compare_digest(expected, presented):
        raise HTTPException(status_code=401, detail="missing or invalid bearer token")


async def _resolve_pool(db: Db, pool: WorkerPool, target_size: int) -> list[dict]:
    """Decide which `target_size` workers to bootstrap into the pool.

    Sources, layered in order until target_size is satisfied:
      1. Env override: `TEAM_ID` + `WORKER_IDENTITY_B64` (single pinned worker).
      2. DB cache: any rows with status='active' (survives orchestrator restart
         without burning ~$0.05/CVM cold-start).
      3. Auto-provision: fill the remaining slots in parallel via phala CLI.

    Provisioning happens via asyncio.gather so an N=4 cold-start finishes in
    ~3 min (one CVM provision wall-time) instead of ~12 min serial.

    Returns dicts of {team_id, identity, cvm_id, app_id, from_env}. Workers
    flagged `from_env=True` are pinned by the operator — the rotate/scale
    paths must not delete or retire them.
    """
    results: list[dict] = []
    seen: set[str] = set()

    env_team = os.environ.get("TEAM_ID", "").strip()
    env_id = os.environ.get("WORKER_IDENTITY_B64", "").strip()
    if env_team and env_id:
        logger.info("using env-pinned worker: team=%s identity=%s...", env_team, env_id[:12])
        results.append({
            "team_id": env_team, "identity": env_id,
            "cvm_id": f"env-{env_team}", "app_id": None, "from_env": True,
        })
        seen.add(env_id)

    for w in db.list_active_workers():
        if len(results) >= target_size:
            break
        if w["identity"] in seen:
            continue
        logger.info("reusing active worker %s from DB", w["cvm_id"][:8])
        results.append({
            "team_id": w["team_id"], "identity": w["identity"],
            "cvm_id": w["cvm_id"], "app_id": w.get("app_id"),
            "from_env": False,
        })
        seen.add(w["identity"])

    shortfall = target_size - len(results)
    if shortfall > 0:
        # Provision serially. Phala's centralized KMS has a UNIQUE constraint
        # on `dstack_app_nonces.address`; two parallel `phala deploy` calls
        # that hash to the same App ID race for that row and the loser fails
        # with `ix_dstack_app_nonces_address`. Serial deploys land the first
        # nonce successfully, and the second deploy proceeds (Phala accepts
        # multiple CVMs sharing an App ID once the nonce is established).
        logger.info("auto-provisioning %d worker(s) serially (may take ~%dmin)",
                    shortfall, 3 * shortfall)
        for i in range(shortfall):
            try:
                r = await asyncio.to_thread(pool.provision)
            except Exception as exc:
                logger.warning("provision %d/%d failed: %s", i + 1, shortfall, exc)
                continue
            assert r.identity is not None
            db.add_active_worker(
                cvm_id=r.cvm_id, app_id=r.app_id,
                team_id=r.team_id, identity=r.identity,
            )
            results.append({
                "team_id": r.team_id, "identity": r.identity,
                "cvm_id": r.cvm_id, "app_id": r.app_id, "from_env": False,
            })
            seen.add(r.identity)
    return results


async def _bootstrap_slot(
    orch: "Orchestrator", db: Db, pool: WorkerPool, w: dict
) -> "WorkerHandle | None":
    """Build + bootstrap one handle. On failure, retire the worker and try
    once more with a fresh provision. Returns the handle on success, None
    if both attempts failed.

    Env-pinned workers are not retired or replaced on failure — we let the
    caller surface the bootstrap error so the operator can debug their CVM.
    """
    for attempt in (1, 2):
        handle = orch.add_handle(
            team_id=w["team_id"], worker_identity=w["identity"],
            cvm_id=w["cvm_id"], app_id=w.get("app_id"),
        )
        try:
            await asyncio.to_thread(orch.bootstrap_handle, handle)
            return handle
        except Exception as exc:
            logger.warning(
                "bootstrap[%s] attempt %d/2 failed: %s",
                w["identity"][:12], attempt, exc,
            )
            orch.remove_handle(w["identity"])
            if w.get("from_env"):
                # User pinned this one; don't try a replacement.
                return None
            db.retire_worker(w["cvm_id"])
            asyncio.create_task(asyncio.to_thread(pool.delete, w["cvm_id"]))
            if attempt == 2:
                return None
            # Provision a replacement for the retry.
            try:
                info = await asyncio.to_thread(pool.provision)
                assert info.identity is not None
                db.add_active_worker(
                    cvm_id=info.cvm_id, app_id=info.app_id,
                    team_id=info.team_id, identity=info.identity,
                )
                w = {
                    "team_id": info.team_id, "identity": info.identity,
                    "cvm_id": info.cvm_id, "app_id": info.app_id, "from_env": False,
                }
            except Exception as prov_exc:
                logger.warning("bootstrap[%s] replacement provision failed: %s",
                               w["identity"][:12], prov_exc)
                return None
    return None


@asynccontextmanager
async def lifespan(app: FastAPI):
    tally_url = os.environ.get("TALLY_WORKERS_URL", "https://tally.nraimbault16.workers.dev")
    identity_path = os.environ.get("ORCH_IDENTITY_PATH", "/tmp/tally-orch/orchestrator.key")
    mls_state_base_dir = os.environ.get("ORCH_MLS_STATE_DIR", "/tmp/tally-orch/mls-state")
    db_path = os.environ.get("ORCH_DB_PATH", "/tmp/tally-orch/tasks.db")
    scripts_env = os.environ.get("SCRIPTS_ENV_PATH", str(Path(__file__).resolve().parents[3] / "scripts" / ".env"))
    target_pool_size = max(1, int(os.environ.get("TALLY_POOL_SIZE", "1")))
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)

    db = Db(db_path)
    state["api_token"] = _resolve_token(Path(db_path).parent)
    # Self-heal any tasks left mid-flight by a previous crash. They'd be
    # invisible to next_pending() and pin nothing on the new pool — but
    # they'd also lie about the worker that ran them in /tasks responses
    # forever. Demote them to `failed` with a clear marker.
    orphans = db.recover_stuck_running("orchestrator restarted while task was running")
    if orphans:
        logger.warning("recovered %d stuck running task(s) on startup (demoted to failed)", orphans)
    event_bus = EventBus()
    pool = WorkerPool(scripts_env_path=scripts_env)
    state["worker_pool"] = pool
    state["db"] = db
    state["event_bus"] = event_bus

    orchestrator = Orchestrator(
        tally_url=tally_url,
        identity_path=identity_path,
        mls_state_base_dir=mls_state_base_dir,
        db=db,
        event_bus=event_bus,
    )
    state["orchestrator"] = orchestrator

    slots = await _resolve_pool(db, pool, target_pool_size)
    logger.info("bootstrapping pool of %d worker(s) in parallel", len(slots))
    handles = await asyncio.gather(
        *[_bootstrap_slot(orchestrator, db, pool, w) for w in slots]
    )
    ok = [h for h in handles if h is not None]
    if not ok:
        raise RuntimeError(
            f"no workers bootstrapped (target={target_pool_size}); "
            "systemd will respawn for a fresh attempt"
        )
    if len(ok) < target_pool_size:
        logger.warning("only %d/%d workers bootstrapped; will run degraded",
                       len(ok), target_pool_size)
    for h in ok:
        orchestrator.start_poller(h)

    processor_task = asyncio.create_task(orchestrator.run_processor_loop())
    state["processor_task"] = processor_task
    logger.info("ready; pool=%d, processor loop started", len(orchestrator.handles))
    try:
        yield
    finally:
        for team_id in list(orchestrator.pollers.keys()):
            orchestrator.stop_poller(team_id)
        processor_task.cancel()
        try:
            await processor_task
        except asyncio.CancelledError:
            pass


app = FastAPI(title="Tally Orchestrator", lifespan=lifespan)


@app.get("/health")
async def health() -> dict:
    return {"status": "ok", "tasks_in_flight": state["db"].next_pending() is not None}


@app.post("/tasks", dependencies=[Depends(require_token)], response_model=TaskResponse)
async def submit_task(body: TaskSubmit) -> TaskResponse:
    task_id = state["db"].create_task(body.description)
    task = state["db"].get_task(task_id)
    return TaskResponse(**task)


@app.get("/tasks/{task_id}", dependencies=[Depends(require_token)], response_model=TaskResponse)
async def get_task(task_id: str) -> TaskResponse:
    task = state["db"].get_task(task_id)
    if not task:
        raise HTTPException(404, f"task {task_id} not found")
    return TaskResponse(**task)


@app.get("/tasks", dependencies=[Depends(require_token)], response_model=list[TaskResponse])
async def list_tasks(limit: int = 100) -> list[TaskResponse]:
    return [TaskResponse(**t) for t in state["db"].list_tasks(limit=limit)]


@app.get("/tasks/{task_id}/events", dependencies=[Depends(require_token)])
async def get_task_events(task_id: str, since_seq: int = -1) -> list[dict]:
    """Return events with seq > since_seq, in order. One-shot read (used by
    clients that don't speak SSE). Live clients should use /stream instead."""
    task = state["db"].get_task(task_id)
    if not task:
        raise HTTPException(404, f"task {task_id} not found")
    return state["db"].list_events(task_id, since_seq=since_seq)


@app.get("/tasks/{task_id}/stream", dependencies=[Depends(require_token)])
async def stream_task_events(task_id: str, request: Request, since_seq: int = -1):
    """Server-Sent Events stream. Emits historical events with seq > since_seq
    first (so reconnects don't lose anything), then live events as they arrive
    via the EventBus. sse_starlette handles client-disconnect detection +
    keep-alive comments."""
    db: Db = state["db"]
    bus: EventBus = state["event_bus"]
    task = db.get_task(task_id)
    if not task:
        raise HTTPException(404, f"task {task_id} not found")

    async def event_source():
        # Replay historical task events first so reconnects don't lose any.
        # Status changes are not persisted — clients get them live or via
        # GET /tasks/{id} for current snapshot.
        last_seq = since_seq
        for ev in db.list_events(task_id, since_seq=since_seq):
            yield {"event": "task_event", "data": json.dumps(ev)}
            last_seq = ev["seq"]
        # Also send the current status snapshot so the client doesn't have to
        # hit a second endpoint right after connecting.
        snap = db.get_task(task_id)
        if snap:
            yield {"event": "status_change", "data": json.dumps({
                "task_id": task_id, "status": snap["status"], "ts": snap["updated_at"],
            })}
        # Subscribe + stream live events.
        queue = await bus.subscribe(task_id)
        try:
            while True:
                if await request.is_disconnected():
                    break
                try:
                    ev = await asyncio.wait_for(queue.get(), timeout=15.0)
                    if ev.get("_kind") == "status_change":
                        out = {k: v for k, v in ev.items() if k != "_kind"}
                        yield {"event": "status_change", "data": json.dumps(out)}
                    else:
                        # Task event from the worker. Skip seqs we already replayed.
                        if ev["seq"] <= last_seq:
                            continue
                        yield {"event": "task_event", "data": json.dumps(ev)}
                        last_seq = ev["seq"]
                except asyncio.TimeoutError:
                    yield {"event": "heartbeat", "data": ""}
        finally:
            await bus.unsubscribe(task_id, queue)

    return EventSourceResponse(event_source())


@app.get("/tasks/{task_id}/files", dependencies=[Depends(require_token)])
async def list_task_files(task_id: str) -> dict:
    """List files in the worker's per-task workspace. Dispatches a fs:list
    wake to the worker over MLS; returns the decrypted entry list."""
    task = state["db"].get_task(task_id)
    if not task:
        raise HTTPException(404, f"task {task_id} not found")
    orch: Orchestrator = state["orchestrator"]
    resp = await orch.list_workspace(task_id)
    if "error" in resp:
        raise HTTPException(404, resp["error"])
    return resp


@app.get("/tasks/{task_id}/files/{path:path}", dependencies=[Depends(require_token)])
async def read_task_file(task_id: str, path: str) -> dict:
    """Read one file from the worker's per-task workspace. Path is forwarded
    to the worker which validates against path traversal."""
    task = state["db"].get_task(task_id)
    if not task:
        raise HTTPException(404, f"task {task_id} not found")
    orch: Orchestrator = state["orchestrator"]
    resp = await orch.read_workspace_file(task_id, path)
    if "error" in resp:
        raise HTTPException(404, resp["error"])
    return resp


class PoolRotateBody(BaseModel):
    identity: str | None = None  # None means "rotate the first handle in the pool"


class PoolScaleBody(BaseModel):
    size: int


@app.get("/admin/pool/status", dependencies=[Depends(require_token)])
async def pool_status() -> dict:
    """Return every active worker's metadata + uptime + lock state.

    Lock state is in-process truth (asyncio.Lock from the WorkerHandle),
    while everything else is pulled from the DB. A worker can be 'active'
    in the DB but absent from `orchestrator.handles` mid-rotation — those
    rows show busy=False, present=False so operators can spot mismatches."""
    db: Db = state["db"]
    orch: Orchestrator = state["orchestrator"]
    now = time.time()
    workers = []
    for w in db.list_active_workers():
        handle = orch.handles.get(w["identity"])
        workers.append({
            **w,
            "uptime_seconds": now - w["created_at"],
            "present": handle is not None,
            "busy": handle.lock.locked() if handle else None,
            "failures": handle.failures if handle else None,
        })
    return {"workers": workers, "pool_size": len(orch.handles)}


@app.post("/admin/pool/rotate", dependencies=[Depends(require_token)])
async def pool_rotate(body: PoolRotateBody | None = None) -> dict:
    """Rotate one worker: provision a fresh CVM, bootstrap a new handle, then
    retire+delete the old one. The other handles keep serving tasks while this
    one is being swapped — no service exit needed (unlike Sprint 12's path).

    Body: {"identity": "<b64-pubkey>"} to target a specific worker.
    Empty/missing body rotates the first handle in pool-insertion order."""
    orch: Orchestrator = state["orchestrator"]
    if not orch.handles:
        raise HTTPException(503, "no workers in pool")
    target_identity = (body.identity if body else None) or next(iter(orch.handles))
    handle = orch.handles.get(target_identity)
    if handle is None:
        raise HTTPException(404, f"worker {target_identity[:12]}... not in active pool")
    if target_identity in orch._rotating:
        raise HTTPException(409, "rotation already in progress for this worker")
    orch._rotating.add(target_identity)
    logger.info("admin rotate: target=%s", target_identity[:12])
    new_handle = await orch._rotate_handle(handle)
    if new_handle is None:
        raise HTTPException(500, "rotation failed; check service logs")
    return {
        "old_worker": {
            "cvm_id": handle.cvm_id, "team_id": handle.team_id,
            "identity": handle.identity,
        },
        "new_worker": {
            "cvm_id": new_handle.cvm_id, "team_id": new_handle.team_id,
            "identity": new_handle.identity,
        },
        "pool_size": len(orch.handles),
    }


@app.post("/admin/pool/scale", dependencies=[Depends(require_token)])
async def pool_scale(body: PoolScaleBody) -> dict:
    """Resize the worker pool to `body.size`. Up = provision N new CVMs in
    parallel + bootstrap. Down = release the tail handles (waits for any
    in-flight task to finish on each before retiring).

    Blocks until the scale completes — scale-up to a new size may take 3-5
    min for the CVM cold-start. Use a generous client timeout."""
    if body.size < 0:
        raise HTTPException(400, "size must be >= 0")
    if body.size > 16:
        raise HTTPException(400, "size capped at 16 for safety")
    orch: Orchestrator = state["orchestrator"]
    before = len(orch.handles)
    logger.info("admin scale: %d -> %d", before, body.size)
    result = await orch.scale_pool(body.size)
    return {"before": before, "after": len(orch.handles), **result}


def main() -> None:
    import uvicorn
    # Default to 0.0.0.0 so LAN devices can reach the service. Override with
    # HOST=127.0.0.1 to lock down to local-only.
    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "8080"))
    uvicorn.run(app, host=host, port=port, log_level="info")


if __name__ == "__main__":
    main()
