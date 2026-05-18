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

from .architect import architect_team
from .clerk_auth import (
    ClerkValidator,
    User as ClerkUser,
    looks_like_jwt as clerk_looks_like_jwt,
)
import jwt
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

-- Sprint 22: agent palette (hardcoded library of roles)
CREATE TABLE IF NOT EXISTS agent_roles (
    name           TEXT PRIMARY KEY,
    description    TEXT NOT NULL,
    default_model  TEXT NOT NULL,
    tools_json     TEXT NOT NULL,            -- JSON list of tool names
    system_prompt  TEXT NOT NULL
);

-- Sprint 22: per-task agent instances. team_spec on tasks holds the architect
-- output as JSON, this table holds the resolved instances for inspection +
-- per-agent worker/result tracking.
CREATE TABLE IF NOT EXISTS agents (
    id              TEXT PRIMARY KEY,
    task_id         TEXT NOT NULL,
    agent_idx       INTEGER NOT NULL,         -- ordinal position in workflow
    role            TEXT NOT NULL,            -- references agent_roles.name
    model           TEXT NOT NULL,            -- may override role default
    spec            TEXT NOT NULL,            -- task-specific instructions
    status          TEXT NOT NULL,            -- pending|running|completed|failed
    result_json     TEXT,
    worker_identity TEXT,                     -- which WorkerHandle ran this agent
    started_at      REAL,
    finished_at     REAL,
    FOREIGN KEY (task_id) REFERENCES tasks(id),
    FOREIGN KEY (role)    REFERENCES agent_roles(name)
);
CREATE INDEX IF NOT EXISTS idx_agents_task     ON agents(task_id);
CREATE INDEX IF NOT EXISTS idx_agents_status   ON agents(status);

-- Sprint 29: saved team templates. A user can promote a successful
-- task's team_spec to a named template; the architect considers
-- saved templates when picking a team for future tasks. Emergent
-- feature per the locked UX memo — not a foundational primitive.
CREATE TABLE IF NOT EXISTS team_templates (
    name           TEXT PRIMARY KEY,
    team_spec      TEXT NOT NULL,        -- JSON {agents, stages, workflow, reasoning}
    source_task_id TEXT,                  -- which task this was promoted from
    note           TEXT,                  -- optional user-supplied description
    created_at     REAL NOT NULL,
    last_used_at   REAL,
    use_count      INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (source_task_id) REFERENCES tasks(id)
);

-- Sprint 26.5 (open-items round): durable artifact map so a mid-task
-- orchestrator restart can rehydrate the in-memory `_task_artifacts`
-- and seed the next agent correctly. Without this, an orch restart
-- between agents 2 and 3 leaves agent 3's workspace empty.
CREATE TABLE IF NOT EXISTS task_artifacts (
    task_id     TEXT NOT NULL,
    path        TEXT NOT NULL,
    b64_content TEXT NOT NULL,
    agent_idx   INTEGER,                  -- which agent produced this
    ts          REAL NOT NULL,
    PRIMARY KEY (task_id, path),
    FOREIGN KEY (task_id) REFERENCES tasks(id)
);
CREATE INDEX IF NOT EXISTS idx_artifacts_task ON task_artifacts(task_id);
"""


def b64url_no_pad(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def b64url_decode(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


class TaskSubmit(BaseModel):
    description: str
    # Sprint 22: optional pre-architected team. When omitted, the legacy
    # single-agent path runs. When present, must match the architect
    # output shape: {agents: [{role, model?, spec?}...], workflow: str?,
    # reasoning: str?}. Sprint 23 wires Tally to produce this when the
    # client doesn't supply one.
    team_spec: dict | None = None


class TaskResponse(BaseModel):
    id: str
    description: str
    status: str
    result: dict | None = None
    error: str | None = None
    created_at: float
    updated_at: float
    # Sprint 25: Discord-shaped UI needs the architect's team spec to render
    # the members sidebar. Null for legacy single-agent tasks.
    team_spec: dict | None = None
    # Sprint 32: owner of the task. 'admin' for legacy bearer-token writes,
    # 'legacy-admin' for pre-Sprint-32 rows, otherwise a Clerk user_id.
    user_id: str = "legacy-admin"


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
        # Sprint 22: team_spec is the Tally architect's output for this task —
        # JSON of {agents: [...], workflow: "...", reasoning: "..."}.
        # Null for Sprint 22 if dispatched by the legacy single-agent path
        # (which we keep as a fallback until Sprint 23 lands Tally).
        try:
            self._conn.execute("ALTER TABLE tasks ADD COLUMN team_spec TEXT")
        except sqlite3.OperationalError:
            pass
        # Sprint 32: multi-user. Owner of the task (Clerk user_id from
        # the JWT sub claim, or 'admin' for legacy bearer-token writes).
        # Existing rows default to 'legacy-admin' so they remain visible
        # to admin queries but not to any specific Clerk user.
        try:
            self._conn.execute(
                "ALTER TABLE tasks ADD COLUMN user_id TEXT NOT NULL DEFAULT 'legacy-admin'"
            )
        except sqlite3.OperationalError:
            pass
        try:
            self._conn.execute(
                "ALTER TABLE team_templates ADD COLUMN user_id TEXT NOT NULL DEFAULT 'legacy-admin'"
            )
        except sqlite3.OperationalError:
            pass
        self._conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_tasks_user ON tasks(user_id, created_at DESC)"
        )
        self._conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_templates_user ON team_templates(user_id, use_count DESC)"
        )
        self._seed_agent_roles()

    def _seed_agent_roles(self) -> None:
        """Idempotent seed of the 7-role palette. INSERT OR IGNORE so
        adding/upgrading a role's prompt requires an explicit migration
        rather than silently overwriting operator customisation. The
        prompt + tools here are the v1 defaults; per-task `spec` strings
        layer task-specific instructions on top."""
        roles = [
            (
                "Planner",
                "Decomposes the task into concrete sub-tasks; writes a plan that downstream agents follow.",
                "moonshotai/kimi-k2.6",
                ["task_tracker", "file_editor_read"],
                "You are a senior engineer planning the work. Read the task and produce a numbered plan "
                "with explicit deliverables. Do not write code; do not run anything. Write your plan to "
                "plan.md and stop.",
            ),
            (
                "Coder",
                "Writes and edits code to implement the task; may run code to verify.",
                # Sprint 22: same Kimi-K2 the single-agent worker has used
                # since Sprint 1. qwen3-coder-* returned upstream errors
                # against the live Red Pill catalog during Sprint 22
                # validation; survey + per-role tuning is a Sprint 22.5
                # follow-up. The architect's per-task override (Sprint 23)
                # can pick coder-specific models when they prove stable.
                "moonshotai/kimi-k2.6",
                ["bash", "file_editor", "terminal"],
                "You are a senior engineer implementing the task. Write idiomatic, testable code. If a "
                "plan.md exists in the workspace, follow it; otherwise infer scope from the task. Prefer "
                "small, verifiable steps. Stop when the task is done.",
            ),
            (
                "Reviewer",
                "Critiques code for bugs, style, missing edge cases. Read-only.",
                "moonshotai/kimi-k2.6",
                ["file_editor_read", "bash_read"],
                "You are a thorough code reviewer. Read every file the previous agent(s) produced. "
                "Write your findings to review.md, organized as: critical issues, style issues, "
                "suggestions. Do not modify code; only write review.md.",
            ),
            (
                "Tester",
                "Runs tests against the produced code; writes a brief report.",
                "moonshotai/kimi-k2.6",
                ["bash", "file_editor", "terminal"],
                "You are a QA engineer. Identify the test runner for this project (pytest, jest, "
                "cargo test, etc.) and run the test suite. Write the outcome to tests.md including "
                "pass/fail counts and any failing-test output.",
            ),
            (
                "DocWriter",
                "Writes documentation for the work the team did.",
                "meta-llama/llama-3.3-70b-instruct",
                ["file_editor"],
                "You are a technical writer. Read the workspace and write a README.md (or equivalent) "
                "that explains what was built, how to run it, and any non-obvious decisions. Keep it "
                "concise and example-driven.",
            ),
            (
                "SecReviewer",
                "Reviews for security vulnerabilities. Read-only.",
                "deepseek/deepseek-r1-0528",
                ["file_editor_read", "bash_read"],
                "You are a security engineer. Read the workspace and identify any vulnerabilities — "
                "injection, secrets in code, weak crypto, unsafe deserialization, auth gaps. Write to "
                "security.md as: critical, high, medium, low. Cite the file:line for each finding.",
            ),
            (
                "DBA",
                "Designs database schemas; writes migrations.",
                "deepseek/deepseek-v3.2",
                ["file_editor", "bash"],
                "You are a database engineer. Design the schema for the task; write migrations under "
                "migrations/. Prefer the database engine the rest of the project uses. Annotate "
                "non-obvious constraints in comments.",
            ),
        ]
        for name, desc, model, tools, prompt in roles:
            self._conn.execute(
                "INSERT OR IGNORE INTO agent_roles (name, description, default_model, tools_json, system_prompt) "
                "VALUES (?, ?, ?, ?, ?)",
                (name, desc, model, json.dumps(tools), prompt),
            )

    _TASK_COLS = "id, description, status, result_json, error, created_at, updated_at, worker_identity, team_spec, user_id"

    def create_task(
        self,
        description: str,
        team_spec: dict | None = None,
        *,
        user_id: str = "legacy-admin",
    ) -> str:
        """Sprint 23: team_spec can be set atomically with task creation so
        the processor loop never sees a `pending` row without its
        team_spec already attached. Without this guard, the architect's
        ~3-5s LLM call lets the processor pick up the task as single-agent
        before the spec lands (race observed in Sprint 23 validation)."""
        task_id = uuid.uuid4().hex
        now = time.time()
        self._conn.execute(
            "INSERT INTO tasks (id, description, status, team_spec, created_at, updated_at, user_id) "
            "VALUES (?, ?, 'pending', ?, ?, ?, ?)",
            (task_id, description, json.dumps(team_spec) if team_spec else None, now, now, user_id),
        )
        return task_id

    def get_task(self, task_id: str, *, user_id: str | None = None) -> dict | None:
        """Sprint 32: when user_id is given (non-admin path), the task
        is only returned if owned by that user. None passes through (admin
        path or internal callers like the result-event handler)."""
        if user_id is None:
            row = self._conn.execute(
                f"SELECT {self._TASK_COLS} FROM tasks WHERE id = ?", (task_id,),
            ).fetchone()
        else:
            row = self._conn.execute(
                f"SELECT {self._TASK_COLS} FROM tasks WHERE id = ? AND user_id = ?",
                (task_id, user_id),
            ).fetchone()
        return self._row_to_dict(row) if row else None

    def list_tasks(self, limit: int = 100, *, user_id: str | None = None) -> list[dict]:
        if user_id is None:
            rows = self._conn.execute(
                f"SELECT {self._TASK_COLS} FROM tasks ORDER BY created_at DESC LIMIT ?", (limit,),
            ).fetchall()
        else:
            rows = self._conn.execute(
                f"SELECT {self._TASK_COLS} FROM tasks WHERE user_id = ? "
                f"ORDER BY created_at DESC LIMIT ?", (user_id, limit),
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

    def recover_stuck_running(self, _error_unused: str = "") -> int:
        """Move every status='running' row to status='recovering' so the
        Sprint 18 result-event recovery path can pick them up.

        Sprint 15 demoted these to `failed` immediately. Sprint 18 keeps
        them in a transient `recovering` state because the worker on the
        other side might still be in-flight, and on completion will push
        the result as a `kind=result` event wake to the orchestrator's
        inbox (which tally-workers retained while the orchestrator was
        down). The recovery-sweeper background task demotes `recovering`
        rows to `failed` after `TALLY_RECOVERY_TIMEOUT` seconds if no
        result event arrives.

        Returns the number of rows transitioned. Caller signature kept
        for back-compat with Sprint 15 callers — the error argument is
        ignored (the eventual `failed` transition writes its own
        timeout error)."""
        now = time.time()
        cursor = self._conn.execute(
            "UPDATE tasks SET status='recovering', updated_at=? WHERE status='running'",
            (now,),
        )
        return cursor.rowcount or 0

    def mark_recovered(self, task_id: str, result: dict) -> bool:
        """Transition a task from 'recovering' (or 'running' as a no-op
        guard) to 'completed' with the given result. Returns True if a
        row was updated; False if the task isn't in a recoverable state
        (already completed, failed, or unknown id). Used by the event
        poller's `kind=result` handler — idempotent across duplicate
        event deliveries."""
        cursor = self._conn.execute(
            "UPDATE tasks SET status='completed', result_json=?, updated_at=? "
            "WHERE id=? AND status IN ('recovering','running')",
            (json.dumps(result), time.time(), task_id),
        )
        return (cursor.rowcount or 0) > 0

    def sweep_recovering(self, older_than_seconds: float, error: str) -> list[str]:
        """Demote any `recovering` row older than `older_than_seconds`
        to `failed` with the given error message. Returns the list of
        demoted task_ids so the orchestrator can clear in_flight_task
        markers on affected handles (Sprint 19).

        Called periodically by `Orchestrator.run_recovery_sweeper`. The
        threshold guards against demoting a task whose result event is
        in flight; a typical OpenHands task is ~30s so 5min is plenty."""
        cutoff = time.time() - older_than_seconds
        rows = self._conn.execute(
            "SELECT id FROM tasks WHERE status='recovering' AND updated_at < ?",
            (cutoff,),
        ).fetchall()
        demoted_ids = [r[0] for r in rows]
        if demoted_ids:
            placeholders = ",".join(["?"] * len(demoted_ids))
            self._conn.execute(
                f"UPDATE tasks SET status='failed', error=?, updated_at=? "
                f"WHERE id IN ({placeholders})",
                [error, time.time(), *demoted_ids],
            )
        return demoted_ids

    # ── Sprint 22: agent palette + per-task agent instances ──────────────

    def list_agent_roles(self) -> list[dict]:
        rows = self._conn.execute(
            "SELECT name, description, default_model, tools_json, system_prompt "
            "FROM agent_roles ORDER BY name"
        ).fetchall()
        return [
            {
                "name": r[0], "description": r[1], "default_model": r[2],
                "tools": json.loads(r[3]), "system_prompt": r[4],
            }
            for r in rows
        ]

    def get_agent_role(self, name: str) -> dict | None:
        row = self._conn.execute(
            "SELECT name, description, default_model, tools_json, system_prompt "
            "FROM agent_roles WHERE name = ?", (name,),
        ).fetchone()
        if not row:
            return None
        return {
            "name": row[0], "description": row[1], "default_model": row[2],
            "tools": json.loads(row[3]), "system_prompt": row[4],
        }

    def set_task_team_spec(self, task_id: str, team_spec: dict) -> None:
        """Persist Tally's architect output on the task. Called after the
        architect picks a team and before dispatch starts."""
        self._conn.execute(
            "UPDATE tasks SET team_spec=?, updated_at=? WHERE id=?",
            (json.dumps(team_spec), time.time(), task_id),
        )

    def get_task_team_spec(self, task_id: str) -> dict | None:
        row = self._conn.execute(
            "SELECT team_spec FROM tasks WHERE id=?", (task_id,),
        ).fetchone()
        if not row or not row[0]:
            return None
        return json.loads(row[0])

    def insert_agent(
        self, *, task_id: str, agent_idx: int, role: str,
        model: str, spec: str,
    ) -> str:
        """Insert a per-task agent instance. Returns the new agent_id (a hex
        ULID-ish string keyed on task_id + idx for deterministic recovery)."""
        agent_id = uuid.uuid4().hex
        self._conn.execute(
            "INSERT INTO agents (id, task_id, agent_idx, role, model, spec, status) "
            "VALUES (?, ?, ?, ?, ?, ?, 'pending')",
            (agent_id, task_id, agent_idx, role, model, spec),
        )
        return agent_id

    def list_agents(self, task_id: str) -> list[dict]:
        rows = self._conn.execute(
            "SELECT id, task_id, agent_idx, role, model, spec, status, "
            "result_json, worker_identity, started_at, finished_at "
            "FROM agents WHERE task_id=? ORDER BY agent_idx",
            (task_id,),
        ).fetchall()
        return [
            {
                "id": r[0], "task_id": r[1], "agent_idx": r[2], "role": r[3],
                "model": r[4], "spec": r[5], "status": r[6],
                "result": json.loads(r[7]) if r[7] else None,
                "worker_identity": r[8],
                "started_at": r[9], "finished_at": r[10],
            }
            for r in rows
        ]

    def mark_agent_running(self, agent_id: str, worker_identity: str) -> None:
        self._conn.execute(
            "UPDATE agents SET status='running', worker_identity=?, started_at=? WHERE id=?",
            (worker_identity, time.time(), agent_id),
        )

    def mark_agent_completed(self, agent_id: str, result: dict) -> None:
        self._conn.execute(
            "UPDATE agents SET status='completed', result_json=?, finished_at=? WHERE id=?",
            (json.dumps(result), time.time(), agent_id),
        )

    def mark_agent_failed(self, agent_id: str, error: str) -> None:
        self._conn.execute(
            "UPDATE agents SET status='failed', result_json=?, finished_at=? WHERE id=?",
            (json.dumps({"success": False, "error": error}), time.time(), agent_id),
        )

    def insert_event(self, task_id: str, seq: int, event: dict) -> None:
        """Insert a streaming event from the worker. Idempotent on (task_id, seq)."""
        self._conn.execute(
            "INSERT OR IGNORE INTO events (task_id, seq, event_json, received_at) VALUES (?, ?, ?, ?)",
            (task_id, seq, json.dumps(event), time.time()),
        )

    # ── Sprint 29: saved team templates ─────────────────────────────────────

    _TEMPLATE_COLS = ("name, team_spec, source_task_id, note, created_at, "
                      "last_used_at, use_count, user_id")

    @staticmethod
    def _template_row_to_dict(r: tuple) -> dict:
        return {
            "name": r[0],
            "team_spec": json.loads(r[1]),
            "source_task_id": r[2],
            "note": r[3],
            "created_at": r[4],
            "last_used_at": r[5],
            "use_count": r[6],
            "user_id": (r[7] if len(r) > 7 and r[7] else "legacy-admin"),
        }

    def create_template(
        self,
        *,
        name: str,
        team_spec: dict,
        source_task_id: str | None = None,
        note: str | None = None,
        user_id: str = "legacy-admin",
    ) -> None:
        """Insert a template. Caller handles uniqueness violations
        (sqlite IntegrityError if `name` already exists)."""
        self._conn.execute(
            "INSERT INTO team_templates (name, team_spec, source_task_id, note, created_at, use_count, user_id) "
            "VALUES (?, ?, ?, ?, ?, 0, ?)",
            (name, json.dumps(team_spec), source_task_id, note, time.time(), user_id),
        )

    def list_templates(self, *, user_id: str | None = None) -> list[dict]:
        if user_id is None:
            rows = self._conn.execute(
                f"SELECT {self._TEMPLATE_COLS} FROM team_templates "
                "ORDER BY use_count DESC, created_at DESC"
            ).fetchall()
        else:
            rows = self._conn.execute(
                f"SELECT {self._TEMPLATE_COLS} FROM team_templates WHERE user_id = ? "
                "ORDER BY use_count DESC, created_at DESC", (user_id,),
            ).fetchall()
        return [self._template_row_to_dict(r) for r in rows]

    def get_template(self, name: str, *, user_id: str | None = None) -> dict | None:
        if user_id is None:
            row = self._conn.execute(
                f"SELECT {self._TEMPLATE_COLS} FROM team_templates WHERE name=?", (name,),
            ).fetchone()
        else:
            row = self._conn.execute(
                f"SELECT {self._TEMPLATE_COLS} FROM team_templates "
                "WHERE name=? AND user_id=?", (name, user_id),
            ).fetchone()
        return self._template_row_to_dict(row) if row else None

    def delete_template(self, name: str, *, user_id: str | None = None) -> bool:
        if user_id is None:
            cur = self._conn.execute("DELETE FROM team_templates WHERE name=?", (name,))
        else:
            cur = self._conn.execute(
                "DELETE FROM team_templates WHERE name=? AND user_id=?", (name, user_id),
            )
        return (cur.rowcount or 0) > 0

    def touch_template(self, name: str, *, user_id: str | None = None) -> None:
        """Bump last_used_at + use_count. No-op if name isn't a template
        (or doesn't belong to the given user_id, when scoped)."""
        if user_id is None:
            self._conn.execute(
                "UPDATE team_templates SET last_used_at=?, use_count=use_count+1 WHERE name=?",
                (time.time(), name),
            )
        else:
            self._conn.execute(
                "UPDATE team_templates SET last_used_at=?, use_count=use_count+1 "
                "WHERE name=? AND user_id=?",
                (time.time(), name, user_id),
            )

    # ── Sprint 26.5: durable artifact map for cross-restart replay ──────────

    def upsert_artifacts(self, task_id: str, agent_idx: int | None, snap: dict[str, str]) -> None:
        """Persist a per-agent file snapshot. Last-writer-wins per path —
        matches the in-memory `_task_artifacts` semantics, just durable."""
        now = time.time()
        self._conn.executemany(
            "INSERT OR REPLACE INTO task_artifacts (task_id, path, b64_content, agent_idx, ts) "
            "VALUES (?, ?, ?, ?, ?)",
            [(task_id, path, b64, agent_idx, now) for path, b64 in snap.items()],
        )

    def load_artifacts(self, task_id: str) -> dict[str, str]:
        """Hydrate the {path: b64} dict for a task — used on lifespan boot
        to rebuild the in-memory artifact map for in-flight tasks."""
        rows = self._conn.execute(
            "SELECT path, b64_content FROM task_artifacts WHERE task_id=?",
            (task_id,),
        ).fetchall()
        return {path: b64 for path, b64 in rows}

    def list_artifact_paths(self, task_id: str) -> list[dict]:
        """Per-agent path manifest for the UI: {agent_idx, path, size_b64}.
        Stays cheap because the table is keyed (task_id, path)."""
        rows = self._conn.execute(
            "SELECT path, agent_idx, length(b64_content) FROM task_artifacts "
            "WHERE task_id=? ORDER BY agent_idx, path",
            (task_id,),
        ).fetchall()
        return [
            {"path": path, "agent_idx": idx, "size_b64": size}
            for path, idx, size in rows
        ]

    def delete_artifacts(self, task_id: str) -> int:
        """Free durable storage after a task is fully terminal."""
        cur = self._conn.execute(
            "DELETE FROM task_artifacts WHERE task_id=?", (task_id,),
        )
        return cur.rowcount or 0

    def list_artifact_task_ids(self) -> list[str]:
        rows = self._conn.execute(
            "SELECT DISTINCT task_id FROM task_artifacts"
        ).fetchall()
        return [r[0] for r in rows]

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
            "team_spec": json.loads(row[8]) if len(row) > 8 and row[8] else None,
            # Pre-Sprint-32 rows have NULL user_id (SQLite leaves it NULL
            # despite the ALTER TABLE … DEFAULT 'legacy-admin' clause when
            # rows existed at migration time). Normalize on the read path.
            "user_id": (row[9] if len(row) > 9 and row[9] else "legacy-admin"),
        }


def _resolve_stages(raw: Any, n_agents: int) -> list[list[int]]:
    """Sprint 27: turn an architect's `stages` value into the
    authoritative execution graph the dispatcher uses.

    Sequential workflows from Sprint 22-26 omit `stages` entirely; we
    return a fully-serialized `[[0], [1], ...]` in that case so the
    Sprint 22 codepath behaves identically.

    Any malformed input falls back to sequential — the architect's
    own validator already runs the same checks, so this is a backstop
    against hand-crafted team_specs and DB rows from older versions.
    """
    default = [[i] for i in range(n_agents)]
    if not isinstance(raw, list) or not raw:
        return default
    seen: set[int] = set()
    cleaned: list[list[int]] = []
    for stage in raw:
        if not isinstance(stage, list) or not stage:
            return default
        cleaned_stage: list[int] = []
        for idx in stage:
            if not isinstance(idx, int) or idx < 0 or idx >= n_agents or idx in seen:
                return default
            seen.add(idx)
            cleaned_stage.append(idx)
        cleaned.append(cleaned_stage)
    if seen != set(range(n_agents)):
        return default
    return cleaned


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
    """One worker's view in the orchestrator: identity, MLS session, lock,
    and an in-flight task marker.

    `lock` is held while a task is being *dispatched* (encrypt + wake +
    decrypt the ack) — the MLS sender ratchet is single-writer, so two
    concurrent encrypts on the same session corrupt state. Sprint 19
    made the dispatch *fire-and-forget* (Sprint 18's persisted result
    event becomes the only completion channel) so the lock is released
    seconds after dispatch, not minutes.

    `in_flight_task` tracks whether the worker is busy running a task
    *between dispatch and result-event arrival*. The lock can be free
    while the worker is still working — `acquire_idle` checks both."""
    identity: str
    team_id: str
    cvm_id: str
    app_id: str | None
    session: MlsSession
    # Sprint 28: how the orchestrator should think about this worker's
    # environment. "tee" = Phala CVM (default; full sandbox, no host
    # filesystem). "local" = a user-installed `tally-agent` daemon on
    # the user's machine — same MLS handshake, just running outside
    # a TEE. Agents whose team_spec sets worker_affinity="local" or
    # "local_if_available" prefer this handle.
    worker_type: str = "tee"
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    failures: int = 0  # consecutive task failures on this handle
    in_flight_task: str | None = None  # task_id currently running on this worker


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
        # Sprint 21: surfaced via /admin/status for the dashboard CLI.
        self._started_at: float = time.time()
        self._sweep_last_at: float | None = None
        self._sweep_last_demoted: int = 0
        self._sweep_total_demoted: int = 0
        # Sprint 23: Red Pill credentials for the Tally architect. Loaded
        # from the same scripts/.env that builds worker env files. None
        # means architect calls fall back to Solo Coder unconditionally
        # (logged at boot if missing).
        self.redpill_key: str | None = None
        self.redpill_base: str = "https://api.redpill.ai/v1"
        # Sprint 26: per-task accumulated artifacts. Each value is a
        # {relative_path: base64_content} dict; agents receive prior
        # agents' files via the `seed_files` field on dispatch, and
        # their result events deliver their snapshot under `files_b64`.
        # In-memory only — the orchestrator can rebuild it from the
        # last agent's result on restart if needed (Sprint 18's
        # recovery semantics already handle the at-least-once case).
        self._task_artifacts: dict[str, dict[str, str]] = {}

    # ── handle lifecycle ──────────────────────────────────────────────────

    def _session_dir(self, team_id: str) -> Path:
        d = self.mls_state_base / f"team-{team_id}"
        d.mkdir(parents=True, exist_ok=True)
        return d

    def add_handle(
        self,
        *,
        team_id: str,
        worker_identity: str,
        cvm_id: str,
        app_id: str | None,
        worker_type: str = "tee",
    ) -> WorkerHandle:
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
            app_id=app_id, session=session, worker_type=worker_type,
        )
        self.handles[worker_identity] = handle
        return handle

    def bootstrap_handle(self, handle: WorkerHandle) -> None:
        """3-wake handshake against handle's worker. Also registers the
        orchestrator's bearer as the task:event handler in the worker's
        team so events route back through tally-workers correctly.

        Sprint 18: the handshake timeout is 240s (was 60s in earlier
        sprints) because an orchestrator-restart-against-busy-worker is
        a supported scenario now — the worker's main loop is single-
        threaded and won't pop the handshake wake from its inbox until
        any in-flight task finishes. Worst case is ~60-90s for a long
        OpenHands run, plus a slack margin.

        The second handshake creates a fresh MLS group; both sides
        re-key cleanly. Any wakes the worker had queued for delivery
        on the old group's ratchet position will fail to decrypt and
        get ack-and-skipped by the Sprint 15 path. Any wakes the worker
        sends *after* re-joining the new group decrypt fine — which is
        what the Sprint 18 result-event recovery relies on."""
        self.client.team_init(handle.team_id, bearer=self.bearer)
        self.client.register(handle.team_id, self.bearer, bearer=self.bearer, context_id=EVENT_CONTEXT_ID)
        logger.info("bootstrap[%s]: requesting worker key package", handle.identity[:8])
        kp_resp = self._dispatch_blocking(
            handle, context_id=BOOTSTRAP_CONTEXT_ID,
            payload=json.dumps({"phase": "request_kp"}).encode("utf-8"),
            timeout_seconds=240,
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
            timeout_seconds=240,
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

    async def acquire_idle(
        self,
        timeout: float = 60.0,
        *,
        affinity: str | None = None,
    ) -> WorkerHandle:
        """Wait up to `timeout` for a handle that is both unlocked AND has
        no in-flight task (Sprint 19). The lock guards MLS sender-ratchet
        state during a dispatch; `in_flight_task` guards worker busyness
        across the gap between dispatch-ack and result-event arrival.

        Sprint 28: `affinity` filters which handles count as candidates.
          - None / "any": any worker type
          - "tee":              only TEE handles
          - "local":            only local handles (hard requirement)
          - "local_if_available": local first; falls back to any handle
            once half the timeout has elapsed without a local match.
        Picks the first matching handle in dict-insertion order."""
        def _matches(h: WorkerHandle, want: str | None) -> bool:
            if want in (None, "any"):
                return True
            if want == "local_if_available":
                return h.worker_type == "local"
            return h.worker_type == want
        deadline = time.monotonic() + timeout
        # For local_if_available, soft-prefer local until half the budget
        # is gone, then accept any handle. Hard "local" / "tee" never
        # widen — operator chose them deliberately.
        soft_deadline = deadline if affinity != "local_if_available" else time.monotonic() + (timeout / 2.0)
        while time.monotonic() < deadline:
            now = time.monotonic()
            want = affinity if (affinity != "local_if_available" or now < soft_deadline) else None
            for handle in list(self.handles.values()):
                if not _matches(handle, want):
                    continue
                if handle.lock.locked() or handle.in_flight_task is not None:
                    continue
                try:
                    await asyncio.wait_for(handle.lock.acquire(), timeout=0.01)
                except asyncio.TimeoutError:
                    continue
                # Re-check under the lock — another task may have grabbed
                # in_flight_task between our check and acquire.
                if handle.in_flight_task is not None:
                    handle.lock.release()
                    continue
                return handle
            await asyncio.sleep(0.5)
        raise TimeoutError(
            f"no idle worker available within {timeout}s (affinity={affinity})"
        )

    async def _publish_status(self, task_id: str, status: str, extra: dict | None = None) -> None:
        payload = {"task_id": task_id, "status": status, "ts": time.time()}
        if extra:
            payload.update(extra)
        await self.event_bus.publish(task_id, {"_kind": "status_change", **payload})

    async def process_task(self, task: dict) -> None:
        """Sprint 19 + 22: fire-and-forget dispatch with two flavours.

        - **Multi-agent** (Sprint 22): if `task.team_spec` is set, this
          is Tally's pre-architected team. Insert per-agent rows then
          dispatch the FIRST agent. The event poller picks up each
          agent's result event and advances to the next agent in the
          workflow.
        - **Single-agent** (legacy): no team_spec → dispatch the
          existing single OpenHands run (Sprint 19 fire-and-forget).
        """
        team_spec = self.db.get_task_team_spec(task["id"])
        if team_spec:
            await self._start_team(task, team_spec)
        else:
            await self._dispatch_single_agent(task)

    async def _start_team(self, task: dict, team_spec: dict) -> None:
        """Resolve role defaults, insert per-agent rows, dispatch the
        first stage.

        Sprint 22 workflow was sequential-only. Sprint 27 adds parallel
        stages: `team_spec["stages"]` is `list[list[int]]`; every agent
        in stage N runs concurrently, the next stage starts when stage N
        is fully complete.
        """
        agents_spec = team_spec.get("agents", []) or []
        if not agents_spec:
            self.db.mark_failed(task["id"], "team_spec has no agents")
            await self._publish_status(task["id"], "failed", {"error": "team_spec has no agents"})
            return
        # Resolve + insert per-agent rows up front so the team's shape is
        # visible in /admin/status before any worker dispatch starts.
        for idx, a in enumerate(agents_spec):
            role_name = a.get("role")
            role = self.db.get_agent_role(role_name)
            if not role:
                self.db.mark_failed(task["id"], f"unknown role: {role_name}")
                await self._publish_status(task["id"], "failed", {"error": f"unknown role: {role_name}"})
                return
            self.db.insert_agent(
                task_id=task["id"], agent_idx=idx, role=role_name,
                model=a.get("model") or role["default_model"],
                spec=a.get("spec", ""),
            )
        self.db.mark_running(task["id"])
        await self._publish_status(task["id"], "running", {"team_size": len(agents_spec)})
        stages = _resolve_stages(team_spec.get("stages"), len(agents_spec))
        first_stage_indices = stages[0]
        all_agents = self.db.list_agents(task["id"])
        by_idx = {a["agent_idx"]: a for a in all_agents}
        first_stage = [by_idx[i] for i in first_stage_indices]
        logger.info("starting team for task %s: %d agents, stage 0 = [%s]",
                    task["id"][:8], len(agents_spec),
                    ", ".join(a["role"] for a in first_stage))
        # Fan out the first stage. Each dispatch is fire-and-forget;
        # _handle_result_event advances stages when the last agent in
        # the current stage finishes.
        for agent in first_stage:
            asyncio.create_task(self._dispatch_agent(task, agent))

    async def _dispatch_agent(self, task: dict, agent: dict) -> None:
        """Encrypt + send one agent's task wake. Fire-and-forget; the
        event poller advances to the next agent on result. Mirrors
        `_dispatch_single_agent` but with per-agent payload."""
        # Sprint 28: per-agent worker_affinity, sourced from the
        # architect's team_spec.agents[idx].worker_affinity. The
        # dispatcher prefers handles of the matching type; with
        # "local_if_available" we widen to any handle after half the
        # acquire timeout, so a missing local worker doesn't stall.
        team_spec = task.get("team_spec") or {}
        agent_idx = agent["agent_idx"]
        spec_agents = (team_spec.get("agents") or []) if isinstance(team_spec, dict) else []
        affinity: str | None = None
        if 0 <= agent_idx < len(spec_agents) and isinstance(spec_agents[agent_idx], dict):
            affinity = spec_agents[agent_idx].get("worker_affinity") or None
        acquire_timeout = int(os.environ.get("TALLY_ACQUIRE_TIMEOUT", "120"))
        try:
            handle = await self.acquire_idle(timeout=acquire_timeout, affinity=affinity)
        except TimeoutError as exc:
            # Sprint 28.5 fallover: a strict "local" or "tee" affinity that
            # times out is usually because that worker tier went away
            # (laptop closed, CVM died). Rather than failing the whole
            # task, retry once with no affinity — better to run on the
            # other tier than to abort the team.
            if affinity in ("local", "tee"):
                logger.warning(
                    "task %s agent %s: affinity=%s unavailable; downgrading to any-worker retry",
                    task["id"][:8], agent["role"], affinity,
                )
                try:
                    handle = await self.acquire_idle(timeout=acquire_timeout, affinity=None)
                    affinity_downgrade = True
                except TimeoutError as exc2:
                    logger.error(
                        "task %s agent %s: no worker available even after downgrade",
                        task["id"][:8], agent["role"],
                    )
                    self.db.mark_agent_failed(agent["id"], str(exc2))
                    self.db.mark_failed(task["id"], f"no worker for {agent['role']}: {exc2}")
                    await self._publish_status(task["id"], "failed", {"error": str(exc2)})
                    return
            else:
                logger.error(
                    "task %s agent %s: no worker available (affinity=%s)",
                    task["id"][:8], agent["role"], affinity,
                )
                self.db.mark_agent_failed(agent["id"], str(exc))
                self.db.mark_failed(task["id"], f"no worker for {agent['role']}: {exc}")
                await self._publish_status(task["id"], "failed", {"error": str(exc)})
                return
        else:
            affinity_downgrade = False
        if affinity_downgrade:
            logger.info(
                "task %s agent %s landed on %s worker after affinity=%s downgrade",
                task["id"][:8], agent["role"], handle.worker_type, affinity,
            )
        try:
            handle.in_flight_task = task["id"]
            self.db.set_task_worker(task["id"], handle.identity)
            self.db.mark_agent_running(agent["id"], handle.identity)
            role = self.db.get_agent_role(agent["role"]) or {}
            await self._publish_status(task["id"], "running", {
                "agent_role": agent["role"], "agent_idx": agent["agent_idx"],
            })
            logger.info("dispatching task %s agent %s/%s (%s) to worker %s",
                        task["id"][:8], agent["agent_idx"], agent["role"],
                        agent["model"], handle.identity[:8])
            try:
                payload_obj = {
                    "task": task["description"],
                    "task_id": task["id"],
                    "orchestrator_bearer": self.bearer,
                    "agent_idx": agent["agent_idx"],
                    "agent_spec": {
                        "role": agent["role"],
                        "model": agent["model"],
                        "spec": agent["spec"],
                        "system_prompt": role.get("system_prompt", ""),
                        "tools": role.get("tools", []),
                    },
                    # Sprint 26: hand the agent its predecessors' files.
                    # Empty on the first agent in a team.
                    "seed_files": self._task_artifacts.get(task["id"], {}),
                }
                ciphertext = handle.session.encrypt(json.dumps(payload_obj).encode("utf-8"))
                ack_bytes = await asyncio.to_thread(
                    self._dispatch_blocking, handle,
                    context_id=TASK_CONTEXT_ID,
                    payload=ciphertext,
                    timeout_seconds=int(os.environ.get("TALLY_TASK_ACK_TIMEOUT", "30")),
                )
                ack_plain = handle.session.decrypt(ack_bytes).decode("utf-8")
                ack = json.loads(ack_plain)
                if not ack.get("ack"):
                    raise RuntimeError(f"worker rejected agent task: {ack.get('error', 'unknown')}")
                handle.failures = 0
                logger.info("task %s agent %s acked by worker %s",
                            task["id"][:8], agent["role"], handle.identity[:8])
            except Exception as exc:
                logger.exception("task %s agent %s dispatch failed", task["id"][:8], agent["role"])
                self.db.mark_agent_failed(agent["id"], str(exc))
                self.db.mark_failed(task["id"], f"agent {agent['role']} dispatch failed: {exc}")
                await self._publish_status(task["id"], "failed", {"error": str(exc)})
                handle.in_flight_task = None
                handle.failures += 1
                if handle.failures >= self._auto_rotate_threshold and handle.identity not in self._rotating:
                    self._rotating.add(handle.identity)
                    asyncio.create_task(self._rotate_handle(handle))
        finally:
            handle.lock.release()

    async def _dispatch_single_agent(self, task: dict) -> None:
        """Legacy single-agent dispatch path (Sprint 19 fire-and-forget).
        Kept for tasks submitted without a team_spec — they get a default
        one-OpenHands-run experience."""
        try:
            handle = await self.acquire_idle(timeout=int(os.environ.get("TALLY_ACQUIRE_TIMEOUT", "120")))
        except TimeoutError as exc:
            logger.error("task %s: no worker available within timeout", task["id"][:8])
            self.db.mark_failed(task["id"], str(exc))
            await self._publish_status(task["id"], "failed", {"error": str(exc)})
            return
        try:
            handle.in_flight_task = task["id"]
            self.db.set_task_worker(task["id"], handle.identity)
            self.db.mark_running(task["id"])
            await self._publish_status(task["id"], "running")
            logger.info("dispatching task %s to worker %s: %s",
                        task["id"][:8], handle.identity[:8], task["description"][:60])
            try:
                payload_obj = {
                    "task": task["description"],
                    "task_id": task["id"],
                    "orchestrator_bearer": self.bearer,
                }
                ciphertext = handle.session.encrypt(json.dumps(payload_obj).encode("utf-8"))
                ack_bytes = await asyncio.to_thread(
                    self._dispatch_blocking, handle,
                    context_id=TASK_CONTEXT_ID,
                    payload=ciphertext,
                    timeout_seconds=int(os.environ.get("TALLY_TASK_ACK_TIMEOUT", "30")),
                )
                ack_plain = handle.session.decrypt(ack_bytes).decode("utf-8")
                ack = json.loads(ack_plain)
                if not ack.get("ack"):
                    raise RuntimeError(f"worker rejected task: {ack.get('error', 'unknown')}")
                handle.failures = 0
                logger.info("task %s acked by worker %s; awaiting result event",
                            task["id"][:8], handle.identity[:8])
            except Exception as exc:
                logger.exception("task %s dispatch on worker %s failed",
                                 task["id"][:8], handle.identity[:8])
                self.db.mark_failed(task["id"], str(exc))
                await self._publish_status(task["id"], "failed", {"error": str(exc)})
                handle.in_flight_task = None
                handle.failures += 1
                if handle.failures >= self._auto_rotate_threshold and handle.identity not in self._rotating:
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
            logger.info("scale: adding %d worker(s) in parallel (current=%d, target=%d)",
                        n, current, target_size)
            # Parallel: per-deploy image tags (Sprint 16) give each CVM
            # its own Phala App ID, so the KMS UNIQUE(address) race that
            # required serial in Sprint 14 no longer applies.
            provisioned = await asyncio.gather(
                *[asyncio.to_thread(pool.provision) for _ in range(n)],
                return_exceptions=True,
            )
            for r in provisioned:
                if isinstance(r, BaseException):
                    logger.warning("scale: provision failed: %s", r)
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

    async def _handle_result_event(
        self, *, task_id: str, worker_identity: str, result: dict
    ) -> None:
        """Sprint 22: a `kind=result` event arrived. Either:

        - Single-agent path (no agent_idx in result): mark task completed
          (legacy Sprint 18-19 behaviour).
        - Multi-agent path (agent_idx present): mark that agent done,
          dispatch the next agent in sequence, or finalize the task if
          this was the last agent.
        """
        agent_idx = result.get("agent_idx")
        if agent_idx is None:
            # Sprint 27 fix: a result event without `agent_idx` should
            # only take the single-agent path when the task is *actually*
            # single-agent. A multi-agent task with running rows but a
            # bare result event signals a worker bug (e.g., exception
            # path dropping agent_idx) — attribute the failure to the
            # in-flight agent on this worker rather than prematurely
            # marking the whole task completed.
            running_agents = [
                a for a in self.db.list_agents(task_id) if a["status"] == "running"
            ]
            if running_agents:
                # Match the result to the agent the worker was busy with.
                target = next(
                    (a for a in running_agents if a.get("worker_identity") == worker_identity),
                    running_agents[0],
                )
                logger.warning(
                    "task %s: result event lacked agent_idx on multi-agent task; "
                    "attributing to running agent %s/%s",
                    task_id[:8], target["agent_idx"], target["role"],
                )
                result = {**result, "agent_idx": target["agent_idx"], "agent_role": target["role"]}
                agent_idx = target["agent_idx"]
                # fall through to the multi-agent path below
            else:
                # Single-agent legacy path.
                completed = self.db.mark_recovered(task_id, result)
                if completed:
                    logger.info(
                        "task %s result event from worker %s: success=%s",
                        task_id[:8], worker_identity[:8], result.get("success"),
                    )
                    await self._publish_status(
                        task_id, "completed",
                        {"success": result.get("success")},
                    )
                return

        # Multi-agent path
        agents = self.db.list_agents(task_id)
        target_agent = next((a for a in agents if a["agent_idx"] == agent_idx), None)
        if target_agent is None:
            logger.warning("result event for unknown agent_idx=%s on task %s; ignoring",
                           agent_idx, task_id[:8])
            return
        if target_agent["status"] in ("completed", "failed"):
            logger.debug("duplicate result event for task %s agent %s; ignoring",
                         task_id[:8], target_agent["role"])
            return
        # Sprint 27: if the task already failed (e.g. one parallel agent
        # crashed and we marked the whole task failed), drop late results
        # from sibling agents. Still record the agent's own row so the UI
        # can see what happened, but don't advance stages or aggregate.
        task_row = self.db.get_task(task_id)
        task_already_terminal = (
            task_row is not None
            and task_row.get("status") in ("completed", "failed")
        )
        if task_already_terminal:
            self.db.mark_agent_completed(target_agent["id"], result) if result.get("success") else \
                self.db.mark_agent_failed(target_agent["id"], result.get("error", "?"))
            logger.info("task %s already terminal; recorded late result from agent %s",
                        task_id[:8], target_agent["role"])
            return
        # Sprint 26: harvest workspace snapshot before persisting the
        # result row. We keep the per-agent files in memory keyed by
        # task_id and strip `files_b64` from what we write into SQLite
        # — those base64 blobs would balloon the row and Sprint 26's
        # caps already keep the in-memory copy bounded (2 MB / task).
        snap = result.pop("files_b64", None) if isinstance(result, dict) else None
        if snap:
            bucket = self._task_artifacts.setdefault(task_id, {})
            for path, b64 in snap.items():
                bucket[path] = b64  # last-write-wins between agents
            # Sprint 26.5: also persist so an orchestrator restart can
            # rehydrate this dict before the next agent dispatches.
            self.db.upsert_artifacts(task_id, agent_idx, snap)
            logger.info("task %s agent %s snapshot: %d file(s); team artifacts now=%d",
                        task_id[:8], target_agent["role"], len(snap), len(bucket))
        # Mark this agent done.
        if result.get("success") is False:
            self.db.mark_agent_failed(target_agent["id"], result.get("error", "agent returned failure"))
            logger.warning("task %s agent %s (%s) failed: %s",
                           task_id[:8], agent_idx, target_agent["role"], result.get("error", "?"))
        else:
            self.db.mark_agent_completed(target_agent["id"], result)
            logger.info("task %s agent %s (%s) completed: files=%s",
                        task_id[:8], agent_idx, target_agent["role"],
                        len(result.get("files_created", []) or []))
        # Did this agent fail? Short-circuit the rest of the workflow.
        if result.get("success") is False:
            self.db.mark_failed(task_id, f"agent {target_agent['role']} failed: {result.get('error', '?')}")
            self._task_artifacts.pop(task_id, None)  # Sprint 26: free memory
            self.db.delete_artifacts(task_id)        # Sprint 26.5: free durable copy
            await self._publish_status(
                task_id, "failed",
                {"error": result.get("error", "agent failed"), "agent_role": target_agent["role"]},
            )
            return
        # Sprint 27: stage-aware advancement. The agent we just finished
        # is in some stage; only advance to the *next* stage when EVERY
        # agent in this stage has reached a terminal status. Sequential
        # workflows collapse to one-agent-per-stage and behave identically
        # to Sprint 22.
        task = self.db.get_task(task_id)
        if task is None:
            logger.error("task %s gone before stage advance", task_id[:8])
            return
        team_spec = task.get("team_spec") or {}
        stages = _resolve_stages(team_spec.get("stages"), len(agents))
        cur_stage_idx = next(
            (i for i, stage in enumerate(stages) if agent_idx in stage),
            None,
        )
        if cur_stage_idx is None:
            logger.warning("task %s agent %d not in any stage; assuming sequential tail",
                           task_id[:8], agent_idx)
            cur_stage_idx = len(stages) - 1
        # Refresh agents — this agent's status changed inside this handler.
        fresh = self.db.list_agents(task_id)
        by_idx = {a["agent_idx"]: a for a in fresh}
        cur_stage = stages[cur_stage_idx]
        stage_pending = [
            i for i in cur_stage
            if by_idx.get(i, {}).get("status") not in ("completed", "failed")
        ]
        if stage_pending:
            logger.debug("task %s stage %d still has pending: %s",
                         task_id[:8], cur_stage_idx, stage_pending)
            return  # other agents in this stage still running
        # Stage complete; dispatch the next one if any.
        next_stage_idx = cur_stage_idx + 1
        if next_stage_idx < len(stages):
            next_stage_indices = stages[next_stage_idx]
            next_agents = [by_idx[i] for i in next_stage_indices if by_idx.get(i)]
            logger.info("task %s stage %d → %d: dispatching [%s]",
                        task_id[:8], cur_stage_idx, next_stage_idx,
                        ", ".join(a["role"] for a in next_agents))
            for a in next_agents:
                asyncio.create_task(self._dispatch_agent(task, a))
            return
        # All agents done — task is complete. Aggregate results.
        final_agents = self.db.list_agents(task_id)
        aggregate = {
            "success": all(a["status"] == "completed" for a in final_agents),
            "agents": [
                {"role": a["role"], "agent_idx": a["agent_idx"],
                 "model": a["model"], "result": a["result"]}
                for a in final_agents
            ],
        }
        self.db.mark_completed(task_id, aggregate)
        artifact_count = len(self._task_artifacts.pop(task_id, {}))  # Sprint 26: free memory
        self.db.delete_artifacts(task_id)  # Sprint 26.5: free durable copy
        await self._publish_status(
            task_id, "completed",
            {"success": aggregate["success"], "agents_run": len(final_agents)},
        )
        logger.info("task %s team complete: %d agents, %d artifact(s) accumulated",
                    task_id[:8], len(final_agents), artifact_count)

    async def run_recovery_sweeper(self) -> None:
        """Sprint 18+19: every 60s, demote any `recovering` row older
        than `TALLY_RECOVERY_TIMEOUT` (default 300s) to `failed`, AND
        clear the in_flight_task marker on any handle whose currently-
        tracked task got demoted (Sprint 19's fire-and-forget model
        leaves the handle marked busy across the result-wait, so a
        worker that silently stops sending result events would keep
        its handle permanently busy without this sweep).

        Demoting also bumps the affected handle's failure counter and
        can trigger auto-rotate — silent task loss is a strong signal
        the worker is unhealthy."""
        timeout_s = float(os.environ.get("TALLY_RECOVERY_TIMEOUT", "300"))
        while True:
            try:
                demoted = self.db.sweep_recovering(
                    older_than_seconds=timeout_s,
                    error=f"no result event arrived within {int(timeout_s)}s",
                )
                self._sweep_last_at = time.time()
                self._sweep_last_demoted = len(demoted)
                self._sweep_total_demoted += len(demoted)
                if demoted:
                    logger.warning(
                        "recovery sweeper demoted %d stale recovering task(s) to failed",
                        len(demoted),
                    )
                    for handle in list(self.handles.values()):
                        if handle.in_flight_task in demoted:
                            logger.warning(
                                "sweeper clearing in_flight on worker %s (task %s never returned)",
                                handle.identity[:8], (handle.in_flight_task or "")[:8],
                            )
                            handle.in_flight_task = None
                            handle.failures += 1
                            if (handle.failures >= self._auto_rotate_threshold
                                    and handle.identity not in self._rotating):
                                logger.warning(
                                    "auto-rotating worker %s after %d sweep-failures",
                                    handle.identity[:8], handle.failures,
                                )
                                self._rotating.add(handle.identity)
                                asyncio.create_task(self._rotate_handle(handle))
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                logger.exception("recovery sweeper iteration failed: %s", exc)
            await asyncio.sleep(60)

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
                                # Sprint 18-19: kind=result events transition
                                # the task to `completed`. Sprint 22:
                                # multi-agent path — the result is *one
                                # agent's* result; mark just that agent
                                # done and advance to the next agent in
                                # the workflow. The task only flips to
                                # completed when the *last* agent
                                # finishes (or any agent fails).
                                event = inner.get("event", {}) or {}
                                if event.get("kind") == "result":
                                    task_id = inner.get("task_id", "")
                                    result = event.get("result", {})
                                    if target.in_flight_task == task_id:
                                        target.in_flight_task = None
                                    await self._handle_result_event(
                                        task_id=task_id,
                                        worker_identity=worker_identity,
                                        result=result,
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
    """FastAPI dependency: 401s any request without a valid Bearer token.

    Sprint 32 leaves this as the admin-only path; new endpoints prefer
    `require_user` which accepts EITHER the admin token OR a Clerk JWT.
    """
    expected: str = state.get("api_token", "")
    presented = creds.credentials if creds and creds.scheme.lower() == "bearer" else ""
    # hmac.compare_digest is constant-time vs short-circuit ==.
    if not expected or not presented or not hmac.compare_digest(expected, presented):
        raise HTTPException(status_code=401, detail="missing or invalid bearer token")


# ── Sprint 32: per-user auth ──────────────────────────────────────────────────


async def require_user(
    creds: HTTPAuthorizationCredentials | None = Depends(_bearer),
) -> ClerkUser:
    """Sprint 32 dispatcher: accepts the legacy admin TALLY_API_TOKEN
    (returns User(id='admin', source='admin')) OR a Clerk JWT (returns
    User(id=<sub>, source='clerk')). Dispatches by token shape — JWTs
    always start with `eyJ`, admin tokens are random URL-safe bytes.

    Routes that scope to the calling user filter by `user.id` when
    `user.source == 'clerk'` and skip the filter for admin.
    """
    presented = creds.credentials if creds and creds.scheme.lower() == "bearer" else ""
    if not presented:
        raise HTTPException(status_code=401, detail="missing bearer token")
    if clerk_looks_like_jwt(presented):
        validator: ClerkValidator | None = state.get("clerk_validator")
        if validator is None:
            raise HTTPException(
                status_code=503,
                detail="Clerk not configured on this orchestrator (set CLERK_PUBLISHABLE_KEY)",
            )
        try:
            return validator.validate(presented)
        except jwt.PyJWTError as exc:
            raise HTTPException(status_code=401, detail=f"invalid clerk JWT: {exc}")
    # Legacy admin token path — constant-time compare against api_token.
    expected: str = state.get("api_token", "")
    if not expected or not hmac.compare_digest(expected, presented):
        raise HTTPException(status_code=401, detail="invalid bearer token")
    return ClerkUser(id="admin", source="admin")


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
        logger.info("using env-pinned tee worker: team=%s identity=%s...", env_team, env_id[:12])
        results.append({
            "team_id": env_team, "identity": env_id,
            "cvm_id": f"env-{env_team}", "app_id": None, "from_env": True,
            "worker_type": "tee",
        })
        seen.add(env_id)

    # Sprint 28: optional second pinned worker — `tally-agent` running on
    # the user's laptop. Identical bootstrap path to the TEE worker, just
    # tagged with worker_type="local" so the dispatcher can route by
    # `worker_affinity` (Sprint 28's affinity-aware acquire_idle).
    local_team = os.environ.get("TEAM_ID_LOCAL", "").strip()
    local_id = os.environ.get("WORKER_IDENTITY_B64_LOCAL", "").strip()
    if local_team and local_id and local_id not in seen:
        logger.info("using env-pinned local worker: team=%s identity=%s...", local_team, local_id[:12])
        results.append({
            "team_id": local_team, "identity": local_id,
            "cvm_id": f"env-{local_team}", "app_id": None, "from_env": True,
            "worker_type": "local",
        })
        seen.add(local_id)

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
        serial = os.environ.get("TALLY_SERIAL_PROVISION", "").lower() in ("1", "true", "yes")
        if serial:
            # Sprint 24: hosted-orchestrator path. Per-deploy image builds
            # (Sprint 16) require docker-in-docker, which Phala CVMs
            # block. Without unique-digest images, parallel provisions
            # race for the same KMS App ID (Sprint 14). Serialize.
            logger.info("auto-provisioning %d worker(s) serially (may take ~%dmin)",
                        shortfall, shortfall * 3)
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
        else:
            # Sprint 16: parallel with per-deploy image builds. Each
            # provision pushes a unique-digest image so each lands in a
            # distinct Phala App ID — no UNIQUE(address) race.
            logger.info("auto-provisioning %d worker(s) in parallel (may take ~3-5min)", shortfall)
            provisioned = await asyncio.gather(
                *[asyncio.to_thread(pool.provision) for _ in range(shortfall)],
                return_exceptions=True,
            )
            for r in provisioned:
                if isinstance(r, BaseException):
                    logger.warning("provision failed: %s", r)
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
            worker_type=w.get("worker_type", "tee"),
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
    # `SCRIPTS_ENV_PATH` overrides; default to <repo>/scripts/.env when the
    # orchestrator runs from a checkout. In the Sprint 24 hosted-CVM image
    # there is no repo around the install dir (parents[3] is OOB), so fall
    # back to a path that simply won't exist — Red Pill creds are then
    # injected via the container's own env vars instead.
    _scripts_env_default = "/dev/null"
    _parents = Path(__file__).resolve().parents
    if len(_parents) > 3:
        _scripts_env_default = str(_parents[3] / "scripts" / ".env")
    scripts_env = os.environ.get("SCRIPTS_ENV_PATH", _scripts_env_default)
    target_pool_size = max(1, int(os.environ.get("TALLY_POOL_SIZE", "1")))
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)

    db = Db(db_path)
    state["api_token"] = _resolve_token(Path(db_path).parent)
    # Self-heal any tasks left mid-flight by a previous crash. They'd be
    # invisible to next_pending() and pin nothing on the new pool — but
    # they'd also lie about the worker that ran them in /tasks responses
    # forever. Sprint 18: instead of immediately marking them failed,
    # move them to `recovering` so the event poller can transition them
    # to `completed` if/when the worker's persistent result event
    # arrives. A separate sweeper demotes stale `recovering` rows after
    # TALLY_RECOVERY_TIMEOUT (default 300s).
    orphans = db.recover_stuck_running()
    if orphans:
        logger.warning(
            "transitioned %d stuck running task(s) to recovering on startup",
            orphans,
        )
    event_bus = EventBus()
    pool = WorkerPool(scripts_env_path=scripts_env)
    state["worker_pool"] = pool
    state["db"] = db
    state["event_bus"] = event_bus

    # Sprint 26.5: rehydrate the in-memory artifact map from the durable
    # task_artifacts table. Without this, a mid-task orchestrator restart
    # would dispatch the next agent with an empty seed_files and break
    # the artifact-passing contract.
    pre_orch_artifacts: dict[str, dict[str, str]] = {}
    for tid in db.list_artifact_task_ids():
        t = db.get_task(tid)
        if t is None or t.get("status") in ("completed", "failed"):
            # Stale entry from a task that finished elsewhere; clean up.
            db.delete_artifacts(tid)
            continue
        pre_orch_artifacts[tid] = db.load_artifacts(tid)
    if pre_orch_artifacts:
        logger.info("rehydrated artifacts for %d in-flight task(s): %s",
                    len(pre_orch_artifacts),
                    ", ".join(f"{tid[:8]}({len(v)})" for tid, v in pre_orch_artifacts.items()))

    orchestrator = Orchestrator(
        tally_url=tally_url,
        identity_path=identity_path,
        mls_state_base_dir=mls_state_base_dir,
        db=db,
        event_bus=event_bus,
    )
    # Sprint 26.5: install the rehydrated artifact map so the next agent
    # dispatched (e.g. by a stage advance after restart) gets the seed.
    if pre_orch_artifacts:
        orchestrator._task_artifacts.update(pre_orch_artifacts)
    # Sprint 23: load Red Pill creds from the same scripts/.env that builds
    # worker env files. The architect uses these for the per-task team
    # picker. Missing key → architect calls fall back to Solo Coder.
    #
    # Sprint 24: in the hosted-CVM image we pass these as direct env
    # vars (no scripts/.env available); read them inline as a fallback
    # so the architect works in both deployment modes.
    try:
        env_lines = Path(scripts_env).read_text().splitlines()
        for line in env_lines:
            line = line.strip()
            if line.startswith("REDPILL_API_KEY="):
                orchestrator.redpill_key = line.split("=", 1)[1].strip()
            elif line.startswith("REDPILL_BASE_URL="):
                orchestrator.redpill_base = line.split("=", 1)[1].strip()
    except OSError as exc:
        logger.debug("scripts_env not readable (%s); falling back to direct env vars", exc)
    if not orchestrator.redpill_key:
        orchestrator.redpill_key = os.environ.get("REDPILL_API_KEY") or None
    if not orchestrator.redpill_base or orchestrator.redpill_base == "https://api.redpill.ai/v1":
        orchestrator.redpill_base = os.environ.get("REDPILL_BASE_URL", "https://api.redpill.ai/v1")
    if orchestrator.redpill_key:
        logger.info("Tally architect ready (Red Pill at %s)", orchestrator.redpill_base)
    else:
        logger.warning("REDPILL_API_KEY not set; architect will fall back to Solo Coder")
    state["orchestrator"] = orchestrator

    # Sprint 32: optional Clerk JWT validator. When CLERK_PUBLISHABLE_KEY
    # is set, /tasks and /templates accept Clerk-issued JWTs alongside
    # the legacy admin TALLY_API_TOKEN. When unset, only the admin
    # token works (existing scripts + cron continue to function).
    clerk_pk = os.environ.get("CLERK_PUBLISHABLE_KEY", "").strip()
    if clerk_pk:
        try:
            state["clerk_validator"] = ClerkValidator(clerk_pk)
        except Exception as exc:
            logger.error("Clerk init failed: %s; falling back to admin-token-only", exc)
            state["clerk_validator"] = None
    else:
        state["clerk_validator"] = None
        logger.info("Clerk not configured (CLERK_PUBLISHABLE_KEY unset); admin-token-only auth")

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
    sweeper_task = asyncio.create_task(orchestrator.run_recovery_sweeper())
    state["sweeper_task"] = sweeper_task
    backup_task = asyncio.create_task(run_nightly_backup())  # Sprint 24.5
    state["backup_task"] = backup_task
    logger.info(
        "ready; pool=%d, processor + recovery sweeper + nightly backup started",
        len(orchestrator.handles),
    )
    try:
        yield
    finally:
        for team_id in list(orchestrator.pollers.keys()):
            orchestrator.stop_poller(team_id)
        for t in (processor_task, sweeper_task, backup_task):
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
async def submit_task(
    body: TaskSubmit,
    user: ClerkUser = Depends(require_user),
) -> TaskResponse:
    db: Db = state["db"]
    orch: Orchestrator = state["orchestrator"]
    # Sprint 22-23: figure out the team BEFORE creating the task row, so
    # the processor loop can't race the architect. Three sources, in
    # order of priority:
    #   1. Client supplied team_spec in the request — use as-is.
    #   2. Tally architect — synchronous LLM call (Llama-3.3 via Red Pill).
    #   3. Architect's internal fallback (Solo Coder).
    # The architect call adds ~500ms-3s of latency to POST /tasks. Worth
    # it for zero-config multi-agent — users just describe what they
    # want and Tally builds the team.
    team_spec = body.team_spec
    if team_spec is None and orch.redpill_key:
        try:
            palette = db.list_agent_roles()
            # Sprint 29: surface saved templates to the architect. The
            # model can pick one verbatim (template_used field) or build
            # fresh — we touch the template's use_count + last_used_at
            # below if it picked one.
            # Sprint 32: surface only THIS user's saved templates so
            # one tenant's pytest-team doesn't bleed into another's
            # team picks. Admin-source callers (legacy bearer) see the
            # full template pool, matching pre-Sprint-32 behaviour.
            scope = None if user.source == "admin" else user.id
            templates = db.list_templates(user_id=scope)
            team_spec = await asyncio.to_thread(
                architect_team,
                description=body.description,
                palette=palette,
                redpill_key=orch.redpill_key,
                redpill_base=orch.redpill_base,
                templates=templates,
            )
            if isinstance(team_spec, dict) and team_spec.get("template_used"):
                db.touch_template(team_spec["template_used"], user_id=scope)
        except Exception as exc:
            logger.exception("architect call raised; falling back to single-agent: %s", exc)
            team_spec = None
    # Atomic insert with team_spec attached — no race window for the
    # processor to pick the task up as single-agent before team_spec
    # lands.
    task_id = db.create_task(body.description, team_spec=team_spec, user_id=user.id)
    task = db.get_task(task_id)
    return TaskResponse(**task)


@app.get("/tasks/{task_id}", response_model=TaskResponse)
async def get_task(
    task_id: str,
    user: ClerkUser = Depends(require_user),
) -> TaskResponse:
    scope = None if user.source == "admin" else user.id
    task = state["db"].get_task(task_id, user_id=scope)
    if not task:
        raise HTTPException(404, f"task {task_id} not found")
    return TaskResponse(**task)


@app.get("/tasks", response_model=list[TaskResponse])
async def list_tasks(
    limit: int = 100,
    user: ClerkUser = Depends(require_user),
) -> list[TaskResponse]:
    scope = None if user.source == "admin" else user.id
    return [TaskResponse(**t) for t in state["db"].list_tasks(limit=limit, user_id=scope)]


@app.get("/tasks/{task_id}/events")
async def get_task_events(
    task_id: str,
    since_seq: int = -1,
    user: ClerkUser = Depends(require_user),
) -> list[dict]:
    """Return events with seq > since_seq, in order. One-shot read (used by
    clients that don't speak SSE). Live clients should use /stream instead."""
    scope = None if user.source == "admin" else user.id
    task = state["db"].get_task(task_id, user_id=scope)
    if not task:
        raise HTTPException(404, f"task {task_id} not found")
    return state["db"].list_events(task_id, since_seq=since_seq)


@app.get("/tasks/{task_id}/stream")
async def stream_task_events(
    task_id: str,
    request: Request,
    since_seq: int = -1,
    user: ClerkUser = Depends(require_user),
):
    """Server-Sent Events stream. Emits historical events with seq > since_seq
    first (so reconnects don't lose anything), then live events as they arrive
    via the EventBus. sse_starlette handles client-disconnect detection +
    keep-alive comments."""
    db: Db = state["db"]
    bus: EventBus = state["event_bus"]
    scope = None if user.source == "admin" else user.id
    task = db.get_task(task_id, user_id=scope)
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
async def list_task_files(
    task_id: str,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """List files in the worker's per-task workspace. Dispatches a fs:list
    wake to the worker over MLS; returns the decrypted entry list."""
    scope = None if user.source == "admin" else user.id
    task = state["db"].get_task(task_id, user_id=scope)
    if not task:
        raise HTTPException(404, f"task {task_id} not found")
    orch: Orchestrator = state["orchestrator"]
    resp = await orch.list_workspace(task_id)
    if "error" in resp:
        raise HTTPException(404, resp["error"])
    return resp


@app.get("/tasks/{task_id}/files/{path:path}")
async def read_task_file(
    task_id: str,
    path: str,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Read one file from the worker's per-task workspace. Path is forwarded
    to the worker which validates against path traversal."""
    scope = None if user.source == "admin" else user.id
    task = state["db"].get_task(task_id, user_id=scope)
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


class PoolGcBody(BaseModel):
    dry_run: bool = True
    older_than_hours: float = 1.0


@app.get("/admin/status", dependencies=[Depends(require_token)])
async def admin_status(task_limit: int = 10) -> dict:
    """One-shot operator snapshot: pool, recent tasks, sweeper state,
    orchestrator uptime. Powers Sprint 21's `tally status` CLI."""
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
            "busy": (handle.lock.locked() or handle.in_flight_task is not None) if handle else None,
            "in_flight_task": handle.in_flight_task if handle else None,
            "failures": handle.failures if handle else None,
        })
    tasks = db.list_tasks(limit=task_limit)
    return {
        "orchestrator": {
            "uptime_seconds": now - orch._started_at,
            "pool_size": len(orch.handles),
            "sweep_last_at": orch._sweep_last_at,
            "sweep_last_demoted": orch._sweep_last_demoted,
            "sweep_total_demoted": orch._sweep_total_demoted,
            "recovery_timeout_seconds": float(os.environ.get("TALLY_RECOVERY_TIMEOUT", "300")),
            "auto_rotate_threshold": orch._auto_rotate_threshold,
        },
        "workers": workers,
        "tasks": tasks,
    }


@app.get("/tasks/{task_id}/team", dependencies=[Depends(require_token)])
async def get_task_team(task_id: str) -> dict:
    """Sprint 22: return the team_spec + per-agent runtime state for a
    multi-agent task. Powers the Discord-shaped task view's members
    sidebar (Sprint 25). Returns {team_spec: null, agents: []} for
    single-agent tasks."""
    db: Db = state["db"]
    task = db.get_task(task_id)
    if not task:
        raise HTTPException(404, f"task {task_id} not found")
    return {
        "task_id": task_id,
        "team_spec": db.get_task_team_spec(task_id),
        "agents": db.list_agents(task_id),
    }


# ── Sprint 29: team templates ──────────────────────────────────────────────


class TemplateCreate(BaseModel):
    name: str
    # Sprint 29 path: promote an existing task's team_spec.
    source_task_id: str | None = None
    # Sprint 30 path: save a hand-built team_spec straight from the
    # visual builder — no preceding task required.
    team_spec: dict | None = None
    note: str | None = None


@app.post("/templates")
async def create_template(
    body: TemplateCreate,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Promote a team to a named template. Two source paths:
      - Sprint 29: pass `source_task_id`; copy that task's team_spec.
      - Sprint 30: pass `team_spec` directly from the visual builder.

    Exactly one must be supplied; both is 400.
    """
    db: Db = state["db"]
    scope = None if user.source == "admin" else user.id
    if (body.source_task_id is None) == (body.team_spec is None):
        raise HTTPException(400, "pass exactly one of source_task_id or team_spec")
    if body.source_task_id is not None:
        task = db.get_task(body.source_task_id, user_id=scope)
        if task is None:
            raise HTTPException(404, f"task {body.source_task_id} not found")
        team_spec = task.get("team_spec")
        if not team_spec:
            raise HTTPException(400, "task has no team_spec to save")
    else:
        team_spec = body.team_spec
        # Light shape check — agents must be a non-empty list of dicts
        # with `role` set. The architect's validator does deeper
        # checks, but at this point we just need a sane on-disk shape.
        if not isinstance(team_spec, dict):
            raise HTTPException(400, "team_spec must be an object")
        agents = team_spec.get("agents")
        if not isinstance(agents, list) or not agents:
            raise HTTPException(400, "team_spec.agents must be a non-empty list")
        for a in agents:
            if not isinstance(a, dict) or not isinstance(a.get("role"), str):
                raise HTTPException(400, "each agent needs a `role` string")
    if not body.name or not body.name.strip():
        raise HTTPException(400, "name is required")
    # Light input sanitization: 64-char cap, no surrounding whitespace,
    # no `/` (URL-segment hygiene), no controls.
    clean_name = body.name.strip()
    if len(clean_name) > 64 or "/" in clean_name or any(ord(c) < 32 for c in clean_name):
        raise HTTPException(400, "name must be ≤64 chars and contain no `/` or control chars")
    try:
        db.create_template(
            name=clean_name,
            team_spec=team_spec,
            source_task_id=body.source_task_id,
            note=(body.note or None),
            user_id=user.id,
        )
    except sqlite3.IntegrityError:
        raise HTTPException(409, f"template `{clean_name}` already exists")
    source_label = (body.source_task_id or "builder")[:8]
    logger.info("template saved: name=%r source=%s agents=%d owner=%s",
                clean_name, source_label,
                len((team_spec.get("agents") or [])), user.id)
    return {"name": clean_name, "team_spec": team_spec}


@app.get("/templates")
async def list_templates(user: ClerkUser = Depends(require_user)) -> dict:
    """List saved templates with usage stats. Sorted by use_count desc.
    Clerk users see only their own templates; admin sees all."""
    scope = None if user.source == "admin" else user.id
    return {"templates": state["db"].list_templates(user_id=scope)}


@app.get("/templates/{name}")
async def get_template(name: str, user: ClerkUser = Depends(require_user)) -> dict:
    scope = None if user.source == "admin" else user.id
    t = state["db"].get_template(name, user_id=scope)
    if t is None:
        raise HTTPException(404, f"template `{name}` not found")
    return t


@app.delete("/templates/{name}")
async def delete_template(name: str, user: ClerkUser = Depends(require_user)) -> dict:
    scope = None if user.source == "admin" else user.id
    if not state["db"].delete_template(name, user_id=scope):
        raise HTTPException(404, f"template `{name}` not found")
    return {"deleted": name}


@app.get("/admin/agent_roles", dependencies=[Depends(require_token)])
async def list_agent_roles() -> dict:
    """The agent palette. Static today (seeded once at orchestrator boot);
    the Discord-shaped Flutter UI uses this to show role glyphs / names
    in the members sidebar without hardcoding the list."""
    return {"roles": state["db"].list_agent_roles()}


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
            "busy": (handle.lock.locked() or handle.in_flight_task is not None) if handle else None,
            "in_flight_task": handle.in_flight_task if handle else None,
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


@app.post("/admin/pool/gc", dependencies=[Depends(require_token)])
async def pool_gc(body: PoolGcBody) -> dict:
    """Garbage-collect stale GHCR package versions from the Sprint 16
    per-deploy-build flow.

    Each pool.provision pushes a `v10-tally-auto-<team_id>` tag (one new
    GHCR package version per CVM). Retired workers' tags never get
    cleaned up automatically, and overwritten tags leave orphaned
    untagged versions behind. After ~weeks of churn that's hundreds of
    stale versions per project.

    Body fields:
      dry_run: bool (default True) — report what would be removed but
        don't actually call DELETE.
      older_than_hours: float (default 1.0) — only remove versions whose
        `updated_at` is older than this many hours. Guards against
        deleting a tag whose worker just got retired mid-rotation.
    """
    pool: WorkerPool = state["worker_pool"]
    db: Db = state["db"]
    keep_team_ids = {w["team_id"] for w in db.list_active_workers()}
    logger.info(
        "admin gc: dry_run=%s older_than=%.1fh keep_active=%d",
        body.dry_run, body.older_than_hours, len(keep_team_ids),
    )
    result = await asyncio.to_thread(
        pool.gc_image_versions,
        keep_team_ids=keep_team_ids,
        older_than_seconds=int(body.older_than_hours * 3600),
        dry_run=body.dry_run,
    )
    return result


# ── Sprint 24.5 (open items): SQLite backup endpoints ─────────────────────────


_BACKUP_DIR_ENV = "ORCH_BACKUP_DIR"
_BACKUP_DIR_DEFAULT = "/data/backups"


def _backup_dir() -> Path:
    return Path(os.environ.get(_BACKUP_DIR_ENV, _BACKUP_DIR_DEFAULT))


def _take_sqlite_backup() -> Path:
    """Use the SQLite Online Backup API (via Python's `backup()` method)
    rather than copying the file, so the snapshot is consistent even
    while the orchestrator is writing. Caller is responsible for
    cleanup if the backup completes successfully."""
    db: Db = state["db"]
    out_dir = _backup_dir()
    out_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    out_path = out_dir / f"tasks-{stamp}.db"
    src = db._conn
    import sqlite3 as _sqlite3
    dst = _sqlite3.connect(str(out_path))
    try:
        src.backup(dst)
    finally:
        dst.close()
    # Prune older than 7 backups — keep operational footprint small.
    keep = 7
    files = sorted(out_dir.glob("tasks-*.db"))
    for old in files[:-keep]:
        try:
            old.unlink()
        except OSError:
            pass
    return out_path


@app.post("/admin/backup", dependencies=[Depends(require_token)])
async def admin_backup_create() -> dict:
    """Trigger a SQLite .backup snapshot into ORCH_BACKUP_DIR (default
    /data/backups). Returns the path + size so an operator can download
    it via /admin/backup/<filename>."""
    path = await asyncio.to_thread(_take_sqlite_backup)
    return {"path": str(path), "size": path.stat().st_size, "filename": path.name}


@app.get("/admin/backup", dependencies=[Depends(require_token)])
async def admin_backup_list() -> dict:
    out_dir = _backup_dir()
    if not out_dir.exists():
        return {"backups": []}
    entries = []
    for p in sorted(out_dir.glob("tasks-*.db")):
        s = p.stat()
        entries.append({"filename": p.name, "size": s.st_size, "mtime": s.st_mtime})
    return {"backups": entries}


@app.get("/admin/backup/{filename}", dependencies=[Depends(require_token)])
async def admin_backup_download(filename: str):
    # Path-traversal guard — filename must be exactly tasks-<stamp>.db.
    if "/" in filename or ".." in filename or not filename.startswith("tasks-"):
        from fastapi import HTTPException
        raise HTTPException(status_code=400, detail="invalid filename")
    p = _backup_dir() / filename
    if not p.exists():
        from fastapi import HTTPException
        raise HTTPException(status_code=404, detail="no such backup")
    from fastapi.responses import FileResponse
    return FileResponse(str(p), media_type="application/octet-stream", filename=filename)


async def run_nightly_backup() -> None:
    """Background coroutine: take a SQLite snapshot every 24h. Started
    from `lifespan`. Failures are warned + the loop continues."""
    interval = float(os.environ.get("ORCH_BACKUP_INTERVAL_S", str(24 * 3600)))
    # First backup at boot+60s (delay so transient startup churn settles).
    await asyncio.sleep(60)
    while True:
        try:
            path = await asyncio.to_thread(_take_sqlite_backup)
            logger.info("nightly backup: %s (%d bytes)", path, path.stat().st_size)
        except Exception as exc:
            logger.warning("nightly backup failed: %s", exc)
        await asyncio.sleep(interval)


def main() -> None:
    import uvicorn
    # Default to 0.0.0.0 so LAN devices can reach the service. Override with
    # HOST=127.0.0.1 to lock down to local-only.
    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "8080"))
    uvicorn.run(app, host=host, port=port, log_level="info")


if __name__ == "__main__":
    main()
