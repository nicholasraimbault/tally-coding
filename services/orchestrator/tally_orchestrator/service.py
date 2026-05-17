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
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from tally_coding_core.identity import bearer_from_pubkey, load_or_create_identity
from tally_coding_core.mls import MlsSession
from tally_coding_core.tally_workers import TallyWorkersClient

logger = logging.getLogger("tally.orchestrator")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")

BOOTSTRAP_CONTEXT_ID = "mls:bootstrap"
TASK_CONTEXT_ID = "task:start"
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
    ) -> None:
        self.tally_url = tally_url
        self.team_id = team_id
        self.worker_identity = worker_identity
        self.db = db
        Path(mls_state_dir).mkdir(parents=True, exist_ok=True)
        _privkey, pubkey = load_or_create_identity(identity_path)
        self.pubkey = pubkey
        self.bearer = bearer_from_pubkey(pubkey)
        self.client = TallyWorkersClient(base_url=tally_url)
        group_id = f"orch-worker-{team_id}".encode("utf-8")
        self.session = MlsSession(data_dir=mls_state_dir, identity=pubkey, group_id=group_id)
        self._dispatch_lock = asyncio.Lock()

    def bootstrap(self) -> None:
        """3-wake bootstrap: request_kp → create_and_add → welcome."""
        self.client.team_init(self.team_id, bearer=self.bearer)
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

    async def process_task(self, task: dict) -> None:
        """Encrypt task, dispatch, decrypt response, update db."""
        async with self._dispatch_lock:
            self.db.mark_running(task["id"])
            logger.info("running task %s: %s", task["id"][:8], task["description"][:80])
            try:
                plaintext = json.dumps({"task": task["description"]}).encode("utf-8")
                ciphertext = self.session.encrypt(plaintext)
                logger.info("dispatching task %s (%d bytes ciphertext)", task["id"][:8], len(ciphertext))
                # dispatch_wake is sync; offload to thread pool so we don't block the event loop
                response_bytes = await asyncio.to_thread(
                    self._dispatch_blocking,
                    context_id=TASK_CONTEXT_ID,
                    payload=ciphertext,
                    timeout_seconds=300,
                )
                response_plain = self.session.decrypt(response_bytes).decode("utf-8")
                result = json.loads(response_plain)
                self.db.mark_completed(task["id"], result)
                logger.info("task %s completed: success=%s", task["id"][:8], result.get("success"))
            except Exception as exc:
                logger.exception("task %s failed", task["id"][:8])
                self.db.mark_failed(task["id"], str(exc))

    async def run_processor_loop(self) -> None:
        while True:
            task = self.db.next_pending()
            if task is None:
                await asyncio.sleep(1.0)
                continue
            await self.process_task(task)


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
    orchestrator = Orchestrator(
        tally_url=tally_url,
        team_id=team_id,
        worker_identity=worker_identity,
        identity_path=identity_path,
        mls_state_dir=mls_state_dir,
        db=db,
    )
    logger.info("bootstrapping MLS session with worker %s", worker_identity[:12])
    await asyncio.to_thread(orchestrator.bootstrap)
    state["orchestrator"] = orchestrator
    state["db"] = db
    processor_task = asyncio.create_task(orchestrator.run_processor_loop())
    state["processor_task"] = processor_task
    logger.info("ready; processor loop started")
    try:
        yield
    finally:
        processor_task.cancel()
        try:
            await processor_task
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


def main() -> None:
    import uvicorn
    host = os.environ.get("HOST", "127.0.0.1")
    port = int(os.environ.get("PORT", "8080"))
    uvicorn.run(app, host=host, port=port, log_level="info")


if __name__ == "__main__":
    main()
