# Tally Coding — OpenHands SDK Exploration

**Date:** 2026-05-15 (drafted); 2026-05-16 (verified patterns added)
**Purpose:** Captures current understanding of OpenHands SDK API for platform integration. Verified against OpenHands SDK docs (`docs.openhands.dev/sdk` via context7) 2026-05-16.

## SDK summary

Package: openhands-ai (PyPI; May 2026 release)
License: MIT
Language: Python 3.12+
Repo: github.com/OpenHands/software-agent-sdk
Docs: docs.openhands.dev/sdk
Paper: arXiv 2511.03690 (MLSys 2026)

Core abstraction: Agent / Conversation / Workspace / Tool / Event

Positioned as engine behind OpenHands CLI and OpenHands Cloud — production-grade, not research artifact. Active development.

## Core primitives

### LLM

Wrapper around LiteLLM. Configures model provider, API key, base URL.

```python
from openhands.sdk import LLM

llm = LLM(
    model="anthropic/claude-sonnet-4-5-20250929",
    api_key=os.getenv("LLM_API_KEY"),
)
```

For Maple integration:
```python
llm = LLM(
    model="openai/gpt-oss-120b",  # or other Maple model
    api_key=os.getenv("MAPLE_API_KEY"),
    base_url="https://enclave.trymaple.ai/v1",
)
```

### Tool

Built-in: TerminalTool, FileEditorTool, TaskTrackerTool, BrowserTool, others via MCP.

Custom tools via subclassing.

### Agent

Combines LLM + tools + (optional) system prompt.

```python
from openhands.sdk import Agent, Tool
from openhands.tools.terminal import TerminalTool
from openhands.tools.file_editor import FileEditorTool

agent = Agent(
    llm=llm,
    tools=[Tool(name=TerminalTool.name), Tool(name=FileEditorTool.name)],
    system_prompt="You are an architect...",
)
```

### Workspace

Local cwd OR remote workspace via Agent Server (Docker/Kubernetes).

### Conversation

Agent + workspace + message history.

```python
conversation = Conversation(agent=agent, workspace=cwd)
conversation.send_message("Write 3 facts about the project into FACTS.txt")
conversation.run()
```

`conversation.run()` is the agent loop.

### Event stream

Every Action and Observation is an Event. Stored in history; replayable; observable real-time for streaming UIs.

Key primitive for Tally Coding: events from agents flow through Tally to other agents AND to Convex for UI.

## Patterns for Tally Coding

### Agent persistence

OpenHands agents stateless per-conversation. For long-term roles: persist Agent CONFIG in Convex; instantiate per task; load prior events to rebuild context.

### Inter-agent messaging via Tally

OpenHands has no built-in multi-agent coordination. Use Tally (which uses Skytale internally for E2E encryption — the relay sees only ciphertext):

```python
class SendToOrchestratorTool(Tool):
    def execute(self, message: str):
        tally_client.dispatch(
            target=ORCHESTRATOR_IDENTITY,
            payload=message,
            context="worker-to-orchestrator",
        )
        return "Message dispatched to orchestrator"
```

Each agent role has custom tools for messages it can send.

### Remote workspaces

OpenHands Agent Server: Docker-managed workspaces. Documented in examples/02_remote_agent_server/.

Decision: probably simpler to run workers directly on Modal with Modal Sandbox than nest Agent Server inside Modal. Re-evaluate week 6.

### Event streaming to UI

```python
conversation.on_event = lambda event: convex.append_event(conversation_id, event)
conversation.run()
```

Convex reactive subscriptions push events to client UI.

## Integration points

### LiteLLM → Maple Proxy

OpenAI-compatible. Configure base_url:
```python
LLM(
    model="openai/",
    api_key="",
    base_url="https://enclave.trymaple.ai/v1",
)
```

### Modal hosting

```python
import modal

app = modal.App("pronoic-agent")
image = modal.Image.debian_slim().pip_install("openhands-ai")

@app.function(image=image, secrets=[modal.Secret.from_name("maple-keys")])
def run_agent(task: str, agent_config: dict):
    llm = LLM(...)
    agent = Agent(llm=llm, tools=[...])
    conversation = Conversation(agent=agent, workspace="/tmp/workspace")
    conversation.send_message(task)
    conversation.run()
    return conversation.events
```

### Sandboxing via Modal

```python
@app.function(image=image)
def run_worker(task: str):
    with modal.Sandbox.create(image=worker_image) as sandbox:
        # Worker agent in sandbox; destroyed on exit
        pass
```

## Open SDK questions

1. ~~Conversation resumption API specifics~~ → **Resolved**: `Conversation(persistence_dir=..., conversation_id=uuid)`. After `del`, reconstruct with same `conversation_id` against same `persistence_dir` to resume.
2. ~~Streaming vs batch LLM responses for UI~~ → **Resolved**: `Conversation(callbacks=[fn])` streams Events (Actions, Observations, LLMConvertibleEvents) as they occur. Platform wires `convex_event_callback`.
3. Tool error handling semantics — Observation type's `success: bool` field convention; need to verify uncaught exception behavior in week 1
4. MCP integration usefulness for user-provided tools (Phase 2)
5. ~~Agent-to-agent within SDK ("subagent") vs Tally~~ → **Resolved**: OpenHands SDK has no built-in subagent primitive for inter-process coordination. Tally is the right abstraction. The platform builds custom `ToolDefinition` wrappers around Skytale + Tally.

## Verified API patterns (2026-05-16)

### Custom tool pattern (for Skytale + Tally wrappers)

```python
from openhands.sdk import Action, Observation, ToolDefinition
from openhands.sdk.tool import ToolExecutor, register_tool

class MyAction(Action):
    param1: str
    param2: int

class MyObservation(Observation):
    result: str
    success: bool

class MyExecutor(ToolExecutor[MyAction, MyObservation]):
    def __call__(self, action, conversation=None):
        return MyObservation(result="...", success=True)

class MyTool(ToolDefinition[MyAction, MyObservation]):
    @classmethod
    def create(cls, conv_state, **params):
        return [cls(
            description="Tool description",
            action_type=MyAction,
            observation_type=MyObservation,
            executor=MyExecutor(),
        )]

register_tool("MyTool", MyTool)
```

Then use: `Agent(llm=llm, tools=[Tool(name="MyTool")])`.

### Callback-based event streaming

```python
def convex_event_callback(event):
    convex_client.mutation("events:append", {
        "conversation_id": str(conv_id),
        "event_kind": type(event).__name__,
        "payload": event.model_dump(),
    })

conversation = Conversation(
    agent=agent,
    workspace=workspace,
    callbacks=[convex_event_callback],
    persistence_dir=f"/data/conversations/{conv_id}",
    conversation_id=conv_id,
    max_iteration_per_run=500,
    stuck_detection=True,
)
```

### Conversation resumption

```python
# First run
conv_id = uuid.uuid4()
c = Conversation(agent=agent, workspace=ws, persistence_dir=PDIR, conversation_id=conv_id)
c.send_message("write hello.py")
c.run()
del c

# Later: resume
c2 = Conversation(agent=agent, workspace=ws, persistence_dir=PDIR, conversation_id=conv_id)
c2.send_message("now add a docstring")
c2.run()
# Access metrics
stats = c2.conversation_stats.get_combined_metrics()
print(f"cost: ${stats.accumulated_cost}")
```

### Remote workspace (alternative to in-process)

```python
from openhands.sdk import RemoteWorkspace

workspace = RemoteWorkspace(
    remote_url="http://localhost:8000",
    api_key=os.getenv("AGENT_SERVER_API_KEY"),
)
conversation = Conversation(
    agent=agent,
    workspace=workspace,
    delete_on_close=True,
)
```

Comes with built-in WebSocket event endpoint: `ws://server/conversations/{id}/events/socket`.

### AgentContext + Skills (for role-pack content)

```python
from openhands.sdk.context import Skill, AgentContext

agent = Agent(
    llm=llm,
    tools=[...],
    agent_context=AgentContext(
        skills=[
            Skill(name="reviewer", content="Review code for...", trigger=None),
        ],
        system_message_suffix="Coordinate via Skytale/Tally tools.",
    ),
)
```

Platform's `board:reviewer` / `board:architect` / etc. role packs can be expressed as `Skill` objects loaded from YAML.

## Comparison context

Considered:
- Goose (Block): less production-mature for SDK use; Apache 2.0
- Claude Agent SDK: doesn't support Maple/privacy positioning
- Cline / Roo Code: VS Code extensions; wrong shape
- Aider: terminal-based; wrong shape
- SWE-agent: research-grade

OpenHands SDK is right fit.

## Provenance

Drafted 2026-05-15. Research-grounded via docs + GitHub + MLSys 2026 paper.
