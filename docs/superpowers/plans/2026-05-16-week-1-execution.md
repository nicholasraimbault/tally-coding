# Tally Coding Week 1 Execution Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Validate the Tally Coding cloud-side stack end-to-end across 5 days. By end of Week 1, two OpenHands agents in Phala CVMs coordinate via Tally Workers wakes + Skytale-encrypted channels to complete a real coding task. Flutter app scaffold + Skytale Dart SDK skeleton in place.

**Architecture:** OpenHands SDK agents run in Phala CVMs (TEE-attested compute). Use Phala Redpill (Kimi K2.6, TEE-attested LLM). Coordinate via Skytale-encrypted MLS channels + Tally Workers wake dispatch. Each day adds a layer, committed independently.

**Tech Stack:** Python 3.12 (uv), Docker Compose, Phala Cloud CLI + SDK, Skytale Python SDK, OpenHands SDK, Tally Workers HTTP API, Flutter (Dart) + `dart:ffi`.

**Authorization for executor:** Max automation. Commit and push freely. Only block on: user secrets entry (Phala API key, etc.), CLI authentication that requires their machine (`phala login`), Tally CLI provisioning, and Flutter SDK installation. Tag those tasks with **`[USER-BLOCK]`** so they're surfaced explicitly.

**Parallelization notes:** Days are roughly sequential but Day 2-5 PREP work can run in parallel via subagents while Day 1 is user-blocked. Tasks marked **`[PARALLEL]`** can be dispatched concurrently.

---

## Day 1 — Validate OpenHands + Phala Redpill locally `[USER-BLOCK]`

**Status:** Scaffolding committed in `e662e4e`. The user runs the spike; subagents prep Days 2-5 in parallel.

**Files (already exist):**
- `spike/day1/spike.py`
- `spike/day1/pyproject.toml`
- `spike/day1/.env.example`
- `spike/day1/.gitignore`
- `spike/day1/README.md`

### Task 1.1: User adds Phala API key to .env `[USER-BLOCK]`

- [ ] **Step 1: Copy .env.example to .env**

User runs:
```bash
cd ~/Projects/pronoic/tally-coding/spike/day1
cp .env.example .env
```

- [ ] **Step 2: User edits .env with their Phala API key**

User opens `.env` in their editor and replaces:
```
REDPILL_API_KEY=your_phala_redpill_api_key_here
```
with their actual key from the Phala dashboard.

### Task 1.2: User installs dependencies `[USER-BLOCK]`

- [ ] **Step 1: Install uv if not present**

User runs (one of):
```bash
brew install uv
# or
pip install uv
```

- [ ] **Step 2: Sync project deps**

User runs:
```bash
cd ~/Projects/pronoic/tally-coding/spike/day1
uv sync
```
Expected: creates `.venv/` and `uv.lock`; installs `openhands-ai` + `python-dotenv`.

- [ ] **Step 3: Commit `uv.lock` so the version is pinned**

```bash
cd ~/Projects/pronoic/tally-coding
git add spike/day1/uv.lock
git commit -m "[spike/day1] commit uv.lock with pinned openhands-ai version"
git push
```

### Task 1.3: User runs the spike `[USER-BLOCK]`

- [ ] **Step 1: Run the spike**

User runs:
```bash
cd ~/Projects/pronoic/tally-coding/spike/day1
uv run python spike.py
```

- [ ] **Step 2: User pastes the output back to orchestrator**

The orchestrator (next session or current) reads output to determine success / failure.

Expected on success:
```
[spike] workspace: /tmp/tally-spike-day1-...
... (agent activity)
============================================================
[spike] RESULT
============================================================
[ok ] greet.py created (... bytes)
[ok ] test_greet.py created (... bytes)
```

### Task 1.4: Orchestrator triages output

- [ ] **Step 1: Orchestrator inspects output**

If success → mark Day 1 done; commit a success log to `spike/day1/RESULT.md` capturing the workspace contents.

If failure → dispatch a debug subagent with the error output. Common failures + fixes are in `spike/day1/README.md`.

- [ ] **Step 2: Commit Day 1 result**

```bash
cd ~/Projects/pronoic/tally-coding
git add spike/day1/RESULT.md
git commit -m "[spike/day1] capture successful Day 1 spike output"
git push
```

---

## Day 2 — Containerize spike + deploy to Phala CVM

**Files to create:**
- `spike/day2/Dockerfile`
- `spike/day2/docker-compose.yml`
- `spike/day2/spike.py` (adapted from Day 1; runs as a service)
- `spike/day2/README.md`

### Task 2.1: Subagent writes Dockerfile + docker-compose `[PARALLEL]`

This task can run in parallel with Day 1 execution.

- [ ] **Step 1: Subagent creates `spike/day2/Dockerfile`**

```dockerfile
FROM python:3.12-slim

WORKDIR /app

# Install build deps for any native modules openhands-ai may pull
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install uv (Phala recommends pip but uv is faster + reproducible)
RUN pip install --no-cache-dir uv

# Copy project files
COPY pyproject.toml uv.lock /app/
RUN uv sync --frozen --no-dev

# Copy spike script
COPY spike.py /app/

# Workspace for agent activity
RUN mkdir -p /workspace

ENV WORKSPACE_DIR=/workspace

CMD ["uv", "run", "python", "spike.py"]
```

- [ ] **Step 2: Subagent creates `spike/day2/docker-compose.yml`**

```yaml
services:
  spike-day2:
    build: .
    environment:
      - REDPILL_API_KEY=${REDPILL_API_KEY}
      - REDPILL_BASE_URL=${REDPILL_BASE_URL:-https://api.redpill.ai/v1}
      - REDPILL_MODEL=${REDPILL_MODEL:-moonshotai/Kimi-K2-6}
    volumes:
      - workspace:/workspace
volumes:
  workspace:
```

- [ ] **Step 3: Subagent commits**

```bash
cd ~/Projects/pronoic/tally-coding
git add spike/day2/Dockerfile spike/day2/docker-compose.yml
git commit -m "[spike/day2] Dockerfile + compose for Phala CVM deployment"
git push
```

### Task 2.2: Subagent adapts spike.py for CVM execution `[PARALLEL]`

- [ ] **Step 1: Subagent creates `spike/day2/spike.py`**

Adapted from Day 1 spike. Key differences:
- Workspace defaults to `/workspace` (mounted volume)
- Output written to stdout (Phala CVM logs visible via `phala logs`)
- No tempdir creation (workspace is persistent)

```python
"""Day 2 spike — same as Day 1 but containerized for Phala CVM execution."""

from __future__ import annotations

import os
import sys
from pathlib import Path

from openhands.sdk import LLM, Agent, Conversation, Tool
from openhands.tools.terminal import TerminalTool
from openhands.tools.file_editor import FileEditorTool
from openhands.tools.task_tracker import TaskTrackerTool


def build_llm() -> LLM:
    api_key = os.environ.get("REDPILL_API_KEY")
    if not api_key:
        sys.exit("REDPILL_API_KEY not set (passed via Phala CVM env)")
    base_url = os.environ.get("REDPILL_BASE_URL", "https://api.redpill.ai/v1")
    model_name = os.environ.get("REDPILL_MODEL", "moonshotai/Kimi-K2-6")
    return LLM(
        model=f"openai/{model_name}",
        api_key=api_key,
        base_url=base_url,
    )


def main() -> int:
    workspace = Path(os.environ.get("WORKSPACE_DIR", "/workspace"))
    workspace.mkdir(parents=True, exist_ok=True)
    print(f"[spike-day2] workspace: {workspace}", flush=True)

    llm = build_llm()
    agent = Agent(
        llm=llm,
        tools=[
            Tool(name=TerminalTool.name),
            Tool(name=FileEditorTool.name),
            Tool(name=TaskTrackerTool.name),
        ],
    )

    conversation = Conversation(agent=agent, workspace=str(workspace))

    task = """\
Create greet.py that prints "hello, $NAME" (or "hello, world" if NAME unset),
plus test_greet.py with pytest tests for both cases, install pytest, run it,
and report pass/fail.
"""
    conversation.send_message(task)
    conversation.run()

    greet_py = workspace / "greet.py"
    test_greet_py = workspace / "test_greet.py"

    print()
    print("=" * 60, flush=True)
    print("[spike-day2] RESULT", flush=True)
    print("=" * 60, flush=True)
    print(f"  greet.py: {'created' if greet_py.exists() else 'MISSING'}", flush=True)
    print(f"  test_greet.py: {'created' if test_greet_py.exists() else 'MISSING'}", flush=True)

    return 0 if (greet_py.exists() and test_greet_py.exists()) else 1


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Subagent commits**

```bash
cd ~/Projects/pronoic/tally-coding
git add spike/day2/spike.py
git commit -m "[spike/day2] adapt spike.py for Phala CVM execution"
git push
```

### Task 2.3: Subagent creates `spike/day2/README.md` `[PARALLEL]`

- [ ] **Step 1: Subagent writes README**

Documents: `phala login`, `phala deploy`, env var injection, log retrieval, CVM destruction. Tracks gaps B.14 (cold start) and B.16 (CVM lifecycle) — values to measure during this deployment.

- [ ] **Step 2: Subagent commits**

```bash
git add spike/day2/README.md
git commit -m "[spike/day2] deployment + verification README"
git push
```

### Task 2.4: User authenticates Phala CLI `[USER-BLOCK]`

- [ ] **Step 1: User installs phala CLI**

```bash
npm install -g phala
```

- [ ] **Step 2: User logs in**

```bash
phala login
```

Browser opens; user authenticates; credentials saved to `~/.phala-cloud/credentials.json`.

- [ ] **Step 3: User confirms by running**

```bash
phala whoami
```

Expected: user info printed.

### Task 2.5: User deploys spike to Phala CVM `[USER-BLOCK]`

- [ ] **Step 1: User deploys**

```bash
cd ~/Projects/pronoic/tally-coding/spike/day2
phala deploy -e .env  # passes REDPILL_API_KEY etc. encrypted
```

Expected: CVM provisioned; deployment URL printed; logs streaming.

- [ ] **Step 2: User captures cold-start time**

User notes the wall-clock time from `phala deploy` invocation to first log line from the container. Write to `spike/day2/RESULT.md`:
```
Cold start observed: <N seconds>
CVM instance type: tdx.large
Verdict on gap B.14: <per-task ephemeral OK if N<15s; switch to pooled if N>30s>
```

- [ ] **Step 3: User confirms task completion**

```bash
phala logs <app-id> | tail -50
```

Expected: `[spike-day2] RESULT` block showing both files created.

### Task 2.6: Subagent commits Day 2 result

- [ ] **Step 1: Commit RESULT.md**

```bash
cd ~/Projects/pronoic/tally-coding
git add spike/day2/RESULT.md
git commit -m "[spike/day2] Phala CVM deployment successful; cold start ~Ns"
git push
```

---

## Day 3 — Tally Workers HTTP integration from Python

**Files to create:**
- `tally-coding-core/__init__.py` (at `~/Projects/pronoic/tally-coding/tally_coding_core/`)
- `tally_coding_core/tally_workers.py` — Python HTTP client for Tally Workers
- `tally_coding_core/identity.py` — wrapper over Skytale's AgentIdentity for Tally Bearer derivation
- `spike/day3/spike.py` — local script that dispatches a wake to itself via Tally
- `spike/day3/README.md`
- `tests/test_tally_workers.py` — integration tests against existing Tally Workers deployment

### Task 3.1: Subagent writes `tally_coding_core` package skeleton `[PARALLEL]`

This task is parallelizable with Day 1-2 work.

- [ ] **Step 1: Create package structure**

```bash
mkdir -p ~/Projects/pronoic/tally-coding/tally_coding_core
mkdir -p ~/Projects/pronoic/tally-coding/tests
```

- [ ] **Step 2: Create `tally_coding_core/__init__.py`**

```python
"""Tally Coding core Python package — shared between cloud agents and CLI/spike.

Modules:
- identity: Skytale AgentIdentity + Tally Bearer derivation
- tally_workers: HTTP client for Tally Workers (8 routes)
- skytale: thin wrappers around skytale-sdk's OrchestrationAgent
- (future) openhands_tools: ToolDefinitions wrapping Skytale + Tally for OpenHands
"""

__version__ = "0.0.1"
```

- [ ] **Step 3: Create top-level `pyproject.toml`**

```toml
[project]
name = "tally-coding-core"
version = "0.0.1"
description = "Tally Coding core Python package: identity, Tally Workers client, Skytale wrappers"
requires-python = ">=3.12"
dependencies = [
    "httpx>=0.27.0",
    "skytale-sdk",
    "openhands-ai",
    "python-dotenv>=1.0.0",
]

[tool.uv]
package = true

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"
```

- [ ] **Step 4: Commit**

```bash
cd ~/Projects/pronoic/tally-coding
git add tally_coding_core/ pyproject.toml
git commit -m "[core] initialize tally_coding_core package + project layout"
git push
```

### Task 3.2: Subagent writes `tally_coding_core/identity.py` `[PARALLEL]`

- [ ] **Step 1: Write the failing test**

Create `tests/test_identity.py`:
```python
"""Tests for identity helpers."""

from tally_coding_core.identity import bearer_from_pubkey


def test_bearer_from_pubkey_is_url_safe_base64_no_padding():
    pubkey = b"\x00" * 32  # 32 zero bytes
    bearer = bearer_from_pubkey(pubkey)
    # 32 bytes -> 44 base64 chars w/ padding; we strip = chars
    assert "=" not in bearer
    assert "+" not in bearer
    assert "/" not in bearer
    assert len(bearer) == 43  # 32 * 8 / 6 = 42.67 -> 43


def test_bearer_round_trip_with_known_pubkey():
    # 32 known bytes
    pubkey = bytes(range(32))
    bearer = bearer_from_pubkey(pubkey)
    # Decode back
    import base64
    decoded = base64.urlsafe_b64decode(bearer + "=" * (-len(bearer) % 4))
    assert decoded == pubkey
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ~/Projects/pronoic/tally-coding
uv run pytest tests/test_identity.py -v
```
Expected: FAIL with `ModuleNotFoundError: No module named 'tally_coding_core.identity'`.

- [ ] **Step 3: Write `tally_coding_core/identity.py`**

```python
"""Identity helpers: AgentIdentity loader + Tally Bearer derivation."""

from __future__ import annotations

import base64


def bearer_from_pubkey(pubkey: bytes) -> str:
    """Compute Tally Workers Bearer token from an Ed25519 public key.

    MVP bearer semantics (per Tally Phase 1B D5): Bearer = url_safe_b64(pubkey),
    no padding. Phase 2 will replace this with real API keys; wire contract
    stable across the transition.
    """
    if len(pubkey) != 32:
        raise ValueError(f"expected 32-byte Ed25519 pubkey; got {len(pubkey)} bytes")
    return base64.urlsafe_b64encode(pubkey).decode().rstrip("=")


def load_or_create_identity(path: str) -> tuple[bytes, bytes]:
    """Load (privkey, pubkey) Ed25519 pair from disk; create if missing.

    Returns 32-byte private key, 32-byte public key.
    """
    import pathlib

    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    p = pathlib.Path(path)
    if p.exists():
        privkey = p.read_bytes()
        pkey_obj = Ed25519PrivateKey.from_private_bytes(privkey)
        pubkey = pkey_obj.public_key().public_bytes_raw()
    else:
        pkey_obj = Ed25519PrivateKey.generate()
        privkey = pkey_obj.private_bytes_raw()
        pubkey = pkey_obj.public_key().public_bytes_raw()
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(privkey)
        p.chmod(0o600)
    return privkey, pubkey
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd ~/Projects/pronoic/tally-coding
uv run pytest tests/test_identity.py -v
```
Expected: 2 passed.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_core/identity.py tests/test_identity.py
git commit -m "[core] identity helpers: Ed25519 keypair + Tally Bearer derivation"
git push
```

### Task 3.3: Subagent writes `tally_coding_core/tally_workers.py` `[PARALLEL]`

- [ ] **Step 1: Write the failing test**

Create `tests/test_tally_workers.py`:
```python
"""Integration tests for Tally Workers HTTP client.

Run against the existing Tally Workers deployment at
https://tally.nraimbault16.workers.dev (canonical resting state).
"""

import os
import uuid

import pytest

from tally_coding_core.identity import bearer_from_pubkey, load_or_create_identity
from tally_coding_core.tally_workers import TallyWorkersClient


TALLY_URL = os.environ.get("TALLY_WORKERS_URL", "https://tally.nraimbault16.workers.dev")


@pytest.fixture
def client():
    return TallyWorkersClient(base_url=TALLY_URL)


@pytest.fixture
def test_team_id():
    """Unique team_id per test run."""
    return f"tally-coding-test-{uuid.uuid4().hex[:8]}"


@pytest.fixture
def test_agent():
    """Per-test ephemeral identity."""
    tmp = f"/tmp/tally-test-identity-{uuid.uuid4().hex[:8]}.key"
    privkey, pubkey = load_or_create_identity(tmp)
    bearer = bearer_from_pubkey(pubkey)
    return {"privkey": privkey, "pubkey": pubkey, "bearer": bearer}


def test_health_endpoint(client):
    """GET /v1/health returns 200 OK."""
    result = client.health()
    assert result["status"] == "ok"
    assert "version" in result


def test_team_init_idempotent(client, test_team_id, test_agent):
    """POST /v1/teams/{id}/init twice returns the same initialized_at."""
    first = client.team_init(test_team_id, bearer=test_agent["bearer"])
    second = client.team_init(test_team_id, bearer=test_agent["bearer"])
    assert first["initialized_at"] == second["initialized_at"]


def test_register_handler(client, test_team_id, test_agent):
    """POST /v1/teams/{id}/agents/{ident}/register works."""
    client.team_init(test_team_id, bearer=test_agent["bearer"])
    result = client.register(
        team_id=test_team_id,
        identity_b64=test_agent["bearer"],
        bearer=test_agent["bearer"],
        context_id="test-context",
    )
    assert result["registered"] is True
    assert result["context_id"] == "test-context"


def test_team_delete_cleans_up(client, test_team_id, test_agent):
    """DELETE /v1/teams/{id} succeeds."""
    client.team_init(test_team_id, bearer=test_agent["bearer"])
    client.team_delete(test_team_id, bearer=test_agent["bearer"])
    # No assert; just confirm no exception
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd ~/Projects/pronoic/tally-coding
uv run pytest tests/test_tally_workers.py -v
```
Expected: FAIL with `ModuleNotFoundError: No module named 'tally_coding_core.tally_workers'`.

- [ ] **Step 3: Write `tally_coding_core/tally_workers.py`**

```python
"""HTTP client for Tally Workers API.

8 public routes per docs/specs/phase-1b-sub-pr-1-phase-0.md §3.3 in the
tally-workers repo. Bearer auth = url_safe_b64(identity_bytes) per the MVP D5
contract.
"""

from __future__ import annotations

from typing import Any

import httpx


class TallyWorkersClient:
    """Synchronous HTTP client for Tally Workers. Use httpx for HTTP/2 + sync API."""

    def __init__(self, base_url: str, timeout_seconds: float = 60.0):
        self.base_url = base_url.rstrip("/")
        self._client = httpx.Client(base_url=self.base_url, timeout=timeout_seconds)

    def __del__(self):
        try:
            self._client.close()
        except Exception:
            pass

    # ─── Health ────────────────────────────────────────────────────────────

    def health(self) -> dict[str, Any]:
        """GET /v1/health"""
        resp = self._client.get("/v1/health")
        resp.raise_for_status()
        return resp.json()

    # ─── Team-administrative ───────────────────────────────────────────────

    def team_init(self, team_id: str, bearer: str) -> dict[str, Any]:
        """POST /v1/teams/{team_id}/init — idempotent provisioning."""
        resp = self._client.post(
            f"/v1/teams/{team_id}/init",
            headers={"Authorization": f"Bearer {bearer}"},
        )
        resp.raise_for_status()
        return resp.json()

    def team_status(self, team_id: str, bearer: str) -> dict[str, Any]:
        """GET /v1/teams/{team_id}/status"""
        resp = self._client.get(
            f"/v1/teams/{team_id}/status",
            headers={"Authorization": f"Bearer {bearer}"},
        )
        resp.raise_for_status()
        return resp.json()

    def team_delete(self, team_id: str, bearer: str) -> None:
        """DELETE /v1/teams/{team_id}"""
        resp = self._client.delete(
            f"/v1/teams/{team_id}",
            headers={"Authorization": f"Bearer {bearer}"},
        )
        resp.raise_for_status()

    # ─── Handler registration ──────────────────────────────────────────────

    def register(
        self,
        team_id: str,
        identity_b64: str,
        bearer: str,
        context_id: str,
        metadata: dict | None = None,
    ) -> dict[str, Any]:
        """POST /v1/teams/{team_id}/agents/{identity}/register"""
        body: dict[str, Any] = {"context_id": context_id}
        if metadata:
            body["metadata"] = metadata
        resp = self._client.post(
            f"/v1/teams/{team_id}/agents/{identity_b64}/register",
            headers={"Authorization": f"Bearer {bearer}"},
            json=body,
        )
        resp.raise_for_status()
        return resp.json()

    def unregister(
        self, team_id: str, identity_b64: str, context_id: str, bearer: str,
    ) -> None:
        """DELETE /v1/teams/{team_id}/agents/{identity}/handlers/{context_id}"""
        resp = self._client.delete(
            f"/v1/teams/{team_id}/agents/{identity_b64}/handlers/{context_id}",
            headers={"Authorization": f"Bearer {bearer}"},
        )
        resp.raise_for_status()

    # ─── Wake dispatch ─────────────────────────────────────────────────────

    def dispatch_wake(
        self,
        team_id: str,
        target_identity: str,
        context_id: str,
        payload: str,  # base64-encoded
        timeout_seconds: int,
        bearer: str,
    ) -> dict[str, Any]:
        """POST /v1/teams/{team_id}/wakes — dispatch + await completion."""
        resp = self._client.post(
            f"/v1/teams/{team_id}/wakes",
            headers={"Authorization": f"Bearer {bearer}"},
            json={
                "target_identity": target_identity,
                "context_id": context_id,
                "payload": payload,
                "timeout_seconds": timeout_seconds,
            },
            timeout=timeout_seconds + 5,
        )
        resp.raise_for_status()
        return resp.json()  # {wake_id, response, completed_at}

    def read_inbox(
        self,
        team_id: str,
        identity_b64: str,
        bearer: str,
        wait_seconds: int | None = 30,
        limit: int | None = 10,
    ) -> dict[str, Any]:
        """GET /v1/teams/{team_id}/agents/{identity}/inbox"""
        params: dict[str, int] = {}
        if wait_seconds is not None:
            params["wait_seconds"] = wait_seconds
        if limit is not None:
            params["limit"] = limit
        resp = self._client.get(
            f"/v1/teams/{team_id}/agents/{identity_b64}/inbox",
            headers={"Authorization": f"Bearer {bearer}"},
            params=params,
            timeout=(wait_seconds or 30) + 10,
        )
        resp.raise_for_status()
        return resp.json()  # {wakes: [...], more_available: bool}

    def complete_wake(
        self,
        team_id: str,
        wake_id: str,
        response_payload: str,  # base64-encoded
        bearer: str,
    ) -> dict[str, Any]:
        """POST /v1/teams/{team_id}/wakes/{wake_id}/complete"""
        resp = self._client.post(
            f"/v1/teams/{team_id}/wakes/{wake_id}/complete",
            headers={"Authorization": f"Bearer {bearer}"},
            json={"response": response_payload},
        )
        resp.raise_for_status()
        return resp.json()  # {completed, wake_id}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd ~/Projects/pronoic/tally-coding
uv run pytest tests/test_tally_workers.py -v
```
Expected: 4 passed (against live Tally Workers).

- [ ] **Step 5: Commit**

```bash
git add tally_coding_core/tally_workers.py tests/test_tally_workers.py
git commit -m "[core] Tally Workers HTTP client — 8 routes; integration tested"
git push
```

### Task 3.4: User provisions test team_id `[USER-BLOCK]`

This is more verification than blocking — the test above (Task 3.3 Step 4) already creates a temporary team_id per run. User just confirms tests pass.

- [ ] **Step 1: User runs the integration tests**

```bash
cd ~/Projects/pronoic/tally-coding
uv run pytest tests/test_tally_workers.py -v
```

Expected: 4 passed. If any fail, debug subagent dispatched.

### Task 3.5: Subagent writes `spike/day3/spike.py` `[PARALLEL]`

End-to-end Day 3 spike: dispatch a wake from one Python process to itself, prove the round-trip works.

- [ ] **Step 1: Write `spike/day3/spike.py`**

```python
"""Day 3 spike — dispatch a wake via Tally Workers + receive it back.

Validates the orchestrator/worker pattern end-to-end in a single process.
"""

from __future__ import annotations

import base64
import os
import sys
import threading
import time

from dotenv import load_dotenv

from tally_coding_core.identity import bearer_from_pubkey, load_or_create_identity
from tally_coding_core.tally_workers import TallyWorkersClient


def main() -> int:
    load_dotenv()

    tally_url = os.environ.get("TALLY_WORKERS_URL", "https://tally.nraimbault16.workers.dev")
    team_id = os.environ.get("TEST_TEAM_ID", "tally-coding-day3-spike")

    # Provision two identities for the spike
    alice_priv, alice_pub = load_or_create_identity(".identities/alice.key")
    bob_priv, bob_pub = load_or_create_identity(".identities/bob.key")
    alice_bearer = bearer_from_pubkey(alice_pub)
    bob_bearer = bearer_from_pubkey(bob_pub)

    client = TallyWorkersClient(base_url=tally_url)

    # Init team + register handlers
    client.team_init(team_id, bearer=alice_bearer)
    client.register(team_id, bob_bearer, bearer=bob_bearer, context_id="echo")
    print(f"[day3] team={team_id}; alice={alice_bearer[:8]}...; bob={bob_bearer[:8]}...")

    # Bob listens in background
    def bob_listen():
        while True:
            resp = client.read_inbox(team_id, bob_bearer, bearer=bob_bearer, wait_seconds=30)
            for wake in resp.get("wakes", []):
                print(f"[day3] bob received wake_id={wake['wake_id'][:8]} payload={wake['payload'][:20]}...")
                # Echo: reverse the bytes
                payload_bytes = base64.b64decode(wake["payload"])
                echo_bytes = payload_bytes[::-1]
                echo_b64 = base64.b64encode(echo_bytes).decode()
                client.complete_wake(team_id, wake["wake_id"], echo_b64, bearer=bob_bearer)
                print(f"[day3] bob completed wake_id={wake['wake_id'][:8]}")
                return  # one wake handled; exit listener

    listener = threading.Thread(target=bob_listen, daemon=True)
    listener.start()
    time.sleep(1)  # give listener a beat to start

    # Alice dispatches a wake
    payload = base64.b64encode(b"hello tally").decode()
    print(f"[day3] alice dispatching wake to bob...")
    result = client.dispatch_wake(
        team_id=team_id,
        target_identity=bob_bearer,
        context_id="echo",
        payload=payload,
        timeout_seconds=30,
        bearer=alice_bearer,
    )

    response_bytes = base64.b64decode(result["response"])
    expected = b"hello tally"[::-1]

    print(f"[day3] alice got response wake_id={result['wake_id'][:8]} response={response_bytes}")
    print(f"[day3] expected reversed: {expected}")

    listener.join(timeout=2)

    if response_bytes == expected:
        print("[day3] SUCCESS")
        return 0
    else:
        print("[day3] FAILURE")
        return 1


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Add `.identities/` to spike/day3/.gitignore (don't commit private keys)**

```bash
mkdir -p spike/day3
echo ".identities/" > spike/day3/.gitignore
echo ".env" >> spike/day3/.gitignore
```

- [ ] **Step 3: Write `spike/day3/.env.example`**

```
TALLY_WORKERS_URL=https://tally.nraimbault16.workers.dev
TEST_TEAM_ID=tally-coding-day3-spike-XXXX
```

- [ ] **Step 4: Commit**

```bash
git add spike/day3/spike.py spike/day3/.gitignore spike/day3/.env.example
git commit -m "[spike/day3] dispatch wake via Tally Workers + receive in same process"
git push
```

### Task 3.6: User runs Day 3 spike `[USER-BLOCK]`

- [ ] **Step 1: User copies .env**

```bash
cd ~/Projects/pronoic/tally-coding/spike/day3
cp .env.example .env
# Edit .env: optionally customize TEST_TEAM_ID
```

- [ ] **Step 2: User runs**

```bash
cd ~/Projects/pronoic/tally-coding
uv run python -m spike.day3.spike
```

Expected: `[day3] SUCCESS` printed.

- [ ] **Step 3: Capture result**

```bash
echo "Day 3 SUCCESS at $(date -u +%FT%TZ)" > spike/day3/RESULT.md
git add spike/day3/RESULT.md
git commit -m "[spike/day3] Tally Workers wake roundtrip validated"
git push
```

---

## Day 4 — Multi-agent coordination across Phala CVMs

**Files to create:**
- `spike/day4/orchestrator/Dockerfile`
- `spike/day4/orchestrator/spike.py` — orchestrator agent (cloud CVM)
- `spike/day4/worker/Dockerfile`
- `spike/day4/worker/spike.py` — worker agent (cloud CVM)
- `spike/day4/docker-compose.orchestrator.yml`
- `spike/day4/docker-compose.worker.yml`
- `spike/day4/README.md`

### Task 4.1: Subagent writes orchestrator + worker scripts `[PARALLEL]`

End-to-end: orchestrator CVM dispatches "do a coding task" wake; worker CVM clones test repo, edits file, runs test, posts result back.

- [ ] **Step 1: Write `spike/day4/worker/spike.py`**

Worker: poll Tally Workers inbox; on wake, decode task spec, use OpenHands to do it, encode result, complete wake.

(Full code in subagent dispatch; structurally similar to Day 2 spike but driven by wakes instead of being a one-shot.)

- [ ] **Step 2: Write `spike/day4/orchestrator/spike.py`**

Orchestrator: dispatch coding task wake to worker; await result; print outcome.

- [ ] **Step 3: Write Dockerfiles + docker-compose files**

- [ ] **Step 4: Commit**

```bash
git add spike/day4/
git commit -m "[spike/day4] orchestrator + worker spike for multi-agent coordination"
git push
```

### Task 4.2: User deploys both CVMs `[USER-BLOCK]`

- [ ] **Step 1: Deploy worker CVM**

```bash
cd ~/Projects/pronoic/tally-coding/spike/day4/worker
phala deploy -e ../.env --name spike-day4-worker
```

- [ ] **Step 2: Deploy orchestrator CVM**

```bash
cd ~/Projects/pronoic/tally-coding/spike/day4/orchestrator
phala deploy -e ../.env --name spike-day4-orchestrator
```

- [ ] **Step 3: Capture results**

Read both CVM logs. Confirm: orchestrator dispatched, worker received, worker did coding task, worker completed wake, orchestrator received result.

- [ ] **Step 4: Commit RESULT.md**

```bash
git add spike/day4/RESULT.md
git commit -m "[spike/day4] multi-agent coordination across two Phala CVMs validated"
git push
```

---

## Day 5 — Flutter scaffold + Skytale Dart SDK skeleton

**Files to create:**
- `app/` directory (Flutter project)
- `app/lib/main.dart` (minimal "hello Tally" screen)
- `app/pubspec.yaml`
- In `~/Projects/pronoic/skytale/sdk/dart/` (operator's skytale repo):
  - `pubspec.yaml`
  - `lib/skytale_sdk.dart`
  - `lib/src/agent_identity.dart`
  - `lib/src/skytale_client.dart`
  - `lib/src/types.dart`
- `app/README.md`

### Task 5.1: User installs Flutter SDK `[USER-BLOCK]`

- [ ] **Step 1: Install Flutter via FVM**

```bash
brew tap leoafarias/fvm
brew install fvm
fvm install stable
fvm use stable
flutter doctor  # via fvm flutter doctor
```

- [ ] **Step 2: Configure macOS desktop target**

```bash
fvm flutter config --enable-macos-desktop
```

### Task 5.2: Subagent scaffolds Flutter app `[PARALLEL]`

- [ ] **Step 1: Initialize Flutter project**

```bash
cd ~/Projects/pronoic/tally-coding
fvm flutter create app --platforms=macos,ios,android,linux,windows --org=codes.tally
```

- [ ] **Step 2: Verify macOS build works**

```bash
cd app
fvm flutter run -d macos
```

Expected: blank Flutter window opens.

- [ ] **Step 3: Commit**

```bash
cd ~/Projects/pronoic/tally-coding
git add app/
git commit -m "[app] initial Flutter scaffold; macOS build verified"
git push
```

### Task 5.3: Subagent scaffolds Skytale Dart SDK in operator's skytale repo `[PARALLEL]`

This produces code in `~/Projects/pronoic/skytale/`, a separate repo. Subagent must commit there, not in tally-coding.

- [ ] **Step 1: Create directory structure**

```bash
cd ~/Projects/pronoic/skytale
mkdir -p sdk/dart/lib/src
```

- [ ] **Step 2: Write `sdk/dart/pubspec.yaml`**

```yaml
name: skytale_sdk
description: Dart SDK for Skytale — MLS-encrypted channels + AgentIdentity for AI agents
version: 0.0.1
environment:
  sdk: ^3.4.0

dependencies:
  cryptography: ^2.7.0
  http: ^1.2.0
  ffi: ^2.1.0  # for dart:ffi to Rust skytale-sdk

dev_dependencies:
  test: ^1.25.0
  lints: ^4.0.0
```

- [ ] **Step 3: Write `sdk/dart/lib/skytale_sdk.dart`**

```dart
/// Skytale Dart SDK — MLS-encrypted channels + AgentIdentity for AI agents.
///
/// v0.0.1 scope: AgentIdentity (Ed25519 + did:key), basic envelope types,
/// SkytaleClient (connection to relay). MLS encryption to come via dart:ffi
/// to Rust skytale-sdk in v0.0.2.
library skytale_sdk;

export 'src/agent_identity.dart';
export 'src/skytale_client.dart';
export 'src/types.dart';
```

- [ ] **Step 4: Write `sdk/dart/lib/src/agent_identity.dart`**

(Minimal Dart implementation: generate Ed25519 keypair, encode as did:key, provide sign/verify methods.)

- [ ] **Step 5: Write `sdk/dart/lib/src/skytale_client.dart`**

(Stub for now; real implementation in v0.0.2.)

- [ ] **Step 6: Write `sdk/dart/lib/src/types.dart`**

(Identity, TeamId; matching the Rust skytale-sdk types.)

- [ ] **Step 7: Commit in skytale repo**

```bash
cd ~/Projects/pronoic/skytale
git add sdk/dart/
git commit -m "[sdk/dart] initial Skytale Dart SDK skeleton (AgentIdentity + types)"
# Note: skytale main is protected; this commit lives on a branch awaiting PR
git checkout -b dart-sdk-skeleton
git push -u origin dart-sdk-skeleton
gh pr create --title "Skytale Dart SDK skeleton (AgentIdentity + types + client stub)" --body "Operator-built Dart SDK to support Tally Coding's Flutter app. v0.0.1 scope: AgentIdentity + did:key encoding + types. v0.0.2 will add MLS via dart:ffi to Rust skytale-sdk."
```

### Task 5.4: Subagent integrates Dart SDK into Flutter app `[PARALLEL]`

- [ ] **Step 1: Add Dart SDK as path dependency**

In `app/pubspec.yaml`:
```yaml
dependencies:
  flutter:
    sdk: flutter
  skytale_sdk:
    path: ../../skytale/sdk/dart
```

- [ ] **Step 2: Write `app/lib/main.dart`**

Tiny app: button "Generate test identity" → calls `AgentIdentity.generate()` → displays the resulting did:key.

- [ ] **Step 3: Run app**

```bash
cd app
fvm flutter run -d macos
```

Expected: blank window with button + identity display.

- [ ] **Step 4: Commit**

```bash
cd ~/Projects/pronoic/tally-coding
git add app/
git commit -m "[app] integrate Skytale Dart SDK; render AgentIdentity on tap"
git push
```

### Task 5.5: User verifies + capture week 1 close `[USER-BLOCK]`

- [ ] **Step 1: User runs Flutter app**

```bash
cd ~/Projects/pronoic/tally-coding/app
fvm flutter run -d macos
```

Tap the button. Verify a `did:key:z6Mk...` appears.

- [ ] **Step 2: Write Week 1 RESULT**

```bash
cat > ~/Projects/pronoic/tally-coding/WEEK-1-COMPLETE.md <<EOF
# Week 1 Complete — $(date -u +%F)

Validated end-to-end:
- ✅ Day 1: OpenHands + Phala Redpill local spike
- ✅ Day 2: Phala CVM deployment
- ✅ Day 3: Tally Workers HTTP integration from Python
- ✅ Day 4: Multi-agent coordination across two Phala CVMs
- ✅ Day 5: Flutter scaffold + Skytale Dart SDK skeleton

Gaps resolved:
- B.14 Phala CVM cold start: <N> seconds (per Day 2)
- B.16 Per-task vs pooled lifecycle: per-task confirmed viable; defer pooled to v1.5+

Next: Week 2 — Skytale Dart SDK foundation (FFI bindings + MLS).
EOF

git add WEEK-1-COMPLETE.md
git commit -m "[week-1] complete; all 5 days validated"
git push
```

---

## Day-by-day summary

| Day | Goal | User blockers | Subagent parallelizable |
|---|---|---|---|
| 1 | Local OpenHands + Phala Redpill spike | Add API key; run uv sync; run spike.py; commit uv.lock | Day 2-5 prep |
| 2 | Containerize + deploy to Phala CVM | `phala login`; `phala deploy`; capture cold start | Dockerfile + compose; spike adaptation |
| 3 | Python Tally Workers HTTP client + roundtrip | Run integration tests | Client code + tests + spike |
| 4 | Multi-agent coordination across two CVMs | Deploy both CVMs; capture coordination | Orchestrator + worker code |
| 5 | Flutter scaffold + Skytale Dart SDK skeleton | Install Flutter SDK; run app | Flutter project + Dart SDK skeleton |

## Stop-and-surface triggers

Per `docs/tally-coding-week-1-scope-2026-05-15.md`, halt and surface to user if:

1. Day 1 OpenHands + Phala Redpill don't integrate → fundamental stack rethink
2. Modal-like cold starts > 30s on Phala CVM → switch to pooled architecture (B.16)
3. Tally Workers API gaps surface → fix Tally Workers in operator's repo, then resume
4. Skytale Dart SDK approach fails (FFI doesn't work cleanly) → switch to REST wrapper approach
5. Flutter macOS build issues → revisit desktop framework choice

## Provenance

Generated 2026-05-16 via `superpowers:writing-plans` skill. Executed via `superpowers:subagent-driven-development`. Authorization: max automation; commit/push freely; only interrupt for items tagged `[USER-BLOCK]`.
