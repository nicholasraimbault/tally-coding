# Tally Coding — Vision Document

**Date:** 2026-05-15
**Author:** Nick

## What it is

Tally is **a privacy-first AI coding team platform**. Your AI coding team lives in the cloud and keeps working while your devices are off. You access them through native apps on every device — macOS, Linux, Windows, iOS, Android. End-to-end encrypted across all messaging: AI ↔ AI, AI ↔ human, human ↔ human. Even Tally's operator cannot read your team's conversations.

A "team" is a roster of mixed members:
- **AI agents in the cloud** — board (architect, reviewer, communicator, orchestrator) + workers (executor, tester, documenter) running in Phala Cloud. The canonical home for coding work.
- **AI agents on your local desktop** (opt-in) — when enabled in the desktop app's settings, your Mac / Linux / Windows machine becomes an agent in your team, executing tasks against your local filesystem. For work on uncommitted code or in your specific dev environment.
- **Human teammates** — real people you invite to your team, participating in the same encrypted channels as the AI agents.

All members coordinate through the same encrypted channels and the same dispatch primitives. The Skytale relay sees only ciphertext; the LLM provider sees only TEE-attested calls.

The workflow: from any device (your laptop, phone, desktop, tablet), you describe a coding goal (e.g., "implement OAuth2 in the auth service"). The board of cloud agents deliberates on the plan; the communicator surfaces consensus; you confirm; the orchestrator dispatches workers — to cloud sandboxes by default, or to your local desktop if you've enabled it — that clone the repo, edit code, run tests, open PRs. While they work, you can close your laptop, take a walk, check progress from your phone. The agents continue. Humans on your team can chat with each other and with the AI in the same channels, all end-to-end encrypted.

Agents are persistent with long-term roles. Multi-device sync via native apps. Mixed-runtime teams (cloud-primary + optional local + humans).

It is not an IDE. Users use their existing tools (VS Code, Cursor, GitHub, terminal) to read code. Tally is the **coordination + collaboration layer above code-writing** — where coding work gets directed, deliberated, dispatched, observed, reviewed, and discussed.

**Why OpenHands SDK** is the runtime: it ships production-grade code-writing tools (FileEditorTool, TerminalTool, TaskTrackerTool, BrowserTool) and a persistent Conversation primitive with built-in event streaming. OpenHands runs as Python in cloud agents (Phala CVMs) and inside the desktop app's optional local execution mode (Python subprocess managed by the Flutter app). The platform inherits these primitives and layers multi-agent coordination + human collaboration (via Skytale + Tally Workers) on top.

**Why Flutter** is the client framework: one codebase targets iOS, Android, macOS, Linux, Windows. Single team builds and maintains all five clients. Native push notifications work everywhere (no PWA-install friction on iOS). Marketing site stays Next.js or static at `tally.codes`. Since Skytale is operator-owned, the platform builds Dart bindings as part of v0.1 — adding to Skytale's SDK lineup (Python, Rust, TypeScript, now Dart).

## Commercial positioning

Privacy-first encrypted team chat with AI coding teammates. Two cryptographic guarantees:

1. **LLM inference is TEE-attested** — Phala Redpill (Phala Cloud Confidential AI). LLM provider cannot see prompts or code.
2. **All team messaging (AI ↔ AI, AI ↔ human, human ↔ human) is E2E encrypted** — Skytale MLS RFC 9420. Even the platform operator cannot read messages, decisions, or DMs.

Privacy as infrastructure, not policy.

Target market: developers, devops engineers, and small teams who need data sovereignty over their code AND want their team's conversations to stay private — regulated industries (finance, healthcare, legal), security-conscious teams, government contractors, founders + their hires, anyone whose code, plans, and team chatter must not be readable by their tooling provider.

For the unified multi-runtime + human-collaboration architecture, see [`tally-coding-human-collaboration-2026-05-16.md`](tally-coding-human-collaboration-2026-05-16.md).

## Who it's for

**v1.0: Privacy-conscious developers and small teams.** People who would benefit from multi-agent coordination + encrypted team chat but cannot or will not send their code and conversations to standard cloud AI / collaboration providers.

**Initial validation user: Nick.** Solo founder; uses the platform to coordinate his own coding work + dogfoods the local-daemon path on his MacBook + uses Tally Coding to build Tally Coding itself.

## What problem it solves

Three problems addressed together:

**1. Coordination friction in current multi-agent coding workflows:**
- Manual relay between layers (copy-paste between chat surfaces)
- Manual state checking (checking git to know where implementation is)
- Coordination state living in human's head rather than in the system
- Context loss between sessions
- Fragile multi-device workflows tied to specific machine state

**2. Privacy gap in commercial multi-agent coding + team-chat platforms:**
- Existing AI coding platforms (Devin, Cognition, Replit Agent, Cursor cloud agents) require trusting the vendor with proprietary code
- Existing team chat (Slack, Teams, Discord) is admin-readable in standard configurations
- Privacy is policy-based ("we promise not to use your data") not infrastructure-based
- No verifiable guarantee that vendor cannot see code or messages

**3. Cloud-only vs local-only false dichotomy:**
- Existing AI coding tools are either cloud-only (Devin, OpenHands Cloud, Replit Agent) — losing local-dev velocity AND requiring code upload — or local-only (Cursor, Claude Code) — losing cross-device sync, persistent agents, and multi-agent coordination
- Tally hybridizes: agents run in the cloud OR on the user's local machines, addressable by the same orchestrator, all visible in the same UI

## The workflow (coding-centric)

1. User describes a coding goal in a chat surface (e.g., "add rate limiting to the API gateway"). User is part of the channel; messages flow E2E-encrypted via Skytale.
2. Board deliberates internally — architect proposes implementation approach; reviewer flags risks; orchestrator decomposes into worker tasks. Humans on the team can chime in here too (they're channel members like the AI agents).
3. Communicator surfaces consensus to user — translates board deliberation into an actionable plan with files-to-touch, tests-to-add, PR-shape
4. User confirms — explicit "go" action (or rejects with feedback)
5. Orchestrator dispatches workers via Tally wakes. Per task: target cloud (Phala CVM) OR target local PC (user's `tally-cli` daemon)
6. Workers execute — either in Phala CVM containers or on the user's local machine via the daemon. Both use OpenHands tools (`FileEditorTool`, `TerminalTool`, `TaskTrackerTool`); the only difference is whose filesystem they touch
7. Workers report status via Skytale-channel `StatusData` messages (files_modified, tests_passing, branch); blockers via `BlockData`
8. Orchestrator escalates to board when needed (e.g., test discovers a flaw in the original plan)
9. Board escalates to user for final calls (e.g., breaking-change decisions)
10. Workers open PRs via GitHub integration; report `PrUpdateData` to the channel; user reviews and merges. Human teammates and AI agents can both comment.

User (and any human teammate) can intervene in any conversation at any layer.

## Architectural stack

**Client (native apps on every device):**
- **Flutter (Dart)** — single codebase for iOS, Android, macOS, Linux, Windows. Native push notifications. App store distribution.
- **Skytale Dart SDK** — built as part of v0.1 (Skytale is operator-owned; adding Dart support is internal scoping work). Provides MLS encryption + channel client + AgentIdentity primitives for the Flutter app.
- **Marketing site (Next.js or static)** — `tally.codes` landing, pricing, docs, signup-to-download. Separate from the app codebase.

**Cloud (the canonical home for agents and state):**
- **Agent runtime:** OpenHands SDK (MIT, Python; `pip install openhands-ai`). Runs as Python in Phala CVMs for cloud agents; runs as embedded Python subprocess in the Flutter desktop app for opt-in local execution.
- **LLM inference:** Phala Redpill → Phala GPU TEE Trusted Execution Environments
- **Encrypted channels (AI ↔ AI, AI ↔ human, human ↔ human):** Skytale SDK ─► Skytale relay at `relay.skytale.sh` (MLS RFC 9420; QUIC/gRPC)
- **Platform's Skytale account/team management:** Skytale REST API at `api.skytale.sh` (one operator-owned Skytale account; customers never sign up for Skytale)
- **Transient wake-routing dispatch:** Tally Workers (Cloudflare Workers HTTP) — implements Stoa's `WakeRouter` trait
- **Cloud agent hosting:** Phala CVM per task
- **State backend:** Convex (operator-owned; the Flutter app subscribes via Dart-wrapped Convex client OR REST + WebSocket; provides cross-device sync of conversation state)
- **Auth:** Clerk (browser OAuth flow opens during Flutter app signup, returns to app)
- **Billing:** Stripe (Phase 2)

See [`tally-coding-stack-integration-2026-05-16.md`](tally-coding-stack-integration-2026-05-16.md) for the concrete integration architecture and [`tally-coding-identity-and-auth-2026-05-16.md`](tally-coding-identity-and-auth-2026-05-16.md) for the per-user provisioning flow.

Considered and rejected:
- Forking OpenCode and calling it "Tally Code" (wrong fit + wrong pattern)
- Forking OpenHands (premature; SDK-as-dependency is sufficient)
- Claude Agent SDK + Anthropic (doesn't support privacy-first positioning)
- Self-hosted everything via Ollama (weak model quality)

## v1.0 minimum

- Marketing site at `tally.codes` (Next.js or static) with signup → download flow
- Flutter native app on macOS, Linux, Windows, iOS, Android (single codebase)
- Skytale Dart SDK (built as part of v0.1 by operator)
- Cloud agent runtime (Phala CVM; board + workers) — the default execution path
- Optional local execution within the desktop app (toggle in settings; embeds Python OpenHands subprocess)
- Humans as first-class team members (Flutter-side AgentIdentity at signup)
- Human-to-human chat (DM channels, group channels, @mentions, threading)
- Native push notifications on all platforms (APNs / FCM on mobile; native OS notifications on desktop)
- Content-free notifications (preserve E2E privacy)
- Multi-device sync (open the app on any device; same view)
- Presence (online/offline indicators)
- Single-user accounts; one project per account (team-level multi-tenancy is Phase 2)
- 4 board agents (architect, reviewer, communicator, orchestrator)
- 3 worker roles (executor, tester, documenter)
- Workers clone GitHub repo, make changes, run tests, open PRs
- Chat surfaces for all conversations
- User intervention surface
- Real-time sync via Convex WebSockets
- "Go" confirmation flow
- Full escalation hierarchy
- Subscription billing
- Self-service signup with GitHub OAuth
- Documentation + support channel

## Explicitly NOT in v1.0

Multi-tenancy/team accounts; native mobile apps; IDE features; multi-LLM-provider choice (Phala-only); marketplace; voice/video; non-GitHub source control; local model option; public API; self-hosted enterprise deployment. All Phase 2.

## Open product questions

1. What counts as a "block" that triggers escalation? (Resolved in architecture doc's block-type taxonomy.)
2. What does board internal deliberation look like (format, structure, frequency)?
3. What does the communicator surface (final consensus only, or mid-deliberation)?
4. What can each layer decide unilaterally (worker, orchestrator, board)?
5. How does the orchestrator decompose work?
6. Agent runtime hosting specifics (Phala Cloud confirmed; sub-options open).
7. State persistence backend specifics (Convex confirmed; schema details open).

## Skytale / Tally substrate context

**Skytale** is a sibling product (at `~/Projects/pronoic/skytale/`) providing E2E encryption for AI agents via MLS RFC 9420. The platform consumes Skytale Python SDK (`pip install skytale-sdk`) for encrypted channels and the Skytale REST API (`api.skytale.sh`) for account/team management. Skytale already ships an `OrchestrationAgent` integration purpose-built for multi-agent coding workflows.

**Tally** (sibling at `~/Projects/pronoic/tally/`) is a Cloudflare-hosted runtime that implements Stoa's `WakeRouter` trait. Stoa is the protocol-interface crate living inside the Skytale repo. Tally provides synchronous request-response dispatch between agent identities — complementary to Skytale's persistent channels. Phase 1B status: Sub-PRs 1 and 3 merged (PRs #17–#27). Sub-PRs 2 (MCP plugin) and 4 (docs + dogfooding) deferred indefinitely.

Both Skytale and Tally are owned by the same operator and consumed by the platform as internal infrastructure. The end user sees one product (Tally Coding); Skytale + Tally are subsystems.
