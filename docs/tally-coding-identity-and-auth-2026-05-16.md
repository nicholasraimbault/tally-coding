# Tally Coding — Identity and Auth Bridging

**Date:** 2026-05-16
**Purpose:** Specifies how a single Clerk-authenticated platform user maps to per-user resources within Tally Coding. Resolves gaps in the v0.1 design before week 1.

**Scenario B locked (2026-05-16):** Skytale is platform-internal infrastructure, not a customer-facing product. Customers sign up for Tally; they never see Skytale. The platform operates a single Skytale account (operator-owned) and partitions per-user resources within it via `team_id`, channel namespaces, and per-user agent identities.

## Three identity layers

The platform composes three identity layers:

| Layer | What it identifies | Provided by | Stored where |
|---|---|---|---|
| **Platform user** | The human signing into Tally | Clerk (GitHub OAuth) | Clerk + Convex `users.clerk_user_id` |
| **Platform Skytale account** | The operator's Skytale account (one for the whole platform) | Skytale API key (`sk_live_...`) | Phala Cloud secret + Convex secret (encrypted) — platform-wide, not per-user |
| **Agent identity** | A specific agent within a user's cloud team | Ed25519 keypair + `did:key:z6Mk...` | Convex secrets (encrypted private key); public key + DID in `agents` table |

The platform Skytale account is shared infrastructure. Per-user partitioning happens via:
- Per-user `team_id` (Tally Workers Durable Object) — isolates wake-routing
- Per-user channel namespace (Skytale channels like `{user_id}/main`) — isolates encrypted conversations
- Per-user agent identities (Ed25519 keypairs) — isolates message authorship and Tally Workers Bearer auth

## Skytale's identity primitive

From `skytale_sdk/identity.py`:

```python
@dataclass(frozen=True)
class AgentIdentity:
    did: str               # "did:key:z6Mk..."
    public_key: bytes      # 32 bytes (Ed25519)
    private_key: Optional[bytes] = None  # 32 bytes when locally generated

    @classmethod
    def generate(cls) -> AgentIdentity: ...
    @classmethod
    def from_private_key(cls, private_key: bytes) -> AgentIdentity: ...
    @classmethod
    def from_did(cls, did: str) -> AgentIdentity: ...

    def sign(self, message: bytes) -> bytes: ...
    def verify(self, message: bytes, signature: bytes) -> bool: ...
    def to_did_document(self) -> dict: ...  # W3C DID Document JSON-LD
```

`did:key` is self-contained — no external resolution needed. The DID embeds the public key directly via multibase encoding. Agent identities are stable across sessions; the private key is the load-bearing secret to protect.

## Tally's identity primitive

From Tally's HTTP API:

- **Authentication header:** `Authorization: Bearer <bearer_token>`
- **MVP bearer semantics:** `bearer_token == url_safe_b64(identity_bytes_no_padding)`, where `identity_bytes` is the 32-byte Ed25519 public key. So:

```python
bearer = base64.urlsafe_b64encode(agent_identity.public_key).rstrip(b"=").decode()
```

- **URL path identity match:** routes containing `{identity}` path segment (`/v1/teams/{team_id}/agents/{identity}/register`, etc.) require the URL identity to equal the authenticated Bearer identity (else 403).
- **Phase 2:** Tally will replace MVP equivalence with real API keys mapped to identities. The wire contract stays stable.

So one `AgentIdentity` Ed25519 keypair gives the platform:
- `did:key:z6Mk...` — agent's identity in Skytale MLS channels (BasicCredential)
- `url_safe_b64(public_key)` — agent's Bearer + URL path identity in Tally

A single keypair backs both auth layers.

## Auth flow on signup

```
1. User clicks "Sign up with GitHub" on Tally landing page
   │
   ▼
2. Clerk redirects to GitHub OAuth
   │
   ▼
3. GitHub returns to Clerk; Clerk creates user; redirects to Tally
   │
   ▼
4. Convex action: bootstrap_user_team(clerk_user_id)
   │   (Uses the platform's existing Skytale account — already configured
   │    in Phala Cloud env / Convex secrets — to provision per-user resources)
   │
   ├─► 4a. Create Convex `users` record:
   │       { clerk_user_id, email, created_at, status="provisioning" }
   │
   ├─► 4b. For each role in PLATFORM_AGENT_ROLES:
   │       identity = AgentIdentity.generate()
   │       Convex insert into `agents`:
   │           { user_id, role, did, public_key_b64,
   │             tally_bearer (=url_safe_b64(public_key)),
   │             created_at }
   │       Convex secret: store identity.private_key (encrypted)
   │
   ├─► 4c. Compute Tally team_id (e.g., uuid4() or derived from user_id):
   │       Tally Workers: POST /v1/teams/{team_id}/init
   │              Authorization: Bearer <any agent's bearer>
   │       Convex update: users.tally_team_id = team_id
   │
   ├─► 4d. For each agent in PLATFORM_AGENT_ROLES:
   │       For each context_id the agent will receive on (per role):
   │           Tally Workers: POST /v1/teams/{team_id}/agents/{agent.bearer}/register
   │                  Authorization: Bearer <agent.bearer>
   │                  Body: { "context_id": "<context>" }
   │       Convex update: agents.{id}.handlers = [contexts...]
   │
   ├─► 4e. (Optional, week 5+) Create user's Skytale channel(s) within the platform's account:
   │       Using platform's SkytaleClient, create `{user_id}/main` channel
   │       (or per-board / per-project sub-channels in v1.0)
   │
   └─► 4f. Mark user as provisioned:
       Convex update: users.{id}.status = "ready"

5. UI redirects to dashboard with "Your cloud team is ready"
```

Total provisioning time: dominated by per-agent identity generation (cryptographic, ~100ms each = ~1s for 7 agents) + Tally Workers register calls (parallelizable, ~50ms each). Estimate: 2-5 seconds. No Skytale account creation per user — the platform's existing Skytale account is shared infrastructure.

## Default agent roles (v1.0)

| Role | Tier | Context IDs registered in Tally |
|---|---|---|
| `board:architect` | Board | `board:deliberation`, `escalation:from-orchestrator` |
| `board:reviewer` | Board | `board:deliberation`, `escalation:from-orchestrator` |
| `board:communicator` | Board | `board:deliberation`, `user:question` |
| `board:orchestrator` | Board | `board:deliberation`, `orchestrator:report`, `worker:result` |
| `worker:executor` | Worker | `task:start`, `task:revise` |
| `worker:tester` | Worker | `task:test`, `task:retest` |
| `worker:documenter` | Worker | `task:document` |

Context IDs are namespace-prefixed strings; meaningful only to the platform's dispatch logic.

## Secret storage discipline

| Secret | Storage location | Access pattern |
|---|---|---|
| Clerk session token | Browser cookie (httponly) | Clerk SDK |
| GitHub OAuth token (for repo access) | Convex secret (encrypted at rest) | Server-side only |
| Skytale API key (`sk_live_...`) | Phala Cloud secret + Convex secret | Phala CVM: env var injection; Convex: server-side only |
| Agent Ed25519 private keys | Convex secrets (encrypted; per-agent) | Phala CVM: pulled at agent spawn; never logged |
| Convex deploy key | Vercel env var | Build time |
| Phala Cloud API token | Vercel env var (server only) | Server actions |

**Discipline:** Skytale API key and agent private keys are NEVER exposed to the browser. The browser interacts only with Convex; Convex relays to Phala Cloud; Phala CVM pulls secrets at function-spawn time.

## Auth flow on agent dispatch (orchestrator → worker)

```
1. Orchestrator agent's OpenHands tool invocation:
   tools.TallyDispatch(
       target_identity_b64="<worker_bearer>",
       context_id="task:start",
       payload_b64="<encrypted_task_spec>",
       timeout_seconds=1800,
   )
   │
   ▼
2. TallyDispatchExecutor sends:
   POST https://tally.nraimbault16.workers.dev/v1/teams/{team_id}/wakes
       Authorization: Bearer <orchestrator_bearer>
       Body: { target_identity, context_id, payload, timeout_seconds }
   │
   ▼
3. Tally Worker:
   - Parses Bearer; calls DO /validate_api_key
   - DO validates Bearer (MVP: parses as identity bytes)
   - Returns identity_b64 = orchestrator_bearer
   - Caller != target check (orchestrator dispatches to worker, OK)
   │
   ▼
4. DO records wake (state=Pending); pushes to target's inbox queue
   │
   ▼
5. Worker (separately running): polls inbox
   GET /v1/teams/{team_id}/agents/{worker_bearer}/inbox?wait_seconds=30
       Authorization: Bearer <worker_bearer>
   │
   ▼
6. Worker receives the wake; decrypts payload using its private key
   (which was loaded from Convex/Phala Cloud secret at spawn time)
   │
   ▼
7. Worker executes task; constructs encrypted response
   │
   ▼
8. Worker calls /complete:
   POST /v1/teams/{team_id}/wakes/{wake_id}/complete
       Authorization: Bearer <worker_bearer>
       Body: { "response": "<encrypted_result>" }
   │
   ▼
9. Orchestrator's awaiting dispatch call returns; decrypts response
```

The two Bearer values (orchestrator, worker) are derived from the respective agent identities. Neither agent ever sees the other's private key.

## Failure modes

| Failure | Where | Recovery |
|---|---|---|
| Tally Workers `/init` fails | Step 4c | Retry; if persistent, fall back to a different `team_id` derivation |
| Agent registration fails | Step 4d | Mark agent's `handlers` empty; retry on next dispatch attempt |
| Platform Skytale API key revoked / leaked | Runtime | Critical incident: rotate the platform-wide key; re-issue from a new key; ALL users affected briefly. Operator-handled, not customer-handled. |
| Agent private key leaked | Runtime | Rotate the affected agent: generate new Ed25519 keypair; re-register Tally Workers handlers; re-add to Skytale channels (MLS rekey provides forward secrecy on member rotation). Single-user scope. |

## Encryption at rest in Convex

Convex doesn't ship a built-in encrypted-secrets primitive — the platform must encrypt secrets in application code before writing. Recommended:

```python
# Platform-side encryption wrapper
from cryptography.fernet import Fernet

# Master key in Phala Cloud secret + Vercel env var
master_key = os.environ["PRONOIC_MASTER_KEY"]
fernet = Fernet(master_key)

def encrypt_secret(plaintext: bytes) -> str:
    return fernet.encrypt(plaintext).decode()

def decrypt_secret(ciphertext: str) -> bytes:
    return fernet.decrypt(ciphertext.encode())

# Convex stores: { user_id, agent_role, encrypted_private_key: "..." }
```

Master key rotation: out of scope for v0.1; document as v1.0 design task.

## v0.1 simplifications

For the v0.1 internal demo (single user = Nick):

- Convex secrets: just Phala Cloud secrets (no encryption wrapper)
- Agent private keys: stored in Convex as plaintext for now (acceptable for a single-user demo)
- Tally team_id: hardcoded for the demo user
- All bootstrapping done manually via a one-off Phala Cloud script, not Convex action

The platform's Skytale account is used as-is (no per-user partitioning ceremony yet; channel names just include the user_id prefix as the de-facto namespace).

Production-grade auth bridging (encryption at rest, key rotation, master key in KMS) lands in v1.0.

## v1.0 hardening

- Encrypted-at-rest agent private keys in Convex (Fernet or libsodium-via-PyNaCl)
- Master key in dedicated KMS (AWS KMS, GCP KMS, or HashiCorp Vault) — not Phala Cloud secret
- Agent key rotation flow (UI + Convex action)
- Audit log of provisioning events (using Skytale's `AuditLog` primitive)
- Compliance export: per-user identity records for GDPR data subject access
- Quota tracking per user against the platform's Skytale account (so individual users can't exhaust shared resources)

## Open decisions

1. **Master key custodianship**: Phala Cloud secret (v0.1) vs dedicated KMS (v1.0) — when to migrate?
2. **Tally Workers `team_id` derivation**: deterministic from `user_id` (UUID-namespace), or randomly generated and stored?
3. **Agent key rotation UX**: surfaced in UI? Automatic on suspicion? Time-based rotation?
4. **Did-web option for enterprise users**: Skytale supports `did:web:domain`; should the platform offer this as an opt-in identity mode for enterprise customers?
5. **Skytale-account partitioning model**: if the platform grows to thousands of users on one Skytale account, how do we partition for cost-attribution + abuse-isolation + quota fairness? (Defer until demand surfaces.)

## Provenance

Drafted 2026-05-16 to resolve the auth-bridging design task surfaced in gaps doc D.1 + stack-integration doc. Grounded in source-of-truth research: Skytale `identity.py`, Tally HTTP auth in `tally-worker/src/lib.rs`, Tally MVP bearer semantics from `cli-sub-pr-phase-0.md` D5.
