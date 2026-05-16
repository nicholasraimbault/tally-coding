# Tally Coding

> **Your AI coding team lives in the cloud. Native apps everywhere.** End-to-end encrypted team chat with AI coding teammates. Your team is a roster of mixed members — AI agents in the cloud (always working, even when your laptop is off), AI agents on your local desktop (opt-in local execution within the desktop app), and human teammates. Access them from native apps on macOS, Linux, Windows, iOS, Android. Coordinate through encrypted channels (board deliberation, orchestrator dispatch, worker reports), execute coding work (clone repos, edit code, run tests, open PRs), and chat with each other (humans + AI in the same conversation). Differentiator: cryptographically-attested privacy — TEE-attested LLM inference (Maple AI) + E2E-encrypted messaging for AI ↔ AI, AI ↔ human, and human ↔ human (Skytale MLS). Even the platform operator cannot read messages.

## Stack

**Native clients (one Flutter codebase, all platforms):**
- **Flutter (Dart)** — iOS, Android, macOS, Linux, Windows native apps from one codebase
- **Skytale Dart SDK** — built by operator as part of v0.1; provides MLS encryption + channels + AgentIdentity for the Flutter app
- **Marketing site (Next.js or static)** — `tally.codes`; signup-to-download flow

**Cloud (always-on; agents continue when devices are off):**
- **OpenHands SDK** — agent runtime (Python; MIT; `pip install openhands-ai`). Runs in Modal cloud functions; also embeddable in the desktop app for opt-in local execution.
- **Maple AI via Maple Proxy** — TEE-attested LLM inference (OpenAI-compatible API)
- **Skytale SDK + relay** — E2E encrypted MLS channels for ALL messaging (AI ↔ AI, AI ↔ human, human ↔ human). Relay at `relay.skytale.sh`; zero-knowledge.
- **Tally Workers** — Cloudflare-hosted Stoa `WakeRouter` for orchestrator-to-worker dispatch
- **Modal** — serverless Python host + sandbox for cloud agent execution
- **Convex** — reactive backend (state, multi-device sync)
- **Clerk** — auth with GitHub OAuth (browser flow during signup; Flutter resumes after)
- **Stripe** — billing (Phase 2)

Privacy is structural — two cryptographic guarantees: LLM inference is TEE-attested (Maple); all messaging is E2E MLS-encrypted (Skytale). The Skytale relay sees only ciphertext; the LLM provider sees only TEE-attested calls.

Skytale and Tally Workers are **peer infrastructure** owned by the same operator, consumed as platform-internal subsystems. See [`docs/tally-coding-stack-integration-2026-05-16.md`](docs/tally-coding-stack-integration-2026-05-16.md) and [`docs/tally-coding-human-collaboration-2026-05-16.md`](docs/tally-coding-human-collaboration-2026-05-16.md).

## What this is

A coordination platform for **people who direct AI agents to write, review, test, and ship code**. The user describes high-level coding vision (e.g., "add OAuth2 to the auth service" or "refactor the payment module for testability"); a board of agents (architect, reviewer, communicator, orchestrator) deliberates on the plan; an orchestrator dispatches workers (executor, tester, documenter) that actually clone the repo, edit files, run tests, and open PRs. User intervenes only when input is genuinely needed.

Coding is the primary use case. Every layer is shaped around it:
- **OpenHands SDK** provides production-grade code-writing tools out of the box: `FileEditorTool`, `TerminalTool`, `TaskTrackerTool`, `BrowserTool`. Workers don't need custom tools for basic coding — those exist.
- **Skytale's OrchestrationAgent** has message types built for coding workflows: `StatusData` (files_modified, tests_passing, tests_failing, branch), `PrUpdateData` (PR number, status, CI, additions, deletions), `BlockData` / `UnblockData` for dependency blockers.
- **Worker sandboxing** = Modal Sandbox containers with Git, build tools, Node.js, Python. Containers are destroyed after each task.
- **GitHub OAuth** is the auth bridge; the platform reads/writes user repos with explicit permission.

Key product properties:
- Long-term persistent agents with stable roles (architect, reviewer, communicator, orchestrator + worker team)
- Cloud-hosted; survives operator laptop power-down
- Cross-device sync (web; eventually native)
- User can intervene in any agent-to-agent conversation
- Cryptographically-attested privacy on both LLM inference and inter-agent messaging

Target market: developers/devops/teams who need data sovereignty over their code — regulated industries (finance, healthcare, legal), security-conscious teams, government contractors. Anyone with proprietary code they cannot expose to Cursor/Devin/Claude Code/standard cloud AI providers.

For full product context: [`docs/tally-coding-vision-2026-05-15.md`](docs/tally-coding-vision-2026-05-15.md).

## What's in this repo

```
platform/
├── README.md                          ← you are here
├── ROADMAP.md                         ← synthesis: stack summary, critical path, technical decisions, risks
├── .gitignore                         ← OS junk + placeholder for stack-specific entries
└── docs/
    ├── tally-coding-vision-2026-05-15.md          ← product direction
    ├── tally-coding-architecture-2026-05-15.md    ← Phase 0 technical decisions
    ├── tally-coding-v0.1-milestones-2026-05-15.md ← 10-week plan
    ├── tally-coding-week-1-scope-2026-05-15.md    ← day-by-day for week 1
    ├── tally-coding-openhands-sdk-exploration-2026-05-15.md   ← OpenHands SDK API reference
    ├── tally-coding-stack-integration-2026-05-16.md          ← concrete integration architecture
    ├── tally-coding-identity-and-auth-2026-05-16.md          ← per-user provisioning + auth bridging
    └── gaps-and-open-questions.md                                ← technical meta-analysis
```

## How to navigate

**If you're starting work:**
1. [`ROADMAP.md`](ROADMAP.md) — stack summary, critical path, decision-point timeline
2. [`docs/tally-coding-week-1-scope-2026-05-15.md`](docs/tally-coding-week-1-scope-2026-05-15.md) — day-by-day for week 1
3. [`docs/gaps-and-open-questions.md`](docs/gaps-and-open-questions.md) — pre-week-1 cleanup checklist (account pre-staging, SDK version pin, Modal runtime verification, Maple topology decision, Skytale version-pin policy)

**If you're a future collaborator or AI assistant on this codebase:**
1. Start with this README
2. Then ROADMAP
3. Then the source artifacts in `docs/` in this order: vision → architecture → milestones → week-1 → SDK exploration
4. The gaps document is technical meta-analysis; useful for understanding open technical decisions but not for understanding the product itself

## Stack dependencies

Tally Coding depends on two infrastructure components:

- **[Tally Workers](https://github.com/nicholasraimbault/tally-workers)** — sibling repo. Cloudflare-hosted runtime for Stoa's `WakeRouter` trait. Provides synchronous request-response dispatch between agent identities via HTTP API. Same product family (`Tally`); both BSL 1.1.

- **[Skytale](https://github.com/nicholasraimbault/skytale)** — open-source (Apache 2.0). E2E encryption for AI agents (MLS RFC 9420). Provides Python SDK (`pip install skytale-sdk`), Rust SDK, TypeScript SDK, QUIC/gRPC relay at `relay.skytale.sh`, REST API at `api.skytale.sh`, CLI (`cargo install skytale-cli`). Includes a ready-made `OrchestrationAgent` integration for multi-agent coding workflows. Stoa (the protocol-interface crate that Tally Workers implements) also lives in the Skytale repo.

**Stack relationship:**
- Skytale provides open primitives (Apache 2.0); Tally provides commercial value-add (BSL 1.1).
- Tally Workers and Tally Coding are sibling products under the Tally brand, both consuming Skytale primitives.
- Coding agents `pip install skytale-sdk` for MLS-encrypted channels, then call Tally Workers HTTP directly for transient wakes.
- Tally Workers does NOT do MLS encryption internally — Tally Coding encrypts wake payloads upstream using Skytale primitives before dispatching to Tally Workers.

**Current Tally Workers state (2026-05-15):**
- Sub-PR 1 (Cloudflare runtime) + Sub-PR 3 (CLI) merged
- Production deployment at `https://tally.nraimbault16.workers.dev`
- 22/22 integration tests passing on `main`
- Canonical resting state — no active development planned during Tally Coding build
- Sub-PR 2 (MCP plugin) and Sub-PR 4 (docs + dogfooding) deferred indefinitely

**Implications for Tally Coding development:**
- Tally Coding builds an OpenHands integration glue (`_openhands.py`-style; initially Tally-Coding-private, possibly upstream contribution to Skytale SDK later) wrapping Skytale + Tally Workers primitives as OpenHands tools
- Per-user provisioning bootstraps within the platform's single Skytale account: N agent identities + Tally Workers `team_id` + handler registrations (no per-user Skytale signup)
- If Tally Coding surfaces a Tally Workers or Skytale bug: fix it in the relevant component (Workers fix in `../`, Skytale fix as upstream PR)
- Tally Workers production deployment shape is a week-19 decision

See [`docs/tally-coding-stack-integration-2026-05-16.md`](docs/tally-coding-stack-integration-2026-05-16.md) for the full integration architecture.

## License

TBD. Likely permissive (MIT or Apache 2.0) for open-source components; commercial license for hosted platform service. Decided closer to v1.0 launch.

## Timeline

Estimated 6 months total for v1.0 (native-only Flutter app + cloud-primary agents + chat + multi-device sync). Internal milestone (v0.1) at ~3 months. Full timeline + week-by-week scope in [`ROADMAP.md`](ROADMAP.md).

## Provenance

Repository initialized 2026-05-15. Vision artifacts drafted same day. Synthesis docs (README, ROADMAP, gaps) revised 2026-05-16 to focus purely on technical content.
