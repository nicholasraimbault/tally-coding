# Tally Coding — Stack Integration

**Date:** 2026-05-16
**Purpose:** Concrete integration architecture across OpenHands SDK, Skytale, Tally, and Maple AI. The "how it all fits together" reference for implementation. Grounded in source-of-truth research across the Skytale repo, Tally repo, and OpenHands SDK docs.

## Stack layers

```
End user (browser)
   │
   │ HTTPS + WebSocket
   ▼
Next.js + shadcn/ui + Tailwind (Vercel)              ← Web frontend
   │ Clerk (GitHub OAuth)
   │
   ▼
Convex (reactive backend)                            ← State + real-time sync
   │  - User accounts, projects, conversations, events, executions
   │  - Reactive subscriptions push events to browser
   │
   ▼
Modal-hosted Python agents                           ← Agent runtime
   │  - OpenHands SDK (LLM + Tool + Conversation + Workspace)
   │  - Custom tools wrap Skytale + Tally primitives
   │  - Modal Sandbox containers for worker code execution
   │
   ├─ LLM inference ──► Maple AI (TEE-attested) via Maple Proxy
   │                     ("https://enclave.trymaple.ai/v1", OpenAI-compatible)
   │
   ├─ Inter-agent channels ──► Skytale relay (MLS-encrypted)
   │                            relay.skytale.sh:5000 (QUIC/gRPC)
   │                            via skytale-sdk Python SDK
   │                            (SkytaleChannelManager / OrchestrationAgent)
   │
   ├─ Agent team management ──► Skytale API
   │                             api.skytale.sh (REST; account + keys + teams)
   │
   └─ Transient wake dispatch ──► Tally (Cloudflare Workers HTTP)
                                   tally.nraimbault16.workers.dev
                                   (Stoa WakeRouter implementation)
```

Two cryptographic privacy guarantees compose the platform's privacy story:
1. **LLM inference is TEE-attested** — Maple AI's Trusted Execution Environments; LLM provider sees only attested calls.
2. **Inter-agent messaging is E2E encrypted** — Skytale's MLS RFC 9420 channels; the Skytale relay sees only ciphertext.

## Resource model

The platform operates one shared Skytale account (operator-owned) and partitions per-user resources within it. Customers never see Skytale — they sign up for Tally.

**Platform-wide (one of each, operator-owned):**

| Resource | Where stored |
|---|---|
| Platform Skytale account | Skytale (via `api.skytale.sh`) |
| Platform Skytale API key (`sk_live_...`) | Modal secret + Convex secret (encrypted) |
| Platform GitHub App (for repo OAuth) | GitHub App config + secrets |
| Platform Maple AI subscription | Maple AI plan (operator pays wholesale) |

**Per-platform-user (provisioned at signup):**

| Resource | Scope | Where stored |
|---|---|---|
| Clerk user identity | 1 per signup | Clerk |
| Convex user record | 1 per signup | Convex `users` table |
| Agent identities (Ed25519 + did:key) | N per user (7 for v1.0: 4 board + 3 worker) | Convex secret per agent |
| Tally Workers `team_id` | 1 per platform user (one DO instance) | Convex `users.tally_team_id` |
| Tally Workers handler registrations | N per user (one per agent context) | Tally DO storage |
| Skytale channel(s) | 1+ per user (v0.1: one shared deliberation channel) | Skytale relay (platform's account) |
| GitHub OAuth token (per-user, repo scope) | 1 per platform user | Convex secret (encrypted) |
| Modal workspace volumes | Per active conversation | Modal volume mounts |

## Provisioning flow on signup

```
User clicks "Sign up with GitHub" (Clerk)
    │
    ▼
Convex action: bootstrap_user_team(clerk_user_id)
    │  (Uses the platform's existing Skytale API key + GitHub App —
    │   already configured in Modal/Convex secrets — to provision
    │   per-user resources within the platform's account)
    │
    ├─► Create Convex `users` record
    │
    ├─► For each agent role in {board:architect, board:reviewer,
    │                            board:communicator, board:orchestrator,
    │                            worker:executor, worker:tester,
    │                            worker:documenter}:
    │       AgentIdentity.generate() → (did:key, public_key, private_key)
    │       Store private_key as Convex secret (encrypted)
    │       Store did:key + public_key in Convex `agents` table
    │
    ├─► Generate Tally Workers team_id (e.g., UUID per user)
    │   Tally Workers: POST /v1/teams/{team_id}/init with any agent's Bearer
    │       (provisions Durable Object; idempotent)
    │
    └─► For each agent:
        Compute bearer = url_safe_b64(agent.public_key)
        For each context the agent will receive on:
            Tally Workers: POST /v1/teams/{team_id}/agents/{bearer}/register
                with body { "context_id": "<role>:<purpose>" }
            e.g., orchestrator registers "task-result"
                  worker:executor registers "task-start"
```

By the time bootstrap completes, the user has:
- A cloud team of 7 agents with stable identities
- A Tally Workers DO provisioned with handler registrations
- Convex state ready to mirror agent activity to the browser UI

The platform's Skytale account stays in use throughout — no per-user Skytale signup. When the first conversation kicks off, the platform creates the relevant Skytale channels (e.g., `{user_id}/main`) on the relay using the platform's API key.

## OrchestrationAgent as the runtime layer

The Skytale SDK already ships `skytale_sdk.integrations._orchestration.OrchestrationAgent` — a multi-agent coding orchestration primitive built on `SkytaleChannelManager` + `SharedContext` + `AuditLog`.

Construction (Python):
```python
from skytale_sdk.integrations._orchestration import OrchestrationAgent

agent = OrchestrationAgent(
    identity=agent_identity.public_key,  # bytes; MLS BasicCredential
    channel=f"{user_id}/board/deliberation",
    broadcast_channel=f"{user_id}/board/announcements",
    api_key=os.environ["SKYTALE_API_KEY"],
    mock=False,  # real Skytale relay
)
```

The agent exposes:
- `send_orchestration_message(channel, message_dict)` — encrypted send via MLS channel
- `receive_orchestration_messages(channel, timeout)` — encrypted receive
- `wait_for_action_response(channel, msg_id, timeout)` — request-response over channels
- `context` → `SharedContext` (CRDT with HLC, write policies, circuit breakers)
- `audit_log` → `AuditLog` (hash-chained tamper-evident events)
- Auto-persist via `~/.skytale/orchestration/{channel_hash}/context.json` (configurable base)

The OrchestrationAgent's message types map directly to platform workflow events:

| OrchestrationAgent type | Platform event | Notes |
|---|---|---|
| `status` | Worker progress report | files_modified, tests_passing, tests_failing, branch |
| `pr_update` | PR creation / merge / close | number, status, ci, additions, deletions |
| `decision_request` | Board → user escalation | options array; blocking flag |
| `decision_record` | Board decision committed | key + value + rationale |
| `block` | Worker → orchestrator blocker | key + description + depends_on |
| `unblock` | Orchestrator → worker resolution | key + resolution |
| `context_share` | Cross-channel sharing | from_channel + key + summary + value |
| `session_start` | Worker begins task | session_id + agent_did |
| `session_end` | Worker completes task | summary + pending + next_steps |
| `error` | Recoverable / unrecoverable error | error + details + stack_trace + recoverable |
| `action_response` | Reply to a request | source_message_id + action + input |

This means the platform's escalation hierarchy spec maps cleanly to existing primitives — no custom message protocol needed.

## Tally integration

Tally provides the synchronous request-response dispatch substrate. The 8 HTTP routes:

```
POST   /v1/teams/{team_id}/init                                    # idempotent team provisioning
GET    /v1/teams/{team_id}/status                                  # team metadata + agents summary
DELETE /v1/teams/{team_id}                                         # clear team state

POST   /v1/teams/{team_id}/agents/{identity}/register              # register (identity, context_id) handler
DELETE /v1/teams/{team_id}/agents/{identity}/handlers/{context_id} # unregister

POST   /v1/teams/{team_id}/wakes                                   # dispatch wake (with timeout)
GET    /v1/teams/{team_id}/agents/{identity}/inbox                 # long-poll for wakes
POST   /v1/teams/{team_id}/wakes/{wake_id}/complete                # complete pending wake

GET    /v1/health                                                  # health check
```

**Authentication:** `Authorization: Bearer <url_safe_b64(identity_bytes)>`. MVP equates Bearer to identity. URL path identity must match Bearer identity (else 403).

**Wake lifecycle:**
- Wake ID: 26-char Crockford-base32 ULID
- Payload: base64-encoded opaque bytes (platform encrypts upstream with Skytale primitives)
- State machine: `Pending → Completed` (target calls `/complete`) OR `Pending → TimedOut` (alarm fires)
- Dispatch is synchronous: caller awaits completion up to `timeout_seconds`; receives the responder's payload back

**Dispatch path** (orchestrator → worker):
```
1. Orchestrator constructs encrypted payload using Skytale primitives:
       payload_ciphertext = skytale.encrypt(target_pubkey, task_spec_bytes)
       payload_b64 = base64(payload_ciphertext)

2. POST /v1/teams/{team_id}/wakes
       Authorization: Bearer <orchestrator_identity_b64>
       Body: {
           "target_identity": "<worker_identity_b64>",
           "context_id": "task-start",
           "payload": "<payload_b64>",
           "timeout_seconds": 1800
       }

3. Worker polls /v1/teams/{team_id}/agents/{worker_identity_b64}/inbox
   (long-poll with wait_seconds=30)

4. Worker receives wake; decrypts payload with Skytale primitives:
       payload_bytes = skytale.decrypt(my_privkey, base64_decode(payload_b64))
       task_spec = parse(payload_bytes)

5. Worker executes task; constructs encrypted response:
       response_ciphertext = skytale.encrypt(orchestrator_pubkey, result_bytes)

6. POST /v1/teams/{team_id}/wakes/{wake_id}/complete
       Authorization: Bearer <worker_identity_b64>
       Body: { "response": "<response_b64>" }

7. Orchestrator's awaiting /v1/teams/{team_id}/wakes call returns with the
   response payload. Decrypts; processes.
```

## OpenHands integration glue

OpenHands SDK has no built-in Skytale or Tally integration. The platform builds `skytale_sdk_extensions/_openhands.py` initially as platform-private code; potential upstream contribution to Skytale SDK as `pip install skytale-sdk[openhands]`.

Pattern follows existing Skytale integrations (e.g., `_openai_agents.py`, `_crewai.py`).

```python
# skytale_sdk_extensions/_openhands.py

from openhands.sdk import Action, Observation, ToolDefinition
from openhands.sdk.tool import ToolExecutor, register_tool

from skytale_sdk.channels import SkytaleChannelManager
from skytale_sdk.integrations._orchestration import OrchestrationAgent
from skytale_sdk.integrations._orchestration_types import make_message

# --- Skytale Send tool ---

class SkytaleSendAction(Action):
    channel: str
    message_type: str  # "status" | "decision_request" | "block" | etc.
    data: dict

class SkytaleSendObservation(Observation):
    status: str
    message_id: str

class SkytaleSendExecutor(ToolExecutor[SkytaleSendAction, SkytaleSendObservation]):
    def __init__(self, orchestration_agent: OrchestrationAgent):
        self._agent = orchestration_agent

    def __call__(self, action, conversation=None):
        msg = make_message(
            type=action.message_type,
            data=action.data,
            sender_did=self._agent.agent_did,
            channel=action.channel,
        )
        self._agent.send_orchestration_message(action.channel, msg)
        return SkytaleSendObservation(status="sent", message_id=msg["id"])

class SkytaleSendTool(ToolDefinition[SkytaleSendAction, SkytaleSendObservation]):
    @classmethod
    def create(cls, conv_state, orchestration_agent):
        return [cls(
            description="Send a structured orchestration message via a Skytale-encrypted channel.",
            action_type=SkytaleSendAction,
            observation_type=SkytaleSendObservation,
            executor=SkytaleSendExecutor(orchestration_agent),
        )]

register_tool("SkytaleSend", SkytaleSendTool)


# --- Tally Dispatch tool ---

class TallyDispatchAction(Action):
    target_identity_b64: str
    context_id: str
    payload_b64: str
    timeout_seconds: int = 30

class TallyDispatchObservation(Observation):
    wake_id: str
    response_b64: str
    completed_at: str

class TallyDispatchExecutor(ToolExecutor[TallyDispatchAction, TallyDispatchObservation]):
    def __init__(self, tally_url: str, team_id: str, caller_bearer: str):
        self._url = tally_url
        self._team_id = team_id
        self._bearer = caller_bearer

    def __call__(self, action, conversation=None):
        import httpx
        resp = httpx.post(
            f"{self._url}/v1/teams/{self._team_id}/wakes",
            headers={"Authorization": f"Bearer {self._bearer}"},
            json={
                "target_identity": action.target_identity_b64,
                "context_id": action.context_id,
                "payload": action.payload_b64,
                "timeout_seconds": action.timeout_seconds,
            },
            timeout=action.timeout_seconds + 5,
        )
        resp.raise_for_status()
        body = resp.json()
        return TallyDispatchObservation(
            wake_id=body["wake_id"],
            response_b64=body["response"],
            completed_at=body["completed_at"],
        )

class TallyDispatchTool(ToolDefinition[TallyDispatchAction, TallyDispatchObservation]):
    @classmethod
    def create(cls, conv_state, tally_url, team_id, caller_bearer):
        return [cls(
            description="Dispatch a synchronous wake to another agent and await response.",
            action_type=TallyDispatchAction,
            observation_type=TallyDispatchObservation,
            executor=TallyDispatchExecutor(tally_url, team_id, caller_bearer),
        )]

register_tool("TallyDispatch", TallyDispatchTool)


# --- Tally Inbox Poll tool ---

class TallyInboxPollAction(Action):
    wait_seconds: int = 30
    limit: int = 10

class TallyWakeEntry(Observation):
    wake_id: str
    caller_identity: str
    context_id: str
    payload_b64: str
    expires_at: str

class TallyInboxPollObservation(Observation):
    wakes: list  # list[TallyWakeEntry]
    more_available: bool

# ... TallyInboxPollExecutor + TallyInboxPollTool follow the same pattern.


# --- Convenience: build the full tool set ---

def build_coding_agent_tools(
    role: str,                         # "board:architect" | "worker:executor" | ...
    orchestration_agent: OrchestrationAgent,
    tally_url: str,
    team_id: str,
    caller_bearer: str,
) -> list:
    """Return the tool set for an OpenHands coding agent.

    Composes OpenHands' built-in coding tools (terminal, file editor, task tracker)
    with the platform's Skytale + Tally coordination tools.
    """
    # Coding tools — from OpenHands; what makes this a software-engineering agent
    coding_tools = [
        Tool(name=TerminalTool.name),       # shell: run tests, git, gh CLI
        Tool(name=FileEditorTool.name),     # read/write/patch source files
        Tool(name=TaskTrackerTool.name),    # break tasks; track progress
    ]
    if role.startswith("board:"):
        # Board agents may browse external docs during deliberation
        coding_tools.append(Tool(name=BrowserTool.name))

    # Coordination tools — platform-built, wrapping Skytale + Tally
    coordination_tools = [
        Tool(name="SkytaleSend", orchestration_agent=orchestration_agent),
        Tool(name="SkytaleReceive", orchestration_agent=orchestration_agent),
        Tool(name="TallyDispatch", tally_url=tally_url, team_id=team_id, caller_bearer=caller_bearer),
        Tool(name="TallyComplete", tally_url=tally_url, team_id=team_id, caller_bearer=caller_bearer),
        Tool(name="TallyInboxPoll", tally_url=tally_url, team_id=team_id, caller_bearer=caller_bearer),
    ]

    return coding_tools + coordination_tools
```

The coding tools come from OpenHands and are battle-tested for software-engineering work. The coordination tools are platform-specific glue. Together they make a software-engineering agent that can also coordinate with peers.

## Event streaming pattern

OpenHands SDK has built-in callback support on Conversation; the platform wires callbacks → Convex for the real-time UI.

```python
from openhands.sdk import Conversation, LLMConvertibleEvent

def convex_event_callback(event):
    """Push an OpenHands Event to Convex for UI subscriptions."""
    convex_client.mutation("events:append", {
        "conversation_id": str(conversation_id),
        "event_kind": type(event).__name__,
        "payload": event.model_dump(),
        "timestamp": time.time(),
    })

conversation = Conversation(
    agent=agent,
    workspace=workspace,
    callbacks=[convex_event_callback],
    persistence_dir=f"/data/conversations/{conversation_id}",
    conversation_id=conversation_id,
    max_iteration_per_run=500,
    stuck_detection=True,
)
```

Each Action, Observation, and LLM message flows through `convex_event_callback`. Convex's reactive subscriptions push updates to the browser via WebSocket — no separate event pipeline needed.

## Conversation persistence pattern

OpenHands SDK has built-in persistence; the platform points `persistence_dir` at a Modal volume.

```python
# In a Modal function:
import modal

volume = modal.Volume.from_name("pronoic-conversations", create_if_missing=True)

@app.function(volumes={"/data/conversations": volume})
def run_agent(user_id: str, conversation_id: str, message: str):
    persistence_dir = f"/data/conversations/{user_id}/{conversation_id}"

    conversation = Conversation(
        agent=agent,
        workspace=...,
        persistence_dir=persistence_dir,
        conversation_id=conversation_id,
        callbacks=[convex_event_callback],
    )
    conversation.send_message(message)
    conversation.run()
    volume.commit()  # Persist to durable storage

# Later: resume after process restart
@app.function(volumes={"/data/conversations": volume})
def resume_agent(user_id: str, conversation_id: str, follow_up: str):
    persistence_dir = f"/data/conversations/{user_id}/{conversation_id}"
    conversation = Conversation(
        agent=agent,
        workspace=...,
        persistence_dir=persistence_dir,
        conversation_id=conversation_id,  # same id → resumes
    )
    conversation.send_message(follow_up)
    conversation.run()
    volume.commit()
```

## v0.1 vs v1.0 progression

**v0.1: minimal viable stack**
- Each user has 7 AgentIdentities + 1 Tally team_id + 1 Skytale account
- Use `SkytaleChannelManager` directly (no SkytaleTeam wrapper)
- One shared Skytale channel per user: `{user_id}/main`
- OrchestrationAgent runs on that channel for all coordination
- Tally for orchestrator → worker dispatches
- All agents share the channel; differentiate by message metadata (sender_did)

**v1.0: formal team-of-agents abstraction**
- Wrap the per-user setup in `SkytaleTeam.create(manager, name=f"user-{user_id}-team")`
- Use SkytaleTeam's role packs for board/worker role definitions (`RolePack.from_yaml(...)`)
- Multiple channels: `{user_id}/board/deliberation`, `{user_id}/projects/{project_id}/main`, etc.
- Forward secrecy on agent rotation (MLS rekey when an agent is removed/replaced)
- Phase 2 hookup: SkytaleTeam invite tokens for shared teams / collaborator agents

The v0.1 → v1.0 transition is incremental: SkytaleTeam wraps SkytaleChannelManager; existing channels continue to work.

## Open implementation decisions

**Workspace mode** (decide week 1 day 2 spike):
- (a) Modal Sandbox direct — agents run as Modal functions, `workspace=os.getcwd()` inside Modal container. Simpler infra. Loses OpenHands' built-in WebSocket event endpoint (but callback pipeline + Convex covers it).
- (b) OpenHands Agent Server on Modal — wrap Agent Server in Modal function; orchestrator uses `RemoteWorkspace(remote_url=modal_endpoint, api_key=...)`. Gets WebSocket event streaming free. More OpenHands-native; more infra layers.

**Recommendation:** start with (a) for v0.1. Migrate to (b) for v1.0 if event streaming becomes load-bearing for cross-agent observation.

**Role pack location** (decide week 5-6):
- Where do the YAML role pack files live? Repository? Per-user customization? Default + override?

**Multi-channel topology** (decide week 5 when boards land):
- v0.1 stays single-channel.
- v1.0 splits into `{user_id}/board/deliberation`, `{user_id}/board/user`, `{user_id}/projects/{project_id}/main`.

**Tally CLI vs HTTP** (decide week 2):
- Tally CLI (`tally agents register`, `tally teams init`) wraps the HTTP API. Platform code can use either.
- Recommendation: use HTTP directly from Python (`httpx`) — fewer dependencies, more control over auth.

## Provenance

Drafted 2026-05-16 after two rounds of source-level research across the Skytale repo (`~/Projects/pronoic/skytale/`), Tally repo (`~/Projects/pronoic/tally/`), and OpenHands SDK docs (via context7).
