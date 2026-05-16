"""Day 1 spike — validate OpenHands SDK + Phala Redpill TEE inference end-to-end.

Goal: a single OpenHands coding agent using Phala Redpill (Kimi K2.6, TEE-attested)
completes a real coding task in a fresh workspace. If this works, the cloud-side
stack is validated and we can move to Day 2 (deploying to Phala CVM).

What this validates:
- OpenHands SDK installs + imports correctly on Python 3.12
- Phala Redpill is reachable + accepts OpenAI-compatible requests
- The agent can use TerminalTool (run shell commands) and FileEditorTool (write files)
- A real coding task (create file + write test + run pytest) completes
- TEE attestation routing happens (verify in response headers / Phala dashboard)
"""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

from dotenv import load_dotenv

from openhands.sdk import LLM, Agent, Conversation, Tool
from openhands.tools.terminal import TerminalTool
from openhands.tools.file_editor import FileEditorTool
from openhands.tools.task_tracker import TaskTrackerTool


def build_llm() -> LLM:
    """Configure OpenHands LLM pointed at Phala Redpill (TEE-attested inference)."""
    api_key = os.environ.get("REDPILL_API_KEY")
    if not api_key or api_key == "your_phala_redpill_api_key_here":
        sys.exit(
            "REDPILL_API_KEY not set. Copy .env.example to .env and add your "
            "Phala API key, then re-run."
        )

    base_url = os.environ.get("REDPILL_BASE_URL", "https://api.redpill.ai/v1")
    model_name = os.environ.get("REDPILL_MODEL", "moonshotai/Kimi-K2-6")

    # LiteLLM (which OpenHands uses) expects "openai/<model>" prefix for
    # OpenAI-compatible endpoints that aren't openai.com itself.
    return LLM(
        model=f"openai/{model_name}",
        api_key=api_key,
        base_url=base_url,
    )


def build_agent(llm: LLM) -> Agent:
    """OpenHands agent with the three coding-task tools."""
    return Agent(
        llm=llm,
        tools=[
            Tool(name=TerminalTool.name),
            Tool(name=FileEditorTool.name),
            Tool(name=TaskTrackerTool.name),
        ],
    )


def run_spike() -> int:
    """Run the spike. Returns 0 on success; non-zero otherwise."""
    load_dotenv()
    llm = build_llm()
    agent = build_agent(llm)

    # Fresh workspace per run so we know the agent created the files.
    workspace = Path(tempfile.mkdtemp(prefix="tally-spike-day1-"))
    print(f"[spike] workspace: {workspace}")

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

    # Verify outputs
    greet_py = workspace / "greet.py"
    test_greet_py = workspace / "test_greet.py"

    print()
    print("=" * 60)
    print("[spike] RESULT")
    print("=" * 60)

    success = True

    if greet_py.exists():
        print(f"[ok ] {greet_py.name} created ({greet_py.stat().st_size} bytes)")
        print(f"      content:\n{greet_py.read_text()}")
    else:
        print(f"[fail] {greet_py.name} NOT created")
        success = False

    print()

    if test_greet_py.exists():
        print(f"[ok ] {test_greet_py.name} created ({test_greet_py.stat().st_size} bytes)")
    else:
        print(f"[fail] {test_greet_py.name} NOT created")
        success = False

    print()
    print(f"[spike] workspace preserved at: {workspace}")
    print("[spike] inspect manually; delete when done.")

    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(run_spike())
