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
You're in an empty Python workspace. Complete this task:

1. Create `greet.py`. It should:
   - Read the environment variable `NAME`
   - Print `hello, <NAME>` (substituting the actual value) followed by a newline
   - If `NAME` is not set or is empty, print `hello, world`

2. Create `test_greet.py` using pytest. It should:
   - Test that running `greet.py` with `NAME=alice` produces the output `hello, alice\\n`
   - Test that running `greet.py` with no `NAME` env var produces `hello, world\\n`

3. Install pytest if not available (use pip).

4. Run pytest. If tests pass, you're done. If they fail, debug and fix.

Report success or failure clearly when done.
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
