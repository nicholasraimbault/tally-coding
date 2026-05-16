# Tally Coding — Human Collaboration & Multi-Runtime Architecture

**Date:** 2026-05-16
**Purpose:** Captures the architectural decisions for mixed-runtime agent teams (cloud + local + human) and end-to-end-encrypted human-to-human collaboration. Grounded in source-level research validating that Skytale's `SkytaleTeam` primitive handles all three runtime types symmetrically.

## The unified team primitive

Skytale's `SkytaleTeam.TeamMember` makes no distinction between AI agents, local-daemon agents, and humans:

```python
@dataclass(frozen=True)
class TeamMember:
    identity: str         # did:key:z6Mk... (AI agent) or did:web:...(human) or did:key (human)
    display_name: str
    role: str             # "board:architect" | "human:nick" | "worker:nick-laptop" | etc.
    joined_at: str
    is_admin: bool
```

All members:
- Have an Ed25519 keypair + `did:key:z6Mk...` URI (or `did:web:domain` for humans with persistent identity)
- Are addressable via Tally Workers Bearer = `url_safe_b64(public_key)`
- Can send + receive Skytale-encrypted messages on team channels
- Can be admins or non-admins
- Can be invited via Skytale invite tokens
- Have role packs associated with their role

The platform's web app surfaces these as a unified roster. Engineering distinguishes runtime via metadata; product treats them identically.

## Three runtime layers

```
Tally Coding "Team" (per user / per project)
│
├── Cloud agents (Phala CVM)
│   ├── board:architect    ← Phala CVM instance
│   ├── board:reviewer     ← Phala CVM instance
│   ├── board:communicator ← Phala CVM instance
│   └── board:orchestrator ← Phala CVM instance
│
├── Local-daemon agents (tally-cli serve)
│   ├── worker:nick-macbook  ← daemon polling Tally inbox from Nick's MacBook
│   ├── worker:nick-desktop  ← daemon polling Tally inbox from Nick's desktop
│   └── worker:alice-laptop  ← daemon on Alice's laptop (Phase 2 multi-tenant)
│
└── Human members (web app)
    ├── human:nick          ← Nick reading the dashboard, posting via the chat UI
    └── human:alice         ← Alice (a teammate) reading the dashboard, posting via the chat UI
```

All three layers post events to the same Skytale channels. Convex subscribes; the web app renders them as one unified activity stream.

## Layer 1 — Cloud agents (Phala CVM)

Already covered in `tally-coding-stack-integration-2026-05-16.md`. Phala CVMs running OpenHands SDK; workspace inside the Phala CVM; spawns Phala CVM per task. The default path for v0.1.

## Layer 2 — Local-daemon agents (tally-cli serve)

A long-running daemon process on the user's PC that registers as an agent in the user's Tally team and executes wakes locally.

### Daemon shape

```bash
# Install
pip install tally-cli         # or: brew install tally-cli (later)

# First-time setup (browser-based OAuth)
tally login
# → opens browser to app.tally.codes/cli-login
# → user authenticates via Clerk
# → backend issues a long-lived agent token tied to a new AgentIdentity
# → token stored in ~/.tally/credentials

# Register this machine as an agent in the user's team
tally agent register --name "nick-macbook" --role "worker:nick-macbook"
# → generates Ed25519 keypair locally
# → backend registers the identity as a member of user's SkytaleTeam
# → handler contexts registered in Tally Workers
# → keypair stored in ~/.tally/identities/nick-macbook/

# Run as daemon
tally agent serve --name "nick-macbook"
# → polls Tally Workers inbox via HTTP long-poll
# → on wake: decrypts payload, runs OpenHands Conversation locally, posts response
# → optionally: install as systemd / launchd service for auto-start
```

### Runtime behavior

When a wake arrives at a local daemon:

```python
# Pseudocode inside tally-cli serve
while True:
    wakes = tally_client.poll_inbox(team_id, identity_b64, wait_seconds=30)
    for wake in wakes:
        # Decrypt the wake payload (Skytale MLS primitives)
        task_spec = skytale.decrypt(my_private_key, wake.payload_b64)

        # Build OpenHands agent with tools pointing at LOCAL filesystem
        llm = LLM(model=REDPILL_MODEL, base_url=REDPILL_API_URL, api_key=REDPILL_KEY)
        agent = Agent(llm=llm, tools=build_coding_agent_tools(
            role="worker:local",
            orchestration_agent=orch,
            tally_url=TALLY_URL,
            team_id=team_id,
            caller_bearer=my_bearer,
        ))

        # Conversation runs in the user's actual cwd
        # OpenHands FileEditorTool / TerminalTool operate on local files
        conversation = Conversation(
            agent=agent,
            workspace=task_spec.workspace_path or os.getcwd(),
            callbacks=[skytale_channel_event_callback],
            persistence_dir=f"~/.tally/conversations/{wake.wake_id}",
            conversation_id=wake.wake_id,
        )
        conversation.send_message(task_spec.instruction)
        conversation.run()

        # Encrypt the response and complete the wake
        response_ciphertext = skytale.encrypt(wake.caller_pubkey, result_bytes)
        tally_client.complete_wake(team_id, wake.wake_id, response_ciphertext)
```

The daemon is NAT-friendly — it only makes outbound HTTPS calls to Tally Workers and Skytale relay. No inbound port required. Works behind any firewall.

### OpenHands Agent Server as an alternative (Phase 2)

OpenHands ships a full Agent Server (`uv run python -m openhands.agent_server --port 3000`) with REST API + WebSocket. The platform could later support running it as an alternative daemon, with cloud orchestrators connecting via `RemoteWorkspace(remote_url=local_agent_server)`. This gives power-user features (external CLI tools talking to the local agent server directly) at the cost of NAT-traversal complexity (needs Cloudflare Tunnel / ngrok / Tailscale for inbound connectivity). Defer to Phase 2.

### Trust model

The daemon runs LLM-driven commands on the user's machine. This is a powerful agent. Discipline:

1. **First-time tool grants** — on initial daemon install, user explicitly approves which tools the daemon can run (e.g., "allow `bash` execution: yes/no"; "allow Git operations: yes/no")
2. **Pre-execution prompts** for sensitive operations (configurable). Examples: `rm`-prefixed commands, `sudo` invocations, network-modifying commands (`iptables`, `pf`), package installations
3. **Audit log of every action** — written to a local file AND emitted as a Skytale channel event for the user to review later
4. **Sandboxing where possible** — daemon optionally runs the OpenHands Conversation inside a local Docker container (similar to Phala CVM but local). This is a v1.5+ polish; v1.0 ships with native execution + user-approved tool grants
5. **Cryptographic provenance** — every action emitted to the audit log is signed by the daemon's agent identity. Tampering is detectable.

## Layer 3 — Human team members

Humans participate in the team via the web app. They have AgentIdentity, channel membership, and the ability to send/receive messages — just like AI agents.

### Browser-side AgentIdentity generation

When a human signs up (Clerk OAuth):

```typescript
// Browser-side, after Clerk auth success
import { AgentIdentity } from '@skytalesh/sdk';

const identity = await AgentIdentity.generate();
// → { did: "did:key:z6Mk...", public_key: Uint8Array(32), private_key: Uint8Array(32) }

// Send private_key to server-side Convex action for encrypted storage
await convex.mutation('users:storeHumanIdentity', {
    clerkUserId: clerk.user.id,
    publicKey: bytesToHex(identity.public_key),
    did: identity.did,
    // private_key encrypted with PRONOIC_MASTER_KEY in the action
    encryptedPrivateKey: await encryptForServer(identity.private_key),
});
```

After this, the human is just another agent identity. The web app loads the human's private key on each session (decrypts server-side, sends to browser memory only; never persisted in localStorage).

### Reading and writing to channels

Humans interact with channels via the web app, not via OpenHands SDK:

```typescript
// Browser-side: post a chat message
async function postChatMessage(channelName: string, content: string) {
    // Encrypt with Skytale primitives in the browser
    const envelope = await skytale.makeEnvelope({
        protocol: 'chat',
        content_type: 'text/markdown',
        payload: content,
    });
    const ciphertext = await skytale.encryptForChannel(channelName, envelope);

    // Send via platform API (which forwards to Skytale relay)
    await convex.mutation('channels:send', { channelName, ciphertext });
}

// Browser-side: subscribe to channel messages
const messages = useQuery('channels:subscribe', { channelName });
// → reactive list; each message has { sender_id, content, timestamp, decrypted_payload }
```

Important: encryption / decryption happens in the BROWSER, not on the platform server. The platform server forwards ciphertext to Skytale relay; relay forwards to channel members; receiving members' browsers decrypt locally. The platform NEVER sees plaintext.

### Reacting to wakes targeted at humans

When an AI agent dispatches a wake to a human (e.g., `decision_request` from board:architect to human:nick), the flow is:

```
1. Board:architect: tools.TallyDispatch(target=human:nick.bearer,
                                       context_id="user:question",
                                       payload=<encrypted decision_request>)
2. Tally Workers routes wake to human:nick's inbox
3. Platform server: detects inbox change (Tally Workers webhook or poll);
                    emits "wake_pending for human:nick" event to Convex
4. Convex push to nick's browser via reactive subscription
5. Browser shows banner: "board:architect needs a decision: <question>"
6. Nick clicks "Approve" / "Reject" / responds with custom text
7. Browser encrypts response; calls Tally Workers /complete for the wake_id
8. Board:architect's awaiting dispatch returns
```

The platform server can see WHO the wake is for (identity_b64 in the URL) but not WHAT it says (payload is encrypted). That's enough to trigger a notification without breaking E2E.

## Human-to-human chat

Same primitives as AI-to-AI; just different message types.

### Channel topology

Per team, the channels expand to:

```
{team_id}/main                            ← team-wide chat (all members)
{team_id}/board/deliberation              ← board agents + admin humans
{team_id}/projects/{project_id}/main      ← per-project channel (members vary)
{team_id}/dm/{identity_a}/{identity_b}    ← 1:1 DM between two members
                                            (identities sorted for determinism)
{team_id}/custom/{slug}                   ← user-created custom channels
                                            (e.g., "deployments-watercooler")
```

Each is a Skytale MLS group. Members of the channel can read/write; non-members cannot decrypt.

### Chat envelope type

OrchestrationAgent's existing message types (status, decision_request, etc.) are for workflow events. Chat needs a separate envelope:

```python
# Add to skytale_sdk_extensions/envelope.py or as platform-local Python
from skytale_sdk.envelope import Envelope, Protocol

CHAT_CONTENT_TYPE = "application/tally-chat+json"

def make_chat_message(
    content: str,           # markdown
    sender_did: str,
    channel: str,
    reply_to: Optional[str] = None,   # message_id of parent (threading)
    mentions: List[str] = [],         # list of @-mentioned identities
) -> Envelope:
    payload = {
        "id": f"msg_{uuid.uuid4().hex}",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "sender_did": sender_did,
        "channel": channel,
        "content": content,
        "reply_to": reply_to,
        "mentions": mentions,
    }
    return Envelope(
        protocol=Protocol.RAW,
        content_type=CHAT_CONTENT_TYPE,
        payload=json.dumps(payload, separators=(",", ":")).encode("utf-8"),
    )
```

AI agents and humans both write `ChatMessage` envelopes. Web app subscribes; renders markdown; resolves mentions.

### Reactions, edits, deletions

MLS messages are immutable. To support reactions / edits / deletions, post FOLLOW-UP messages that reference the original:

```python
# Reaction
{
    "type": "reaction",
    "target_message_id": "msg_xyz",
    "reaction": "👍",
    "actor_did": "did:key:z6Mk...",
}

# Edit (the UI shows "(edited)" + the new content)
{
    "type": "edit",
    "target_message_id": "msg_xyz",
    "new_content": "<corrected markdown>",
    "edited_at": "...",
    "actor_did": "<must equal original sender's did>",   # enforced client-side
}

# Deletion (UI shows "<deleted>" instead of original)
{
    "type": "delete",
    "target_message_id": "msg_xyz",
    "deleted_at": "...",
    "actor_did": "<must equal original sender's did>",
}
```

Client-side rendering coalesces reactions + edits + deletions onto the original message.

## @mentions and notifications

### Mention syntax

Standard: `@display_name` in chat. The web app autocompletes from the team roster. On message send, mentions are resolved to identities:

```python
# Browser-side
mentions = parseAtMentions(content, roster);
// → [{ display_name: "alice", did: "did:key:z6Mk..." }, ...]
```

Stored alongside the message; surfaced in the message envelope.

### In-app notifications

When a member's identity is in the `mentions` list of an incoming message, the browser:
- Highlights the channel in the sidebar (unread badge)
- Plays a notification sound (if user enabled)
- Flashes the tab title
- Shows a transient banner

All client-side; no server intervention needed.

### Push notifications (the E2E tension)

For offline users, the platform needs to push notifications via web push API / mobile push. But the platform doesn't know the message content (it's encrypted).

**Resolution (standard MLS practice):**

The server CAN see who a Skytale message was addressed to (recipient identity = wake target or channel member). Same for chat messages — the platform sees "channel X has new traffic; here are the members." So the server triggers content-free notifications:

```
"You have new activity in Tally" → user opens app
                                 → browser decrypts the actual message
                                 → user sees who messaged + content
```

The push notification reveals NO message content. This is the trade-off; same as Signal, WhatsApp, MLS-compliant apps. Worth surfacing as a feature: "Notifications never reveal message content — even to us."

For an additional polish step, the server can show: "Activity in channel X" or "1 mention in #project-frontend" without revealing the message. The channel name itself isn't encrypted (it's the MLS group identifier), but message content stays private.

## Multi-PC support

Each PC has its own AgentIdentity (registered via `tally agent register`). All PCs are members of the user's team. The orchestrator can dispatch to any specific one ("run this on `nick-macbook`") or any-available ("run this on whichever worker is online").

A user with 3 PCs sees their roster:

```
"Nick's Tally Team"
├── board:architect       (cloud)
├── ...
├── worker:nick-macbook   (online — last seen 30s ago)
├── worker:nick-desktop   (offline — last seen 4h ago)
└── worker:nick-server    (online — last seen 5s ago)
```

Presence tracking: the daemon emits a heartbeat to a Skytale channel every 30s. Convex aggregates. UI shows online/offline indicator.

## Privacy properties (what each layer preserves)

| Layer | What's encrypted | What server sees | What the user sees |
|---|---|---|---|
| Cloud agent (Phala CVM) | LLM calls TEE-attested; inter-agent comms E2E | Encrypted bytes flowing; runtime metadata (which agent dispatched what wake) | Full plaintext on their browser |
| Local daemon | LLM calls TEE-attested; agent code runs locally; inter-agent comms E2E | NO local file access; no code visibility; only encrypted wake metadata | Full plaintext on their machine |
| Human in browser | All channel messages E2E encrypted | Channel membership + message metadata (sender, timestamp, recipient list); NOT message content | Decrypted messages in their browser only |
| Human-to-human DMs | E2E encrypted between participants | Channel membership; message metadata | Both participants see plaintext |

Operator (platform team) can prove they cannot read anything by audit: master key derivation, key access patterns, etc.

## v1.0 scope vs v1.5 polish

### v1.0 (commercial launch)
- Cloud agents (Phala CVM) — existing
- `tally-cli serve` daemon for local execution (Option A: poll-based)
- First-time tool grants + per-execution approval prompts
- Humans as team members (web app participation; browser-side AgentIdentity)
- Basic chat: send/receive in channels; markdown rendering; @mentions; in-app notifications; threading via reply_to
- DM channels (1:1)
- Group channels (3+ members)
- Multi-PC support (multiple daemons per user)
- Presence (online/offline indicators)
- Content-free push notifications

### v1.5+ polish
- Reactions (👍 + custom emoji)
- Message editing / deletion
- Read receipts (per-message; opt-in)
- File sharing (upload encrypted to S3/R2; post link)
- Link previews (client-side, opt-in)
- Full-text search (client-side incremental index)
- Mobile push notifications (iOS / Android apps; or PWA push)
- OpenHands Agent Server adapter (alternative daemon for power users)
- Local sandboxing via Docker (daemon-side sandbox like Phala CVM)

## Provenance

Drafted 2026-05-16 to capture the multi-runtime + human-collaboration architecture decisions. Validated against:
- Skytale `team.py` (SkytaleTeam supports humans symmetrically)
- Skytale `identity.py` (AgentIdentity generation works browser-side via `cryptography.hazmat`)
- OpenHands Agent Server docs (`uv run python -m openhands.agent_server`) — alternative daemon path
- Tally Workers HTTP API (8 routes; identity-based inbox polling works for any runtime)

No new Skytale primitives required. The platform's task is web app + daemon binary + chat UI + notification glue.
