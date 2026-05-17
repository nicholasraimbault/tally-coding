"""Day 4 / Sprint 2 worker — receives MLS-encrypted task wakes via Tally Workers.

Bootstrap dance (plaintext, public MLS artifacts only):
  1. Orchestrator dispatches mls:bootstrap with phase=request_kp
  2. Worker responds with its KeyPackage (base64)
  3. Orchestrator dispatches mls:bootstrap with phase=welcome + Welcome bytes
  4. Worker calls MlsSession.join(welcome), registers for task:start

Task delivery (MLS-encrypted):
  5. Orchestrator dispatches task:start with payload = MLS-encrypted {"task": "..."}
  6. Worker decrypts via MlsSession, runs OpenHands, encrypts response
  7. Worker completes the wake with the encrypted response
"""

from __future__ import annotations

import base64
import json
import os
import sys
from pathlib import Path

from openhands.sdk import LLM, Agent, Conversation, Tool
from openhands.tools.terminal import TerminalTool
from openhands.tools.file_editor import FileEditorTool
from openhands.tools.task_tracker import TaskTrackerTool

from tally_coding_core.identity import bearer_from_pubkey, load_or_create_identity
from tally_coding_core.mls import MlsSession
from tally_coding_core.tally_workers import TallyWorkersClient


BOOTSTRAP_CONTEXT_ID = "mls:bootstrap"
TASK_CONTEXT_ID = "task:start"


def b64url_no_pad(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def b64url_decode(s: str) -> bytes:
    s = s + "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s)


def build_llm() -> LLM:
    api_key = os.environ.get("REDPILL_API_KEY")
    if not api_key:
        sys.exit("REDPILL_API_KEY not set")
    base_url = os.environ.get("REDPILL_BASE_URL", "https://api.redpill.ai/v1")
    model_name = os.environ.get("REDPILL_MODEL", "moonshotai/kimi-k2.6")
    return LLM(model=f"openai/{model_name}", api_key=api_key, base_url=base_url)


def perform_task(task_description: str, workspace: Path) -> dict:
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
    conversation.send_message(task_description)
    conversation.run()
    files_created = sorted(
        str(p.relative_to(workspace)) for p in workspace.rglob("*") if p.is_file()
    )
    return {"success": True, "files_created": files_created}


def handle_bootstrap_wake(session: MlsSession, payload: bytes) -> tuple[bytes, bool]:
    """Returns (response_bytes, bootstrapped_now). response_bytes is plaintext JSON."""
    msg = json.loads(payload.decode("utf-8"))
    phase = msg.get("phase")
    if phase == "request_kp":
        kp = session.my_key_package()
        print(f"[worker] bootstrap: returning key_package ({len(kp)} bytes)", flush=True)
        return json.dumps({"key_package": b64url_no_pad(kp)}).encode("utf-8"), False
    elif phase == "welcome":
        welcome = b64url_decode(msg["welcome"])
        session.join(welcome)
        print(f"[worker] bootstrap: joined group via welcome ({len(welcome)} bytes)", flush=True)
        return json.dumps({"ok": True}).encode("utf-8"), True
    else:
        return json.dumps({"error": f"unknown phase: {phase}"}).encode("utf-8"), False


def handle_task_wake(session: MlsSession, payload: bytes, workspace: Path) -> bytes:
    """Decrypt payload, run task, return MLS-encrypted response bytes."""
    plaintext_json = session.decrypt(payload).decode("utf-8")
    task_spec = json.loads(plaintext_json)
    task_description = task_spec["task"]
    print(f"[worker] task (decrypted): {task_description[:80]}...", flush=True)
    result = perform_task(task_description, workspace)
    return session.encrypt(json.dumps(result).encode("utf-8"))


def main() -> int:
    tally_url = os.environ.get("TALLY_WORKERS_URL", "https://tally.nraimbault16.workers.dev")
    team_id = os.environ["TEAM_ID"]
    identity_path = os.environ.get("WORKER_IDENTITY_PATH", "/data/worker.key")
    mls_state_dir = os.environ.get("WORKER_MLS_STATE_DIR", "/workspace/mls-state")

    workspace = Path(os.environ.get("WORKSPACE_DIR", "/workspace"))
    workspace.mkdir(parents=True, exist_ok=True)
    Path(mls_state_dir).mkdir(parents=True, exist_ok=True)

    _privkey, pubkey = load_or_create_identity(identity_path)
    bearer = bearer_from_pubkey(pubkey)

    client = TallyWorkersClient(base_url=tally_url)
    client.team_init(team_id, bearer=bearer)
    client.register(team_id, bearer, bearer=bearer, context_id=BOOTSTRAP_CONTEXT_ID)
    print(f"[worker] ready; team={team_id}; identity={bearer}", flush=True)

    # group_id will be replaced when we join via Welcome; placeholder for now.
    session = MlsSession(
        data_dir=mls_state_dir,
        identity=pubkey,
        group_id=b"pending-bootstrap",
    )

    task_handler_registered = False

    while True:
        resp = client.read_inbox(team_id, bearer, bearer=bearer, wait_seconds=30)
        wakes = resp.get("wakes", [])
        if not wakes:
            print("[worker] inbox empty; continuing to poll...", flush=True)
            continue
        wake = wakes[0]
        wake_id = wake["wake_id"]
        context_id = wake.get("context_id", "?")
        print(f"[worker] received wake_id={wake_id[:8]} context={context_id}", flush=True)

        payload = b64url_decode(wake["payload"])
        try:
            if context_id == BOOTSTRAP_CONTEXT_ID:
                response_bytes, bootstrapped_now = handle_bootstrap_wake(session, payload)
                if bootstrapped_now and not task_handler_registered:
                    client.register(team_id, bearer, bearer=bearer, context_id=TASK_CONTEXT_ID)
                    task_handler_registered = True
                    print("[worker] registered task:start handler post-bootstrap", flush=True)
            elif context_id == TASK_CONTEXT_ID:
                if not session.bootstrapped:
                    raise RuntimeError("task wake received before MLS bootstrap")
                response_bytes = handle_task_wake(session, payload, workspace)
            else:
                raise RuntimeError(f"unknown context_id: {context_id}")
        except Exception as exc:
            print(f"[worker] wake handler failed: {exc}", flush=True)
            response_bytes = json.dumps({"success": False, "error": str(exc)}).encode("utf-8")

        client.complete_wake(team_id, wake_id, b64url_no_pad(response_bytes), bearer=bearer)
        print(f"[worker] completed wake_id={wake_id[:8]}", flush=True)

        # After completing a task wake, exit (CVM lifecycle).
        if context_id == TASK_CONTEXT_ID:
            return 0


if __name__ == "__main__":
    sys.exit(main())
