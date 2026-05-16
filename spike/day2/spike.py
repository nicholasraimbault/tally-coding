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
