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
import hashlib
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

from fastapi import Depends, FastAPI, HTTPException, Query, Request, Response, WebSocket, WebSocketDisconnect
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
from .clerk_backend import ClerkBackendClient
from .clerk_billing import ClerkBillingClient
from .cost import compute_cost_micro_usd, format_micro_usd
from .credentials import CredentialsManager, fernet_key_help, redact_token
from .github_push import (
    GithubPushAuthError,
    GithubPushError,
    GithubPushRepoError,
    push_project,
    validate_repo,
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

# Sprint 48: task lifecycle statuses
TASK_STATUS_TERMINAL: frozenset[str] = frozenset({
    "completed", "failed", "aborted",
    "aborted_cost_cap", "period_cap_reached", "cancelled",
})
TASK_STATUS_COUNTS_AGAINST_QUOTA: frozenset[str] = frozenset({
    "pending", "running", "completed", "failed",
    "aborted", "aborted_cost_cap", "period_cap_reached",
})

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

-- Sprint 40: per-user custom agent roles.  Same shape as agent_roles
-- but namespaced by user_id, so two users can both have a role
-- named "DataAnalyst" without colliding.  Lookups go user-roles-
-- first, then fall back to the seeded global agent_roles, so
-- custom roles never accidentally shadow seeded ones unless the
-- user explicitly creates one with a seeded role's name (which
-- the validator rejects).
CREATE TABLE IF NOT EXISTS user_agent_roles (
    user_id        TEXT NOT NULL,
    name           TEXT NOT NULL,
    description    TEXT NOT NULL,
    default_model  TEXT NOT NULL,
    tools_json     TEXT NOT NULL,
    system_prompt  TEXT NOT NULL,
    created_at     REAL NOT NULL,
    updated_at     REAL NOT NULL,
    PRIMARY KEY (user_id, name)
);
CREATE INDEX IF NOT EXISTS idx_user_roles_user
    ON user_agent_roles(user_id, updated_at DESC);

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

-- Sprint 41: multi-task workflows.  A child task can name a parent
-- task whose final artifacts seed the child's first-agent workspace
-- (overrides the project's HEAD seed when both are present).  Tasks
-- can have one parent and zero-or-more children — together this
-- forms a DAG users + architects can navigate as a single "thread
-- of work".  Tasks without a parent_task_id behave exactly as
-- pre-S41 (free-standing or project-rooted).
CREATE TABLE IF NOT EXISTS task_dependencies (
    parent_task_id TEXT NOT NULL,
    child_task_id  TEXT NOT NULL,
    created_at     REAL NOT NULL,
    PRIMARY KEY (parent_task_id, child_task_id),
    FOREIGN KEY (parent_task_id) REFERENCES tasks(id),
    FOREIGN KEY (child_task_id)  REFERENCES tasks(id)
);
CREATE INDEX IF NOT EXISTS idx_task_deps_parent
    ON task_dependencies(parent_task_id);
CREATE INDEX IF NOT EXISTS idx_task_deps_child
    ON task_dependencies(child_task_id);

-- Sprint 37: persistent project workspaces.  A user can group tasks
-- under a project; the project's HEAD artifact set seeds the first
-- agent of every task in the project, and successful task artifacts
-- merge back into the project HEAD (last-writer-wins per path).
-- This is what enables iterating on a real codebase across multiple
-- Tally runs instead of starting from /workspaces/task-XXX every time.
CREATE TABLE IF NOT EXISTS projects (
    id          TEXT PRIMARY KEY,
    user_id     TEXT NOT NULL,
    name        TEXT NOT NULL,
    description TEXT,
    created_at  REAL NOT NULL,
    updated_at  REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_projects_user ON projects(user_id, updated_at DESC);

-- Project HEAD artifact set.  Parallel structure to task_artifacts
-- minus the per-agent column (project HEAD has no notion of which
-- task produced which file — the project history lives in the tasks
-- table, not here).
CREATE TABLE IF NOT EXISTS project_artifacts (
    project_id  TEXT NOT NULL,
    path        TEXT NOT NULL,
    b64_content TEXT NOT NULL,
    ts          REAL NOT NULL,
    PRIMARY KEY (project_id, path),
    FOREIGN KEY (project_id) REFERENCES projects(id)
);
CREATE INDEX IF NOT EXISTS idx_project_artifacts ON project_artifacts(project_id);

-- Sprint 38: encrypted per-user credentials store.  One row per
-- (user_id, kind) pair; the ciphertext is a Fernet token (binary,
-- stored as BLOB).  The orchestrator's CREDENTIALS_KEY decrypts.
-- Today only kind='github_pat' is used (Sprint 38); future kinds
-- (e.g. 'aws_role_arn', 'openai_api_key' for BYOK) drop in without
-- a schema change.
CREATE TABLE IF NOT EXISTS user_credentials (
    user_id        TEXT NOT NULL,
    kind           TEXT NOT NULL,
    ciphertext     BLOB NOT NULL,
    created_at     REAL NOT NULL,
    updated_at     REAL NOT NULL,
    PRIMARY KEY (user_id, kind)
);

-- Sprint 39: LLM cost events.  One row per upstream LLM call (the
-- architect, eventually the worker agents).  Cost is computed at
-- insert time using the static price table in `cost.py` so reads
-- don't have to repeat the math.  Stored as micro-USD (int) to
-- avoid float drift over time: 1 USD = 1_000_000 micro_usd.
CREATE TABLE IF NOT EXISTS cost_events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id         TEXT NOT NULL,
    task_id         TEXT,                  -- nullable for non-task LLM calls (future)
    agent_idx       INTEGER,               -- nullable for architect calls
    kind            TEXT NOT NULL,         -- 'architect' | 'agent' | 'other'
    model           TEXT NOT NULL,
    prompt_tokens   INTEGER NOT NULL DEFAULT 0,
    completion_tokens INTEGER NOT NULL DEFAULT 0,
    total_tokens    INTEGER NOT NULL DEFAULT 0,
    cost_micro_usd  INTEGER NOT NULL DEFAULT 0,
    ts              REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_cost_events_user_ts ON cost_events(user_id, ts DESC);
CREATE INDEX IF NOT EXISTS idx_cost_events_task ON cost_events(task_id);

-- Sprint 33: per-user quotas. One row per Clerk user (plus
-- 'admin'/'legacy-admin' for those paths). Plans are name-only;
-- the caps come from the QUOTA_PLANS dict in service.py — keeps the
-- table simple and lets us tune caps without a migration.
CREATE TABLE IF NOT EXISTS quotas (
    user_id                       TEXT PRIMARY KEY,
    plan                          TEXT NOT NULL DEFAULT 'free',
    stripe_customer_id            TEXT,           -- nullable until first checkout
    stripe_subscription_id        TEXT,           -- nullable for free tier
    period_start                  REAL NOT NULL,  -- unix ts of current billing period
    period_tasks_used             INTEGER NOT NULL DEFAULT 0,
    period_agent_seconds_used     INTEGER NOT NULL DEFAULT 0,
    updated_at                    REAL NOT NULL
);

-- Sprint 46: overage purchases — one row per successful credit top-up.
CREATE TABLE IF NOT EXISTS overage_purchases (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    ts REAL NOT NULL,
    credits_purchased INTEGER NOT NULL,
    cost_charged_micro_usd INTEGER NOT NULL,
    kind TEXT NOT NULL,
    stripe_payment_intent_id TEXT,
    status TEXT NOT NULL DEFAULT 'pending',
    failure_reason TEXT
);
CREATE INDEX IF NOT EXISTS idx_overage_user_ts ON overage_purchases(user_id, ts DESC);

-- Sprint 46: per-user notification rules (spend alerts, etc.).
CREATE TABLE IF NOT EXISTS notification_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    threshold INTEGER NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    last_fired_at REAL,
    created_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_notif_rules_user ON notification_rules(user_id, enabled);

-- Sprint 46: notification log.
CREATE TABLE IF NOT EXISTS notifications (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    rule_id INTEGER,
    kind TEXT NOT NULL,
    severity TEXT NOT NULL DEFAULT 'info',
    payload_json TEXT NOT NULL,
    created_at REAL NOT NULL,
    dismissed_at REAL
);
CREATE INDEX IF NOT EXISTS idx_notifications_user ON notifications(user_id, dismissed_at, created_at DESC);

-- Sprint 46: registered push devices for server-sent alerts.
CREATE TABLE IF NOT EXISTS push_devices (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    provider TEXT NOT NULL,
    endpoint_url TEXT,
    label TEXT,
    platform TEXT,
    enabled INTEGER NOT NULL DEFAULT 1,
    last_seen_at REAL,
    created_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_push_devices_user ON push_devices(user_id, enabled);

-- Sprint 47: chat-foundation tables (workspaces, members, channels, messages).
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

-- Sprint 49: persistent agents — long-lived agent identities that live
-- inside a workspace and can be triggered by cron schedule or events.
-- Mirrors the workspace_members.persistent_agent_id FK; this is the
-- authoritative record.  deleted_at uses soft-delete so history and
-- channel membership rows can still resolve the agent name after
-- removal.
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

-- Sprint 51: workspace-scoped audit log.  Records every privileged
-- action taken inside a workspace (member invite/kick, channel create/
-- archive, agent enable/disable, settings change, etc.) so workspace
-- owners and compliance exports have a tamper-evident history.
-- actor_kind: 'user' | 'persistent_agent' | 'system'
-- kind: free-text action verb (e.g. 'member.invite', 'channel.archive')
-- target_kind / target_id: the entity acted upon (optional)
-- payload_json: action-specific structured detail
CREATE TABLE IF NOT EXISTS workspace_audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    workspace_id INTEGER NOT NULL REFERENCES workspaces(id),
    actor_user_id TEXT NOT NULL,
    actor_kind TEXT NOT NULL,
    kind TEXT NOT NULL,
    target_kind TEXT,
    target_id TEXT,
    payload_json TEXT NOT NULL DEFAULT '{}',
    created_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_log_workspace ON workspace_audit_log(workspace_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_actor ON workspace_audit_log(actor_user_id);
"""

# Sprint 46: credit-based plan config.  Replaces Sprint 33's
# tasks-per-period model — credits are units of $0.01 of Red Pill
# COGS.  Beta tiers are sold at 1.5× COGS markup (25% discount vs
# stable's 2× markup) and stay locked for the life of a subscription.
# `model_allowlist=None` means "any Red Pill model"; the Free tier
# restricts to llama-3.3 only because its credits are too few to
# safely allow premium reasoning models.
QUOTA_PLANS: dict[str, dict] = {
    "free": {
        "label": "Free",
        "price_micro_usd_monthly": 0,
        "included_credits": 50,
        "default_per_task_cap_credits": 25,
        "max_per_task_cap_credits": 50,
        "model_allowlist": {"meta-llama/llama-3.3-70b-instruct"},
        "overage_eligible": False,
        "is_beta": False,
        # TODO(s46-a7): remove after credit gate replaces task-count gate
        "tasks": 10**9,
        "agent_seconds": 10**9,
    },
    "pro_beta": {
        "label": "Pro (Beta)",
        "price_micro_usd_monthly": 15_000_000,
        "included_credits": 1000,
        "default_per_task_cap_credits": 100,
        "max_per_task_cap_credits": None,
        "model_allowlist": None,
        "overage_eligible": True,
        "is_beta": True,
        # TODO(s46-a7): remove after credit gate replaces task-count gate
        "tasks": 10**9,
        "agent_seconds": 10**9,
    },
    "max_beta": {
        "label": "Max (Beta)",
        "price_micro_usd_monthly": 75_000_000,
        "included_credits": 5000,
        "default_per_task_cap_credits": 500,
        "max_per_task_cap_credits": None,
        "model_allowlist": None,
        "overage_eligible": True,
        "is_beta": True,
        # TODO(s46-a7): remove after credit gate replaces task-count gate
        "tasks": 10**9,
        "agent_seconds": 10**9,
    },
    "ultra_beta": {
        "label": "Ultra (Beta)",
        "price_micro_usd_monthly": 150_000_000,
        "included_credits": 10_000,
        "default_per_task_cap_credits": 1000,
        "max_per_task_cap_credits": None,
        "model_allowlist": None,
        "overage_eligible": True,
        "is_beta": True,
        # TODO(s46-a7): remove after credit gate replaces task-count gate
        "tasks": 10**9,
        "agent_seconds": 10**9,
    },
    "unlimited": {
        "label": "Unlimited (admin)",
        "price_micro_usd_monthly": 0,
        "included_credits": 10**8,
        "default_per_task_cap_credits": 10**8,
        "max_per_task_cap_credits": None,
        "model_allowlist": None,
        "overage_eligible": False,
        "is_beta": False,
        # TODO(s46-a7): remove after credit gate replaces task-count gate
        "tasks": 10**9,
        "agent_seconds": 10**9,
    },
}


def b64url_no_pad(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def b64url_decode(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def _verify_stripe_signature(payload: bytes, sig_header: str) -> dict:
    """Verify a Stripe webhook signature; return the parsed event.

    Raises HTTPException(503) when STRIPE_WEBHOOK_SECRET is not set.
    Raises HTTPException(400) on any signature failure.
    Must be a module-level function so tests can monkeypatch it via
    ``tally_orchestrator.service._verify_stripe_signature``.
    """
    secret = os.environ.get("STRIPE_WEBHOOK_SECRET", "").strip()
    if not secret:
        raise HTTPException(503, "STRIPE_WEBHOOK_SECRET not configured")
    try:
        import stripe
        event = stripe.Webhook.construct_event(payload, sig_header, secret)
    except Exception as exc:
        raise HTTPException(400, f"invalid stripe signature: {exc}")
    # Sprint 46.5: stripe-python 15.x returns a `StripeObject` whose
    # custom `__getattr__` shadows the `.get()` dict method.  `to_dict()`
    # recursively converts the whole tree to plain nested dicts so the
    # rest of the handler can use familiar `.get(key, default)` access.
    return event.to_dict()


class TaskSubmit(BaseModel):
    description: str
    # Sprint 22: optional pre-architected team. When omitted, the legacy
    # single-agent path runs. When present, must match the architect
    # output shape: {agents: [{role, model?, spec?}...], workflow: str?,
    # reasoning: str?}. Sprint 23 wires Tally to produce this when the
    # client doesn't supply one.
    team_spec: dict | None = None
    # Sprint 37: optional persistent-project grouping. When set, the
    # first agent's workspace seeds from the project's HEAD artifact
    # set, and final task artifacts merge back into HEAD on success.
    project_id: str | None = None
    # Sprint 41: optional parent task — the new child task's first
    # agent inherits the parent's final artifact set as seed_files
    # (takes priority over project HEAD).  Lets users branch from a
    # completed task without needing the project to be the same.
    parent_task_id: str | None = None


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
    # Sprint 37: persistent project the task belongs to (nullable).
    project_id: str | None = None
    # Sprint 41: parent task (set via the parent_task_id input).  Surfaced
    # so the Flutter shell can render a "branched from <task>" pill.
    parent_task_id: str | None = None
    # Sprint 41: direct children's task ids in created-at order.
    child_task_ids: list[str] = []


# ── Sprint 46 A12: billing request models ─────────────────────────────────────


class CreditsCheckoutRequest(BaseModel):
    credits: int
    success_url: str = "tallycoding://billing/success"
    cancel_url: str = "tallycoding://billing/cancel"


class AutoRechargeSetupRequest(BaseModel):
    success_url: str = "tallycoding://billing/auto-recharge/success"
    cancel_url: str = "tallycoding://billing/auto-recharge/cancel"


class AutoRechargePatchRequest(BaseModel):
    mode: int | None = None  # 0, 1, 2, 3
    block_credits: int | None = None
    monthly_cap_micro_usd: int | None = None


class CapsPatchRequest(BaseModel):
    per_task_cap_credits: int | None = None
    daily_spend_cap_credits: int | None = None
    weekly_spend_cap_credits: int | None = None


# ── Sprint 46 A15: notification + push device request models ──────────────────

class NotificationRuleRequest(BaseModel):
    kind: str  # 'period_pct' | 'daily_amount' | 'weekly_amount' | 'per_task_amount' | 'auto_recharge_monthly_pct'
    threshold: int
    enabled: bool = True


class NotificationRulePatchRequest(BaseModel):
    threshold: int | None = None
    enabled: bool | None = None


class PushDeviceRequest(BaseModel):
    provider: str  # 'unifiedpush' | 'desktop_local'
    endpoint_url: str | None = None
    label: str | None = None
    platform: str | None = None


# Sprint 47: channel + message request models.

class ChannelMemberRoleOverrideRequest(BaseModel):
    role_override: str | None = None  # None to clear, or one of: channel_admin, read_only


class ChannelReadRequest(BaseModel):
    last_read_message_id: int


class MessageCreateRequest(BaseModel):
    text: str | None = None
    kind: str = "text"  # text | interactive_prompt_response
    payload: dict | None = None
    reply_to_id: int | None = None


class MessagePatchRequest(BaseModel):
    text: str | None = None
    payload: dict | None = None


class TaskTeamSpecPatchRequest(BaseModel):
    team_spec: dict


# Sprint 49: persistent_agents request model.

class PersistentAgentCreateRequest(BaseModel):
    workspace_id: int
    name: str
    role_name: str
    team_spec: dict
    tool_allowlist: dict | None = None
    model: str | None = None
    cron_schedule: str | None = None
    event_triggers: list[dict] | None = None


class PersistentAgentPatchRequest(BaseModel):
    name: str | None = None
    team_spec: dict | None = None
    tool_allowlist: dict | None = None
    model: str | None = None
    cron_schedule: str | None = None
    event_triggers: list[dict] | None = None
    enabled: bool | None = None


class DmCreateRequest(BaseModel):
    target_kind: str
    target_id: str | None = None


class WorkspaceCreateRequest(BaseModel):
    name: str


_VALID_WORKSPACE_ROLES = {"owner", "admin", "manager", "member"}


class WorkspaceMemberInviteRequest(BaseModel):
    user_id: str
    role: str


class WorkspaceMemberRolePatchRequest(BaseModel):
    role: str


# Sprint 50: custom channel creation + channel_member CRUD models.

class ChannelMemberSpec(BaseModel):
    kind: str  # 'human' | 'tally' | 'persistent_agent'
    id: str | None = None  # user_id or persistent_agent_id; null for tally


class CustomChannelCreateRequest(BaseModel):
    workspace_id: int
    kind: str  # must be 'custom' in Sprint 50
    name: str
    members: list[ChannelMemberSpec]


class ChannelMemberAddRequest(BaseModel):
    member_kind: str
    user_id: str | None = None
    persistent_agent_id: int | None = None


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
        # Sprint 34: share-with-link.  Opaque token granting read-only
        # access to the team_spec without an account.  Nullable until
        # the owner explicitly generates one; unique when set so a
        # leaked token can be rotated.
        try:
            self._conn.execute("ALTER TABLE team_templates ADD COLUMN share_token TEXT")
        except sqlite3.OperationalError:
            pass
        # Sprint 37: persistent projects.  Tasks can belong to a project;
        # the project's HEAD artifact set seeds the first agent of every
        # task in the project.  Nullable so legacy / one-off tasks
        # continue to work unchanged.
        try:
            self._conn.execute("ALTER TABLE tasks ADD COLUMN project_id TEXT")
        except sqlite3.OperationalError:
            pass
        self._conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_tasks_project ON tasks(project_id, created_at DESC)"
        )
        self._conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_tasks_user ON tasks(user_id, created_at DESC)"
        )
        self._conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_templates_user ON team_templates(user_id, use_count DESC)"
        )
        self._conn.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_templates_share_token "
            "ON team_templates(share_token) WHERE share_token IS NOT NULL"
        )
        # Sprint 46: credit-based pricing extends `quotas` with cap +
        # overage + alert columns.  All additive; existing rows get
        # NULL/default and behave as "no cap, overage off".
        _s46_quota_cols = [
            ("per_task_cap_credits", "INTEGER"),
            ("daily_spend_cap_credits", "INTEGER"),
            ("weekly_spend_cap_credits", "INTEGER"),
            ("overage_enabled", "INTEGER NOT NULL DEFAULT 0"),
            ("auto_recharge_mode", "INTEGER NOT NULL DEFAULT 0"),
            ("auto_recharge_block_credits", "INTEGER NOT NULL DEFAULT 500"),
            ("auto_recharge_monthly_cap_micro_usd", "INTEGER"),
            ("auto_recharge_spent_this_month_micro_usd", "INTEGER NOT NULL DEFAULT 0"),
            ("stripe_payment_method_id", "TEXT"),
            ("prepaid_credit_balance", "INTEGER NOT NULL DEFAULT 0"),
            ("spend_alert_threshold_pct", "INTEGER NOT NULL DEFAULT 80"),
            ("alert_80_sent_at", "REAL"),
            ("alert_100_sent_at", "REAL"),
        ]
        for col, ddl in _s46_quota_cols:
            try:
                self._conn.execute(f"ALTER TABLE quotas ADD COLUMN {col} {ddl}")
            except sqlite3.OperationalError:
                pass
        # Sprint 47: track which user messages each agent has already seen
        # so the dispatch path can inject only the new ones.
        try:
            self._conn.execute(
                "ALTER TABLE agents ADD COLUMN last_user_msg_ts REAL NOT NULL DEFAULT 0"
            )
        except sqlite3.OperationalError:
            pass  # column already exists
        # Sprint 48: track which iteration of a back-edge cycle each agent is on.
        try:
            self._conn.execute(
                "ALTER TABLE agents ADD COLUMN iteration_idx INTEGER NOT NULL DEFAULT 0"
            )
        except sqlite3.OperationalError:
            pass  # column already exists
        # Sprint 49: link tasks to the persistent agent that triggered them.
        # Nullable FK — ad-hoc tasks (no persistent agent) leave this NULL.
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
        # Sprint 50: soft-delete support for workspaces.
        try:
            self._conn.execute("ALTER TABLE workspaces ADD COLUMN deleted_at REAL")
        except sqlite3.OperationalError:
            pass  # column already exists
        # Sprint 47: backfill workspaces + channels for pre-existing data.
        # Idempotent — only creates rows when they're missing.
        self._backfill_workspaces_and_channels()
        self._seed_agent_roles()

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
            "WHERE c.id IS NULL AND t.status NOT IN ('proposed', 'cancelled')"
        ).fetchall()
        for task_id, user_id, status, created_at, updated_at in task_rows:
            user_id = user_id or "admin"
            ws_row = self._conn.execute(
                "SELECT id FROM workspaces WHERE owner_user_id=?", (user_id,)
            ).fetchone()
            if ws_row is None:
                continue  # shouldn't happen given step 2 ran first
            archived_at = updated_at if status in ("completed", "failed") else None
            ch_cur = self._conn.execute(
                "INSERT INTO channels (workspace_id, kind, name, task_id, created_at, archived_at) "
                "VALUES (?, 'task', ?, ?, ?, ?)",
                (ws_row[0], f"task-{task_id[:8]}", task_id, created_at, archived_at),
            )
            self._conn.execute(
                "INSERT INTO channel_members (channel_id, member_kind, user_id, joined_at) "
                "VALUES (?, 'human', ?, ?)",
                (ch_cur.lastrowid, user_id, created_at),
            )
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
        # Sprint 49: add Tally as channel_member of every existing #general / #backlog channel.
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

    def create_workspace(self, *, name: str, owner_user_id: str, plan_slug: str = "free") -> int:
        """Sprint 50: create a workspace + owner + Tally workspace_members
        + #general / #backlog channels + Tally as channel_member of each.
        Mirrors what the Sprint 47 backfill does for a single user."""
        now = time.time()
        cur = self._conn.execute(
            "INSERT INTO workspaces (name, owner_user_id, plan_slug, created_at) "
            "VALUES (?, ?, ?, ?)",
            (name, owner_user_id, plan_slug, now),
        )
        ws_id = int(cur.lastrowid or 0)
        # Owner workspace_member
        self._conn.execute(
            "INSERT INTO workspace_members (workspace_id, member_kind, user_id, role, joined_at) "
            "VALUES (?, 'human', ?, 'owner', ?)",
            (ws_id, owner_user_id, now),
        )
        # Tally workspace_member
        self._conn.execute(
            "INSERT INTO workspace_members (workspace_id, member_kind, user_id, role, joined_at) "
            "VALUES (?, 'tally', NULL, 'tally', ?)",
            (ws_id, now),
        )
        # general + backlog channels with owner + Tally as members
        for kind in ("general", "backlog"):
            ch_cur = self._conn.execute(
                "INSERT INTO channels (workspace_id, kind, name, created_at) "
                "VALUES (?, ?, ?, ?)",
                (ws_id, kind, kind, now),
            )
            ch_id = int(ch_cur.lastrowid or 0)
            self._conn.execute(
                "INSERT INTO channel_members (channel_id, member_kind, user_id, joined_at) "
                "VALUES (?, 'human', ?, ?)",
                (ch_id, owner_user_id, now),
            )
            self._conn.execute(
                "INSERT INTO channel_members (channel_id, member_kind, user_id, joined_at) "
                "VALUES (?, 'tally', NULL, ?)",
                (ch_id, now),
            )
        return ws_id

    def list_workspace_members(self, *, workspace_id: int) -> list[dict]:
        """Sprint 50: list all members of a workspace."""
        rows = self._conn.execute(
            "SELECT id, member_kind, user_id, persistent_agent_id, role, joined_at "
            "FROM workspace_members WHERE workspace_id=? ORDER BY joined_at ASC",
            (workspace_id,),
        ).fetchall()
        return [
            {
                "id": r[0],
                "member_kind": r[1],
                "user_id": r[2],
                "persistent_agent_id": r[3],
                "role": r[4],
                "joined_at": r[5],
            }
            for r in rows
        ]

    def audit_log(
        self,
        *,
        workspace_id: int,
        actor_user_id: str | None,
        actor_kind: str = "human",
        kind: str,
        target_kind: str | None = None,
        target_id: str | None = None,
        payload: dict | None = None,
    ) -> None:
        """Sprint 51: append to workspace_audit_log.  Best-effort —
        callers wrap in try/except so logging failure doesn't break the request."""
        self._conn.execute(
            "INSERT INTO workspace_audit_log "
            "(workspace_id, actor_user_id, actor_kind, kind, target_kind, target_id, payload_json, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (
                workspace_id,
                actor_user_id or "system",
                actor_kind,
                kind,
                target_kind,
                target_id,
                json.dumps(payload or {}),
                time.time(),
            ),
        )

    def list_audit_log(
        self,
        *,
        workspace_id: int,
        limit: int = 100,
        before_id: int | None = None,
    ) -> list[dict]:
        """Sprint 51: list audit log entries newest-first with keyset pagination."""
        limit = min(max(1, limit), 500)
        where = ["workspace_id=?"]
        params: list = [workspace_id]
        if before_id is not None:
            where.append("id < ?")
            params.append(before_id)
        params.append(limit)
        rows = self._conn.execute(
            f"SELECT id, workspace_id, actor_user_id, actor_kind, kind, target_kind, target_id, payload_json, created_at "
            f"FROM workspace_audit_log WHERE {' AND '.join(where)} "
            f"ORDER BY id DESC LIMIT ?",
            params,
        ).fetchall()
        return [
            {
                "id": r[0], "workspace_id": r[1], "actor_user_id": r[2],
                "actor_kind": r[3], "kind": r[4],
                "target_kind": r[5], "target_id": r[6],
                "payload": json.loads(r[7]) if r[7] else {},
                "created_at": r[8],
            }
            for r in rows
        ]

    def add_workspace_member(
        self, *, workspace_id: int, user_id: str, role: str
    ) -> None:
        """Sprint 50: add a human user as a workspace_member.
        Idempotent: silent if (workspace_id, user_id) already exists."""
        existing = self._conn.execute(
            "SELECT 1 FROM workspace_members "
            "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
            (workspace_id, user_id),
        ).fetchone()
        if existing:
            return
        self._conn.execute(
            "INSERT INTO workspace_members "
            "(workspace_id, member_kind, user_id, role, joined_at) "
            "VALUES (?, 'human', ?, ?, ?)",
            (workspace_id, user_id, role, time.time()),
        )

    def update_workspace_member_role(
        self, *, workspace_id: int, user_id: str, role: str
    ) -> bool:
        """Sprint 50: change a human member's role.  Returns True if a
        row was updated."""
        cur = self._conn.execute(
            "UPDATE workspace_members SET role=? "
            "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
            (role, workspace_id, user_id),
        )
        return cur.rowcount > 0

    def remove_workspace_member(self, *, workspace_id: int, user_id: str) -> bool:
        """Sprint 50: remove a human member.  Returns True if a row was deleted."""
        cur = self._conn.execute(
            "DELETE FROM workspace_members "
            "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
            (workspace_id, user_id),
        )
        return cur.rowcount > 0

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

    _TASK_COLS = "id, description, status, result_json, error, created_at, updated_at, worker_identity, team_spec, user_id, project_id"

    def create_task(
        self,
        description: str,
        team_spec: dict | None = None,
        *,
        user_id: str = "legacy-admin",
        project_id: str | None = None,
        status: str = "proposed",
    ) -> str:
        """Sprint 23: team_spec can be set atomically with task creation so
        the processor loop never sees a `pending` row without its
        team_spec already attached. Without this guard, the architect's
        ~3-5s LLM call lets the processor pick up the task as single-agent
        before the spec lands (race observed in Sprint 23 validation).

        Sprint 37: ``project_id`` (optional) groups tasks under a
        persistent workspace.  The orchestrator hydrates the first
        agent's seed_files from the project's HEAD artifact set, and
        merges the task's final artifacts back into HEAD on success.

        Sprint 48: tasks default to status='proposed' (no channel).
        Call approve_task(task_id) to transition to 'pending' and
        create the task channel + owner channel_member.
        """
        task_id = uuid.uuid4().hex
        now = time.time()
        self._conn.execute(
            "INSERT INTO tasks (id, description, status, team_spec, created_at, updated_at, user_id, project_id) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (task_id, description, status, json.dumps(team_spec) if team_spec else None, now, now, user_id, project_id),
        )
        return task_id

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
        _, user_id, _ = row
        user_id = user_id or "admin"
        self._conn.execute(
            "UPDATE tasks SET status='pending', updated_at=? WHERE id=?",
            (time.time(), task_id),
        )
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
        # Sprint 49 A13: reset persistent agent failure counter on success.
        pa_row = self._conn.execute(
            "SELECT persistent_agent_id FROM tasks WHERE id=?", (task_id,)
        ).fetchone()
        if pa_row and pa_row[0]:
            self.reset_persistent_agent_failures(pa_row[0])

    def mark_failed(self, task_id: str, error: str) -> None:
        self._conn.execute(
            "UPDATE tasks SET status='failed', error=?, updated_at=? WHERE id=?",
            (error, time.time(), task_id),
        )
        # Sprint 49 A13: bump persistent agent failure counter on failure.
        pa_row = self._conn.execute(
            "SELECT persistent_agent_id FROM tasks WHERE id=?", (task_id,)
        ).fetchone()
        if pa_row and pa_row[0]:
            self.bump_persistent_agent_failure(pa_row[0])

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
        updated = (cursor.rowcount or 0) > 0
        # Sprint 49 A13: reset persistent agent failure counter on recovery→completed.
        if updated:
            pa_row = self._conn.execute(
                "SELECT persistent_agent_id FROM tasks WHERE id=?", (task_id,)
            ).fetchone()
            if pa_row and pa_row[0]:
                self.reset_persistent_agent_failures(pa_row[0])
        return updated

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
            "SELECT id, persistent_agent_id FROM tasks WHERE status='recovering' AND updated_at < ?",
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
            # Sprint 49 A13: bump failure counter for each persistent-agent-owned task.
            for task_id, pa_id in rows:
                if pa_id:
                    self.bump_persistent_agent_failure(pa_id)
        return demoted_ids

    # ── Sprint 22: agent palette + per-task agent instances ──────────────

    def list_agent_roles(self, *, user_id: str | None = None) -> list[dict]:
        """Sprint 40: returns seeded global roles + caller's custom
        roles when ``user_id`` is supplied.  Custom roles are tagged
        with ``source='custom'`` + ``owner=user_id``; seeded roles
        get ``source='seeded'``.  Used by the architect (which sees
        each user's palette including their custom roles) and by
        the team builder UI."""
        rows = self._conn.execute(
            "SELECT name, description, default_model, tools_json, system_prompt "
            "FROM agent_roles ORDER BY name"
        ).fetchall()
        roles = [
            {
                "name": r[0], "description": r[1], "default_model": r[2],
                "tools": json.loads(r[3]), "system_prompt": r[4],
                "source": "seeded", "owner": None,
            }
            for r in rows
        ]
        if user_id is not None:
            custom_rows = self._conn.execute(
                "SELECT name, description, default_model, tools_json, system_prompt "
                "FROM user_agent_roles WHERE user_id = ? ORDER BY name",
                (user_id,),
            ).fetchall()
            roles.extend([
                {
                    "name": r[0], "description": r[1], "default_model": r[2],
                    "tools": json.loads(r[3]), "system_prompt": r[4],
                    "source": "custom", "owner": user_id,
                }
                for r in custom_rows
            ])
        return roles

    def get_agent_role(self, name: str, *, user_id: str | None = None) -> dict | None:
        """Sprint 40: lookup checks the caller's custom roles first,
        then falls back to seeded.  Letting custom override seeded for
        the same name was considered but rejected — the create
        endpoint validates that custom names don't collide with
        seeded ones, so the fallback path is the only one that hits
        ``agent_roles``."""
        if user_id is not None:
            row = self._conn.execute(
                "SELECT name, description, default_model, tools_json, system_prompt "
                "FROM user_agent_roles WHERE user_id = ? AND name = ?",
                (user_id, name),
            ).fetchone()
            if row:
                return {
                    "name": row[0], "description": row[1], "default_model": row[2],
                    "tools": json.loads(row[3]), "system_prompt": row[4],
                    "source": "custom", "owner": user_id,
                }
        row = self._conn.execute(
            "SELECT name, description, default_model, tools_json, system_prompt "
            "FROM agent_roles WHERE name = ?", (name,),
        ).fetchone()
        if not row:
            return None
        return {
            "name": row[0], "description": row[1], "default_model": row[2],
            "tools": json.loads(row[3]), "system_prompt": row[4],
            "source": "seeded", "owner": None,
        }

    # ── Sprint 40: user-defined custom roles ───────────────────────────────

    def create_custom_role(
        self,
        *,
        user_id: str,
        name: str,
        description: str,
        default_model: str,
        tools: list[str],
        system_prompt: str,
    ) -> None:
        """Insert a user-scoped role.  Caller validates the name
        doesn't collide with a seeded role (via ``get_agent_role`` or
        the seeded-name set) — this method just trusts the input."""
        now = time.time()
        self._conn.execute(
            "INSERT INTO user_agent_roles "
            "(user_id, name, description, default_model, tools_json, "
            " system_prompt, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (user_id, name, description, default_model,
             json.dumps(tools), system_prompt, now, now),
        )

    def update_custom_role(
        self,
        *,
        user_id: str,
        name: str,
        description: str | None = None,
        default_model: str | None = None,
        tools: list[str] | None = None,
        system_prompt: str | None = None,
    ) -> dict | None:
        """Partial PATCH.  Returns the updated row or ``None`` when
        the role doesn't exist for this user."""
        updates: list[str] = []
        params: list = []
        if description is not None:
            updates.append("description = ?")
            params.append(description)
        if default_model is not None:
            updates.append("default_model = ?")
            params.append(default_model)
        if tools is not None:
            updates.append("tools_json = ?")
            params.append(json.dumps(tools))
        if system_prompt is not None:
            updates.append("system_prompt = ?")
            params.append(system_prompt)
        if not updates:
            return self.get_agent_role(name, user_id=user_id)
        updates.append("updated_at = ?")
        params.append(time.time())
        params.extend([user_id, name])
        cur = self._conn.execute(
            f"UPDATE user_agent_roles SET {', '.join(updates)} "
            f"WHERE user_id = ? AND name = ?",
            params,
        )
        if (cur.rowcount or 0) == 0:
            return None
        return self.get_agent_role(name, user_id=user_id)

    def delete_custom_role(self, *, user_id: str, name: str) -> bool:
        cur = self._conn.execute(
            "DELETE FROM user_agent_roles WHERE user_id = ? AND name = ?",
            (user_id, name),
        )
        return (cur.rowcount or 0) > 0

    def list_custom_role_names(self, user_id: str) -> set[str]:
        """Fast set lookup for the name-collision check."""
        return {
            r[0]
            for r in self._conn.execute(
                "SELECT name FROM user_agent_roles WHERE user_id = ?",
                (user_id,),
            ).fetchall()
        }

    def seeded_role_names(self) -> set[str]:
        return {
            r[0] for r in self._conn.execute("SELECT name FROM agent_roles").fetchall()
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
            "result_json, worker_identity, started_at, finished_at, last_user_msg_ts "
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
                "last_user_msg_ts": r[11] if r[11] is not None else 0.0,
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
                      "last_used_at, use_count, user_id, share_token")

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
            # Sprint 34: opaque share token (nullable).  Owners can
            # generate one to share a read-only link with teammates;
            # leaked tokens can be rotated via DELETE /templates/{name}/share.
            "share_token": (r[8] if len(r) > 8 else None),
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

    # ── Sprint 34: update + share-with-link ────────────────────────────────

    def update_template(
        self,
        name: str,
        *,
        user_id: str | None = None,
        new_name: str | None = None,
        team_spec: dict | None = None,
        note: str | None = None,
    ) -> dict | None:
        """Patch a template in place.  Any of ``new_name``, ``team_spec``,
        ``note`` may be omitted to leave that column alone.

        Returns the updated row as a dict on success, ``None`` when the
        template doesn't exist (or doesn't belong to ``user_id`` when
        scoped).  Raises ``sqlite3.IntegrityError`` if ``new_name``
        collides with another template — caller maps to 409.
        """
        updates: list[str] = []
        params: list = []
        if new_name is not None:
            updates.append("name = ?")
            params.append(new_name)
        if team_spec is not None:
            updates.append("team_spec = ?")
            params.append(json.dumps(team_spec))
        if note is not None:
            updates.append("note = ?")
            # Treat empty string as "clear the note" — consistent with
            # the create endpoint's `(body.note or None)` collapse.
            params.append(note or None)
        if not updates:
            # No-op patch returns the row unchanged.
            return self.get_template(name, user_id=user_id)
        # WHERE clause: scope to user_id when given.
        where = "name = ?"
        params.append(name)
        if user_id is not None:
            where += " AND user_id = ?"
            params.append(user_id)
        cur = self._conn.execute(
            f"UPDATE team_templates SET {', '.join(updates)} WHERE {where}",
            params,
        )
        if (cur.rowcount or 0) == 0:
            return None
        final_name = new_name or name
        return self.get_template(final_name, user_id=user_id)

    def ensure_share_token(
        self, name: str, *, user_id: str | None = None
    ) -> str | None:
        """Return the existing share_token for the template, or generate +
        store a new one if it has none yet.  ``None`` when the template
        doesn't exist (or isn't owned by ``user_id``).

        Token shape: 32 base64url chars (~192 bits).  Stored as-is; the
        only auth check is `share_token = ?` against the indexed column,
        so the token IS the credential.  Leaks are mitigated by
        ``delete_share_token`` which rotates.
        """
        existing = self.get_template(name, user_id=user_id)
        if existing is None:
            return None
        if existing.get("share_token"):
            return existing["share_token"]
        # Cryptographically random token; 24 bytes → 32 base64url chars.
        import secrets
        token = secrets.token_urlsafe(24)
        cur = self._conn.execute(
            "UPDATE team_templates SET share_token = ? WHERE name = ? "
            + ("AND user_id = ?" if user_id is not None else ""),
            ((token, name, user_id) if user_id is not None else (token, name)),
        )
        if (cur.rowcount or 0) == 0:
            # Concurrent delete between get_template and UPDATE — bail.
            return None
        return token

    def delete_share_token(self, name: str, *, user_id: str | None = None) -> bool:
        """Revoke the share token.  Subsequent
        ``ensure_share_token`` generates a fresh one.  Returns True if a
        token was cleared, False if there was nothing to clear or the
        template wasn't found / owned by ``user_id``.
        """
        sql = (
            "UPDATE team_templates SET share_token = NULL "
            "WHERE name = ? AND share_token IS NOT NULL"
        )
        params: tuple = (name,)
        if user_id is not None:
            sql += " AND user_id = ?"
            params = (name, user_id)
        cur = self._conn.execute(sql, params)
        return (cur.rowcount or 0) > 0

    def get_template_by_share_token(self, token: str) -> dict | None:
        """Anonymous read by share token.  Used by GET /shared-templates/{token}.
        Returns ``None`` if the token doesn't match any template (or was
        revoked)."""
        if not token:
            return None
        row = self._conn.execute(
            f"SELECT {self._TEMPLATE_COLS} FROM team_templates WHERE share_token = ?",
            (token,),
        ).fetchone()
        return self._template_row_to_dict(row) if row else None

    # ── Sprint 41: task DAG (parent → child) helpers ────────────────────────

    def link_tasks(self, *, parent_task_id: str, child_task_id: str) -> None:
        """Record the parent → child edge.  Idempotent — re-linking is
        a no-op since the PK absorbs duplicates."""
        self._conn.execute(
            "INSERT OR IGNORE INTO task_dependencies "
            "(parent_task_id, child_task_id, created_at) VALUES (?, ?, ?)",
            (parent_task_id, child_task_id, time.time()),
        )

    def get_parent_task_id(self, task_id: str) -> str | None:
        """Return the parent_task_id for a child task (if any).  A
        task has at most one parent in our model."""
        row = self._conn.execute(
            "SELECT parent_task_id FROM task_dependencies "
            "WHERE child_task_id = ? LIMIT 1",
            (task_id,),
        ).fetchone()
        return row[0] if row else None

    def list_child_task_ids(self, parent_task_id: str) -> list[str]:
        """Return all direct children of a task in created-at order."""
        rows = self._conn.execute(
            "SELECT child_task_id FROM task_dependencies "
            "WHERE parent_task_id = ? ORDER BY created_at",
            (parent_task_id,),
        ).fetchall()
        return [r[0] for r in rows]

    # ── Sprint 37: persistent project workspaces ────────────────────────────

    @staticmethod
    def _project_row_to_dict(r: tuple, file_count: int = 0) -> dict:
        return {
            "id": r[0],
            "user_id": r[1],
            "name": r[2],
            "description": r[3],
            "created_at": r[4],
            "updated_at": r[5],
            "file_count": file_count,
        }

    def create_project(
        self,
        *,
        user_id: str,
        name: str,
        description: str | None = None,
    ) -> str:
        """Insert a new project, return its generated id."""
        project_id = f"proj_{secrets.token_urlsafe(9)}"
        now = time.time()
        self._conn.execute(
            "INSERT INTO projects (id, user_id, name, description, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (project_id, user_id, name, description or None, now, now),
        )
        return project_id

    def list_projects(self, *, user_id: str | None = None) -> list[dict]:
        """List projects, optionally scoped to one user.  Each row
        carries a ``file_count`` computed from project_artifacts."""
        if user_id is None:
            rows = self._conn.execute(
                "SELECT p.id, p.user_id, p.name, p.description, p.created_at, p.updated_at, "
                "COALESCE(c.n, 0) FROM projects p "
                "LEFT JOIN (SELECT project_id, COUNT(*) n FROM project_artifacts GROUP BY project_id) c "
                "ON c.project_id = p.id "
                "ORDER BY p.updated_at DESC"
            ).fetchall()
        else:
            rows = self._conn.execute(
                "SELECT p.id, p.user_id, p.name, p.description, p.created_at, p.updated_at, "
                "COALESCE(c.n, 0) FROM projects p "
                "LEFT JOIN (SELECT project_id, COUNT(*) n FROM project_artifacts GROUP BY project_id) c "
                "ON c.project_id = p.id WHERE p.user_id = ? "
                "ORDER BY p.updated_at DESC", (user_id,),
            ).fetchall()
        return [self._project_row_to_dict(r[:6], file_count=r[6]) for r in rows]

    def get_project(self, project_id: str, *, user_id: str | None = None) -> dict | None:
        if user_id is None:
            row = self._conn.execute(
                "SELECT id, user_id, name, description, created_at, updated_at "
                "FROM projects WHERE id=?", (project_id,),
            ).fetchone()
        else:
            row = self._conn.execute(
                "SELECT id, user_id, name, description, created_at, updated_at "
                "FROM projects WHERE id=? AND user_id=?", (project_id, user_id),
            ).fetchone()
        if row is None:
            return None
        file_count = self._conn.execute(
            "SELECT COUNT(*) FROM project_artifacts WHERE project_id=?",
            (project_id,),
        ).fetchone()[0]
        return self._project_row_to_dict(row, file_count=file_count)

    def delete_project(self, project_id: str, *, user_id: str | None = None) -> bool:
        """Delete the project AND its artifact set.  Tasks that
        reference it keep ``project_id`` set (orphan reference) so we
        don't accidentally lose audit visibility on what ran where."""
        if user_id is None:
            self._conn.execute(
                "DELETE FROM project_artifacts WHERE project_id=?", (project_id,),
            )
            cur = self._conn.execute(
                "DELETE FROM projects WHERE id=?", (project_id,),
            )
        else:
            # Verify ownership before deleting artifacts.
            owner = self._conn.execute(
                "SELECT user_id FROM projects WHERE id=?", (project_id,),
            ).fetchone()
            if owner is None or owner[0] != user_id:
                return False
            self._conn.execute(
                "DELETE FROM project_artifacts WHERE project_id=?", (project_id,),
            )
            cur = self._conn.execute(
                "DELETE FROM projects WHERE id=? AND user_id=?", (project_id, user_id),
            )
        return (cur.rowcount or 0) > 0

    def update_project(
        self,
        project_id: str,
        *,
        user_id: str | None = None,
        name: str | None = None,
        description: str | None = None,
    ) -> dict | None:
        """Rename and/or update the description.  Returns the updated
        row, or ``None`` if the project doesn't exist / isn't owned."""
        if name is None and description is None:
            return self.get_project(project_id, user_id=user_id)
        updates: list[str] = []
        params: list = []
        if name is not None:
            updates.append("name = ?")
            params.append(name)
        if description is not None:
            updates.append("description = ?")
            params.append(description or None)
        updates.append("updated_at = ?")
        params.append(time.time())
        where = "id = ?"
        params.append(project_id)
        if user_id is not None:
            where += " AND user_id = ?"
            params.append(user_id)
        cur = self._conn.execute(
            f"UPDATE projects SET {', '.join(updates)} WHERE {where}", params,
        )
        if (cur.rowcount or 0) == 0:
            return None
        return self.get_project(project_id, user_id=user_id)

    def upsert_project_artifacts(self, project_id: str, snap: dict[str, str]) -> None:
        """Merge a {path: b64} snapshot into the project's HEAD.
        Last-writer-wins per path."""
        if not snap:
            return
        now = time.time()
        self._conn.executemany(
            "INSERT OR REPLACE INTO project_artifacts "
            "(project_id, path, b64_content, ts) VALUES (?, ?, ?, ?)",
            [(project_id, path, b64, now) for path, b64 in snap.items()],
        )
        # Bump project updated_at so the list sorts by activity.
        self._conn.execute(
            "UPDATE projects SET updated_at=? WHERE id=?", (now, project_id),
        )

    def load_project_artifacts(self, project_id: str) -> dict[str, str]:
        """Hydrate the project's HEAD as {path: b64}.  Used to seed
        the first agent of a task that belongs to this project."""
        rows = self._conn.execute(
            "SELECT path, b64_content FROM project_artifacts WHERE project_id=?",
            (project_id,),
        ).fetchall()
        return {r[0]: r[1] for r in rows}

    # ── Sprint 49: persistent agents ────────────────────────────────────────

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
        ch_cur = self._conn.execute(
            "INSERT INTO channels (workspace_id, kind, name, persistent_agent_id, created_at) "
            "VALUES (?, 'scheduled_agent', ?, ?, ?)",
            (workspace_id, name, pid, now),
        )
        channel_id = ch_cur.lastrowid
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
        """Sprint 49: fetch a single persistent agent by id (including deleted)."""
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
        """Sprint 49: soft delete; disables future fires."""
        self._conn.execute(
            "UPDATE persistent_agents SET deleted_at=?, enabled=0 WHERE id=?",
            (time.time(), pid),
        )

    # ── Sprint 49 A13: auto-pause on consecutive failures ──────────────────

    PERMANENT_FAILURE_DM_TEMPLATE = (
        "@{owner} — {agent_name} has failed 3 times in a row. I've paused it. "
        "See #{channel_name} for the failures. Enable again from settings."
    )

    def bump_persistent_agent_failure(self, pid: int) -> None:
        """Sprint 49 A13: increment consecutive_failures; at 3, disable the
        agent + emit the permanent-failure Tally DM.

        Example::

            db.bump_persistent_agent_failure(pid)
        """
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
            owner_row = self._conn.execute(
                "SELECT owner_user_id FROM workspaces WHERE id=?", (workspace_id,)
            ).fetchone()
            sa_ch_row = self._conn.execute(
                "SELECT name FROM channels WHERE persistent_agent_id=? AND kind='scheduled_agent'",
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
                    owner=owner_row[0], agent_name=name, channel_name=sa_ch_row[0],
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
        """Sprint 49 A13: reset consecutive_failures to 0 on task success.

        Example::

            db.reset_persistent_agent_failures(pid)
        """
        self._conn.execute(
            "UPDATE persistent_agents SET consecutive_failures=0 WHERE id=?", (pid,)
        )

    # ── Sprint 39: LLM cost accounting ─────────────────────────────────────

    def record_cost_event(
        self,
        *,
        user_id: str,
        kind: str,
        model: str,
        prompt_tokens: int,
        completion_tokens: int,
        total_tokens: int,
        cost_micro_usd: int,
        task_id: str | None = None,
        agent_idx: int | None = None,
    ) -> None:
        """Insert one cost event.  Safe to call from background threads;
        ``self._conn`` is autocommit (sprint-1 default)."""
        self._conn.execute(
            "INSERT INTO cost_events "
            "(user_id, task_id, agent_idx, kind, model, "
            " prompt_tokens, completion_tokens, total_tokens, cost_micro_usd, ts) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                user_id, task_id, agent_idx, kind, model,
                prompt_tokens, completion_tokens, total_tokens,
                cost_micro_usd, time.time(),
            ),
        )

    def cost_summary(self, *, user_id: str, since_ts: float) -> dict:
        """Return aggregated cost for ``user_id`` since ``since_ts``.
        Shape matches what the BillingScreen consumes:

          {
            "since_ts": ...,
            "total_micro_usd": int,
            "total_tokens": int,
            "by_kind":  [{kind, total_micro_usd, total_tokens, calls}, ...],
            "by_model": [{model, total_micro_usd, total_tokens, calls}, ...],
          }
        """
        total_row = self._conn.execute(
            "SELECT COALESCE(SUM(cost_micro_usd), 0), COALESCE(SUM(total_tokens), 0) "
            "FROM cost_events WHERE user_id=? AND ts >= ?",
            (user_id, since_ts),
        ).fetchone()
        total_micro_usd = int(total_row[0] or 0)
        total_tokens = int(total_row[1] or 0)
        by_kind = [
            {
                "kind": r[0],
                "total_micro_usd": int(r[1] or 0),
                "total_tokens": int(r[2] or 0),
                "calls": int(r[3] or 0),
            }
            for r in self._conn.execute(
                "SELECT kind, SUM(cost_micro_usd), SUM(total_tokens), COUNT(*) "
                "FROM cost_events WHERE user_id=? AND ts >= ? GROUP BY kind "
                "ORDER BY SUM(cost_micro_usd) DESC",
                (user_id, since_ts),
            ).fetchall()
        ]
        by_model = [
            {
                "model": r[0],
                "total_micro_usd": int(r[1] or 0),
                "total_tokens": int(r[2] or 0),
                "calls": int(r[3] or 0),
            }
            for r in self._conn.execute(
                "SELECT model, SUM(cost_micro_usd), SUM(total_tokens), COUNT(*) "
                "FROM cost_events WHERE user_id=? AND ts >= ? GROUP BY model "
                "ORDER BY SUM(cost_micro_usd) DESC",
                (user_id, since_ts),
            ).fetchall()
        ]
        return {
            "since_ts": since_ts,
            "total_micro_usd": total_micro_usd,
            "total_tokens": total_tokens,
            "by_kind": by_kind,
            "by_model": by_model,
        }

    def task_cost(self, task_id: str) -> dict:
        """Sum cost for one task — used in the per-task billing pill on
        the task channel."""
        row = self._conn.execute(
            "SELECT COALESCE(SUM(cost_micro_usd), 0), COALESCE(SUM(total_tokens), 0), COUNT(*) "
            "FROM cost_events WHERE task_id=?", (task_id,),
        ).fetchone()
        return {
            "task_id": task_id,
            "total_micro_usd": int(row[0] or 0),
            "total_tokens": int(row[1] or 0),
            "calls": int(row[2] or 0),
        }

    # ── Sprint 46: credit balance + period usage + overage state ───────────

    def credits_used_this_period(self, user_id: str, period_start: float) -> int:
        """Credits consumed since `period_start`.  Derived from
        `cost_events.cost_micro_usd` (single source of truth — no
        denormalized counter on `quotas`)."""
        from .credits import micro_usd_to_credits
        row = self._conn.execute(
            "SELECT COALESCE(SUM(cost_micro_usd), 0) FROM cost_events "
            "WHERE user_id=? AND ts >= ?",
            (user_id, period_start),
        ).fetchone()
        return micro_usd_to_credits(int(row[0] or 0))

    def credits_used_in_window(self, user_id: str, since_ts: float) -> int:
        """Credits in a rolling window (used for daily / weekly cap checks).

        Identical query shape to `credits_used_this_period`; delegates
        to keep the SQL in one place."""
        return self.credits_used_this_period(user_id, since_ts)

    def credits_available(self, user_id: str) -> int:
        """Subscription pool remaining + prepaid balance.

        Negative values clamp to 0 — we don't allow negative
        available-credit anywhere callers might branch on `> 0`.
        """
        q = self.get_or_create_quota(user_id)
        plan = QUOTA_PLANS.get(q["plan"], QUOTA_PLANS["free"])
        used = self.credits_used_this_period(user_id, q["period_start"])
        subscription_left = max(0, plan["included_credits"] - used)
        return subscription_left + int(q.get("prepaid_credit_balance") or 0)

    def get_prepaid_balance(self, user_id: str) -> int:
        row = self._conn.execute(
            "SELECT prepaid_credit_balance FROM quotas WHERE user_id=?",
            (user_id,),
        ).fetchone()
        return int(row[0]) if row else 0

    def set_prepaid_balance(self, user_id: str, credits: int) -> None:
        self._conn.execute(
            "UPDATE quotas SET prepaid_credit_balance=?, updated_at=? WHERE user_id=?",
            (credits, time.time(), user_id),
        )

    def increment_prepaid_balance(self, user_id: str, delta: int) -> None:
        self._conn.execute(
            "UPDATE quotas SET prepaid_credit_balance = prepaid_credit_balance + ?, "
            "updated_at=? WHERE user_id=?",
            (delta, time.time(), user_id),
        )

    def consume_prepaid_balance(self, user_id: str, credits: int) -> None:
        """Decrement (clamped at 0).  Called from the cost-event insert
        path when a task's cost lands and subscription credits are
        already exhausted."""
        self._conn.execute(
            "UPDATE quotas SET prepaid_credit_balance = MAX(0, prepaid_credit_balance - ?), "
            "updated_at=? WHERE user_id=?",
            (credits, time.time(), user_id),
        )

    def effective_per_task_cap_credits(self, user_id: str) -> int:
        """Quota override wins; plan default otherwise."""
        q = self.get_or_create_quota(user_id)
        override = q.get("per_task_cap_credits")
        if override is not None:
            return int(override)
        plan = QUOTA_PLANS.get(q["plan"], QUOTA_PLANS["free"])
        return int(plan["default_per_task_cap_credits"])

    def set_per_task_cap(self, user_id: str, credits: int | None) -> None:
        self._conn.execute(
            "UPDATE quotas SET per_task_cap_credits=?, updated_at=? WHERE user_id=?",
            (credits, time.time(), user_id),
        )

    def set_daily_cap(self, user_id: str, credits: int | None) -> None:
        self._conn.execute(
            "UPDATE quotas SET daily_spend_cap_credits=?, updated_at=? WHERE user_id=?",
            (credits, time.time(), user_id),
        )

    def set_weekly_cap(self, user_id: str, credits: int | None) -> None:
        self._conn.execute(
            "UPDATE quotas SET weekly_spend_cap_credits=?, updated_at=? WHERE user_id=?",
            (credits, time.time(), user_id),
        )

    # ── Sprint 38: encrypted per-user credentials ──────────────────────────

    def put_credential(self, *, user_id: str, kind: str, ciphertext: bytes) -> None:
        """Upsert ``(user_id, kind) → ciphertext``.  Caller is
        responsible for the encryption (see ``credentials.py``)."""
        now = time.time()
        existing = self._conn.execute(
            "SELECT created_at FROM user_credentials WHERE user_id=? AND kind=?",
            (user_id, kind),
        ).fetchone()
        if existing:
            self._conn.execute(
                "UPDATE user_credentials SET ciphertext=?, updated_at=? "
                "WHERE user_id=? AND kind=?",
                (ciphertext, now, user_id, kind),
            )
        else:
            self._conn.execute(
                "INSERT INTO user_credentials "
                "(user_id, kind, ciphertext, created_at, updated_at) "
                "VALUES (?, ?, ?, ?, ?)",
                (user_id, kind, ciphertext, now, now),
            )

    def get_credential(self, *, user_id: str, kind: str) -> bytes | None:
        """Return the raw ciphertext (or None if not stored).  Caller
        decrypts."""
        row = self._conn.execute(
            "SELECT ciphertext FROM user_credentials WHERE user_id=? AND kind=?",
            (user_id, kind),
        ).fetchone()
        return row[0] if row else None

    def has_credential(self, *, user_id: str, kind: str) -> bool:
        return self._conn.execute(
            "SELECT 1 FROM user_credentials WHERE user_id=? AND kind=?",
            (user_id, kind),
        ).fetchone() is not None

    def delete_credential(self, *, user_id: str, kind: str) -> bool:
        cur = self._conn.execute(
            "DELETE FROM user_credentials WHERE user_id=? AND kind=?",
            (user_id, kind),
        )
        return (cur.rowcount or 0) > 0

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

    # ── Sprint 33: quotas ───────────────────────────────────────────────────

    @staticmethod
    def _period_start_now() -> float:
        """A 30-day rolling window keyed off the user's first task.
        Trivial to swap for calendar-month or Stripe billing-period
        windows later; today we want simple-and-correct enforcement."""
        return time.time()

    def get_or_create_quota(self, user_id: str, plan_hint: str | None = None) -> dict:
        """Idempotent. Default plan: 'unlimited' for admin/legacy-admin
        (so they never trip caps), 'free' for everyone else.

        Sprint 33-rest: ``plan_hint`` is the plan slug read off the
        caller's Clerk JWT (``pla`` claim).  When provided and
        different from the stored plan, we update opportunistically
        — Clerk's session token is the source of truth, so this
        catches plan upgrades the webhook may not have delivered yet.
        Admin / legacy-admin rows ignore the hint (they're forever
        'unlimited').
        """
        row = self._conn.execute(
            "SELECT plan, stripe_customer_id, stripe_subscription_id, "
            "period_start, period_tasks_used, period_agent_seconds_used, updated_at, "
            "per_task_cap_credits, daily_spend_cap_credits, weekly_spend_cap_credits, "
            "overage_enabled, auto_recharge_mode, auto_recharge_block_credits, "
            "auto_recharge_monthly_cap_micro_usd, auto_recharge_spent_this_month_micro_usd, "
            "stripe_payment_method_id, prepaid_credit_balance, spend_alert_threshold_pct, "
            "alert_80_sent_at, alert_100_sent_at "
            "FROM quotas WHERE user_id=?", (user_id,),
        ).fetchone()
        is_admin = user_id in ("admin", "legacy-admin")
        if row is None:
            plan = "unlimited" if is_admin else (plan_hint or "free")
            now = self._period_start_now()
            self._conn.execute(
                "INSERT INTO quotas (user_id, plan, period_start, updated_at) "
                "VALUES (?, ?, ?, ?)",
                (user_id, plan, now, now),
            )
            return {
                "user_id": user_id, "plan": plan,
                "stripe_customer_id": None, "stripe_subscription_id": None,
                "period_start": now, "period_tasks_used": 0,
                "period_agent_seconds_used": 0, "updated_at": now,
                "per_task_cap_credits": None,
                "daily_spend_cap_credits": None,
                "weekly_spend_cap_credits": None,
                "overage_enabled": 0,
                "auto_recharge_mode": 0,
                "auto_recharge_block_credits": 500,
                "auto_recharge_monthly_cap_micro_usd": None,
                "auto_recharge_spent_this_month_micro_usd": 0,
                "stripe_payment_method_id": None,
                "prepaid_credit_balance": 0,
                "spend_alert_threshold_pct": 80,
                "alert_80_sent_at": None,
                "alert_100_sent_at": None,
            }
        stored_plan = row[0]
        if plan_hint and not is_admin and plan_hint != stored_plan:
            now = time.time()
            self._conn.execute(
                "UPDATE quotas SET plan=?, updated_at=? WHERE user_id=?",
                (plan_hint, now, user_id),
            )
            stored_plan = plan_hint
            # Sprint 46: seed default rules on plan upgrade.  Best-effort —
            # never let alert seeding fail an opportunistic plan sync.
            if plan_hint != "free":
                try:
                    from .notifications import seed_default_rules
                    seed_default_rules(self, user_id, plan=plan_hint)
                except Exception:
                    pass
        return {
            "user_id": user_id, "plan": stored_plan,
            "stripe_customer_id": row[1], "stripe_subscription_id": row[2],
            "period_start": row[3], "period_tasks_used": row[4],
            "period_agent_seconds_used": row[5], "updated_at": row[6],
            "per_task_cap_credits": row[7],
            "daily_spend_cap_credits": row[8],
            "weekly_spend_cap_credits": row[9],
            "overage_enabled": row[10],
            "auto_recharge_mode": row[11],
            "auto_recharge_block_credits": row[12],
            "auto_recharge_monthly_cap_micro_usd": row[13],
            "auto_recharge_spent_this_month_micro_usd": row[14],
            "stripe_payment_method_id": row[15],
            "prepaid_credit_balance": row[16],
            "spend_alert_threshold_pct": row[17],
            "alert_80_sent_at": row[18],
            "alert_100_sent_at": row[19],
        }

    def increment_task_count(self, user_id: str, delta: int = 1) -> None:
        self._conn.execute(
            "UPDATE quotas SET period_tasks_used = period_tasks_used + ?, "
            "updated_at=? WHERE user_id=?",
            (delta, time.time(), user_id),
        )

    def add_agent_seconds(self, user_id: str, seconds: int) -> None:
        if seconds <= 0:
            return
        self._conn.execute(
            "UPDATE quotas SET period_agent_seconds_used = period_agent_seconds_used + ?, "
            "updated_at=? WHERE user_id=?",
            (seconds, time.time(), user_id),
        )

    def set_user_plan(
        self,
        user_id: str,
        *,
        plan: str,
        stripe_customer_id: str | None = None,
        stripe_subscription_id: str | None = None,
    ) -> None:
        """Sprint 33: called by the Stripe webhook handler when a
        subscription transitions. Upserts the row in case the user
        upgrades before they've submitted any tasks."""
        now = time.time()
        existing = self._conn.execute(
            "SELECT 1 FROM quotas WHERE user_id=?", (user_id,)
        ).fetchone()
        if existing is None:
            self._conn.execute(
                "INSERT INTO quotas (user_id, plan, stripe_customer_id, "
                "stripe_subscription_id, period_start, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (user_id, plan, stripe_customer_id, stripe_subscription_id, now, now),
            )
        else:
            self._conn.execute(
                "UPDATE quotas SET plan=?, stripe_customer_id=COALESCE(?, stripe_customer_id), "
                "stripe_subscription_id=?, updated_at=? WHERE user_id=?",
                (plan, stripe_customer_id, stripe_subscription_id, now, user_id),
            )

    def reset_quota_period(self, user_id: str) -> None:
        """Start a new billing period; called by the period-rollover
        sweeper when 30 days elapse, OR by the webhook handler on
        invoice.payment_succeeded for the next period."""
        self._conn.execute(
            "UPDATE quotas SET period_start=?, period_tasks_used=0, "
            "period_agent_seconds_used=0, updated_at=? WHERE user_id=?",
            (time.time(), time.time(), user_id),
        )

    def list_quota_rows_due_for_rollover(self, period_seconds: float) -> list[str]:
        """Sprint 44: return user_ids whose ``period_start`` is older
        than ``period_seconds`` and that aren't on the practical-
        infinity ``unlimited`` plan.  Used by the period-rollover
        sweeper.  Admin / legacy-admin rows are on ``unlimited`` and
        excluded so the sweeper doesn't churn them every cycle."""
        cutoff = time.time() - period_seconds
        rows = self._conn.execute(
            "SELECT user_id FROM quotas "
            "WHERE plan != 'unlimited' AND period_start < ?",
            (cutoff,),
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
            # Sprint 37: persistent project (nullable).  Pre-S37 tasks
            # have NULL here; the orchestrator treats them as one-off
            # tasks just like before.
            "project_id": (row[10] if len(row) > 10 else None),
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


# ---------------------------------------------------------------------------
# Sprint 50: per-node tool allowlist helper
# ---------------------------------------------------------------------------

def _effective_tools_for_node(role_tools: list[str], node_allowlist: list[str] | None) -> list[str]:
    """Sprint 50: intersect a role's allowed tools with a node's optional
    allowlist.  None allowlist = use all role tools; [] allowlist =
    deliberately no tools.  Output preserves role_tools order."""
    if node_allowlist is None:
        return list(role_tools)
    allowed_set = set(node_allowlist)
    return [t for t in role_tools if t in allowed_set]


# ---------------------------------------------------------------------------
# Sprint 48: nodes_v1 graph-traversal helpers
# ---------------------------------------------------------------------------

def _nodes_v1_entry_nodes(spec: dict) -> set[str]:
    """Sprint 48: return the set of node ids with no incoming edge
    (entry points dispatched first in nodes_v1 mode)."""
    all_ids = {n["id"] for n in spec.get("nodes", [])}
    targets = {e["to"] for e in spec.get("edges", [])}
    return all_ids - targets


def _nodes_v1_next_ready(spec: dict, completed: dict[str, str]) -> set[str]:
    """Sprint 48: return node ids that are NOT yet completed but whose
    incoming edges have all fired given the ``completed`` map
    ``{node_id: 'succeeded'|'failed'}``.

    Edge firing rules:
      - ``'always'`` (default): fires when source completes regardless of status
      - ``'if_succeeded'``: fires only if source status == ``'succeeded'``
      - ``'if_failed'``: fires only if source status == ``'failed'``
      - ``'if_returned'``: Sprint 48 parses but doesn't evaluate (deferred)

    A node becomes ready when ALL its incoming edges have fired
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
            continue  # entry node — caller dispatches separately
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
                # Sprint 48 parses but doesn't evaluate — deferred to Sprint 48.5
                all_fired = False
                break
        if all_fired:
            ready.add(nid)
    return ready


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

    def _seed_files_for_task(self, task: dict) -> dict[str, str]:
        """Sprint 37/41: return the seed_files snapshot to hand to the
        next agent of ``task``.

        Hydration priority (highest wins):
          1. In-memory ``_task_artifacts[task_id]`` if any predecessor
             agent already ran in this task (Sprint 26 contract).
          2. Sprint 41: parent task's final artifacts when the task
             has a ``task_dependencies`` row pointing at a successful
             parent.  Lets the architect chain tasks — child builds
             on parent's output, not a generic project HEAD.
          3. Sprint 37: project HEAD when the task belongs to a project
             AND has no parent.  Lets users iterate on a codebase
             across multiple Tally runs.
          4. Empty dict otherwise.
        """
        existing = self._task_artifacts.get(task["id"])
        if existing:
            return existing
        task_id = task["id"]

        # Path 2: parent-task inheritance (Sprint 41).
        parent_id = self.db.get_parent_task_id(task_id)
        if parent_id:
            parent_task = self.db.get_task(parent_id)
            if parent_task and parent_task.get("status") == "completed":
                # Read parent's final artifacts from the durable
                # ``task_artifacts`` table.  These were captured by
                # ``upsert_artifacts`` at parent run time and persist
                # for the lifetime of the parent task.
                seed = self.db.load_artifacts(parent_id)
                if seed:
                    self._task_artifacts[task_id] = dict(seed)
                    logger.info(
                        "task %s: hydrated %d file(s) from parent task=%s",
                        task_id[:8], len(seed), parent_id[:8],
                    )
                    return seed

        # Path 3: project HEAD (Sprint 37).
        project_id = task.get("project_id")
        if project_id:
            seed = self.db.load_project_artifacts(project_id)
            if seed:
                self._task_artifacts[task_id] = dict(seed)
                logger.info(
                    "task %s: hydrated %d file(s) from project=%s HEAD",
                    task_id[:8], len(seed), project_id,
                )
                return seed

        return {}

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

        Sprint 48: when ``team_spec`` is nodes_v1 format (``"nodes"`` +
        ``"edges"`` keys), use graph-traversal helpers to identify entry
        nodes and dispatch them.  The advancement logic lives in
        ``_handle_result_event``'s nodes_v1 branch.
        """
        from .team_spec_compat import is_nodes_v1

        # ---------------------------------------------------------------
        # Sprint 48: nodes_v1 dispatch path
        # ---------------------------------------------------------------
        if is_nodes_v1(team_spec):
            nodes = team_spec.get("nodes", [])
            # Filter to dispatchable (agent-kind) nodes only.
            agent_nodes = [n for n in nodes if n.get("kind", "agent") == "agent"]
            if not agent_nodes:
                self.db.mark_failed(task["id"], "nodes_v1 team_spec has no agent nodes")
                await self._publish_status(task["id"], "failed",
                                           {"error": "nodes_v1 team_spec has no agent nodes"})
                return
            owner_id = task.get("user_id")
            role_scope = owner_id if owner_id and owner_id not in ("admin", "legacy-admin") else None
            # Insert ALL agent nodes up-front so the team shape is visible
            # in /admin/status.  Each node's list-index becomes agent_idx.
            for idx, node in enumerate(nodes):
                if node.get("kind", "agent") != "agent":
                    continue  # skip output / terminal marker nodes
                role_name = node.get("role")
                role = self.db.get_agent_role(role_name, user_id=role_scope)
                if not role:
                    self.db.mark_failed(task["id"], f"unknown role: {role_name}")
                    await self._publish_status(task["id"], "failed",
                                               {"error": f"unknown role: {role_name}"})
                    return
                self.db.insert_agent(
                    task_id=task["id"],
                    agent_idx=idx,
                    role=role_name,
                    model=node.get("model") or role["default_model"],
                    spec=node.get("spec", ""),
                )
            self.db.mark_running(task["id"])
            await self._publish_status(task["id"], "running", {"team_size": len(agent_nodes)})
            # Determine entry nodes (those with no incoming edge).
            entry_ids = _nodes_v1_entry_nodes(team_spec)
            all_agents = self.db.list_agents(task["id"])
            by_idx = {a["agent_idx"]: a for a in all_agents}
            # Map node_id → agent_idx for dispatch.
            node_id_to_idx = {n["id"]: i for i, n in enumerate(nodes)}
            entry_agents = [
                by_idx[node_id_to_idx[nid]]
                for nid in entry_ids
                if nid in node_id_to_idx and node_id_to_idx[nid] in by_idx
            ]
            logger.info(
                "starting nodes_v1 team for task %s: %d agent nodes, entries = [%s]",
                task["id"][:8], len(agent_nodes),
                ", ".join(a["role"] for a in entry_agents),
            )
            for agent in entry_agents:
                asyncio.create_task(self._dispatch_agent(task, agent))
            return
        # ---------------------------------------------------------------
        # Flat (Sprint 22-27) dispatch path
        # ---------------------------------------------------------------
        agents_spec = team_spec.get("agents", []) or []
        if not agents_spec:
            self.db.mark_failed(task["id"], "team_spec has no agents")
            await self._publish_status(task["id"], "failed", {"error": "team_spec has no agents"})
            return
        # Resolve + insert per-agent rows up front so the team's shape is
        # visible in /admin/status before any worker dispatch starts.
        # Sprint 40: scope role lookups to the task's owner so custom
        # roles defined by THAT user resolve.  Admin / legacy-admin
        # tasks fall through to seeded-only lookups.
        owner_id = task.get("user_id")
        role_scope = owner_id if owner_id and owner_id not in ("admin", "legacy-admin") else None
        for idx, a in enumerate(agents_spec):
            role_name = a.get("role")
            role = self.db.get_agent_role(role_name, user_id=role_scope)
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
            # Sprint 40: scope role lookup to the task owner so the
            # worker dispatch picks up custom roles' system_prompt + tools.
            owner_id = task.get("user_id")
            role_scope = owner_id if owner_id and owner_id not in ("admin", "legacy-admin") else None
            role = self.db.get_agent_role(agent["role"], user_id=role_scope) or {}
            await self._publish_status(task["id"], "running", {
                "agent_role": agent["role"], "agent_idx": agent["agent_idx"],
            })
            logger.info("dispatching task %s agent %s/%s (%s) to worker %s",
                        task["id"][:8], agent["agent_idx"], agent["role"],
                        agent["model"], handle.identity[:8])
            try:
                # Sprint 47: pull any user messages posted in the task channel
                # since the last agent step; prepend to this agent's spec so the
                # LLM sees them as teammate input.  Persists the new
                # last_user_msg_ts so subsequent steps don't re-include them.
                from .channels import resolve_task_channel_id, fetch_user_messages_since
                agent_spec_text = agent["spec"] or ""
                ch_id = resolve_task_channel_id(self.db, task["id"])
                if ch_id is not None:
                    since_ts = float(agent.get("last_user_msg_ts") or 0)
                    user_msgs = fetch_user_messages_since(
                        self.db, channel_id=ch_id, since_ts=since_ts,
                    )
                    if user_msgs:
                        intervention_block = "\n\n## User intervention (since last step)\n" + "\n".join(
                            f"- @{m['author_user_id']}: {m['text']}" for m in user_msgs
                        )
                        agent_spec_text = agent_spec_text + intervention_block
                        self.db._conn.execute(
                            "UPDATE agents SET last_user_msg_ts=? WHERE id=?",
                            (user_msgs[-1]["created_at"], agent["id"]),
                        )
                # Sprint 50: per-node tool_allowlist intersects with role tools.
                # nodes_v1: look up the nth agent-kind node; flat: look up
                # agents[agent_idx].  None allowlist = full role tools.
                node_allowlist: list[str] | None = None
                try:
                    from .team_spec_compat import is_nodes_v1
                    if is_nodes_v1(team_spec):
                        agent_nodes = [n for n in team_spec.get("nodes", []) if n.get("kind") == "agent"]
                        if 0 <= agent_idx < len(agent_nodes):
                            raw = agent_nodes[agent_idx].get("tool_allowlist")
                            if isinstance(raw, list):
                                node_allowlist = [str(t) for t in raw]
                    else:
                        agents_flat = team_spec.get("agents") or []
                        if 0 <= agent_idx < len(agents_flat):
                            raw = agents_flat[agent_idx].get("tool_allowlist")
                            if isinstance(raw, list):
                                node_allowlist = [str(t) for t in raw]
                except Exception:
                    node_allowlist = None
                effective_tools = _effective_tools_for_node(role.get("tools", []), node_allowlist)
                payload_obj = {
                    "task": task["description"],
                    "task_id": task["id"],
                    "orchestrator_bearer": self.bearer,
                    "agent_idx": agent["agent_idx"],
                    "agent_spec": {
                        "role": agent["role"],
                        "model": agent["model"],
                        "spec": agent_spec_text,
                        "system_prompt": role.get("system_prompt", ""),
                        "tools": effective_tools,
                    },
                    # Sprint 26: hand the agent its predecessors' files.
                    # Empty on the first agent in a team.
                    # Sprint 37: when the task belongs to a project, the
                    # first agent inherits the project's HEAD artifacts
                    # so the team can iterate on real code instead of
                    # starting from scratch.  Hydrated lazily — once per
                    # task — on first dispatch.
                    "seed_files": self._seed_files_for_task(task),
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
            # Sprint 33: bill agent wall-time to the task's owner.
            # started_at was set in mark_agent_running; pull the fresh
            # row to get both timestamps + the owner's user_id.
            try:
                refreshed_agent = next(
                    (a for a in self.db.list_agents(task_id)
                     if a["agent_idx"] == agent_idx), None,
                )
                task_row = self.db.get_task(task_id)
                if refreshed_agent and task_row:
                    start = refreshed_agent.get("started_at") or 0
                    end = refreshed_agent.get("finished_at") or time.time()
                    elapsed = max(0, int(end - start))
                    owner = task_row.get("user_id") or "legacy-admin"
                    if elapsed > 0:
                        self.db.add_agent_seconds(owner, elapsed)
                    # Sprint 39: per-agent LLM cost.  Workers emit
                    # `usage_tokens` (an OpenAI-shaped {prompt_tokens,
                    # completion_tokens, total_tokens} dict) and
                    # `model` in their final result event.  Either may
                    # be missing — older workers don't ship S39's
                    # accounting yet, in which case the dashboard shows
                    # architect-only cost.
                    usage = result.get("usage_tokens") if isinstance(result, dict) else None
                    if isinstance(usage, dict) and task_row:
                        model = (
                            result.get("model")
                            or (refreshed_agent.get("model") if refreshed_agent else None)
                            or "unknown"
                        )
                        prompt = int(usage.get("prompt_tokens", 0) or 0)
                        completion = int(usage.get("completion_tokens", 0) or 0)
                        total = int(usage.get("total_tokens", prompt + completion) or 0)
                        if total > 0:
                            cost = compute_cost_micro_usd(model, prompt, completion)
                            self.db.record_cost_event(
                                user_id=owner,
                                task_id=task_id,
                                agent_idx=agent_idx,
                                kind="agent",
                                model=model,
                                prompt_tokens=prompt,
                                completion_tokens=completion,
                                total_tokens=total,
                                cost_micro_usd=cost,
                            )
                            logger.info(
                                "agent cost: task=%s agent=%s/%s model=%s tokens=%d cost=%s",
                                task_id[:8], agent_idx, target_agent["role"],
                                model, total, format_micro_usd(cost),
                            )
                            # Sprint 46 Checkpoint 6 — mid-run period cap +
                            # auto-recharge.  After this cost event, if the
                            # user's period pool just went negative AND they
                            # have Mode 2/3 auto-recharge with overage
                            # enabled, try a top-up.  If they don't (or
                            # top-up fails), abort the task with
                            # period_cap_reached.
                            try:
                                avail = self.db.credits_available(owner)
                                if avail <= 0:
                                    quota = self.db.get_or_create_quota(owner)
                                    mode = int(quota.get("auto_recharge_mode") or 0)
                                    handled = False
                                    if mode == 3:
                                        try:
                                            from .stripe_direct import trigger_auto_recharge_unlimited
                                            await trigger_auto_recharge_unlimited(self.db, owner)
                                            handled = True
                                        except Exception as rex:
                                            logger.warning(
                                                "mid-run auto-recharge (mode 3) failed for %s: %s",
                                                owner, rex,
                                            )
                                    elif mode == 2:
                                        try:
                                            from .stripe_direct import trigger_auto_recharge_capped
                                            if await trigger_auto_recharge_capped(self.db, owner):
                                                handled = True
                                        except Exception as rex:
                                            logger.warning(
                                                "mid-run auto-recharge (mode 2) failed for %s: %s",
                                                owner, rex,
                                            )
                                    if not handled:
                                        self.db.mark_failed(
                                            task_id,
                                            "period cap reached: no credits available",
                                        )
                                        self._task_artifacts.pop(task_id, None)
                                        self.db.delete_artifacts(task_id)
                                        # Sprint 46 follow-up: unified payload
                                        # shape across both abort sites so the
                                        # Flutter CapAbortDialog can render the
                                        # right copy via the `reason` field.
                                        from .credits import micro_usd_to_credits
                                        task_cost_micro = self.db.task_cost(task_id)["total_micro_usd"]
                                        await self._publish_status(task_id, "aborted_cost_cap", {
                                            "reason": "period_cap",
                                            "cost_credits": micro_usd_to_credits(task_cost_micro),
                                            "cap_credits": 0,
                                            "available_credits": 0,
                                        })
                                        logger.info(
                                            "task %s aborted: period cap reached for user=%s",
                                            task_id[:8], owner,
                                        )
                                        return
                            except Exception as exc:
                                logger.warning(
                                    "period cap check failed for task %s: %s",
                                    task_id[:8], exc,
                                )
                            # Sprint 46 Checkpoint 7 — alert eval on every
                            # agent cost event.  Fires notification rules
                            # whose threshold was just crossed.
                            try:
                                from .notifications import (
                                    evaluate_rules_for_cost_event,
                                    fan_out_push,
                                )
                                fired = evaluate_rules_for_cost_event(self.db, owner)
                                for f in fired:
                                    asyncio.create_task(fan_out_push(self.db, owner, f["id"]))
                            except Exception as exc:
                                logger.warning("alert eval (agent) raised: %s", exc)
            except Exception as exc:
                logger.warning("usage-accounting raised; ignoring: %s", exc)
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
        # Sprint 46: Checkpoint 5 — mid-run per-task cap.  If the
        # cumulative cost for this task has crossed the user's per-task
        # cap, abort the remaining stages.  S41's task_artifacts
        # retention rule applies — partials stay.
        try:
            from .credits import micro_usd_to_credits
            task_cost_micro = self.db.task_cost(task_id)["total_micro_usd"]
            task_cost_credits = micro_usd_to_credits(task_cost_micro)
            _task_for_cap = self.db.get_task(task_id)
            user_id = (_task_for_cap.get("user_id") if _task_for_cap else None) or "legacy-admin"
            effective_cap = self.db.effective_per_task_cap_credits(user_id)
            if task_cost_credits > effective_cap:
                self.db.mark_failed(
                    task_id,
                    f"cost cap reached: {task_cost_credits} > {effective_cap}",
                )
                self._task_artifacts.pop(task_id, None)
                # Match other abort paths (failed agent, end-of-task failure):
                # durable artifact rows are only retained for SUCCESSFUL tasks
                # so child tasks can hydrate from them.
                self.db.delete_artifacts(task_id)
                await self._publish_status(task_id, "aborted_cost_cap", {
                    "reason": "per_task_cap",
                    "cost_credits": task_cost_credits,
                    "cap_credits": effective_cap,
                    "available_credits": self.db.credits_available(user_id),
                })
                logger.info(
                    "task %s aborted: cost cap %d > %d",
                    task_id[:8], task_cost_credits, effective_cap,
                )
                return
        except Exception as exc:
            # Cost cap is safety, not feature — never crash the
            # orchestrator if accounting fails.
            logger.warning("cost cap check failed for task %s: %s", task_id[:8], exc)
        # Sprint 27 / 48: stage-aware (flat) or graph-aware (nodes_v1) advancement.
        task = self.db.get_task(task_id)
        if task is None:
            logger.error("task %s gone before stage advance", task_id[:8])
            return
        team_spec = task.get("team_spec") or {}

        # -------------------------------------------------------------------
        # Sprint 48: nodes_v1 advancement path
        # -------------------------------------------------------------------
        from .team_spec_compat import is_nodes_v1
        if is_nodes_v1(team_spec):
            fresh = self.db.list_agents(task_id)
            by_idx = {a["agent_idx"]: a for a in fresh}
            nodes = team_spec.get("nodes", [])
            # Build completed map: {node_id -> 'succeeded'|'failed'}.
            # agent_idx == the node's index in the nodes list.
            completed_map: dict[str, str] = {}
            for a in fresh:
                idx = a["agent_idx"]
                if 0 <= idx < len(nodes) and a["status"] in ("completed", "failed"):
                    node_id = nodes[idx]["id"]
                    completed_map[node_id] = (
                        "succeeded" if a["status"] == "completed" else "failed"
                    )
            # Find newly-ready nodes (all completed agent nodes whose
            # edges have fired, excluding output/terminal nodes).
            ready_ids = _nodes_v1_next_ready(team_spec, completed_map)
            # Also exclude already-dispatched nodes (pending/running/done).
            dispatched_idxs = {a["agent_idx"] for a in fresh}
            node_id_to_idx = {n["id"]: i for i, n in enumerate(nodes)}
            to_dispatch = [
                nid for nid in ready_ids
                if (
                    nid in node_id_to_idx
                    and nodes[node_id_to_idx[nid]].get("kind", "agent") == "agent"
                    and node_id_to_idx[nid] not in dispatched_idxs
                )
            ]
            if to_dispatch:
                for nid in to_dispatch:
                    a_idx = node_id_to_idx[nid]
                    agent_row = by_idx.get(a_idx)
                    if agent_row is None:
                        # Insert the agent row on first dispatch (lazy init).
                        node = nodes[a_idx]
                        role_name = node.get("role")
                        owner_id = task.get("user_id")
                        role_scope = (
                            owner_id
                            if owner_id and owner_id not in ("admin", "legacy-admin")
                            else None
                        )
                        role = self.db.get_agent_role(role_name, user_id=role_scope) or {}
                        self.db.insert_agent(
                            task_id=task_id,
                            agent_idx=a_idx,
                            role=role_name or "unknown",
                            model=node.get("model") or role.get("default_model", "unknown"),
                            spec=node.get("spec", ""),
                        )
                        fresh2 = self.db.list_agents(task_id)
                        by_idx = {a["agent_idx"]: a for a in fresh2}
                        agent_row = by_idx.get(a_idx)
                    if agent_row:
                        logger.info(
                            "task %s nodes_v1: dispatching next node %s (%s)",
                            task_id[:8], nid, agent_row["role"],
                        )
                        asyncio.create_task(self._dispatch_agent(task, agent_row))
                return
            # No new nodes to dispatch.  Check if all agent nodes are terminal.
            agent_node_idxs = [
                i for i, n in enumerate(nodes)
                if n.get("kind", "agent") == "agent"
            ]
            all_terminal = all(
                by_idx.get(i, {}).get("status") in ("completed", "failed")
                for i in agent_node_idxs
            )
            if not all_terminal:
                # Some agent nodes are still running / pending — wait.
                logger.debug(
                    "task %s nodes_v1: waiting on %d more agent node(s)",
                    task_id[:8],
                    sum(
                        1 for i in agent_node_idxs
                        if by_idx.get(i, {}).get("status") not in ("completed", "failed")
                    ),
                )
                return
            # Fall through to task-completion aggregation below.

        else:
            # ---------------------------------------------------------------
            # Sprint 27: flat stage-aware advancement (unchanged)
            # ---------------------------------------------------------------
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
        # Sprint 37: when the task belongs to a project AND the run
        # succeeded overall, merge its final artifacts back into the
        # project's HEAD before we free the in-memory copy.  Failed
        # tasks do NOT update HEAD — keeps the project's working
        # codebase from absorbing bad partial outputs.
        final_artifacts = self._task_artifacts.pop(task_id, {})  # Sprint 26: free memory
        artifact_count = len(final_artifacts)
        if aggregate["success"]:
            task_row = self.db.get_task(task_id)
            project_id = (task_row or {}).get("project_id")
            if project_id and final_artifacts:
                self.db.upsert_project_artifacts(project_id, final_artifacts)
                logger.info(
                    "task %s: merged %d file(s) into project=%s HEAD",
                    task_id[:8], artifact_count, project_id,
                )
            # Sprint 41: keep the durable task_artifacts row around
            # for SUCCESSFUL tasks — they're the snapshot that child
            # tasks hydrate from in `_seed_files_for_task`.  Storage
            # cost is bounded by the artifact-size caps from Sprint 26.
            # Failed tasks still get cleaned up below since their
            # artifacts shouldn't seed anything.
        else:
            self.db.delete_artifacts(task_id)  # free durable copy on failure
        await self._publish_status(
            task_id, "completed",
            {"success": aggregate["success"], "agents_run": len(final_agents)},
        )
        logger.info("task %s team complete: %d agents, %d artifact(s) accumulated",
                    task_id[:8], len(final_agents), artifact_count)

    async def run_period_rollover_sweeper(self) -> None:
        """Sprint 44: every hour, roll over any quota row whose
        ``period_start`` is older than 30 days.  Resets
        ``period_tasks_used`` + ``period_agent_seconds_used`` to 0
        and bumps ``period_start`` to now.

        Aligns with the comment in ``_period_start_now`` ("30-day
        rolling window keyed off the user's first task").  Calendar-
        month or Clerk-subscription-renewal anchored windows would
        be nicer but require either a cron job or wiring webhooks
        for renewal events; this is good enough for v1 and runs
        inside the orchestrator's existing async loop.
        """
        period_seconds = float(os.environ.get("TALLY_QUOTA_PERIOD_S", str(30 * 86400)))
        sweep_interval_s = float(os.environ.get("TALLY_QUOTA_SWEEP_INTERVAL_S", "3600"))
        while True:
            try:
                due = self.db.list_quota_rows_due_for_rollover(period_seconds)
                if due:
                    for user_id in due:
                        self.db.reset_quota_period(user_id)
                    logger.info(
                        "period sweeper: rolled over %d quota row(s) (period=%ds)",
                        len(due), int(period_seconds),
                    )
            except Exception as exc:
                logger.warning("period sweeper raised; ignoring: %s", exc)
            try:
                await asyncio.sleep(sweep_interval_s)
            except asyncio.CancelledError:
                return

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

    async def _fire_persistent_agent(self, pid: int, *, trigger: str) -> str | None:
        """Sprint 49: create a tasks row + dispatch.  Returns task_id or
        None if the agent is disabled / deleted / missing.  trigger is
        one of 'cron', 'webhook', 'manual'."""
        agent = self.db.get_persistent_agent(pid)
        if agent is None or agent.get("deleted_at") or not agent.get("enabled"):
            return None
        task_id = uuid.uuid4().hex
        now = time.time()
        # Get the workspace owner as the task's user_id
        owner_row = self.db._conn.execute(
            "SELECT owner_user_id FROM workspaces WHERE id=?", (agent["workspace_id"],)
        ).fetchone()
        owner = owner_row[0] if owner_row else "admin"
        self.db._conn.execute(
            "INSERT INTO tasks (id, description, team_spec, status, "
            "persistent_agent_id, user_id, created_at, updated_at) "
            "VALUES (?, ?, ?, 'pending', ?, ?, ?, ?)",
            (
                task_id,
                f"[persistent: {agent['name']}] {trigger} fire",
                json.dumps(agent["team_spec"]),
                pid,
                owner,
                now,
                now,
            ),
        )
        logger.info(
            "persistent agent %s (%s) fired via %s -> task %s",
            pid, agent["name"], trigger, task_id[:8],
        )
        # Worker poller picks up status='pending' on its next tick.  Kick if available.
        if hasattr(self, "_kick_poller"):
            try:
                asyncio.create_task(self._kick_poller())
            except Exception:
                pass
        return task_id

    async def _persistent_agents_tick(self) -> None:
        """Sprint 49: one iteration of the persistent-agents cron poll.
        Factored out so tests can call a single tick without the loop."""
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
                logger.error(
                    "invalid cron %r for agent %s: %s; disabling", cron, agent_id, exc
                )
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
        """Sprint 49: cron poller for persistent agents.  Runs every 30s
        until self._stopping is True."""
        while not self._stopping:
            try:
                await self._persistent_agents_tick()
            except Exception as exc:
                logger.exception("persistent_agents_loop iteration failed: %s", exc)
            await asyncio.sleep(30)


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

    # Sprint 33-rest: Clerk Billing replaces direct Stripe.  We only
    # own the webhook secret + parser; the customer/subscription
    # state lives in Clerk.  /webhooks/clerk returns 503 when
    # CLERK_WEBHOOK_SECRET is unset (development tier without
    # billing wired up).  Quotas + the free-tier 429s still work
    # because the plan flows from the user's JWT `pla` claim.
    clerk_billing = ClerkBillingClient()
    state["clerk_billing"] = clerk_billing
    # Sprint 38: encrypted credentials manager (PATs, future BYOK).
    # When CREDENTIALS_KEY is unset, /github/* routes 503 with a
    # generation-instructions detail so operators know how to fix it.
    credentials = CredentialsManager()
    state["credentials"] = credentials
    if credentials.configured:
        logger.info("Credentials manager ready (Fernet master key loaded)")
    else:
        logger.info("CREDENTIALS_KEY not configured; /github/* routes will 503")
    # Sprint 38.5: Clerk Backend API client.  When CLERK_SECRET_KEY is
    # set, the push endpoint tries Clerk-mediated GitHub OAuth before
    # falling back to a stored PAT — users who signed in via "Continue
    # with GitHub" don't have to paste anything.
    clerk_backend = ClerkBackendClient()
    state["clerk_backend"] = clerk_backend
    if clerk_backend.configured:
        logger.info("Clerk Backend API client ready (sk_..%s)",
                    clerk_backend.secret_key[-4:])
    else:
        logger.info("CLERK_SECRET_KEY not configured; /projects/{id}/push "
                    "will only use stored PATs (no Clerk-mediated OAuth)")
    if clerk_billing.webhook_enabled:
        logger.info("Clerk Billing webhook enabled (whsec_...%s)",
                    clerk_billing.webhook_secret[-4:])
    else:
        logger.info("Clerk Billing webhook not configured; /webhooks/clerk will 503")

    # Sprint 35: split the worker-pool bootstrap off the lifespan critical
    # path so HTTP comes up immediately.  Routes that *need* a worker
    # (POST /tasks) gate on ``state["pool_ready"]`` and return 503 with
    # a Retry-After hint until the pool finishes joining MLS.  Routes
    # that don't need workers (/health, /billing/usage, /webhooks/clerk,
    # /tasks GETs, /templates) stay available throughout the bootstrap
    # window.  Previous behaviour blocked the entire HTTP surface for
    # ~4 minutes of worker-handshake time which made Clerk webhooks
    # retry unnecessarily and bricked the operator UX during redeploys.
    state["pool_ready"] = False
    state["pool_status"] = {
        "target_size": target_pool_size,
        "joined": 0,
        "last_error": None,
    }

    # Sprint 43: retry schedule for the pool bootstrap.  Sequence
    # repeats indefinitely so the orchestrator self-heals when workers
    # come back online after an outage.  Last entry is the cap; the
    # bootstrap stays on the slowest cadence forever rather than
    # giving up.
    _retry_delays_s = [60, 300, 900]  # 1 min, 5 min, 15 min

    async def _bootstrap_pool_in_background() -> None:
        attempt = 0
        while not state.get("pool_ready"):
            attempt += 1
            try:
                slots = await _resolve_pool(db, pool, target_pool_size)
                logger.info(
                    "bootstrapping pool of %d worker(s) in parallel "
                    "(background; attempt=%d)",
                    len(slots), attempt,
                )
                handles = await asyncio.gather(
                    *[_bootstrap_slot(orchestrator, db, pool, w) for w in slots]
                )
                ok = [h for h in handles if h is not None]
                state["pool_status"]["joined"] = len(ok)
                if not ok:
                    state["pool_status"]["last_error"] = (
                        f"no workers bootstrapped (target={target_pool_size}; "
                        f"attempt={attempt})"
                    )
                    logger.error(
                        "%s; sleeping %ds before retry",
                        state["pool_status"]["last_error"],
                        _retry_delays_s[min(attempt - 1, len(_retry_delays_s) - 1)],
                    )
                    # Sprint 43: don't crash, don't give up — sleep and
                    # try again.  Backoff caps at the last entry.
                    delay = _retry_delays_s[min(attempt - 1, len(_retry_delays_s) - 1)]
                    await asyncio.sleep(delay)
                    continue
                if len(ok) < target_pool_size:
                    logger.warning(
                        "only %d/%d workers bootstrapped; running degraded",
                        len(ok), target_pool_size,
                    )
                for h in ok:
                    orchestrator.start_poller(h)
                # Processor loop dispatches tasks to workers; only starts
                # now that handles exist.
                state["processor_task"] = asyncio.create_task(
                    orchestrator.run_processor_loop()
                )
                state["pool_ready"] = True
                state["pool_status"]["last_error"] = None  # clear on success
                logger.info(
                    "pool ready (attempt=%d): %d worker(s) joined; "
                    "processor loop running",
                    attempt, len(orchestrator.handles),
                )
                return
            except asyncio.CancelledError:
                # Shutdown — propagate cleanly so the lifespan finalizer
                # gets the cancellation it expects.
                raise
            except Exception as exc:
                state["pool_status"]["last_error"] = repr(exc)
                logger.exception(
                    "pool bootstrap raised (attempt=%d); sleeping before retry: %s",
                    attempt, exc,
                )
                delay = _retry_delays_s[min(attempt - 1, len(_retry_delays_s) - 1)]
                try:
                    await asyncio.sleep(delay)
                except asyncio.CancelledError:
                    raise

    # Sweeper + backup don't depend on workers — start them eagerly so
    # the recovery clock keeps ticking even during a pool outage.
    sweeper_task = asyncio.create_task(orchestrator.run_recovery_sweeper())
    state["sweeper_task"] = sweeper_task
    # Sprint 44: hourly quota-period rollover so paying users don't stay
    # capped at "this period" forever.
    state["quota_sweeper_task"] = asyncio.create_task(
        orchestrator.run_period_rollover_sweeper()
    )
    backup_task = asyncio.create_task(run_nightly_backup())  # Sprint 24.5
    state["backup_task"] = backup_task
    # Sprint 49: cron poller fires due persistent agents every 30s.
    orchestrator._stopping = False
    state["persistent_agents_task"] = asyncio.create_task(
        orchestrator._persistent_agents_loop()
    )
    state["pool_bootstrap_task"] = asyncio.create_task(_bootstrap_pool_in_background())
    logger.info(
        "HTTP up; sweeper + nightly backup + persistent-agents cron started; "
        "pool bootstrap kicked off in background (target=%d)",
        target_pool_size,
    )
    try:
        yield
    finally:
        for team_id in list(orchestrator.pollers.keys()):
            orchestrator.stop_poller(team_id)
        # Sprint 35: processor_task only exists after pool bootstrap; the
        # bootstrap task itself might still be in flight if shutdown
        # arrives during a redeploy window.  Cancel whatever's set.
        orchestrator._stopping = True
        for key in ("pool_bootstrap_task", "processor_task", "sweeper_task", "quota_sweeper_task", "backup_task", "persistent_agents_task"):
            t = state.get(key)
            if t is None:
                continue
            t.cancel()
            try:
                await t
            except asyncio.CancelledError:
                pass


app = FastAPI(title="Tally Orchestrator", lifespan=lifespan)


@app.get("/metrics")
async def prometheus_metrics() -> Response:
    """Sprint 45: Prometheus-format metrics endpoint.

    Public (no auth) so any scrape pipeline can pull without
    juggling a bearer token.  Numbers are point-in-time SQL
    aggregates — cheap on the order of milliseconds even with
    thousands of rows because we lean on the existing indices.

    Exposed series (alphabetical):

      - tally_cost_micro_usd_total{kind=architect|agent|other}
      - tally_pool_joined            (gauge)
      - tally_pool_ready             (gauge 0/1)
      - tally_pool_target            (gauge)
      - tally_quota_exceeded_total   (counter, summed across users)
      - tally_tasks_total{status=pending|running|recovering|completed|failed}
      - tally_workers_active         (gauge)

    Operators wire these into Grafana / Datadog / vendor-of-choice.
    No labels carry user_id — privacy + cardinality both win.
    """
    db: Db = state["db"]
    pool_status = state.get("pool_status") or {}
    lines: list[str] = []

    def _add(name: str, help_text: str, kind: str, samples: list[tuple[dict, float]]) -> None:
        lines.append(f"# HELP {name} {help_text}")
        lines.append(f"# TYPE {name} {kind}")
        for labels, value in samples:
            label_str = (
                "{" + ",".join(f'{k}="{v}"' for k, v in labels.items()) + "}"
                if labels else ""
            )
            lines.append(f"{name}{label_str} {value}")

    _add(
        "tally_pool_ready", "1 when at least one worker joined and the processor loop is running",
        "gauge", [({}, 1 if state.get("pool_ready") else 0)],
    )
    _add(
        "tally_pool_target", "Desired pool size from TALLY_POOL_SIZE.",
        "gauge", [({}, pool_status.get("target_size", 0))],
    )
    _add(
        "tally_pool_joined", "Workers that completed MLS bootstrap this attempt.",
        "gauge", [({}, pool_status.get("joined", 0))],
    )

    # Task counts by status — one indexed SELECT.
    rows = db._conn.execute(
        "SELECT status, COUNT(*) FROM tasks GROUP BY status"
    ).fetchall()
    _add(
        "tally_tasks_total", "Total tasks broken down by status.",
        "gauge", [({"status": r[0]}, r[1]) for r in rows] or [({"status": "none"}, 0)],
    )

    # Cost totals by kind.
    rows = db._conn.execute(
        "SELECT kind, COALESCE(SUM(cost_micro_usd), 0) FROM cost_events GROUP BY kind"
    ).fetchall()
    _add(
        "tally_cost_micro_usd_total",
        "Cumulative LLM cost in micro-USD broken down by call kind.",
        "counter",
        [({"kind": r[0]}, r[1]) for r in rows] or [({"kind": "none"}, 0)],
    )

    # Workers active.
    workers_active = len(db.list_active_workers())
    _add(
        "tally_workers_active", "Workers in `active` state in the worker pool DB.",
        "gauge", [({}, workers_active)],
    )

    # Quota-exceeded counter.  Approximation: count rows where used >= cap.
    # The actual 429 event count would need its own counter table; this
    # gauge tells operators "N users are at their cap right now."
    rows = db._conn.execute(
        "SELECT COUNT(*) FROM quotas WHERE period_tasks_used >= 25 AND plan = 'free'"
    ).fetchall()
    _add(
        "tally_quota_at_cap_users", "Users whose period_tasks_used >= free-tier cap (25).",
        "gauge", [({}, rows[0][0] if rows else 0)],
    )

    return Response(content="\n".join(lines) + "\n", media_type="text/plain; version=0.0.4")


@app.get("/admin/alerts", dependencies=[Depends(require_token)])
async def admin_alerts() -> dict:
    """Sprint 45: hand-rolled summary of operational concerns the
    operator should look at right now.  Cheaper than wiring full
    Grafana alerts; lets the operator pipe ``curl /admin/alerts | jq``
    into a Slack notifier or whatever.  Admin-only since the
    error-string field could leak internal details.

    Each entry: ``{severity, code, message, value}`` where severity
    is ``info | warn | crit``.
    """
    db: Db = state["db"]
    pool_status = state.get("pool_status") or {}
    alerts: list[dict] = []

    if not state.get("pool_ready"):
        sev = "crit" if pool_status.get("last_error") else "warn"
        alerts.append({
            "severity": sev,
            "code": "pool_not_ready",
            "message": "Worker pool not ready; /tasks is 503'ing.",
            "value": pool_status.get("last_error") or "still bootstrapping",
        })

    cb: ClerkBillingClient | None = state.get("clerk_billing")  # type: ignore
    if cb is not None and not cb.webhook_enabled:
        alerts.append({
            "severity": "info",
            "code": "clerk_webhook_unset",
            "message": "CLERK_WEBHOOK_SECRET unset; /webhooks/clerk will 503.",
            "value": None,
        })

    cm: CredentialsManager | None = state.get("credentials")  # type: ignore
    if cm is not None and not cm.configured:
        alerts.append({
            "severity": "info",
            "code": "credentials_key_unset",
            "message": "CREDENTIALS_KEY unset; /github/* routes will 503.",
            "value": None,
        })

    backed = state.get("clerk_backend")
    if backed is not None and not backed.configured:  # type: ignore[union-attr]
        alerts.append({
            "severity": "info",
            "code": "clerk_secret_key_unset",
            "message": "CLERK_SECRET_KEY unset; project push falls back to PAT-only.",
            "value": None,
        })

    # Tasks stuck in `recovering` for > 1h indicate a worker that
    # silently stopped sending result events.
    cutoff = time.time() - 3600
    stuck = db._conn.execute(
        "SELECT COUNT(*) FROM tasks WHERE status='recovering' AND updated_at < ?",
        (cutoff,),
    ).fetchone()
    if stuck and stuck[0] > 0:
        alerts.append({
            "severity": "warn",
            "code": "tasks_stuck_recovering",
            "message": "Tasks stuck in `recovering` for >1h — workers may be silently dropping result events.",
            "value": stuck[0],
        })

    # Pool bootstrap last_error sticky → surface for retry-not-yet-succeeded state.
    if pool_status.get("last_error") and state.get("pool_ready"):
        # Cleared after success; this is here for completeness.
        pass

    return {"alerts": alerts, "count": len(alerts)}


@app.get("/health")
async def health() -> dict:
    """Sprint 35: surface pool readiness alongside basic liveness so
    operators + the Flutter shell can render a "workers warming up"
    banner during cold-start instead of staring at a generic 503.

    Returns:
      status:           "ok"      — always (we're alive serving HTTP)
      pool_ready:       bool      — workers joined and processor loop running
      pool_target:      int       — desired pool size from TALLY_POOL_SIZE
      pool_joined:      int       — workers that completed MLS bootstrap
      pool_last_error:  str|None  — last bootstrap failure reason (cleared on success)
      tasks_in_flight:  bool      — preserved from earlier versions
    """
    pool_status = state.get("pool_status") or {}
    return {
        "status": "ok",
        "pool_ready": bool(state.get("pool_ready")),
        "pool_target": pool_status.get("target_size", 0),
        "pool_joined": pool_status.get("joined", 0),
        "pool_last_error": pool_status.get("last_error"),
        "tasks_in_flight": state["db"].next_pending() is not None,
    }


@app.get("/whoami")
async def whoami(user: ClerkUser = Depends(require_user)) -> dict:
    """Sprint 32.5: return the caller's resolved identity. Useful for
    Flutter debug + confirming the bearer is what you expect. Cheap;
    no DB hit beyond the Clerk JWKS cache."""
    return {
        "id": user.id,
        "source": user.source,
        "email": user.email,
        "github": user.github,
    }


@app.post("/tasks", response_model=TaskResponse)
async def submit_task(
    body: TaskSubmit,
    user: ClerkUser = Depends(require_user),
) -> TaskResponse:
    # Sprint 35: gate on pool readiness.  Until the worker pool finishes
    # joining MLS, dispatching a task has nothing to land on — return
    # 503 with Retry-After so clients (and the Flutter shell) can show
    # a "workers warming up" hint and try again automatically.
    if not state.get("pool_ready"):
        ps = state.get("pool_status") or {}
        raise HTTPException(
            status_code=503,
            detail={
                "error": "pool_not_ready",
                "pool_target": ps.get("target_size", 0),
                "pool_joined": ps.get("joined", 0),
                "last_error": ps.get("last_error"),
                "retry_after_seconds": 5,
            },
            headers={"Retry-After": "5"},
        )
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
            # Sprint 40: hand the architect THIS user's palette
            # (seeded roles + their custom roles).  Admin uses the
            # seeded-only palette.
            palette_scope = None if user.source == "admin" else user.id
            palette = db.list_agent_roles(user_id=palette_scope)
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
            # Sprint 39: pass a cost recorder so the architect's Red
            # Pill call surfaces token usage into cost_events.  Per-
            # agent worker cost is captured separately at result-event
            # time once workers start reporting `usage_tokens`.
            # Sprint 46: capture the event loop NOW (we're in async
            # context); the closure runs inside asyncio.to_thread where
            # asyncio.get_event_loop() raises on Python 3.10+.
            _loop_for_recorder = asyncio.get_running_loop()
            def _record_architect_cost(model: str, usage: dict) -> None:
                prompt = int(usage.get("prompt_tokens", 0) or 0)
                completion = int(usage.get("completion_tokens", 0) or 0)
                total = int(usage.get("total_tokens", prompt + completion) or 0)
                cost = compute_cost_micro_usd(model, prompt, completion)
                db.record_cost_event(
                    user_id=user.id,
                    kind="architect",
                    model=model,
                    prompt_tokens=prompt,
                    completion_tokens=completion,
                    total_tokens=total,
                    cost_micro_usd=cost,
                )
                logger.info(
                    "architect call: user=%s model=%s tokens=%d cost=%s",
                    user.id, model, total, format_micro_usd(cost),
                )
                # Sprint 46: Checkpoint 7 — evaluate alert rules after each
                # architect cost event.  _record_architect_cost runs inside
                # asyncio.to_thread so we must use call_soon_threadsafe to
                # schedule coroutines back on the event loop.
                # Worker-side wiring deferred to A18.
                try:
                    from .notifications import evaluate_rules_for_cost_event, fan_out_push
                    fired = evaluate_rules_for_cost_event(db, user.id)
                    for f in fired:
                        _loop_for_recorder.call_soon_threadsafe(
                            asyncio.create_task,
                            fan_out_push(db, user.id, f["id"]),
                        )
                except Exception as exc:
                    logger.warning("alert evaluation raised: %s", exc)

            plan_caps_for_arch = QUOTA_PLANS.get(user.plan or "free", QUOTA_PLANS["free"])
            team_spec = await asyncio.to_thread(
                architect_team,
                description=body.description,
                palette=palette,
                redpill_key=orch.redpill_key,
                redpill_base=orch.redpill_base,
                templates=templates,
                cost_recorder=_record_architect_cost,
                model_allowlist=plan_caps_for_arch.get("model_allowlist"),
            )
            if isinstance(team_spec, dict) and team_spec.get("template_used"):
                db.touch_template(team_spec["template_used"], user_id=scope)
        except Exception as exc:
            logger.exception("architect call raised; falling back to single-agent: %s", exc)
            team_spec = None
    # Sprint 46: credit-based pre-submit gates.  Replace the old
    # task-count cap with credit-of-COGS accounting + daily/weekly
    # spend caps.  Admin's `unlimited` plan has 10**8 included
    # credits so this check is a no-op for them.
    quota = db.get_or_create_quota(user.id, plan_hint=user.plan)
    available = db.credits_available(user.id)
    if available <= 0:
        # Mode 3 (full auto unlimited) auto-tops-up before failing
        mode = int(quota.get("auto_recharge_mode") or 0)
        recharged = False
        if mode == 3:
            try:
                from .stripe_direct import trigger_auto_recharge_unlimited
                await trigger_auto_recharge_unlimited(db, user.id)
                recharged = True
            except Exception as exc:
                logger.warning("auto_recharge_unlimited failed for %s: %s", user.id, exc)
                raise HTTPException(
                    status_code=503,
                    detail={"error": "auto_recharge_payment_failed",
                            "message": "Stripe unreachable, retry shortly"},
                )
        elif mode == 2:
            try:
                from .stripe_direct import trigger_auto_recharge_capped
                if await trigger_auto_recharge_capped(db, user.id):
                    recharged = True
            except Exception as exc:
                logger.warning("auto_recharge_capped failed for %s: %s", user.id, exc)
        if not recharged:
            raise HTTPException(
                status_code=402,
                detail={
                    "error": "no_credits_remaining",
                    "plan": quota["plan"],
                    "available_credits": 0,
                    "overage_enabled": bool(quota.get("overage_enabled") or 0),
                    "upgrade_action": "open_pricing_table",
                },
            )
    # Daily cap (rolling 24h)
    daily_cap = quota.get("daily_spend_cap_credits")
    if daily_cap is not None and int(daily_cap) > 0:
        day_since = time.time() - 86400
        daily_used = db.credits_used_in_window(user.id, day_since)
        if daily_used >= int(daily_cap):
            raise HTTPException(
                status_code=402,
                detail={
                    "error": "daily_cap_reached",
                    "cap_credits": int(daily_cap),
                    "used_credits": daily_used,
                },
            )
    # Weekly cap (rolling 7d)
    weekly_cap = quota.get("weekly_spend_cap_credits")
    if weekly_cap is not None and int(weekly_cap) > 0:
        week_since = time.time() - 7 * 86400
        weekly_used = db.credits_used_in_window(user.id, week_since)
        if weekly_used >= int(weekly_cap):
            raise HTTPException(
                status_code=402,
                detail={
                    "error": "weekly_cap_reached",
                    "cap_credits": int(weekly_cap),
                    "used_credits": weekly_used,
                },
            )
    # Sprint 46: Checkpoint 4 — estimated-cost pre-check.  If the team
    # team_spec's estimated cost exceeds the user's per-task cap, try
    # rerouting to cheap models; if still over, abort with a 402
    # before we burn agent compute.
    from .cost_estimate import estimate_team_cost_credits, reroute_to_cheap_models
    if team_spec and team_spec.get("agents"):
        cap = db.effective_per_task_cap_credits(user.id)
        estimate = estimate_team_cost_credits(team_spec, len(body.description))
        if estimate["total_credits"] > cap:
            # Try one re-route pass to llama-only
            cheap_allowlist = {"meta-llama/llama-3.3-70b-instruct"}
            team_spec = reroute_to_cheap_models(team_spec, cheap_allowlist)
            estimate = estimate_team_cost_credits(team_spec, len(body.description))
        if estimate["total_credits"] > cap:
            raise HTTPException(
                status_code=402,
                detail={
                    "error": "task_cap_estimated_exceeds",
                    "estimated_credits": estimate["total_credits"],
                    "cap_credits": cap,
                    "per_agent": estimate["per_agent"],
                },
            )
    # Sprint 37: validate project_id (if supplied) before binding the
    # task to it.  Owner-scoped so a Clerk user can't smuggle their
    # task into someone else's project.
    if body.project_id is not None:
        scope = None if user.source == "admin" else user.id
        proj = db.get_project(body.project_id, user_id=scope)
        if proj is None:
            raise HTTPException(
                404, f"project `{body.project_id}` not found or not owned by you",
            )
    # Sprint 41: validate parent_task_id.  Parent must exist + be
    # owned by the caller (or the caller must be admin) + be in a
    # state that's safe to inherit from (completed; in-flight parents
    # would race the child's seed hydration).
    if body.parent_task_id is not None:
        parent_scope = None if user.source == "admin" else user.id
        parent = db.get_task(body.parent_task_id, user_id=parent_scope)
        if parent is None:
            raise HTTPException(
                404, f"parent task `{body.parent_task_id}` not found or not owned by you",
            )
        if parent.get("status") != "completed":
            raise HTTPException(
                400,
                f"parent task `{body.parent_task_id}` has status "
                f"`{parent.get('status')}`; only completed tasks can seed a child.",
            )
    # Atomic insert with team_spec attached — no race window for the
    # processor to pick the task up as single-agent before team_spec
    # lands.
    task_id = db.create_task(
        body.description,
        team_spec=team_spec,
        user_id=user.id,
        project_id=body.project_id,
    )
    if body.parent_task_id is not None:
        db.link_tasks(parent_task_id=body.parent_task_id, child_task_id=task_id)
        logger.info(
            "task %s linked as child of parent=%s",
            task_id[:8], body.parent_task_id[:8],
        )
    db.increment_task_count(user.id)
    # Sprint 48 A6: insert a team_proposal message in the user's #general
    # channel so the Discord-shaped UI can show the proposed team and let
    # the user approve/edit/cancel before any agent is dispatched.
    # team_spec may be None when the client omits it and redpill is off;
    # only insert the proposal when there is a team to propose.
    if team_spec is not None:
        from .channels import insert_team_proposal_message
        msg_id = insert_team_proposal_message(
            db,
            task_id=task_id,
            user_id=user.id,
            description=body.description,
            team_spec=team_spec,
        )
        if msg_id > 0:
            row = db._conn.execute(
                "SELECT channel_id FROM messages WHERE id=?", (msg_id,)
            ).fetchone()
            if row:
                t = asyncio.create_task(_broadcast_new_message(row[0], msg_id))
                _background_tasks.add(t)
                t.add_done_callback(_background_tasks.discard)
    task = db.get_task(task_id)
    # Enrich the response with the parent/children edges so the
    # Flutter shell can render the relationship without an extra round
    # trip.
    task["parent_task_id"] = db.get_parent_task_id(task_id)
    task["child_task_ids"] = db.list_child_task_ids(task_id)
    return TaskResponse(**task)


@app.get("/tasks/{task_id}", response_model=TaskResponse)
async def get_task(
    task_id: str,
    user: ClerkUser = Depends(require_user),
) -> TaskResponse:
    scope = None if user.source == "admin" else user.id
    db: Db = state["db"]
    task = db.get_task(task_id, user_id=scope)
    if not task:
        raise HTTPException(404, f"task {task_id} not found")
    # Sprint 41: enrich with parent + children edges.
    task["parent_task_id"] = db.get_parent_task_id(task_id)
    task["child_task_ids"] = db.list_child_task_ids(task_id)
    return TaskResponse(**task)


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
    # Worker poller picks up status='pending' on its next tick.
    # If the orchestrator has an explicit kick method, use it for lower latency.
    orch = state.get("orchestrator")
    if orch is not None and hasattr(orch, "_kick_poller"):
        try:
            asyncio.create_task(orch._kick_poller())
        except Exception:
            pass  # kick is best-effort
    new_row = db._conn.execute(
        "SELECT id, status, team_spec FROM tasks WHERE id=?", (task_id,)
    ).fetchone()
    return {
        "id": new_row[0],
        "status": new_row[1],
        "team_spec": json.loads(new_row[2]) if new_row[2] else None,
    }


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
    # Update the team_proposal message's payload + re-broadcast
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
        t = asyncio.create_task(_broadcast_new_message(channel_id, msg_id))
        _background_tasks.add(t)
        t.add_done_callback(_background_tasks.discard)
    return {"id": task_id, "status": status, "team_spec": body.team_spec}


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


@app.get("/tasks/{task_id}/team")
async def get_task_team(
    task_id: str,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 22: return the team_spec + per-agent runtime state for a
    multi-agent task. Powers the Discord-shaped task view's members
    sidebar (Sprint 25). Returns {team_spec: null, agents: []} for
    single-agent tasks.

    Sprint 32.5: per-user scoping — Clerk users only see their own
    tasks; admin sees all."""
    db: Db = state["db"]
    scope = None if user.source == "admin" else user.id
    task = db.get_task(task_id, user_id=scope)
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


# ── Sprint 37: persistent projects ────────────────────────────────────────────


class ProjectCreate(BaseModel):
    name: str
    description: str | None = None


class ProjectPatch(BaseModel):
    """Partial update.  Either or both fields may be supplied."""
    name: str | None = None
    description: str | None = None


@app.post("/projects")
async def create_project(
    body: ProjectCreate,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Create a persistent project.  Tasks created with this
    ``project_id`` will inherit the project's HEAD artifact set on
    their first agent and merge successful artifacts back on
    completion."""
    db: Db = state["db"]
    name = (body.name or "").strip()
    if not name:
        raise HTTPException(400, "name is required")
    if len(name) > 64:
        raise HTTPException(400, "name must be ≤64 chars")
    project_id = db.create_project(
        user_id=user.id, name=name, description=(body.description or None),
    )
    logger.info("project created: id=%s name=%r owner=%s", project_id, name, user.id)
    return db.get_project(project_id) or {"id": project_id, "name": name}


@app.get("/projects")
async def list_projects(user: ClerkUser = Depends(require_user)) -> dict:
    """List the caller's projects.  Admin sees all."""
    scope = None if user.source == "admin" else user.id
    return {"projects": state["db"].list_projects(user_id=scope)}


@app.get("/projects/{project_id}")
async def get_project(project_id: str, user: ClerkUser = Depends(require_user)) -> dict:
    scope = None if user.source == "admin" else user.id
    proj = state["db"].get_project(project_id, user_id=scope)
    if proj is None:
        raise HTTPException(404, f"project `{project_id}` not found")
    return proj


@app.patch("/projects/{project_id}")
async def update_project(
    project_id: str,
    body: ProjectPatch,
    user: ClerkUser = Depends(require_user),
) -> dict:
    scope = None if user.source == "admin" else user.id
    # Sanitise name when supplied.
    name: str | None = None
    if body.name is not None:
        name = body.name.strip()
        if not name:
            raise HTTPException(400, "name is empty after strip")
        if len(name) > 64:
            raise HTTPException(400, "name must be ≤64 chars")
    proj = state["db"].update_project(
        project_id, user_id=scope, name=name, description=body.description,
    )
    if proj is None:
        raise HTTPException(404, f"project `{project_id}` not found")
    return proj


@app.delete("/projects/{project_id}")
async def delete_project(project_id: str, user: ClerkUser = Depends(require_user)) -> dict:
    scope = None if user.source == "admin" else user.id
    if not state["db"].delete_project(project_id, user_id=scope):
        raise HTTPException(404, f"project `{project_id}` not found")
    logger.info("project deleted: id=%s owner=%s", project_id, user.id)
    return {"deleted": project_id}


# ── Sprint 38: GitHub PAT + project push ──────────────────────────────────────


class GithubTokenSet(BaseModel):
    pat: str


class GithubPush(BaseModel):
    """Body for ``POST /projects/{id}/push``."""
    repo: str  # "owner/repo"
    branch: str | None = None  # default: tally/push-<unix-ts>
    commit_message: str | None = None  # default: "Push from Tally project ..."


def _require_credentials_configured() -> CredentialsManager:
    cm: CredentialsManager = state.get("credentials")  # type: ignore
    if cm is None or not cm.configured:
        raise HTTPException(
            status_code=503,
            detail=(
                "Credentials store not configured on this orchestrator. "
                + fernet_key_help()
            ),
        )
    return cm


@app.post("/github/token")
async def set_github_token(
    body: GithubTokenSet,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Store an encrypted GitHub PAT for the caller.  The PAT is
    Fernet-encrypted before persisting; we never log any byte of
    it (see ``credentials.redact_token``).

    Validation is shallow — we don't call GitHub's API to verify
    the token here (would block the request on network).  The next
    ``POST /projects/{id}/push`` will surface a clean auth error if
    the PAT is bad.
    """
    cm = _require_credentials_configured()
    pat = (body.pat or "").strip()
    if not pat:
        raise HTTPException(400, "pat is empty")
    if len(pat) > 256:
        raise HTTPException(400, "pat is implausibly long; check that you pasted only the token")
    # Light shape check: github tokens start with one of these prefixes.
    if not (pat.startswith("ghp_") or pat.startswith("github_pat_") or pat.startswith("gho_")):
        logger.info(
            "github_pat for user=%s has unrecognised prefix; storing anyway %s",
            user.id, redact_token(pat),
        )
    db: Db = state["db"]
    db.put_credential(user_id=user.id, kind="github_pat", ciphertext=cm.encrypt(pat))
    logger.info("stored github_pat for user=%s (%s)", user.id, redact_token(pat))
    return {"stored": True}


@app.get("/github/token")
async def get_github_token_status(user: ClerkUser = Depends(require_user)) -> dict:
    """Boolean check: does the caller have a stored PAT?  We never
    return the token itself.  Drives the "Connected to GitHub"
    indicator in the Flutter settings UI."""
    db: Db = state["db"]
    return {"has_token": db.has_credential(user_id=user.id, kind="github_pat")}


@app.delete("/github/token")
async def delete_github_token(user: ClerkUser = Depends(require_user)) -> dict:
    db: Db = state["db"]
    if not db.delete_credential(user_id=user.id, kind="github_pat"):
        raise HTTPException(404, "no GitHub token stored for this user")
    return {"deleted": True}


@app.post("/projects/{project_id}/push")
async def push_project_to_github(
    project_id: str,
    body: GithubPush,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Push the project's HEAD artifact set to ``owner/repo`` as a
    new branch.

    Sprint 38.5 — credential source priority:

      1. **Clerk-mediated GitHub OAuth** (preferred): fetched at push
         time from Clerk's Backend API.  Zero user friction for anyone
         signed in via "Continue with GitHub".  Requires the Clerk
         GitHub provider to grant ``repo`` scope.
      2. **Stored PAT** (fallback): the Fernet-encrypted PAT from
         Sprint 38.  Used when:
           - Clerk Backend isn't configured (``CLERK_SECRET_KEY`` unset),
           - the user has no GitHub OAuth connection, or
           - the Clerk OAuth token push failed with 401 (insufficient
             scope) and a PAT IS stored.

    The Flutter UI surfaces both states via ``GET /github/connection-status``.
    Errors map to:
      - 400: malformed inputs (bad repo, empty branch, etc.).
      - 401: every available credential rejected by GitHub.
      - 404: project not found / not owned, OR no credentials available.
      - 502: any other git push failure.
    """
    db: Db = state["db"]
    scope = None if user.source == "admin" else user.id
    project = db.get_project(project_id, user_id=scope)
    if project is None:
        raise HTTPException(404, f"project `{project_id}` not found")

    # Validate the repo shape early so we don't even decrypt the PAT
    # if the input is garbage.
    try:
        repo = validate_repo(body.repo)
    except GithubPushError as exc:
        raise HTTPException(400, exc.user_facing)

    artifacts = db.load_project_artifacts(project_id)
    if not artifacts:
        raise HTTPException(400, "project has no files in HEAD to push")

    # Build the credential queue.  Try Clerk-mediated OAuth first;
    # PAT is the fallback.
    clerk_backend: ClerkBackendClient = state.get("clerk_backend")  # type: ignore
    cm: CredentialsManager = state.get("credentials")  # type: ignore

    credentials_to_try: list[tuple[str, str]] = []  # [(source_label, token), ...]

    if user.source != "admin" and clerk_backend is not None and clerk_backend.configured:
        try:
            oauth_token, oauth_scopes = await asyncio.to_thread(
                clerk_backend.fetch_github_token, user.id,
            )
            if oauth_token:
                logger.info(
                    "push %s: Clerk GitHub OAuth token available for user=%s scopes=%s",
                    project_id, user.id, oauth_scopes,
                )
                credentials_to_try.append(("clerk_oauth", oauth_token))
        except Exception as exc:
            logger.warning("Clerk OAuth fetch raised; falling through to PAT: %s", exc)

    if cm is not None and cm.configured:
        ciphertext = db.get_credential(user_id=user.id, kind="github_pat")
        if ciphertext is not None:
            try:
                pat = cm.decrypt(ciphertext)
                credentials_to_try.append(("stored_pat", pat))
            except Exception as exc:
                logger.exception("decrypt failed for user=%s: %s", user.id, exc)

    if not credentials_to_try:
        raise HTTPException(
            404,
            "no GitHub credentials available for this user. "
            "Sign in with GitHub (granting `repo` scope), or POST a PAT "
            "to /github/token.",
        )

    last_auth_err: str | None = None
    last_other_err: Exception | None = None

    for source_label, token in credentials_to_try:
        try:
            result = await asyncio.to_thread(
                push_project,
                project_name=project["name"],
                artifacts=artifacts,
                repo=repo,
                branch=body.branch,
                commit_message=body.commit_message,
                pat=token,
            )
            logger.info(
                "pushed project=%s for user=%s via %s → %s @ %s (sha=%s)",
                project_id, user.id, source_label,
                result.repo, result.branch, result.commit_sha[:8],
            )
            return {
                "repo": result.repo,
                "branch": result.branch,
                "commit_sha": result.commit_sha,
                "branch_url": result.branch_url,
                "credential_source": source_label,
            }
        except GithubPushAuthError as exc:
            last_auth_err = exc.user_facing
            logger.info(
                "push %s: %s rejected by GitHub; trying next credential",
                project_id, source_label,
            )
            continue
        except GithubPushRepoError as exc:
            # Repo-not-found is terminal — won't fix by switching credential.
            logger.warning(
                "push %s via %s: repo error — %s",
                project_id, source_label, exc,
            )
            raise HTTPException(404, exc.user_facing)
        except GithubPushError as exc:
            last_other_err = exc
            continue

    # Exhausted all sources without a success.
    if last_auth_err is not None:
        raise HTTPException(
            401,
            last_auth_err + " (Clerk OAuth token may lack `repo` scope — "
            "either reconnect GitHub with `repo` scope at sign-in, "
            "or POST a PAT to /github/token as a fallback.)",
        )
    detail = str(last_other_err) if last_other_err else "all credential sources failed"
    raise HTTPException(502, detail)


@app.get("/github/connection-status")
async def github_connection_status(
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 38.5: surface which credential sources are available to
    this user, without revealing tokens.  Drives the Flutter "GitHub
    connected via sign-in / Connect manually" UI.

    Returns:
      - ``clerk_oauth_available``: True when Clerk Backend is configured
        AND the user has a GitHub OAuth connection.  We don't try to
        validate the token's scopes here (would require a GitHub API
        call); the push endpoint surfaces the real result.
      - ``pat_stored``: True when a Fernet-encrypted PAT row exists.
    """
    db: Db = state["db"]
    clerk_backend: ClerkBackendClient = state.get("clerk_backend")  # type: ignore
    cm: CredentialsManager = state.get("credentials")  # type: ignore

    clerk_oauth_available = False
    oauth_scopes: list[str] = []
    if user.source != "admin" and clerk_backend is not None and clerk_backend.configured:
        try:
            token, oauth_scopes = await asyncio.to_thread(
                clerk_backend.fetch_github_token, user.id,
            )
            clerk_oauth_available = token is not None
        except Exception as exc:
            logger.debug("Clerk OAuth status probe failed: %s", exc)

    pat_stored = False
    if cm is not None and cm.configured:
        pat_stored = db.has_credential(user_id=user.id, kind="github_pat")

    return {
        "clerk_oauth_available": clerk_oauth_available,
        "clerk_oauth_scopes": oauth_scopes,
        "pat_stored": pat_stored,
    }


# ── Sprint 34: template edit + share-with-link ────────────────────────────────


class TemplatePatch(BaseModel):
    """Partial update.  Every field is optional; omitted = leave alone."""
    new_name: str | None = None
    team_spec: dict | None = None
    note: str | None = None


@app.patch("/templates/{name}")
async def update_template(
    name: str,
    body: TemplatePatch,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Patch an existing template's name / team_spec / note.

    All three fields are optional — pass only what you want changed.
    Rename collisions return 409.  Owner-scoped (admin sees all)."""
    db: Db = state["db"]
    scope = None if user.source == "admin" else user.id
    # Sanitise new_name if provided (same rules as create_template).
    new_name: str | None = None
    if body.new_name is not None:
        clean = body.new_name.strip()
        if not clean:
            raise HTTPException(400, "new_name is empty after strip")
        if len(clean) > 64 or "/" in clean or any(ord(c) < 32 for c in clean):
            raise HTTPException(
                400, "new_name must be ≤64 chars and contain no `/` or control chars",
            )
        new_name = clean
    # Light shape check on team_spec when supplied.
    if body.team_spec is not None:
        agents = body.team_spec.get("agents")
        if not isinstance(agents, list) or not agents:
            raise HTTPException(400, "team_spec.agents must be a non-empty list")
        for a in agents:
            if not isinstance(a, dict) or not isinstance(a.get("role"), str):
                raise HTTPException(400, "each agent needs a `role` string")
    try:
        updated = db.update_template(
            name,
            user_id=scope,
            new_name=new_name,
            team_spec=body.team_spec,
            note=body.note,
        )
    except sqlite3.IntegrityError:
        raise HTTPException(409, f"template `{new_name}` already exists")
    if updated is None:
        raise HTTPException(404, f"template `{name}` not found")
    logger.info("template patched: name=%r new_name=%r owner=%s",
                name, new_name, user.id)
    return updated


@app.post("/templates/{name}/share")
async def share_template(
    name: str, user: ClerkUser = Depends(require_user)
) -> dict:
    """Mint (or return the existing) share token for this template.

    The returned ``share_url`` is a public, anonymous-readable link
    that resolves to a read-only view of the team_spec via
    ``GET /shared-templates/{token}``.  Idempotent: calling twice
    returns the same token until ``DELETE /templates/{name}/share``
    rotates it."""
    db: Db = state["db"]
    scope = None if user.source == "admin" else user.id
    token = db.ensure_share_token(name, user_id=scope)
    if token is None:
        raise HTTPException(404, f"template `{name}` not found")
    # The orchestrator doesn't know its public base URL; clients
    # construct the share URL themselves from the token + their
    # configured base URL.  We surface the token + a relative path
    # so the Flutter app can build the canonical URL.
    return {"name": name, "share_token": token, "share_path": f"/shared-templates/{token}"}


@app.delete("/templates/{name}/share")
async def revoke_share_token(
    name: str, user: ClerkUser = Depends(require_user)
) -> dict:
    """Revoke the current share token.  Returns 404 if there's nothing
    to revoke (template missing or no token set).  After revocation,
    ``POST /templates/{name}/share`` mints a fresh one."""
    db: Db = state["db"]
    scope = None if user.source == "admin" else user.id
    if not db.delete_share_token(name, user_id=scope):
        raise HTTPException(404, f"no active share token for `{name}`")
    return {"name": name, "revoked": True}


@app.get("/shared-templates/{token}")
async def get_shared_template(token: str) -> dict:
    """Anonymous read-only template view.  No bearer required — the
    token is the credential.  Returns a stripped view: the user_id
    and source_task_id are omitted so the link doesn't leak
    cross-tenant metadata."""
    db: Db = state["db"]
    t = db.get_template_by_share_token(token)
    if t is None:
        raise HTTPException(404, "shared template not found or token revoked")
    # Strip per-tenant metadata from the public view.
    return {
        "name": t["name"],
        "team_spec": t["team_spec"],
        "note": t["note"],
        "created_at": t["created_at"],
        "use_count": t["use_count"],
    }


# ── Sprint 33-rest: Clerk Billing + quotas ────────────────────────────────────


@app.get("/billing/cost")
async def billing_cost(user: ClerkUser = Depends(require_user)) -> dict:
    """Sprint 39: per-period LLM cost for the calling user, broken
    down by kind (architect / agent / other) and by model.

    The window aligns with the quota period (Sprint 33) so the
    cost dashboard matches the tasks-this-period counter.  Numbers
    are estimates — Red Pill bills the orchestrator, not the user
    directly — but they're computed from real token counts that
    Red Pill returned in each chat-completions response.
    """
    db: Db = state["db"]
    quota = db.get_or_create_quota(user.id, plan_hint=user.plan)
    return db.cost_summary(user_id=user.id, since_ts=quota["period_start"])


# ── Sprint 50 A3: workspace create route ──────────────────────────────────────


@app.post("/workspaces")
async def create_workspace_route(
    body: WorkspaceCreateRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 50: create a workspace owned by the caller.
    Enforces 20-per-user soft cap (429 workspace_limit)."""
    db: Db = state["db"]
    existing = db._conn.execute(
        "SELECT COUNT(*) FROM workspaces WHERE owner_user_id=? AND deleted_at IS NULL",
        (user.id,),
    ).fetchone()[0]
    if existing >= 20:
        raise HTTPException(429, {"error": "workspace_limit", "limit": 20, "current": existing})
    name = body.name.strip()
    if not name:
        raise HTTPException(400, "workspace name required")
    wid = db.create_workspace(name=name, owner_user_id=user.id)
    try:
        db.audit_log(workspace_id=wid, actor_user_id=user.id, kind="workspace_created", payload={"name": name})
    except Exception as exc:
        logger.warning("audit_log workspace_created failed: %s", exc)
    return {"id": wid, "name": name, "role": "owner"}


class WorkspacePatchRequest(BaseModel):
    name: str | None = None
    settings: dict | None = None


@app.patch("/workspaces/{wid}")
async def patch_workspace_route(
    wid: int,
    body: WorkspacePatchRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 50: update workspace name and/or merge settings_json. Owner-only."""
    db: Db = state["db"]
    row = db._conn.execute(
        "SELECT owner_user_id, name, settings_json FROM workspaces WHERE id=? AND deleted_at IS NULL",
        (wid,),
    ).fetchone()
    if row is None:
        raise HTTPException(404, "workspace not found")
    owner, current_name, current_settings = row
    if owner != user.id:
        raise HTTPException(403, "owner only")
    sets: list[str] = []
    params: list = []
    if body.name is not None:
        sets.append("name=?")
        params.append(body.name.strip())
    if body.settings is not None:
        merged = json.loads(current_settings or "{}")
        merged.update(body.settings)
        sets.append("settings_json=?")
        params.append(json.dumps(merged))
    if not sets:
        return {"id": wid, "name": current_name}
    params.append(wid)
    db._conn.execute(f"UPDATE workspaces SET {', '.join(sets)} WHERE id=?", tuple(params))
    if body.name is not None and body.name.strip() != current_name:
        try:
            db.audit_log(workspace_id=wid, actor_user_id=user.id, kind="workspace_renamed",
                         payload={"old_name": current_name, "new_name": body.name.strip()})
        except Exception as exc:
            logger.warning("audit_log workspace_renamed failed: %s", exc)
    if body.settings is not None:
        try:
            db.audit_log(workspace_id=wid, actor_user_id=user.id, kind="workspace_settings_updated",
                         payload={"keys_changed": list(body.settings.keys())})
        except Exception as exc:
            logger.warning("audit_log workspace_settings_updated failed: %s", exc)
    return {"id": wid}


@app.get("/me/workspaces")
async def list_my_workspaces(
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 50: list all workspaces the caller is a member of."""
    db: Db = state["db"]
    rows = db._conn.execute(
        "SELECT w.id, w.name, wm.role, w.created_at "
        "FROM workspaces w JOIN workspace_members wm ON wm.workspace_id=w.id "
        "WHERE wm.user_id=? AND wm.member_kind='human' "
        "AND w.deleted_at IS NULL "
        "ORDER BY w.created_at ASC",
        (user.id,),
    ).fetchall()
    return {
        "workspaces": [
            {"id": r[0], "name": r[1], "role": r[2], "created_at": r[3]}
            for r in rows
        ],
    }


@app.get("/workspaces/{wid}/members")
async def list_workspace_members_route(
    wid: int,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 50: list workspace_members.  Member-only access (returns
    empty for non-members, doesn't leak workspace existence)."""
    db: Db = state["db"]
    is_member = db._conn.execute(
        "SELECT 1 FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human' LIMIT 1",
        (wid, user.id),
    ).fetchone()
    if not is_member:
        return {"members": []}
    return {"members": db.list_workspace_members(workspace_id=wid)}


@app.post("/workspaces/{wid}/members")
async def invite_workspace_member_route(
    wid: int,
    body: WorkspaceMemberInviteRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 50: invite a human to a workspace.  Admin+ only.
    Sprint 50 trusts the caller's user_id (no Clerk roundtrip)."""
    if body.role not in _VALID_WORKSPACE_ROLES:
        raise HTTPException(400, f"invalid role: {body.role}")
    if body.role == "owner":
        raise HTTPException(400, "cannot invite as owner; transfer ownership is Sprint 51")
    db: Db = state["db"]
    caller = db._conn.execute(
        "SELECT role FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (wid, user.id),
    ).fetchone()
    if caller is None:
        raise HTTPException(403, "not a member of this workspace")
    if caller[0] not in ("owner", "admin"):
        raise HTTPException(403, "admin+ only")
    db.add_workspace_member(workspace_id=wid, user_id=body.user_id, role=body.role)
    try:
        db.audit_log(workspace_id=wid, actor_user_id=user.id, kind="member_invited",
                     target_kind="member", target_id=body.user_id,
                     payload={"user_id": body.user_id, "role": body.role})
    except Exception as exc:
        logger.warning("audit_log member_invited failed: %s", exc)
    return {"ok": True, "workspace_id": wid, "user_id": body.user_id, "role": body.role}


@app.delete("/workspaces/{wid}/members/{target_user_id}")
async def remove_workspace_member_route(
    wid: int,
    target_user_id: str,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 50: remove a human member.  Admin+ only.  Cannot remove owner."""
    db: Db = state["db"]
    target = db._conn.execute(
        "SELECT role FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (wid, target_user_id),
    ).fetchone()
    if target is None:
        raise HTTPException(404, "member not found")
    if target[0] == "owner":
        raise HTTPException(400, "cannot remove the workspace owner")
    caller = db._conn.execute(
        "SELECT role FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (wid, user.id),
    ).fetchone()
    if caller is None or caller[0] not in ("owner", "admin"):
        raise HTTPException(403, "admin+ only")
    db.remove_workspace_member(workspace_id=wid, user_id=target_user_id)
    try:
        db.audit_log(workspace_id=wid, actor_user_id=user.id, kind="member_removed",
                     target_kind="member", target_id=target_user_id,
                     payload={"user_id": target_user_id})
    except Exception as exc:
        logger.warning("audit_log member_removed failed: %s", exc)
    return {"ok": True}


@app.patch("/workspaces/{wid}/members/{target_user_id}")
async def patch_workspace_member_role_route(
    wid: int,
    target_user_id: str,
    body: WorkspaceMemberRolePatchRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 50: change a member's role.
    - Owner can change any non-owner role.
    - Admin can change Manager/Member roles.
    - Cannot set role to/from 'owner' (ownership transfer is Sprint 51).
    """
    if body.role not in _VALID_WORKSPACE_ROLES:
        raise HTTPException(400, f"invalid role: {body.role}")
    if body.role == "owner":
        raise HTTPException(400, "ownership transfer is Sprint 51")
    db: Db = state["db"]
    target = db._conn.execute(
        "SELECT role FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (wid, target_user_id),
    ).fetchone()
    if target is None:
        raise HTTPException(404, "member not found")
    if target[0] == "owner":
        raise HTTPException(400, "cannot change the owner's role")
    caller = db._conn.execute(
        "SELECT role FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (wid, user.id),
    ).fetchone()
    if caller is None:
        raise HTTPException(403, "not a workspace member")
    if caller[0] not in ("owner", "admin"):
        raise HTTPException(403, "admin+ only")
    # Admin can only change Manager/Member roles
    if caller[0] == "admin" and target[0] not in ("manager", "member"):
        raise HTTPException(403, "admin can only change manager/member roles")
    old_role = target[0]
    if not db.update_workspace_member_role(workspace_id=wid, user_id=target_user_id, role=body.role):
        raise HTTPException(404, "member not found")
    try:
        db.audit_log(workspace_id=wid, actor_user_id=user.id, kind="member_role_changed",
                     target_kind="member", target_id=target_user_id,
                     payload={"user_id": target_user_id, "old_role": old_role, "new_role": body.role})
    except Exception as exc:
        logger.warning("audit_log member_role_changed failed: %s", exc)
    return {"ok": True, "role": body.role}


# ── Sprint 47 A4: channels routes ─────────────────────────────────────────────


@app.get("/channels")
async def list_workspace_channels(
    workspace_id: int,
    include_archived: bool = False,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 47: list channels in a workspace, filtered by the caller's
    visibility.  Only channels where the user is a `channel_members` row
    are returned (so private custom channels stay hidden).  Returns an
    empty list if the caller is not a member of the workspace at all
    (don't leak workspace existence)."""
    db: Db = state["db"]
    # Workspace-isolation guard: caller must be a workspace_members row.
    is_member = db._conn.execute(
        "SELECT 1 FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human' LIMIT 1",
        (workspace_id, user.id),
    ).fetchone()
    if not is_member:
        return {"channels": []}
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
    ws_row = db._conn.execute(
        "SELECT id FROM workspaces WHERE owner_user_id=? LIMIT 1", (user.id,)
    ).fetchone()
    if ws_row is None:
        raise HTTPException(404, "no workspace for caller")
    workspace_id = ws_row[0]
    from .channels import ensure_dm_channel, resolve_channel
    if body.target_kind == "tally":
        ch_id = ensure_dm_channel(
            db, workspace_id=workspace_id,
            kind_a="human", id_a=user.id,
            kind_b="tally", id_b=None,
        )
    elif body.target_kind == "human":
        if not body.target_id:
            raise HTTPException(400, "target_id required for human DM")
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
    return resolve_channel(db, ch_id)


@app.post("/channels")
async def create_custom_channel_route(
    body: CustomChannelCreateRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 50: create a custom channel.  Admin+ only.

    Only kind='custom' is accepted; attempting another kind returns 400.
    Members are inserted atomically in the same transaction.

    Example::

        POST /channels
        {
            "workspace_id": 1, "kind": "custom", "name": "code-review",
            "members": [{"kind": "human", "id": "alice"}, {"kind": "tally"}]
        }
    """
    if body.kind != "custom":
        raise HTTPException(400, f"Sprint 50 only supports kind='custom'; got {body.kind!r}")
    db: Db = state["db"]
    caller = db._conn.execute(
        "SELECT role FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (body.workspace_id, user.id),
    ).fetchone()
    if caller is None or caller[0] not in ("owner", "admin"):
        raise HTTPException(403, "admin+ only")
    name = body.name.strip()
    if not name:
        raise HTTPException(400, "name required")
    now = time.time()
    cur = db._conn.execute(
        "INSERT INTO channels (workspace_id, kind, name, created_at) "
        "VALUES (?, 'custom', ?, ?)",
        (body.workspace_id, name, now),
    )
    ch_id = int(cur.lastrowid or 0)
    for m in body.members:
        if m.kind == "human":
            db._conn.execute(
                "INSERT INTO channel_members (channel_id, member_kind, user_id, joined_at) "
                "VALUES (?, 'human', ?, ?)",
                (ch_id, m.id, now),
            )
        elif m.kind == "tally":
            db._conn.execute(
                "INSERT INTO channel_members (channel_id, member_kind, user_id, joined_at) "
                "VALUES (?, 'tally', NULL, ?)",
                (ch_id, now),
            )
        elif m.kind == "persistent_agent":
            pa_id = int(m.id) if m.id else None
            db._conn.execute(
                "INSERT INTO channel_members "
                "(channel_id, member_kind, persistent_agent_id, joined_at) "
                "VALUES (?, 'persistent_agent', ?, ?)",
                (ch_id, pa_id, now),
            )
    try:
        db.audit_log(workspace_id=body.workspace_id, actor_user_id=user.id, kind="channel_created",
                     target_kind="channel", target_id=str(ch_id),
                     payload={"channel_id": ch_id, "kind": "custom", "name": name})
    except Exception as exc:
        logger.warning("audit_log channel_created failed: %s", exc)
    from .channels import resolve_channel
    return resolve_channel(db, ch_id)


@app.post("/channels/{channel_id}/members")
async def add_channel_member_route(
    channel_id: int,
    body: ChannelMemberAddRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 50: add a member to a custom channel.  Admin+ only.

    Returns 400 if the channel is not of kind='custom' (general / task /
    scheduled_agent channels manage their own membership automatically).

    Example::

        POST /channels/42/members
        {"member_kind": "human", "user_id": "bob"}
    """
    db: Db = state["db"]
    ch = db._conn.execute(
        "SELECT workspace_id, kind FROM channels WHERE id=? AND archived_at IS NULL",
        (channel_id,),
    ).fetchone()
    if ch is None:
        raise HTTPException(404, "channel not found")
    if ch[1] != "custom":
        raise HTTPException(400, "only custom channels can have members added directly")
    caller = db._conn.execute(
        "SELECT role FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (ch[0], user.id),
    ).fetchone()
    if caller is None or caller[0] not in ("owner", "admin"):
        raise HTTPException(403, "admin+ only")
    now = time.time()
    db._conn.execute(
        "INSERT INTO channel_members "
        "(channel_id, member_kind, user_id, persistent_agent_id, joined_at) "
        "VALUES (?, ?, ?, ?, ?)",
        (channel_id, body.member_kind, body.user_id, body.persistent_agent_id, now),
    )
    return {"ok": True}


@app.delete("/channels/{channel_id}/members/{target_user_id}")
async def remove_channel_member_route(
    channel_id: int,
    target_user_id: str,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 50: remove a human member from a custom channel.  Admin+ only.

    Returns 400 for non-custom channels, 404 if the member isn't present.

    Example::

        DELETE /channels/42/members/bob
    """
    db: Db = state["db"]
    ch = db._conn.execute(
        "SELECT workspace_id, kind FROM channels WHERE id=?",
        (channel_id,),
    ).fetchone()
    if ch is None:
        raise HTTPException(404, "channel not found")
    if ch[1] != "custom":
        raise HTTPException(400, "only custom channels support member removal")
    caller = db._conn.execute(
        "SELECT role FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human'",
        (ch[0], user.id),
    ).fetchone()
    if caller is None or caller[0] not in ("owner", "admin"):
        raise HTTPException(403, "admin+ only")
    cur = db._conn.execute(
        "DELETE FROM channel_members WHERE channel_id=? AND user_id=?",
        (channel_id, target_user_id),
    )
    if cur.rowcount == 0:
        raise HTTPException(404, "member not in channel")
    return {"ok": True}


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


@app.post("/channels/{channel_id}/read")
async def post_channel_read(
    channel_id: int,
    body: ChannelReadRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 47: mark messages up to `last_read_message_id` as read for
    the caller in this channel.  Returns 403 if caller isn't a member.

    Uses MAX(last_read_message_id, ?) so out-of-order calls cannot
    regress the read pointer.
    """
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


_background_tasks: set[asyncio.Task] = set()


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

    For `kind='text'`, body.text is the required content.  If both
    `body.text` and `body.payload['text']` are provided, `body.text`
    wins and overwrites the payload field.

    TODO(Sprint 49): when private channels (DMs) land, consider
    collapsing the 404/403 paths into 403 to avoid leaking channel
    existence to non-members.
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
    row = db._conn.execute(
        "SELECT id, channel_id, author_kind, author_user_id, author_agent_id, "
        "kind, payload_json, reply_to_id, created_at, edited_at "
        "FROM messages WHERE id=?",
        (msg_id,),
    ).fetchone()
    # Sprint 47 Task A10 will broadcast over WebSocket here.
    # Hold a strong reference so the GC cannot collect the task before it runs.
    t = asyncio.create_task(_broadcast_new_message(channel_id, msg_id))
    _background_tasks.add(t)
    t.add_done_callback(_background_tasks.discard)
    return {
        "id": row[0], "channel_id": row[1], "author_kind": row[2],
        "author_user_id": row[3], "author_agent_id": row[4],
        "kind": row[5], "payload_json": row[6], "reply_to_id": row[7],
        "created_at": row[8], "edited_at": row[9],
    }


@app.get("/channels/{channel_id}/messages")
async def get_messages(
    channel_id: int,
    limit: int = Query(default=50, ge=1, le=200),
    since_id: int | None = Query(default=None, ge=1),
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 47: paginated message history.  Reverse chronological
    (newest first).  `since_id` returns messages with id > since_id
    (used by clients catching up after WebSocket reconnect).

    Permission: 404 if channel doesn't exist; 403 if caller is not a
    channel member.

    TODO(Sprint 49): when private channels (DMs) land, collapse 404/403
    into 403 to avoid leaking channel existence.
    """
    db: Db = state["db"]
    from .channels import resolve_channel, resolve_effective_role, list_messages
    if resolve_channel(db, channel_id) is None:
        raise HTTPException(404, f"channel {channel_id} not found")
    role = resolve_effective_role(db, channel_id=channel_id, user_id=user.id)
    if role is None:
        raise HTTPException(403, "permission denied — not a channel member")
    msgs = list_messages(db, channel_id=channel_id, limit=limit, since_id=since_id)
    return {"channel_id": channel_id, "messages": msgs}


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
    payload = json.loads(row[1])
    if body.payload:
        payload.update(body.payload)
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


async def _broadcast_new_message(channel_id: int, message_id: int) -> None:
    """Sprint 47 A10: send new_message events to every WebSocket subscribed
    to the user's notification feed where the user is a member of the channel.

    Re-uses the existing notifications WS registry (_ACTIVE_WS) from Sprint 46
    rather than introducing a new per-channel WebSocket type.
    Frame shape:
        {"type": "new_message", "channel_id": int, "message_id": int}
    """
    from .notifications import _ACTIVE_WS
    db: Db = state["db"]
    members = db._conn.execute(
        "SELECT DISTINCT user_id FROM channel_members "
        "WHERE channel_id=? AND user_id IS NOT NULL",
        (channel_id,),
    ).fetchall()
    user_ids = {m[0] for m in members}
    for user_id in user_ids:
        sockets = list(_ACTIVE_WS.get(user_id) or [])  # works for list or set
        for ws in sockets:
            try:
                await ws.send_json({
                    "type": "new_message",
                    "channel_id": channel_id,
                    "message_id": message_id,
                })
            except Exception as exc:
                logger.warning(
                    "ws send_new_message failed for user=%s: %s", user_id, exc
                )

    # Sprint 49: Tally escalation responder.  If the broadcast message is
    # kind='escalation', create a DM with the workspace owner + post the
    # templated Tally message.
    try:
        msg_row = db._conn.execute(
            "SELECT kind FROM messages WHERE id=?", (message_id,)
        ).fetchone()
        if msg_row and msg_row[0] == "escalation":
            from .channels import handle_escalation
            dm_ch = handle_escalation(db, channel_id=channel_id, message_id=message_id)
            if dm_ch:
                new_msg = db._conn.execute(
                    "SELECT id FROM messages WHERE channel_id=? ORDER BY id DESC LIMIT 1",
                    (dm_ch,),
                ).fetchone()
                if new_msg:
                    # Re-enter broadcast for the DM message.  Bounded:
                    # the new message is kind='text', not 'escalation',
                    # so this won't recurse further.
                    await _broadcast_new_message(dm_ch, new_msg[0])
    except Exception as exc:
        logger.warning("escalation handler failed: %s", exc)


# ── Sprint 49: persistent_agents routes ───────────────────────────────────────


@app.post("/persistent_agents")
async def create_persistent_agent_route(
    body: PersistentAgentCreateRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 49: create a persistent agent + scheduled_agent channel.
    Caller must be a workspace_member of the target workspace."""
    db: Db = state["db"]
    is_member = db._conn.execute(
        "SELECT 1 FROM workspace_members "
        "WHERE workspace_id=? AND user_id=? AND member_kind='human' LIMIT 1",
        (body.workspace_id, user.id),
    ).fetchone()
    if not is_member:
        raise HTTPException(403, "not a member of this workspace")
    # Sprint 49: server generates id + HMAC secret for new HTTP triggers
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
    try:
        db.audit_log(workspace_id=body.workspace_id, actor_user_id=user.id,
                     kind="persistent_agent_created",
                     target_kind="persistent_agent", target_id=str(pid),
                     payload={"agent_id": pid, "name": body.name, "role_name": body.role_name})
    except Exception as exc:
        logger.warning("audit_log persistent_agent_created failed: %s", exc)
    return db.get_persistent_agent(pid)


@app.get("/persistent_agents")
async def list_persistent_agents_route(
    workspace_id: int,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 49: list active persistent agents in a workspace.
    Returns empty list if caller isn't a member (workspace-isolation
    pattern from Sprint 47 GET /channels)."""
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
    """Sprint 49: partial update.  Owner-only via workspace membership.
    Recomputes next_scheduled_run_at if cron_schedule changes."""
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
    patch = body.model_dump(exclude_unset=True)
    db.update_persistent_agent(pid, patch=patch)
    if body.enabled is not None and bool(body.enabled) != bool(agent.get("enabled")):
        try:
            db.audit_log(workspace_id=agent["workspace_id"], actor_user_id=user.id,
                         kind="persistent_agent_enabled_toggled",
                         target_kind="persistent_agent", target_id=str(pid),
                         payload={"agent_id": pid, "name": agent["name"], "enabled": bool(body.enabled)})
        except Exception as exc:
            logger.warning("audit_log persistent_agent_enabled_toggled failed: %s", exc)
    return db.get_persistent_agent(pid)


@app.post("/persistent_agents/{pid}/run_now")
async def run_persistent_agent_now_route(
    pid: int,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 49: manually fire a persistent agent.  Workspace-member only."""
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
    orch: "Orchestrator" = state.get("orchestrator")
    if orch is None:
        raise HTTPException(503, "orchestrator not ready")
    task_id = await orch._fire_persistent_agent(pid, trigger="manual")
    return {"ok": True, "task_id": task_id, "persistent_agent_id": pid}


@app.delete("/persistent_agents/{pid}")
async def delete_persistent_agent_route(
    pid: int,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 49: soft-delete a persistent agent."""
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
    try:
        db.audit_log(workspace_id=agent["workspace_id"], actor_user_id=user.id,
                     kind="persistent_agent_deleted",
                     target_kind="persistent_agent", target_id=str(pid),
                     payload={"agent_id": pid, "name": agent["name"]})
    except Exception as exc:
        logger.warning("audit_log persistent_agent_deleted failed: %s", exc)
    return {"ok": True}


# ── Sprint 46 A12: credit balance, caps, checkout, auto-recharge ──────────────


@app.get("/billing/credits")
async def get_credits_balance(
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 46: credit balance + plan summary for the billing screen."""
    db: Db = state["db"]
    quota = db.get_or_create_quota(user.id, plan_hint=user.plan)
    plan = QUOTA_PLANS.get(quota["plan"], QUOTA_PLANS["free"])
    used = db.credits_used_this_period(user.id, quota["period_start"])
    available = db.credits_available(user.id)
    return {
        "plan": quota["plan"],
        "plan_label": plan["label"],
        "is_beta": plan.get("is_beta", False),
        "period_start": quota["period_start"],
        "included_credits": plan["included_credits"],
        "used_credits": used,
        "available_credits": available,
        "prepaid_credit_balance": int(quota.get("prepaid_credit_balance") or 0),
        "overage_enabled": bool(quota.get("overage_enabled") or 0),
        "auto_recharge_mode": int(quota.get("auto_recharge_mode") or 0),
        "auto_recharge_block_credits": int(quota.get("auto_recharge_block_credits") or 500),
        "auto_recharge_monthly_cap_micro_usd": quota.get("auto_recharge_monthly_cap_micro_usd"),
        "auto_recharge_spent_this_month_micro_usd": int(
            quota.get("auto_recharge_spent_this_month_micro_usd") or 0
        ),
        # Sprint 46 follow-up: don't leak the Stripe payment-method id to
        # clients — surface a boolean instead so the Flutter UI can render
        # the "saved card" badge without knowing the pm_*** token.
        "has_saved_card": bool(quota.get("stripe_payment_method_id")),
        "spend_alert_threshold_pct": int(quota.get("spend_alert_threshold_pct") or 80),
    }


@app.get("/billing/caps")
async def get_caps(user: ClerkUser = Depends(require_user)) -> dict:
    """Sprint 46: spending caps for the calling user."""
    db: Db = state["db"]
    quota = db.get_or_create_quota(user.id, plan_hint=user.plan)
    return {
        "per_task_cap_credits": db.effective_per_task_cap_credits(user.id),
        "daily_spend_cap_credits": quota.get("daily_spend_cap_credits"),
        "weekly_spend_cap_credits": quota.get("weekly_spend_cap_credits"),
    }


@app.patch("/billing/caps")
async def patch_caps(
    body: CapsPatchRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 46: update spending caps.  Returns the updated caps dict."""
    db: Db = state["db"]
    db.get_or_create_quota(user.id, plan_hint=user.plan)
    if body.per_task_cap_credits is not None:
        plan = QUOTA_PLANS.get(user.plan or "free", QUOTA_PLANS["free"])
        max_cap = plan.get("max_per_task_cap_credits")
        if max_cap is not None and body.per_task_cap_credits > max_cap:
            raise HTTPException(400, f"per_task_cap exceeds plan max ({max_cap})")
        db.set_per_task_cap(user.id, body.per_task_cap_credits)
    if body.daily_spend_cap_credits is not None:
        db.set_daily_cap(user.id, body.daily_spend_cap_credits)
    if body.weekly_spend_cap_credits is not None:
        db.set_weekly_cap(user.id, body.weekly_spend_cap_credits)
    return await get_caps(user=user)


@app.post("/billing/credits/checkout")
async def post_credits_checkout(
    body: CreditsCheckoutRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 46: create a Stripe Checkout Session for a one-time credit purchase."""
    db: Db = state["db"]
    from .stripe_direct import create_credits_checkout_session, StripeNotConfiguredError
    try:
        out = create_credits_checkout_session(
            db, user_id=user.id, credits=body.credits,
            success_url=body.success_url, cancel_url=body.cancel_url,
        )
    except ValueError as exc:
        raise HTTPException(400, str(exc))
    except StripeNotConfiguredError:
        raise HTTPException(503, "Stripe billing not configured")
    except Exception as exc:
        # Network blip / Stripe API error → 503 so client can retry.
        logger.warning("checkout session creation failed: %s", exc)
        raise HTTPException(503, "Stripe API error; retry shortly")
    return out


@app.post("/billing/auto-recharge/setup")
async def post_auto_recharge_setup(
    body: AutoRechargeSetupRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 46: create a Stripe Setup Session to save a payment method."""
    db: Db = state["db"]
    from .stripe_direct import create_setup_session, StripeNotConfiguredError
    try:
        return create_setup_session(
            db, user_id=user.id, success_url=body.success_url, cancel_url=body.cancel_url,
        )
    except StripeNotConfiguredError:
        raise HTTPException(503, "Stripe billing not configured")
    except Exception as exc:
        logger.warning("setup session creation failed: %s", exc)
        raise HTTPException(503, "Stripe API error; retry shortly")


@app.patch("/billing/auto-recharge")
async def patch_auto_recharge(
    body: AutoRechargePatchRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 46: configure auto-recharge mode, block size, and monthly cap."""
    db: Db = state["db"]
    db.get_or_create_quota(user.id, plan_hint=user.plan)
    fields: list[str] = []
    values: list = []
    if body.mode is not None:
        if body.mode not in (0, 1, 2, 3):
            raise HTTPException(400, "mode must be 0, 1, 2, or 3")
        fields.append("auto_recharge_mode=?")
        values.append(body.mode)
        fields.append("overage_enabled=?")
        values.append(0 if body.mode == 0 else 1)
    if body.block_credits is not None:
        if body.block_credits < 250:
            raise HTTPException(400, "block_credits minimum is 250 ($5)")
        fields.append("auto_recharge_block_credits=?")
        values.append(body.block_credits)
    if body.monthly_cap_micro_usd is not None:
        if body.monthly_cap_micro_usd <= 0:
            raise HTTPException(400, "monthly_cap_micro_usd must be > 0")
        fields.append("auto_recharge_monthly_cap_micro_usd=?")
        values.append(body.monthly_cap_micro_usd)
    if not fields:
        raise HTTPException(400, "no fields to update")
    fields.append("updated_at=?")
    values.append(time.time())
    values.append(user.id)
    db._conn.execute(
        f"UPDATE quotas SET {', '.join(fields)} WHERE user_id=?", values,
    )
    return await get_credits_balance(user=user)


# ── Sprint 46 A15: notifications + notification_rules + push devices ──────────

_NOTIFICATION_RULE_KINDS = {
    "period_pct", "daily_amount", "weekly_amount",
    "per_task_amount", "auto_recharge_monthly_pct",
}
_PUSH_PROVIDERS = {"unifiedpush", "desktop_local"}


@app.get("/notifications")
async def get_notifications(
    limit: int = 50,
    since_id: int | None = None,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 46: list undismissed notifications for the calling user."""
    from .notifications import list_notifications
    db: Db = state["db"]
    items = list_notifications(db, user.id, limit=limit, since_id=since_id)
    next_since = max((n["id"] for n in items), default=since_id or 0)
    return {"notifications": items, "next_since_id": next_since}


@app.post("/notifications/{notification_id}/dismiss")
async def post_dismiss_notification(
    notification_id: int,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 46: mark one notification dismissed; 404 if not found."""
    from .notifications import dismiss_notification
    db: Db = state["db"]
    if not dismiss_notification(db, user.id, notification_id):
        raise HTTPException(404, "notification not found")
    return {"ok": True}


@app.get("/notification_rules")
async def get_notification_rules(user: ClerkUser = Depends(require_user)) -> dict:
    """Sprint 46: list all notification rules for the calling user."""
    db: Db = state["db"]
    rows = db._conn.execute(
        "SELECT id, kind, threshold, enabled, last_fired_at, created_at "
        "FROM notification_rules WHERE user_id=? ORDER BY created_at",
        (user.id,),
    ).fetchall()
    rules = [
        {"id": r[0], "kind": r[1], "threshold": r[2],
         "enabled": bool(r[3]), "last_fired_at": r[4], "created_at": r[5]}
        for r in rows
    ]
    return {"rules": rules}


@app.post("/notification_rules")
async def post_notification_rule(
    body: NotificationRuleRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 46: create a notification rule; validates kind + threshold."""
    if body.kind not in _NOTIFICATION_RULE_KINDS:
        raise HTTPException(400, f"unknown kind: {body.kind}")
    if body.threshold <= 0:
        raise HTTPException(400, "threshold must be > 0")
    db: Db = state["db"]
    cur = db._conn.execute(
        "INSERT INTO notification_rules "
        "(user_id, kind, threshold, enabled, created_at) "
        "VALUES (?, ?, ?, ?, ?)",
        (user.id, body.kind, body.threshold, int(body.enabled), time.time()),
    )
    return {
        "id": cur.lastrowid, "kind": body.kind, "threshold": body.threshold,
        "enabled": body.enabled,
    }


@app.patch("/notification_rules/{rule_id}")
async def patch_notification_rule(
    rule_id: int,
    body: NotificationRulePatchRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 46: partial update of a notification rule.  Scoped to the calling user."""
    db: Db = state["db"]
    fields: list[str] = []
    values: list = []
    if body.threshold is not None:
        if body.threshold <= 0:
            raise HTTPException(400, "threshold must be > 0")
        fields.append("threshold=?")
        values.append(body.threshold)
    if body.enabled is not None:
        fields.append("enabled=?")
        values.append(int(body.enabled))
    if not fields:
        raise HTTPException(400, "no fields to update")
    values += [rule_id, user.id]
    cur = db._conn.execute(
        f"UPDATE notification_rules SET {', '.join(fields)} WHERE id=? AND user_id=?",
        values,
    )
    if cur.rowcount == 0:
        raise HTTPException(404, "rule not found")
    row = db._conn.execute(
        "SELECT id, kind, threshold, enabled, last_fired_at, created_at "
        "FROM notification_rules WHERE id=? AND user_id=?",
        (rule_id, user.id),
    ).fetchone()
    return {
        "id": row[0], "kind": row[1], "threshold": row[2],
        "enabled": bool(row[3]), "last_fired_at": row[4], "created_at": row[5],
    }


@app.delete("/notification_rules/{rule_id}")
async def delete_notification_rule(
    rule_id: int,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 46: delete a notification rule; 404 if not owned by calling user."""
    db: Db = state["db"]
    cur = db._conn.execute(
        "DELETE FROM notification_rules WHERE id=? AND user_id=?",
        (rule_id, user.id),
    )
    if cur.rowcount == 0:
        raise HTTPException(404, "rule not found")
    return {"ok": True}


@app.get("/push/devices")
async def get_push_devices(user: ClerkUser = Depends(require_user)) -> dict:
    """Sprint 46: list registered push devices for the calling user."""
    db: Db = state["db"]
    rows = db._conn.execute(
        "SELECT id, provider, endpoint_url, label, platform, enabled, last_seen_at, created_at "
        "FROM push_devices WHERE user_id=? ORDER BY created_at DESC",
        (user.id,),
    ).fetchall()
    devices = [
        {"id": r[0], "provider": r[1], "endpoint_url": r[2], "label": r[3],
         "platform": r[4], "enabled": bool(r[5]), "last_seen_at": r[6],
         "created_at": r[7]}
        for r in rows
    ]
    return {"devices": devices}


@app.post("/push/devices")
async def post_push_device(
    body: PushDeviceRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 46: register a push device.  unifiedpush requires endpoint_url."""
    if body.provider not in _PUSH_PROVIDERS:
        raise HTTPException(400, f"unknown provider: {body.provider}")
    if body.provider == "unifiedpush" and not body.endpoint_url:
        raise HTTPException(400, "unifiedpush requires endpoint_url")
    db: Db = state["db"]
    cur = db._conn.execute(
        "INSERT INTO push_devices "
        "(user_id, provider, endpoint_url, label, platform, enabled, created_at) "
        "VALUES (?, ?, ?, ?, ?, 1, ?)",
        (user.id, body.provider, body.endpoint_url, body.label, body.platform, time.time()),
    )
    return {
        "id": cur.lastrowid, "provider": body.provider,
        "endpoint_url": body.endpoint_url, "label": body.label,
        "platform": body.platform, "enabled": True,
    }


@app.delete("/push/devices/{device_id}")
async def delete_push_device(
    device_id: int,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 46: deregister a push device; 404 if not owned by calling user."""
    db: Db = state["db"]
    cur = db._conn.execute(
        "DELETE FROM push_devices WHERE id=? AND user_id=?",
        (device_id, user.id),
    )
    if cur.rowcount == 0:
        raise HTTPException(404, "device not found")
    return {"ok": True}


# ── Sprint 46 A17: WebSocket notification feed ────────────────────────────────


async def _ws_authenticate(websocket: WebSocket) -> str:
    """Bearer-token (admin) or Clerk JWT auth via ?token query param.

    Returns the resolved user_id string; closes the WebSocket and raises
    WebSocketDisconnect(4401) on any authentication failure.
    """
    token = websocket.query_params.get("token", "")
    if not token:
        await websocket.close(code=4401, reason="missing token")
        raise WebSocketDisconnect(code=4401)
    bearer = os.environ.get("TALLY_API_TOKEN", "").strip()
    if bearer and token == bearer:
        return "admin"
    try:
        from .clerk_auth import _verify_session_token
        validator: ClerkValidator | None = state.get("clerk_validator")
        if validator is None:
            raise ValueError("Clerk validator not configured")
        claims = _verify_session_token(token, validator=validator)
        return claims.get("sub") or "anon"
    except Exception:
        await websocket.close(code=4401, reason="invalid token")
        raise WebSocketDisconnect(code=4401)


@app.websocket("/ws/notifications")
async def ws_notifications(websocket: WebSocket) -> None:
    """Sprint 46: live notification feed.

    Client connects with ?token=<bearer-or-jwt>; receives hello then signals.
    Ping/pong keepalive: client sends ``{"type": "ping"}``, server replies
    ``{"type": "pong"}``.  ``fan_out_push`` delivers
    ``{"type": "new_notification", "id": N}`` to all registered sockets.
    """
    await websocket.accept()
    user_id = await _ws_authenticate(websocket)
    from .notifications import register_websocket, unregister_websocket
    register_websocket(user_id, websocket)
    await websocket.send_json({"type": "hello", "user_id": user_id})
    try:
        while True:
            msg = await websocket.receive_json()
            if msg.get("type") == "ping":
                await websocket.send_json({"type": "pong"})
    except WebSocketDisconnect:
        pass
    finally:
        unregister_websocket(user_id, websocket)


@app.get("/tasks/{task_id}/cost")
async def task_cost(task_id: str, user: ClerkUser = Depends(require_user)) -> dict:
    """Sprint 39: per-task cost roll-up.  Drives the cost pill on
    the task channel header."""
    db: Db = state["db"]
    scope = None if user.source == "admin" else user.id
    task = db.get_task(task_id, user_id=scope)
    if task is None:
        raise HTTPException(404, f"task `{task_id}` not found")
    return db.task_cost(task_id)


@app.get("/billing/usage")
async def billing_usage(user: ClerkUser = Depends(require_user)) -> dict:
    """Return current period usage + plan caps for the calling user.
    Drives the Flutter UI's "Usage" surface.

    Sprint 33-rest: opportunistically syncs the stored plan against
    the JWT's `pla` claim before reading, so the response reflects
    the freshest plan even if the webhook hasn't landed yet.
    """
    db: Db = state["db"]
    q = db.get_or_create_quota(user.id, plan_hint=user.plan)
    caps = QUOTA_PLANS.get(q["plan"], QUOTA_PLANS["free"])
    return {
        "user_id": user.id,
        "plan": q["plan"],
        "plan_label": caps["label"],
        "period_start": q["period_start"],
        "tasks": {"used": q["period_tasks_used"], "cap": caps["tasks"]},
        "agent_seconds": {
            "used": q["period_agent_seconds_used"],
            "cap": caps["agent_seconds"],
        },
        # Sprint 33-rest: these columns now hold Clerk Billing IDs
        # (payer id + subscriptionItem id) rather than Stripe IDs.
        # The column names are kept for migration-stability; the
        # response keys carry the generic semantic.
        "billing_payer_id": q["stripe_customer_id"],
        "billing_subscription_id": q["stripe_subscription_id"],
    }


@app.post("/webhooks/clerk")
async def clerk_webhook(request: Request) -> dict:
    """Sprint 33-rest: Clerk Billing webhook delivery.

    Clerk signs every webhook with svix.  ``CLERK_WEBHOOK_SECRET``
    (the ``whsec_…`` value from the dashboard) feeds the HMAC-SHA256
    verifier; bad signatures yield 400.

    Handled event types (all under ``subscriptionItem.*``):
      - ``subscriptionItem.created`` / ``subscriptionItem.active`` /
        ``subscriptionItem.updated`` — sync the user's plan + record
        the subscription id.
      - ``subscriptionItem.canceled`` — flip the user back to ``free``.

    Other events (``paymentAttempt.*``, ``subscription.past_due``,
    etc.) are accepted-and-ignored so Clerk doesn't retry forever.

    JWT-claim sync runs on every request, so the webhook is only
    load-bearing for state changes that happen *between* user
    sessions (failed renewal, admin-side cancel, etc.).
    """
    billing: ClerkBillingClient = state["clerk_billing"]
    if not billing.webhook_enabled:
        raise HTTPException(503, "CLERK_WEBHOOK_SECRET not configured on this orchestrator")
    payload = await request.body()
    try:
        billing.verify_svix_signature(
            payload=payload,
            svix_id=request.headers.get("svix-id", ""),
            svix_timestamp=request.headers.get("svix-timestamp", ""),
            svix_signature=request.headers.get("svix-signature", ""),
        )
    except ValueError as exc:
        logger.warning("Clerk webhook verify failed: %s", exc)
        raise HTTPException(400, f"invalid signature: {exc}")
    try:
        raw_event = json.loads(payload.decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise HTTPException(400, f"bad json: {exc}")
    if not isinstance(raw_event, dict):
        raise HTTPException(400, "expected JSON object")

    evt = billing.parse_event(raw_event)
    db: Db = state["db"]

    if not evt.user_id:
        # Unknown event shape or user_id missing — accept-and-no-op
        # so Clerk doesn't retry; log for visibility.
        logger.info("clerk webhook: skipping %s (no user_id)", evt.type)
        return {"received": True, "event": evt.type, "applied": False}

    if evt.type.startswith("subscriptionItem."):
        new_plan = evt.plan or "free"
        db.set_user_plan(
            evt.user_id,
            plan=new_plan,
            stripe_customer_id=None,  # Clerk owns payer state; no separate id
            stripe_subscription_id=evt.subscription_id,
        )
        # Sprint 46: seed default alert rules for newly paid users
        try:
            from .notifications import seed_default_rules
            seed_default_rules(db, evt.user_id, plan=new_plan)
        except Exception as exc:
            logger.warning("seed_default_rules raised: %s", exc)
        logger.info("clerk webhook %s → user=%s plan=%s sub=%s",
                    evt.type, evt.user_id, new_plan, evt.subscription_id)
        return {"received": True, "event": evt.type, "applied": True}

    # Other event families (paymentAttempt.*, etc.): accepted, not acted on.
    logger.debug("clerk webhook: ignored event_type=%s", evt.type)
    return {"received": True, "event": evt.type, "applied": False}


@app.post("/webhooks/stripe")
async def stripe_webhook(request: Request) -> dict:
    """Sprint 46: Stripe → Tally webhook receiver.

    Events we act on:
      - checkout.session.completed: one-time credit purchase completed
      - setup_intent.succeeded: save card for auto-recharge
      - payment_intent.succeeded: auto-recharge fired successfully
      - payment_intent.payment_failed: disable auto-recharge + notify

    Other events: 200 OK, no-op (Stripe retries on non-2xx indefinitely).
    Idempotency is enforced via the ``overage_purchases.status='pending'``
    guard — duplicate deliveries see status='succeeded' and are silently
    dropped.
    """
    db: Db = state["db"]
    payload = await request.body()
    sig = request.headers.get("stripe-signature") or ""
    event = _verify_stripe_signature(payload, sig)
    evt_type = event.get("type", "")
    data = (event.get("data") or {}).get("object") or {}
    metadata = data.get("metadata") or {}
    user_id = metadata.get("user_id")

    if evt_type == "checkout.session.completed":
        if not user_id:
            logger.warning("stripe webhook: checkout.session.completed missing user_id")
            return {"ok": True}
        pi_id = data.get("payment_intent")
        credits = int(metadata.get("credits", "0") or 0)
        # Idempotent: only credit if the matching overage_purchases row is
        # still 'pending'.  Re-deliveries find status='succeeded' and no-op.
        cur = db._conn.execute(
            "SELECT id, credits_purchased, status FROM overage_purchases "
            "WHERE stripe_payment_intent_id=? AND user_id=?",
            (pi_id, user_id),
        ).fetchone()
        if cur and cur[2] == "pending":
            db.increment_prepaid_balance(user_id, int(cur[1]))
            db._conn.execute(
                "UPDATE overage_purchases SET status='succeeded' WHERE id=?",
                (cur[0],),
            )
            logger.info(
                "stripe: checkout.session.completed credited %d to user=%s from pi=%s",
                cur[1], user_id, pi_id,
            )
        elif not cur and credits > 0:
            # Defensive: no pending row but metadata contains credit count.
            # Synthesize a row and credit.  Should not happen in normal flow.
            db.increment_prepaid_balance(user_id, credits)
            db._conn.execute(
                "INSERT INTO overage_purchases "
                "(user_id, ts, credits_purchased, cost_charged_micro_usd, "
                "kind, stripe_payment_intent_id, status) "
                "VALUES (?, ?, ?, ?, 'one_time', ?, 'succeeded')",
                (user_id, time.time(), credits, credits * 20_000, pi_id),
            )
            logger.warning(
                "stripe: checkout.session.completed: no pending row found; "
                "synthesized credit=%d for user=%s", credits, user_id,
            )
        return {"ok": True}

    if evt_type == "setup_intent.succeeded":
        if not user_id:
            logger.warning("stripe webhook: setup_intent.succeeded missing user_id")
            return {"ok": True}
        pm = data.get("payment_method")
        customer = data.get("customer")
        db._conn.execute(
            "UPDATE quotas SET "
            "stripe_payment_method_id=?, "
            "stripe_customer_id=COALESCE(?, stripe_customer_id), "
            "updated_at=? WHERE user_id=?",
            (pm, customer, time.time(), user_id),
        )
        logger.info(
            "stripe: setup_intent.succeeded saved payment_method=%s customer=%s for user=%s",
            pm, customer, user_id,
        )
        return {"ok": True}

    if evt_type == "payment_intent.succeeded":
        if not user_id:
            logger.warning("stripe webhook: payment_intent.succeeded missing user_id")
            return {"ok": True}
        pi_id = data.get("id")
        cur = db._conn.execute(
            "SELECT id, credits_purchased, status FROM overage_purchases "
            "WHERE stripe_payment_intent_id=? AND user_id=?",
            (pi_id, user_id),
        ).fetchone()
        if cur and cur[2] == "pending":
            db.increment_prepaid_balance(user_id, int(cur[1]))
            db._conn.execute(
                "UPDATE overage_purchases SET status='succeeded' WHERE id=?",
                (cur[0],),
            )
            logger.info(
                "stripe: payment_intent.succeeded credited %d to user=%s pi=%s",
                cur[1], user_id, pi_id,
            )
        return {"ok": True}

    if evt_type == "payment_intent.payment_failed":
        if not user_id:
            logger.warning("stripe webhook: payment_intent.payment_failed missing user_id")
            return {"ok": True}
        reason = (data.get("last_payment_error") or {}).get("message", "unknown")
        pi_id = data.get("id")
        db._conn.execute(
            "UPDATE overage_purchases SET status='failed', failure_reason=? "
            "WHERE stripe_payment_intent_id=? AND user_id=?",
            (reason, pi_id, user_id),
        )
        # Disable auto-recharge so the user is not bombarded with repeated
        # failures.  They must explicitly re-enable from the billing screen.
        db._conn.execute(
            "UPDATE quotas SET auto_recharge_mode=0, overage_enabled=0, updated_at=? "
            "WHERE user_id=?",
            (time.time(), user_id),
        )
        logger.warning(
            "stripe: payment_failed user=%s reason=%s; auto-recharge disabled",
            user_id, reason,
        )
        # Sprint 46 A14: emit a spend-alert notification.  Best-effort —
        # notifications.py is created in A14; wrap in try/except so A13
        # stays fully testable before A14 lands.
        try:
            from .notifications import emit_notification
            await emit_notification(
                db, user_id,
                kind="auto_recharge_failed",
                severity="error",
                payload={"reason": reason},
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning("stripe webhook: emit_notification raised: %s", exc)
        return {"ok": True}

    # All other event types: accept-and-no-op.  Returning 200 prevents
    # Stripe from retrying the delivery indefinitely.
    logger.debug("stripe webhook: unhandled event type %s", evt_type)
    return {"ok": True}


# ── Sprint 49 A10: persistent-agent HTTP event triggers ───────────────────────


@app.post("/webhooks/agents/{trigger_id}")
async def fire_event_trigger(trigger_id: str, request: Request) -> dict:
    """Sprint 49 A10: fire a persistent agent via its HTTP event trigger.

    Auth: HMAC-SHA256 over raw request body using the trigger's secret,
    passed in ``X-Tally-Signature: sha256=<hex>``.  No user session
    required — callers are external systems (GitHub, Slack, etc.)."""
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
                    orch: "Orchestrator" = state.get("orchestrator")
                    if orch is None:
                        raise HTTPException(503, "orchestrator not ready")
                    task_id = await orch._fire_persistent_agent(agent_id, trigger="webhook")
                    return {"ok": True, "agent_id": agent_id, "task_id": task_id}
                else:
                    raise HTTPException(401, "invalid signature")
    raise HTTPException(404, "trigger not found")


@app.get("/admin/agent_roles")
async def list_agent_roles(user: ClerkUser = Depends(require_user)) -> dict:
    """The agent palette.  Returns seeded roles plus the caller's
    custom roles (Sprint 40).  Each row has ``source`` ∈
    ``{seeded, custom}`` so the UI can render them differently.

    Auth: any authenticated user (admin OR Clerk JWT).  Admin sees
    only seeded roles (admin has no per-user custom-role rows).
    """
    scope = None if user.source == "admin" else user.id
    return {"roles": state["db"].list_agent_roles(user_id=scope)}


# ── Sprint 40: user-defined custom roles ─────────────────────────────────────


class CustomRoleCreate(BaseModel):
    name: str
    description: str
    default_model: str
    tools: list[str] = []
    system_prompt: str


class CustomRolePatch(BaseModel):
    """Partial update; any subset of fields may be supplied."""
    description: str | None = None
    default_model: str | None = None
    tools: list[str] | None = None
    system_prompt: str | None = None


# Allow-list of model ids we'll accept on the create/patch path.  Keeps
# operators from accidentally typing a model that isn't on Red Pill.
# Extend by editing this set as Red Pill's catalogue grows.
_ALLOWED_MODELS = {
    "meta-llama/llama-3.3-70b-instruct",
    "moonshotai/kimi-k2-instruct",
    "moonshotai/kimi-k2.6-instruct",
    "deepseek/deepseek-r1-0528",
    "deepseek/deepseek-r1",
    "deepseek/deepseek-v3.2",
    "deepseek/deepseek-v3",
}

# Tool palette mirrors the seeded roles' tools_json values.  Any
# subset accepted; unknown tool names rejected so users can't smuggle
# in something the worker doesn't honour.
_ALLOWED_TOOLS = {
    "file_editor",
    "file_editor_read",
    "bash",
    "bash_read",
    "browser",
}


def _validate_custom_role_inputs(
    *,
    name: str,
    default_model: str,
    tools: list[str],
    system_prompt: str,
) -> None:
    """Raises HTTPException 400 on any input violation."""
    if not name or not name.strip():
        raise HTTPException(400, "name is required")
    clean = name.strip()
    if len(clean) > 64:
        raise HTTPException(400, "name must be ≤64 chars")
    if "/" in clean or any(ord(c) < 32 for c in clean):
        raise HTTPException(
            400, "name must contain no `/` or control chars",
        )
    if default_model not in _ALLOWED_MODELS:
        raise HTTPException(
            400,
            f"default_model `{default_model}` not in allow-list. "
            f"Pick one of: {sorted(_ALLOWED_MODELS)}",
        )
    for tool in tools:
        if tool not in _ALLOWED_TOOLS:
            raise HTTPException(
                400,
                f"unknown tool `{tool}`. Pick from: {sorted(_ALLOWED_TOOLS)}",
            )
    if not system_prompt or not system_prompt.strip():
        raise HTTPException(400, "system_prompt is required")
    if len(system_prompt) > 8192:
        raise HTTPException(400, "system_prompt is too long (>8 KiB)")


@app.post("/agent_roles")
async def create_custom_role(
    body: CustomRoleCreate,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Mint a user-scoped custom role.  Cannot collide with seeded
    role names (returns 409) or with the user's own existing custom
    roles (also 409)."""
    if user.source == "admin":
        raise HTTPException(
            400, "admin doesn't own custom roles; sign in as a Clerk user",
        )
    db: Db = state["db"]
    _validate_custom_role_inputs(
        name=body.name,
        default_model=body.default_model,
        tools=body.tools,
        system_prompt=body.system_prompt,
    )
    clean_name = body.name.strip()
    seeded = db.seeded_role_names()
    if clean_name in seeded:
        raise HTTPException(
            409,
            f"`{clean_name}` collides with a seeded role. Pick a different name.",
        )
    existing_custom = db.list_custom_role_names(user.id)
    if clean_name in existing_custom:
        raise HTTPException(409, f"you already have a custom role named `{clean_name}`")
    description = (body.description or "").strip() or f"Custom role: {clean_name}"
    db.create_custom_role(
        user_id=user.id,
        name=clean_name,
        description=description,
        default_model=body.default_model,
        tools=body.tools,
        system_prompt=body.system_prompt,
    )
    logger.info("custom_role created: user=%s name=%r model=%s",
                user.id, clean_name, body.default_model)
    return db.get_agent_role(clean_name, user_id=user.id) or {"name": clean_name}


@app.patch("/agent_roles/{name}")
async def update_custom_role(
    name: str,
    body: CustomRolePatch,
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Patch a custom role.  Cannot rename — drop + recreate for that.
    Seeded roles are immutable from this endpoint."""
    if user.source == "admin":
        raise HTTPException(400, "admin can't patch custom roles via this endpoint")
    db: Db = state["db"]
    if body.default_model is not None and body.default_model not in _ALLOWED_MODELS:
        raise HTTPException(400, f"default_model `{body.default_model}` not in allow-list")
    if body.tools is not None:
        for tool in body.tools:
            if tool not in _ALLOWED_TOOLS:
                raise HTTPException(400, f"unknown tool `{tool}`")
    if body.system_prompt is not None and len(body.system_prompt) > 8192:
        raise HTTPException(400, "system_prompt is too long (>8 KiB)")
    updated = db.update_custom_role(
        user_id=user.id,
        name=name,
        description=body.description,
        default_model=body.default_model,
        tools=body.tools,
        system_prompt=body.system_prompt,
    )
    if updated is None:
        raise HTTPException(404, f"custom role `{name}` not found")
    return updated


@app.delete("/agent_roles/{name}")
async def delete_custom_role(
    name: str, user: ClerkUser = Depends(require_user),
) -> dict:
    """Delete a custom role.  Tasks already running with this role
    are unaffected (the role spec lives in their team_spec column)."""
    if user.source == "admin":
        raise HTTPException(400, "admin can't delete custom roles via this endpoint")
    db: Db = state["db"]
    if not db.delete_custom_role(user_id=user.id, name=name):
        raise HTTPException(404, f"custom role `{name}` not found")
    return {"deleted": name}


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
