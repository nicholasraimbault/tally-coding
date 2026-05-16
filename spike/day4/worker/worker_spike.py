"""Day 4 worker — polls Tally Workers inbox; runs OpenHands SDK on incoming tasks.

Wake payload contract: JSON {"task": "<task description>"}. Worker decodes,
runs OpenHands on /workspace, then completes the wake with a JSON response
{"success": true|false, "files_created": [...], "stdout_tail": "..."}.
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
from tally_coding_core.tally_workers import TallyWorkersClient


WORKER_CONTEXT_ID = "task:start"


def build_llm() -> LLM:
    api_key = os.environ.get("REDPILL_API_KEY")
    if not api_key:
        sys.exit("REDPILL_API_KEY not set")
    base_url = os.environ.get("REDPILL_BASE_URL", "https://api.redpill.ai/v1")
    model_name = os.environ.get("REDPILL_MODEL", "moonshotai/Kimi-K2-6")
    return LLM(model=f"openai/{model_name}", api_key=api_key, base_url=base_url)


def perform_task(task_description: str, workspace: Path) -> dict:
    """Run OpenHands agent in workspace to perform task_description."""
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

    # Collect what was created
    files_created = sorted(str(p.relative_to(workspace)) for p in workspace.rglob("*") if p.is_file())
    return {"success": True, "files_created": files_created}


def main() -> int:
    tally_url = os.environ.get("TALLY_WORKERS_URL", "https://tally.nraimbault16.workers.dev")
    team_id = os.environ["TEAM_ID"]
    identity_path = os.environ.get("WORKER_IDENTITY_PATH", "/data/worker.key")

    workspace = Path(os.environ.get("WORKSPACE_DIR", "/workspace"))
    workspace.mkdir(parents=True, exist_ok=True)

    _privkey, pubkey = load_or_create_identity(identity_path)
    bearer = bearer_from_pubkey(pubkey)

    client = TallyWorkersClient(base_url=tally_url)

    # Ensure team exists + register our handler
    client.team_init(team_id, bearer=bearer)
    client.register(team_id, bearer, bearer=bearer, context_id=WORKER_CONTEXT_ID)
    print(f"[worker] ready; team={team_id}; identity={bearer[:8]}...", flush=True)

    # Poll loop: handle one task then exit (CVM lifecycle; orchestrator restarts as needed)
    while True:
        resp = client.read_inbox(team_id, bearer, bearer=bearer, wait_seconds=30)
        wakes = resp.get("wakes", [])
        if not wakes:
            print("[worker] inbox empty; continuing to poll...", flush=True)
            continue
        wake = wakes[0]
        wake_id = wake["wake_id"]
        print(f"[worker] received wake_id={wake_id[:8]}", flush=True)

        try:
            payload_json = base64.b64decode(wake["payload"]).decode("utf-8")
            task_spec = json.loads(payload_json)
            task_description = task_spec["task"]
            print(f"[worker] task: {task_description[:80]}...", flush=True)
            result = perform_task(task_description, workspace)
        except Exception as exc:
            print(f"[worker] task failed: {exc}", flush=True)
            result = {"success": False, "error": str(exc)}

        result_b64 = base64.b64encode(json.dumps(result).encode("utf-8")).decode("ascii")
        client.complete_wake(team_id, wake_id, result_b64, bearer=bearer)
        print(f"[worker] completed wake_id={wake_id[:8]}; result={result}", flush=True)
        return 0


if __name__ == "__main__":
    sys.exit(main())
