# Tally Coding — Architecture Document (Phase 0)

**Date:** 2026-05-15
**Author:** Nick
**Prerequisite:** tally-coding-vision-2026-05-15.md

## Purpose

Lock specific technical decisions for v1.0 commercial release. The vision document captured product direction; this document captures actual technical choices that gate implementation.

## Architecture overview

```
User devices (Flutter native apps; one Dart codebase, 5 targets)
┌───────────────────────────────────────────────────────────────────┐
│ macOS app    Linux app    Windows app    iOS app    Android app   │
│ (+ optional  (+ optional  (+ optional                             │
│  local exec)  local exec)  local exec)                            │
└────────────────────────────┬──────────────────────────────────────┘
                             │ HTTPS / WebSocket
                             │ (via Skytale Dart SDK + Convex Dart client)
                             ▼
┌───────────────────────────────────────────────────────────────────┐
│ Cloud (operator-owned; always-on; agents work while devices off)  │
│                                                                   │
│  Convex ────────► state, multi-device sync, agent metadata        │
│   │                                                               │
│   │ Convex actions dispatch wakes / spawn Modal functions         │
│   ▼                                                               │
│  Modal (Python OpenHands SDK; cloud agents)                       │
│   │   │                                                           │
│   │   └── LLM inference ──► Maple AI (TEE) via Maple Proxy        │
│   │                                                               │
│   ├── Encrypted channels ──► Skytale relay (relay.skytale.sh;     │
│   │                          QUIC/gRPC; MLS RFC 9420; zero-       │
│   │                          knowledge; sees only ciphertext)     │
│   │                                                               │
│   ├── Account mgmt ──► Skytale REST API (api.skytale.sh;          │
│   │                    operator-owned account)                    │
│   │                                                               │
│   └── Wake dispatch ──► Tally Workers (Cloudflare; Stoa           │
│                          WakeRouter; 8 routes; ULID wake IDs)     │
└───────────────────────────────────────────────────────────────────┘

Workers execute in Modal Sandbox containers (cloud) or in the desktop
Flutter app's embedded Python subprocess (opt-in local execution).
```

Data flow:
1. User opens Flutter app on any device (signed in via Clerk OAuth on first install)
2. App subscribes to Convex `users.{me}` for state + agent roster + conversation events
3. User dispatches a task from the app — Flutter calls Convex action → Convex calls Tally Workers to dispatch a wake to the orchestrator's cloud Modal function
4. Cloud orchestrator (Modal function): receives wake, deliberates with board via Skytale-encrypted channels, dispatches workers via Tally Workers
5. Cloud workers (Modal Sandbox containers): clone GitHub repo, edit code via OpenHands `FileEditorTool`/`TerminalTool`, run tests, commit, push, open PR via `gh pr create`
6. All agent activity flows through Skytale channels (E2E encrypted); also persisted as encrypted-metadata events in Convex (message content stays encrypted)
7. Native app on any device subscribes to Convex + Skytale; renders the unified team view; user can close one device and continue from another
8. Optional: if user enables "local execution" in the desktop app, the app embeds a Python OpenHands subprocess that registers as a worker agent. Same dispatch flow; just targets the local machine instead of Modal.

See [`tally-coding-stack-integration-2026-05-16.md`](tally-coding-stack-integration-2026-05-16.md) for concrete integration shapes, [`tally-coding-human-collaboration-2026-05-16.md`](tally-coding-human-collaboration-2026-05-16.md) for multi-runtime + human-collaboration details, and [`tally-coding-identity-and-auth-2026-05-16.md`](tally-coding-identity-and-auth-2026-05-16.md) for per-user provisioning.

## Component decisions

### Agent runtime: OpenHands SDK on Modal

Package: openhands-ai (PyPI; MIT; Python 3.12+)
Repo: github.com/OpenHands/software-agent-sdk
Paper: arXiv 2511.03690 (MLSys 2026)

**OpenHands is purpose-built for software-engineering agents.** It ships production-grade code-writing tools out of the box:
- `TerminalTool` — execute shell commands in the workspace (run tests, install deps, git operations)
- `FileEditorTool` — read / write / patch source files
- `TaskTrackerTool` — break tasks into subtasks; track progress
- `BrowserTool` — browse docs, search Stack Overflow, navigate web

Plus `Conversation` with built-in event streaming, persistent state via `persistence_dir`, stuck-detection, and remote workspace primitives. The platform inherits these and adds custom tools for inter-agent coordination (Skytale + Tally wrappers).

Hosting on Modal because: Python-native serverless; long-running function support (24h); per-second billing; Docker sandboxing for workers; persistent volumes for conversation state; faster cold-start than Lambda.

Rejected: E2B (less production-mature for full agent processes), Fly Machines (more operational complexity), AWS Lambda (15-min limit incompatible), custom Docker on VPS (too much operational overhead for solo founder), Cloudflare Workers (Python support constrained).

### LLM inference: Maple Proxy → Maple AI

Maple AI via Maple Proxy (github.com/opensecretcloud/maple-proxy) as OpenAI-compatible inference endpoint.

Privacy as infrastructure via TEE. Cryptographic attestation; zero data retention. OpenAI-compatible API integrates via LiteLLM (which OpenHands uses). $20/mo Pro plan.

Configuration deferred to first-week implementation: hosted endpoint vs self-hosted sidecar (trial both).

Trade-off: model quality lower than frontier Claude/GPT for hardest coding tasks; acceptable for v1.0; Phase 2 may add "BYO-LLM" option.

### Inter-agent comms: Skytale channels + Tally wakes (two layers)

Skytale and Tally are **peer components**, not nested. The platform uses each for different inter-agent patterns:

**Skytale — persistent encrypted channels** (sibling repo at `~/Projects/pronoic/skytale/`):
- Skytale SDK (`pip install skytale-sdk`) ships an `OrchestrationAgent` integration with message types purpose-built for multi-agent coding (status, decision_request, block, unblock, context_share, session_start/end, error, action_response, pr_update)
- Channels backed by MLS RFC 9420 groups; the Skytale relay (at `relay.skytale.sh`) routes ciphertext only (zero-knowledge)
- Used for: board↔board deliberation, board↔user chat, ongoing observation threads
- Identity: `AgentIdentity` (Ed25519 keypair + `did:key:z6Mk...` URI)

**Tally — transient request-response dispatch** (sibling repo at `~/Projects/pronoic/tally/`):
- Tally implements Stoa's `WakeRouter` trait on Cloudflare Workers + Durable Objects
- Stoa is a separate protocol-interface crate inside the Skytale repo; defines `TeamPrimitive`, `RolePackHandler`, `AuditTrail`, `WakeRouter`
- Tally is currently the only production-grade `WakeRouter` runtime; deployed at `tally.nraimbault16.workers.dev`
- 8 HTTP routes; ULID wake IDs; Bearer auth = `url_safe_b64(identity_bytes)`
- Used for: orchestrator→worker task dispatch, worker→orchestrator status reports / blocker escalation
- Payloads are opaque bytes; platform encrypts upstream with Skytale primitives before dispatch

Phase 1B Tally status: Sub-PR 1 + Sub-PR 3 merged. Sub-PR 2 (MCP plugin) and Sub-PR 4 (docs + dogfooding) deferred indefinitely. Tally is internal substrate for the platform; external developer audience no longer central.

See [`tally-coding-stack-integration-2026-05-16.md`](tally-coding-stack-integration-2026-05-16.md) for code-shape integration patterns including the OpenHands tool wrappers for both Skytale and Tally.

### State + real-time sync: Convex (convex.dev)

Reactive backend with WebSocket subscriptions. TypeScript backend functions; matches Next.js frontend. Built-in Clerk auth integration. Document database with reactive queries. Free tier covers prototype; $25/mo Starter for early users.

Rejected: Supabase realtime (more operational complexity), Liveblocks (focused on collaborative editing, overkill), Firebase (lock-in), custom Postgres + WebSocket (too much from-scratch infrastructure).

Initial schema sketch:
- users, projects, agents, conversations, messages, events, executions (worker run records)

### Client framework: Flutter (Dart) for native apps; Next.js (or static) for marketing site

**Flutter (Dart)** for the application UI. Single codebase targets iOS, Android, macOS, Linux, Windows. Native push notifications via APNs / FCM / OS-native. App store distribution.

**Skytale Dart SDK** — built as part of v0.1 (Skytale is operator-owned). Adds Dart to Skytale's SDK lineup (Python, Rust, TypeScript, Dart). Used by the Flutter app for MLS encryption, channel client, AgentIdentity primitives.

**Next.js (or static)** for `tally.codes` marketing site only. Landing page, pricing, docs, signup-to-download flow. Not the application UI.

Rejected for the app UI:
- Web app only (Next.js / browser) — would lose native push on iOS without PWA install; loses "real tool" brand feel; doesn't work when user wants laptop off and agents continuing
- React Native — would still need separate web codebase; Dart provides truly cross-platform single codebase
- Electron — heavy resource use; doesn't solve mobile
- Tauri — desktop only, doesn't solve mobile
- Native per-platform (SwiftUI + Kotlin + ...) — too much maintenance for solo founder

Rejected for marketing:
- Marketing in Flutter Web — bigger payload, slower load, less SEO-friendly than Next.js

### Auth: Clerk

Drop-in Next.js integration; GitHub OAuth built in (critical for repo integration); Convex integrates via JWT verification; free tier covers 10,000 MAU.

Rejected: Supabase Auth (pairs with Supabase better), Auth.js (more setup), custom JWT, Stack Auth (newer, less proven).

### Sandboxed execution: OpenHands + Modal Sandbox (coding-specific)

Workers run in Modal Sandbox containers per coding task. The container image includes: Git, build tools, Node.js, Python, common language toolchains (Rust, Go, Java), gh CLI for PR operations. Workers can:
- Clone the user's GitHub repo (via per-user OAuth scope)
- Edit code via OpenHands `FileEditorTool`
- Run tests via `TerminalTool` (`pytest`, `npm test`, `cargo test`, etc.)
- Commit + push branches; open PRs via `gh pr create`
- Read CI logs

Container destroyed on completion. Cost scales with usage. Sandbox isolation means even if a worker agent goes off-script, it cannot escape into the platform's broader infrastructure.

### Billing: Stripe (deferred to v1.0)

v0.1 ships without billing. Gather users first.

### Hosting cost summary (rough)

Tally Coding pays for its full stack; Skytale + Tally Workers are operator-owned infrastructure, so costs are at-wholesale rather than per-user-subscription:

- Marketing site hosting (Vercel or Cloudflare Pages): $0-20/mo (low traffic; static-ish)
- Convex: $25/mo (fixed; scales with usage)
- Clerk: free → $25/mo (fixed)
- Modal: $50-200/mo (variable; per-agent-second + sandbox compute)
- Maple AI: $20-60/mo per active platform user (variable; one platform Maple subscription, internally attributed per user)
- Tally Workers: ~$5/mo (Cloudflare Paid; operator-owned infrastructure)
- Skytale relay: operator-owned (Apache 2.0 self-host); cost = compute hosting + bandwidth, not a per-user subscription
- Skytale API: operator-owned (Axum + Postgres self-host)
- Domain: ~$30/year for `tally.codes`
- App store + code signing: Apple Developer Program ($99/year), Apple notarization, Microsoft Store ($19 once), Google Play Console ($25 once)
- Misc: ~$10/mo

Fixed (operator overhead, regardless of user count): ~$150-250/mo + ~$200/year (app stores, signing). Variable per active user: ~$50-200/mo (dominated by Maple LLM costs + Modal agent runtime).

No Vercel hosting cost for the application UI — Flutter apps distribute via app stores + direct download. Saves a small recurring cost vs the web-app architecture.

Per-user economics implication: paid tier needs to be $100+/mo per active user to cover variable costs and contribute to fixed-cost recoupment. Pricing TBD.

## Multi-agent coordination

### Agent identity model

Each agent has:
- Identity (Tally identity; ed25519 keypair; immutable)
- Role (board:architect, board:reviewer, board:communicator, orchestrator, worker:executor, worker:tester, worker:documenter)
- System prompt (stored in Convex; editable by user)
- Long-term memory (event-sourced; stored in Convex)
- Active workspace (Modal container; ephemeral per task)

### Escalation classification (v1.0)

| Block type | Escalation | Trigger |
|---|---|---|
| Missing information | One level up | Worker doesn't know what user wants |
| Ambiguous requirement | One level up | Multiple valid interpretations |
| Technical infeasibility | Up to board | Implementation impossible as specified |
| Test failure | Worker self-handles N attempts then escalates | Automated CI feedback |
| Permission required | Up to user | Action affects production; high-risk |
| External failure | Worker debugs; escalates if stuck | Network, dependency |

### Event sourcing

OpenHands SDK Action/Observation events. Tally Coding extends: all inter-agent messages stored as events in Convex; user interventions stored as events; full audit trail; replay supported.

## Decisions deferred to implementation

1. Modal vs Modal+Maple-sidecar topology (trial in week 1)
2. Convex schema migrations (design as you go)
3. Specific OpenHands tools per agent role (experimentation)
4. WebSocket message format (Convex standard pattern initially)
5. Rate limiting / abuse prevention (Phase 2)
6. Logging / observability (basic Convex logs for v1.0)

## Risk register

1. Modal cold starts (2-10s; acceptable for v1.0)
2. Convex pricing scaling (predictable; not load-bearing). Also: Convex from Flutter (Dart) is less first-class than from TypeScript — verify the integration during week 5.
3. Maple AI dependency (mitigation: OpenAI-compatibility means swap to alternative TEE provider possible)
4. OpenHands SDK breaking changes (pin to version; upgrade deliberately)
5. Skytale SDK breaking changes (pin version; OrchestrationAgent is currently in `_orchestration.py` — underscore-prefixed; treat as semi-public API and pin specific Skytale SDK release)
6. Cloudflare Workers limits on Tally Workers (current usage well within Paid tier)
7. Stoa protocol revision (`WakeRouter` trait is provisional per stoa docs; future changes require Tally Workers upgrade + platform integration update)
8. Skytale Dart SDK build cost — building Dart bindings is internal scoping (operator owns Skytale) but still requires engineering time. Estimated 2-3 weeks for v0.1 minimum.
9. Flutter cross-platform edge cases (especially Windows + Linux); plan for 1-2 weeks of cross-platform debugging
10. App store review delays — Apple notarization can take days; can block bug-fix releases. Mitigate with direct-download path + auto-update for users who install via website.

## Open architectural questions

- Voice/audio (Phase 2)
- Multi-project support (Phase 2; affects Convex schema)
- Mobile native apps (Phase 2; web responsive for now)
- Self-hosted on-premises tier (Phase 3)

## Provenance

Drafted 2026-05-15. Architecture decisions verified against current external service documentation.
