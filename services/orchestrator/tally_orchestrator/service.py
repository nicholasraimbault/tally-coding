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
import json
import logging
import os
import sqlite3
import sys
import time
import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException, Request
from pydantic import BaseModel
from sse_starlette.sse import EventSourceResponse

from tally_coding_core.identity import bearer_from_pubkey, load_or_create_identity
from tally_coding_core.mls import MlsSession
from tally_coding_core.tally_workers import TallyWorkersClient

logger = logging.getLogger("tally.orchestrator")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")

BOOTSTRAP_CONTEXT_ID = "mls:bootstrap"
TASK_CONTEXT_ID = "task:start"
EVENT_CONTEXT_ID = "task:event"
FS_LIST_CONTEXT_ID = "task:fs:list"
FS_READ_CONTEXT_ID = "task:fs:read"
SCHEMA = """
CREATE TABLE IF NOT EXISTS tasks (
    id           TEXT PRIMARY KEY,
    description  TEXT NOT NULL,
    status       TEXT NOT NULL,
    result_json  TEXT,
    error        TEXT,
    created_at   REAL NOT NULL,
    updated_at   REAL NOT NULL
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
            "SELECT id, description, status, result_json, error, created_at, updated_at FROM tasks WHERE id = ?",
            (task_id,),
        ).fetchone()
        return self._row_to_dict(row) if row else None

    def list_tasks(self, limit: int = 100) -> list[dict]:
        rows = self._conn.execute(
            "SELECT id, description, status, result_json, error, created_at, updated_at "
            "FROM tasks ORDER BY created_at DESC LIMIT ?",
            (limit,),
        ).fetchall()
        return [self._row_to_dict(r) for r in rows]

    def next_pending(self) -> dict | None:
        row = self._conn.execute(
            "SELECT id, description, status, result_json, error, created_at, updated_at "
            "FROM tasks WHERE status = 'pending' ORDER BY created_at LIMIT 1"
        ).fetchone()
        return self._row_to_dict(row) if row else None

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

    def insert_event(self, task_id: str, seq: int, event: dict) -> None:
        """Insert a streaming event from the worker. Idempotent on (task_id, seq)."""
        self._conn.execute(
            "INSERT OR IGNORE INTO events (task_id, seq, event_json, received_at) VALUES (?, ?, ?, ?)",
            (task_id, seq, json.dumps(event), time.time()),
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


class Orchestrator:
    """Holds the MLS session with the worker; dispatches encrypted task wakes."""

    def __init__(
        self,
        *,
        tally_url: str,
        team_id: str,
        worker_identity: str,
        identity_path: str,
        mls_state_dir: str,
        db: Db,
        event_bus: EventBus,
    ) -> None:
        self.tally_url = tally_url
        self.team_id = team_id
        self.worker_identity = worker_identity
        self.db = db
        self.event_bus = event_bus
        Path(mls_state_dir).mkdir(parents=True, exist_ok=True)
        _privkey, pubkey = load_or_create_identity(identity_path)
        self.pubkey = pubkey
        self.bearer = bearer_from_pubkey(pubkey)
        self.client = TallyWorkersClient(base_url=tally_url)
        group_id = f"orch-worker-{team_id}".encode("utf-8")
        self.session = MlsSession(data_dir=mls_state_dir, identity=pubkey, group_id=group_id)
        self._dispatch_lock = asyncio.Lock()

    def bootstrap(self) -> None:
        """3-wake bootstrap: request_kp → create_and_add → welcome.
        Also registers task:event handler so the worker can stream events back."""
        self.client.team_init(self.team_id, bearer=self.bearer)
        self.client.register(
            self.team_id, self.bearer, bearer=self.bearer, context_id=EVENT_CONTEXT_ID
        )
        logger.info("bootstrap step 1: requesting worker key package")
        kp_resp = self._dispatch_blocking(
            context_id=BOOTSTRAP_CONTEXT_ID,
            payload=json.dumps({"phase": "request_kp"}).encode("utf-8"),
            timeout_seconds=60,
        )
        worker_kp = b64url_decode(json.loads(kp_resp.decode("utf-8"))["key_package"])
        logger.info("received key package (%d bytes); creating MLS group", len(worker_kp))

        welcome_bytes = None
        for attempt in range(6):
            try:
                welcome_bytes = self.session.create_and_add(worker_kp)
                break
            except Exception as exc:
                if "InvalidLifetime" in str(exc) and attempt < 5:
                    logger.warning("add_member InvalidLifetime (attempt %d/6); sleeping 5s", attempt + 1)
                    time.sleep(5)
                    continue
                raise
        if welcome_bytes is None:
            raise RuntimeError("create_and_add failed after retries")

        logger.info("bootstrap step 3: sending welcome (%d bytes)", len(welcome_bytes))
        ack = self._dispatch_blocking(
            context_id=BOOTSTRAP_CONTEXT_ID,
            payload=json.dumps({"phase": "welcome", "welcome": b64url_no_pad(welcome_bytes)}).encode("utf-8"),
            timeout_seconds=60,
        )
        if not json.loads(ack.decode("utf-8")).get("ok"):
            raise RuntimeError(f"worker rejected welcome: {ack!r}")
        logger.info("MLS session established")

    def _dispatch_blocking(self, *, context_id: str, payload: bytes, timeout_seconds: int) -> bytes:
        """Synchronous wake dispatch. Returns response bytes (b64 decoded)."""
        result = self.client.dispatch_wake(
            team_id=self.team_id,
            target_identity=self.worker_identity,
            context_id=context_id,
            payload=b64url_no_pad(payload),
            timeout_seconds=timeout_seconds,
            bearer=self.bearer,
        )
        return b64url_decode(result["response"])

    async def _publish_status(self, task_id: str, status: str, extra: dict | None = None) -> None:
        """Publish a status_change marker to the bus so SSE subscribers learn
        about task transitions without needing to poll /tasks/{id}."""
        payload = {"task_id": task_id, "status": status, "ts": time.time()}
        if extra:
            payload.update(extra)
        await self.event_bus.publish(task_id, {"_kind": "status_change", **payload})

    async def process_task(self, task: dict) -> None:
        """Encrypt task, dispatch, decrypt response, update db, push status events."""
        async with self._dispatch_lock:
            self.db.mark_running(task["id"])
            await self._publish_status(task["id"], "running")
            logger.info("running task %s: %s", task["id"][:8], task["description"][:80])
            try:
                payload_obj = {
                    "task": task["description"],
                    "task_id": task["id"],
                    "orchestrator_bearer": self.bearer,
                }
                ciphertext = self.session.encrypt(json.dumps(payload_obj).encode("utf-8"))
                logger.info("dispatching task %s (%d bytes ciphertext)", task["id"][:8], len(ciphertext))
                response_bytes = await asyncio.to_thread(
                    self._dispatch_blocking,
                    context_id=TASK_CONTEXT_ID,
                    payload=ciphertext,
                    timeout_seconds=300,
                )
                response_plain = self.session.decrypt(response_bytes).decode("utf-8")
                result = json.loads(response_plain)
                self.db.mark_completed(task["id"], result)
                await self._publish_status(task["id"], "completed", {"success": result.get("success")})
                logger.info("task %s completed: success=%s", task["id"][:8], result.get("success"))
            except Exception as exc:
                logger.exception("task %s failed", task["id"][:8])
                self.db.mark_failed(task["id"], str(exc))
                await self._publish_status(task["id"], "failed", {"error": str(exc)})

    async def list_workspace(self, task_id: str) -> dict:
        """Dispatch a fs:list wake and return the decrypted response dict."""
        async with self._dispatch_lock:
            payload = json.dumps({"task_id": task_id}).encode("utf-8")
            ciphertext = self.session.encrypt(payload)
            resp = await asyncio.to_thread(
                self._dispatch_blocking,
                context_id=FS_LIST_CONTEXT_ID,
                payload=ciphertext,
                timeout_seconds=30,
            )
            return json.loads(self.session.decrypt(resp).decode("utf-8"))

    async def read_workspace_file(self, task_id: str, path: str) -> dict:
        """Dispatch a fs:read wake and return the decrypted response dict."""
        async with self._dispatch_lock:
            payload = json.dumps({"task_id": task_id, "path": path}).encode("utf-8")
            ciphertext = self.session.encrypt(payload)
            resp = await asyncio.to_thread(
                self._dispatch_blocking,
                context_id=FS_READ_CONTEXT_ID,
                payload=ciphertext,
                timeout_seconds=30,
            )
            return json.loads(self.session.decrypt(resp).decode("utf-8"))

    async def run_processor_loop(self) -> None:
        while True:
            task = self.db.next_pending()
            if task is None:
                await asyncio.sleep(1.0)
                continue
            await self.process_task(task)

    async def run_event_poller_loop(self) -> None:
        """Long-poll the orchestrator inbox for task:event wakes from the worker;
        decrypt + persist each one. Events come in MLS-encrypted; the session
        handles both directions since it's the same group."""
        while True:
            try:
                # Long-poll with a short wait so a stuck worker doesn't tie us up.
                resp = await asyncio.to_thread(
                    self.client.read_inbox,
                    self.team_id,
                    self.bearer,
                    bearer=self.bearer,
                    wait_seconds=15,
                )
            except Exception as exc:
                logger.warning("inbox poll error: %s; sleeping 2s", exc)
                await asyncio.sleep(2)
                continue
            wakes = resp.get("wakes", [])
            for wake in wakes:
                wake_id = wake["wake_id"]
                context_id = wake.get("context_id", "?")
                if context_id != EVENT_CONTEXT_ID:
                    logger.warning("unexpected wake context %s; ignoring", context_id)
                    # Complete it anyway so it doesn't sit in the inbox forever.
                    await asyncio.to_thread(
                        self.client.complete_wake,
                        self.team_id, wake_id, b64url_no_pad(b"{}"), bearer=self.bearer,
                    )
                    continue
                try:
                    ciphertext = b64url_decode(wake["payload"])
                    plaintext = self.session.decrypt(ciphertext).decode("utf-8")
                    msg = json.loads(plaintext)
                    self.db.insert_event(msg["task_id"], msg["seq"], msg["event"])
                    # Push to any live SSE subscribers for this task. Format mirrors
                    # the GET /events response: includes seq + received_at + event fields.
                    await self.event_bus.publish(
                        msg["task_id"],
                        {"seq": msg["seq"], "received_at": time.time(), **msg["event"]},
                    )
                except Exception as exc:
                    logger.exception("event decode failed for wake %s: %s", wake_id[:8], exc)
                # Always ack the wake (worker doesn't read the body anyway).
                await asyncio.to_thread(
                    self.client.complete_wake,
                    self.team_id, wake_id, b64url_no_pad(b"{}"), bearer=self.bearer,
                )


# ─── FastAPI app ─────────────────────────────────────────────────────────────

state: dict[str, Any] = {}


@asynccontextmanager
async def lifespan(app: FastAPI):
    tally_url = os.environ.get("TALLY_WORKERS_URL", "https://tally.nraimbault16.workers.dev")
    team_id = os.environ["TEAM_ID"]
    worker_identity = os.environ["WORKER_IDENTITY_B64"]
    identity_path = os.environ.get("ORCH_IDENTITY_PATH", "/tmp/tally-orch/orchestrator.key")
    mls_state_dir = os.environ.get("ORCH_MLS_STATE_DIR", "/tmp/tally-orch/mls-state")
    db_path = os.environ.get("ORCH_DB_PATH", "/tmp/tally-orch/tasks.db")
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)

    db = Db(db_path)
    event_bus = EventBus()
    orchestrator = Orchestrator(
        tally_url=tally_url,
        team_id=team_id,
        worker_identity=worker_identity,
        identity_path=identity_path,
        mls_state_dir=mls_state_dir,
        db=db,
        event_bus=event_bus,
    )
    logger.info("bootstrapping MLS session with worker %s", worker_identity[:12])
    await asyncio.to_thread(orchestrator.bootstrap)
    state["orchestrator"] = orchestrator
    state["db"] = db
    state["event_bus"] = event_bus
    processor_task = asyncio.create_task(orchestrator.run_processor_loop())
    event_task = asyncio.create_task(orchestrator.run_event_poller_loop())
    state["processor_task"] = processor_task
    state["event_task"] = event_task
    logger.info("ready; processor + event-poller loops started")
    try:
        yield
    finally:
        for t in (processor_task, event_task):
            t.cancel()
            try:
                await t
            except asyncio.CancelledError:
                pass


app = FastAPI(title="Tally Orchestrator", lifespan=lifespan)


@app.get("/health")
async def health() -> dict:
    return {"status": "ok", "tasks_in_flight": state["db"].next_pending() is not None}


@app.post("/tasks", response_model=TaskResponse)
async def submit_task(body: TaskSubmit) -> TaskResponse:
    task_id = state["db"].create_task(body.description)
    task = state["db"].get_task(task_id)
    return TaskResponse(**task)


@app.get("/tasks/{task_id}", response_model=TaskResponse)
async def get_task(task_id: str) -> TaskResponse:
    task = state["db"].get_task(task_id)
    if not task:
        raise HTTPException(404, f"task {task_id} not found")
    return TaskResponse(**task)


@app.get("/tasks", response_model=list[TaskResponse])
async def list_tasks(limit: int = 100) -> list[TaskResponse]:
    return [TaskResponse(**t) for t in state["db"].list_tasks(limit=limit)]


@app.get("/tasks/{task_id}/events")
async def get_task_events(task_id: str, since_seq: int = -1) -> list[dict]:
    """Return events with seq > since_seq, in order. One-shot read (used by
    clients that don't speak SSE). Live clients should use /stream instead."""
    task = state["db"].get_task(task_id)
    if not task:
        raise HTTPException(404, f"task {task_id} not found")
    return state["db"].list_events(task_id, since_seq=since_seq)


@app.get("/tasks/{task_id}/stream")
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


@app.get("/tasks/{task_id}/files")
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


@app.get("/tasks/{task_id}/files/{path:path}")
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


def main() -> None:
    import uvicorn
    host = os.environ.get("HOST", "127.0.0.1")
    port = int(os.environ.get("PORT", "8080"))
    uvicorn.run(app, host=host, port=port, log_level="info")


if __name__ == "__main__":
    main()
