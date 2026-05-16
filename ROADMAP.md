# Tally Coding — ROADMAP

**Date:** 2026-05-15 (drafted); 2026-05-16 (revised — technical only)
**Stack:** OpenHands SDK · Maple AI · Skytale · Tally · Modal · Convex · Next.js · Clerk

Synthesis of the source artifacts in [`docs/`](docs/). For source material:
- Product direction → [`docs/tally-coding-vision-2026-05-15.md`](docs/tally-coding-vision-2026-05-15.md)
- Technical architecture → [`docs/tally-coding-architecture-2026-05-15.md`](docs/tally-coding-architecture-2026-05-15.md)
- Week-by-week scope → [`docs/tally-coding-v0.1-milestones-2026-05-15.md`](docs/tally-coding-v0.1-milestones-2026-05-15.md)
- Concrete week-1 plan → [`docs/tally-coding-week-1-scope-2026-05-15.md`](docs/tally-coding-week-1-scope-2026-05-15.md)
- OpenHands SDK API reference → [`docs/tally-coding-openhands-sdk-exploration-2026-05-15.md`](docs/tally-coding-openhands-sdk-exploration-2026-05-15.md)
- **Concrete stack integration (Skytale + Tally + OpenHands)** → [`docs/tally-coding-stack-integration-2026-05-16.md`](docs/tally-coding-stack-integration-2026-05-16.md)
- **Per-user identity + auth bridging** → [`docs/tally-coding-identity-and-auth-2026-05-16.md`](docs/tally-coding-identity-and-auth-2026-05-16.md)
- Technical gaps (meta) → [`docs/gaps-and-open-questions.md`](docs/gaps-and-open-questions.md)

## Stack summary

The platform is a **native-only AI coding team platform**: cloud-primary agents accessible from Flutter native apps on every device. **OpenHands / Maple / Skytale / Tally** stack:

**Client (single Flutter codebase):**
- **Flutter (Dart)** — native apps for macOS, Linux, Windows, iOS, Android. App store distribution. Native push notifications (APNs / FCM / OS-native).
- **Skytale Dart SDK** — operator-built as part of v0.1 (Skytale is operator-owned, so adding Dart support is internal scoping). Provides MLS encryption + channel client + `AgentIdentity` primitives for the Flutter app.
- **Marketing site (Next.js or static)** at `tally.codes` — landing, pricing, docs, signup-to-download. Separate from the app codebase.

**Cloud (the canonical home for agents; works while user devices are off):**
- **OpenHands SDK** — agent runtime (Python; MIT). Runs in Modal cloud functions for cloud agents. Also embeds inside Flutter desktop app for opt-in local execution (Python subprocess managed by the app).
- **Maple AI via Maple Proxy** — TEE-attested LLM inference (privacy guarantee #1)
- **Skytale SDK + relay** at `relay.skytale.sh` — Python SDK (cloud agents) + Dart SDK (Flutter app). All team messaging — AI ↔ AI, AI ↔ human, human ↔ human, DMs, group chats — flows through MLS-encrypted channels. (Privacy guarantee #2.)
- **Skytale REST API** at `api.skytale.sh` — platform's Skytale account / team / key management (operator-owned; customers never sign up for Skytale)
- **Tally Workers** — Cloudflare-hosted Stoa `WakeRouter`. Synchronous request-response dispatch (orchestrator → worker, worker → orchestrator, AI → human decision-request). 8 HTTP routes; ULID wake IDs.
- **Modal** — serverless Python host + sandbox for cloud agent execution
- **Convex** — reactive backend (state, multi-device sync). Flutter app subscribes via Dart-wrapped Convex client.
- **Clerk** — auth with GitHub OAuth (browser OAuth flow opens during Flutter signup; returns to app)
- **Stripe** — billing (Phase 2)

**Skytale and Tally Workers are peer infrastructure**, both owned by the same operator. Skytale handles persistent encrypted conversations; Tally Workers handles transient request-response dispatch.

The Skytale relay sees only ciphertext; the LLM provider sees only TEE-attested calls. Even the platform operator cannot read team messages. Privacy is structural.

**Cloud-primary agents** means: agents keep running while the user's devices are off. User can dispatch from laptop, close it, watch progress from phone. Multi-device sync via Convex.

**Local execution** is an opt-in feature inside the desktop Flutter app. When enabled, the desktop app embeds a Python OpenHands subprocess and registers as a worker agent. For users who want code to run on their own machine instead of in Modal Sandbox.

For the unified multi-runtime + human-collaboration architecture, see [`docs/tally-coding-human-collaboration-2026-05-16.md`](docs/tally-coding-human-collaboration-2026-05-16.md).

## Critical path map

The v0.1 critical path (12 weeks) — each week's output blocks the next:

```
Week 1: OpenHands+Maple spike (cloud + local)
   ↓
Week 2: Skytale Dart SDK foundation (operator builds in skytale repo)
   ↓
Week 3: Tally Workers Dart client; cloud-agent ↔ Dart roundtrip
   ↓
Week 4: Flutter app scaffold + Clerk auth + AgentIdentity generation
   ↓
Week 5: Convex from Flutter + team provisioning
   ↓
Week 6: Skytale channel UI + AI agent dispatch from Flutter
   ↓
Week 7: Cloud workers in Modal Sandbox + GitHub integration
   ↓
Week 8: Opt-in local execution in Flutter desktop app
   ↓
Week 9: Conversation persistence + multi-device sync
   ↓
Week 10: Escalation hierarchy + robustness
   ↓
Week 11: Cross-platform Flutter (Linux + Windows builds)
   ↓
Week 12: Dogfood
   ↓
v0.1 complete
```

The v0.1 → v1.0 path (12 more weeks):

```
v0.1
 ↓
Week 13-14: Flutter mobile MVP (iOS + Android)
   ↓
Week 15: User isolation + production hardening
   ↓
Week 16: Humans as team members + DM channels
   ↓
Week 17: Chat polish (@mentions, threading, markdown, in-app notifications)
   ↓
Week 18: Push notifications (APNs / FCM / OS-native)
   ↓
Week 19: Billing + onboarding + security audit
   ↓
Week 20: Documentation + marketing site
   ↓
Week 21-22: App store distribution (Apple, Google, Microsoft, Linux packages)
   ↓
Week 23: Beta testing
   ↓
Week 24: Launch prep + launch
   ↓
v1.0 LIVE
```

Total: ~24 weeks (~6 months) for v1.0.

**External dependencies on the critical path** (account setup; should be pre-staged):
- Maple AI Pro plan (week 1 day 1)
- Modal (week 1 day 1)
- Convex (week 3)
- Clerk (week 3)
- Vercel (week 4-5)
- Stripe (week 13; longer verification lead time)
- Sentry / observability vendor (week 15)
- Security audit vendor (line up by week 10; engagement week 16)

**Recommended pre-staging**: ~30 minutes in week 0 to create all v0.1 + v1.0 accounts at once so no week is blocked on account creation. Stripe especially deserves early creation because business verification can take 1-2 weeks.

**Existing substrate dependencies (already satisfied):**
- Tally HTTP API (deployed at `https://tally.nraimbault16.workers.dev`; canonical resting state after PRs #25, #27)
- Tally CLI (local; used for agent identity provisioning)
- Skytale (MLS encryption layer; consumed transitively via Tally)
- OpenHands SDK (PyPI; pin version at week 1 day 1)

## Decision-point timeline

When technical decisions are needed during build. Cross-referenced to [`docs/gaps-and-open-questions.md`](docs/gaps-and-open-questions.md).

| Week | Decision | Gap ref | Notes |
|---|---|---|---|
| **Pre-week-1** | OpenHands SDK version pin | D.3 | Pin to avoid breaking changes mid-build |
| **Pre-week-1** | Skytale SDK version pin | C.3 | `_orchestration.py` is semi-public; pin specific release |
| **Pre-week-1** | Account pre-staging | D.1 | All v0.1 + v1.0 accounts created at once |
| **Pre-week-1** | Verify Modal function runtime limits | D.4 | Confirm 24h cap or actual |
| Week 1 day 2 | Maple Proxy topology | A.1 | Hosted endpoint vs sidecar |
| Week 1-2 | Workspace mode | B.1 | Modal Sandbox direct vs OpenHands Agent Server on Modal |
| Week 3 | Convex/Clerk JWT integration verification | C.1 | Verify against current docs |
| Week 5 | Board deliberation format | B.2 | Likely emerges from week-5 experimentation |
| Week 5 | Communicator surface | B.3 | UX of "go" flow |
| Week 5 | Multi-channel topology (v0.1 starting point) | B.6 | Single channel for v0.1; transition plan |
| Week 5-6 | Role pack location | B.7 | Repo / per-user / default-with-override |
| Week 6 | Orchestrator decomposition strategy | B.5 | Board-shaped plan vs orchestrator-generated |
| Week 7-8 | Block taxonomy refinement; layer autonomy | B.4 | Escalation specifics |
| Week 10 | Security audit vendor selection | — | 4-8 week lead time = start by week 10 |
| Weeks 11-12 | Master key custodianship | C.4 | Modal env var → KMS migration |
| Phase 2 | Skytale-account partitioning model | C.5 | Defer until demand pulls; platform uses one shared account through v1.0 |
| Weeks 11-12 | Multi-channel topology (v1.0 transition) | B.6 | Split into board/projects channels |
| Week 13 | Maple plan billing structure | D.5 | Shared subscription vs per-user |
| Week 19 | Tally production deployment shape | D.2 | Personal account vs platform account; custom domain |

## Week-by-week summary

Detailed scope per week lives in [`docs/tally-coding-v0.1-milestones-2026-05-15.md`](docs/tally-coding-v0.1-milestones-2026-05-15.md). Day-by-day for week 1 in [`docs/tally-coding-week-1-scope-2026-05-15.md`](docs/tally-coding-week-1-scope-2026-05-15.md). This section adds critical-path callouts.

### v0.1 (weeks 1-10)

- **Week 1** — Foundation + spike. **Critical**: OpenHands SDK + Maple Proxy validation. If they don't integrate, the stack rethinks.
- **Week 2** — Skytale + Tally integration. Build `_openhands.py` glue (Tool wrappers for Skytale send/receive + Tally dispatch/complete). Wire `OrchestrationAgent` for the channel runtime. **Document**: Skytale SDK version-pin policy (gap C.3).
- **Week 3** — Convex state model + auth shell. **Verify**: Clerk+Convex JWT integration against current docs (gap C.1).
- **Week 4** — Agent dispatch from UI + event streaming. **Critical**: end-to-end vertical slice (UI → Convex → Tally → Modal → OpenHands callback → Convex → UI subscription) works. OpenHands `callbacks=[convex_event_callback]` handles event pipeline.
- **Week 5** — Multi-agent + board (multi-OrchestrationAgent on shared channel). **Decide**: board deliberation format, communicator surface, multi-channel topology starting point (gaps B.2, B.3, B.6).
- **Week 6** — Orchestrator + workers via Tally wakes; first real coding execution. **Decide**: orchestrator decomposition strategy, role pack location (gaps B.5, B.7).
- **Week 7** — Escalation hierarchy. Use OrchestrationAgent's `BlockData` / `UnblockData` message types. **Decide**: layer autonomy boundaries (gap B.4).
- **Week 8** — User intervention surface + conversation persistence. Wire OpenHands `persistence_dir` to Modal volume per conversation.
- **Week 9** — Robustness + GitHub integration. **Critical**: permission model affects security posture for v1.0.
- **Week 10** — Dogfood. **Start**: security audit vendor selection.

### v0.1 → v1.0 (weeks 11-20; scope expanded to include daemon + humans + chat)

- **Week 11-12** — User isolation + production hardening. Wrap per-user agents in `SkytaleTeam.create()` (platform's single Skytale account hosts all SkytaleTeams). Encryption-at-rest for agent private keys. Migration plan for master key custodianship (gap C.4), multi-channel topology (gap B.6). DM channel topology design. Single-user accounts per vision; not team multi-tenancy.
- **Week 13** — Billing + Stripe + `tally-cli` daemon protocol design. **Decide**: Maple billing structure (gap D.5).
- **Week 14** — Onboarding flow + `tally-cli serve` MVP shipped. Each user can register their local PC as an agent; web app roster shows it.
- **Week 15** — Error handling + observability + humans-as-team-members. Browser-side `AgentIdentity`; decision_request UI flow.
- **Week 16** — Security audit + DM channels. Pen test the crypto stack. Ship 1:1 DM chat between any two team members.
- **Week 17** — Documentation + marketing + chat polish. @mentions, in-app notifications, group channels, threading.
- **Week 18** — Beta testing. 5-10 users install daemon, invite teammates, use chat + dispatch end-to-end.
- **Week 19** — Launch prep + push notifications (content-free) + presence indicators. **Decide**: Tally Workers production deployment shape (gap D.2).
- **Week 20** — v1.0 launch.

**v1.0 scope expansion vs original plan:** adding `tally-cli` daemon (weeks 13-14), humans-as-team-members (week 15), and chat MVP (weeks 16-19) shifts v1.0 timeline from 8-12 weeks post-v0.1 to 12-16 weeks. Polish (reactions, file sharing, search, mobile push) is Phase 2 / v1.5.

## Tally substrate state

Tally is consumed as a dependency, not actively developed during platform build. Tally consumes Skytale internally for E2E encryption; the platform inherits Skytale's cryptographic guarantees transitively.

**Current state (canonical resting; 2026-05-15):**
- Sub-PR 1 (Cloudflare runtime) merged via PRs #17, #18, #19, #20, #22
- Sub-PR 3 (CLI) merged via PRs #23, #24, #25
- Post-Sub-PR-3 follow-ups (harness cleanup) merged via PR #27
- 22/22 integration tests pass on `main`
- Production deployment at `https://tally.nraimbault16.workers.dev` (personal Cloudflare account)
- All Phase 1B locked architectural decisions hold (D1-D11 from `cli-sub-pr-phase-0.md`)
- Skytale (MLS RFC 9420) consumed internally for inter-agent E2E encryption

**Deferred indefinitely:**
- Sub-PR 2 (MCP plugin) — was intended for third-party developer audience; deferred
- Sub-PR 4 (docs + dogfooding) — same deferral

**Maintenance during platform build:**
- **None scheduled.** Tally is in resting state; expected to serve as substrate without modification through v1.0
- **Reactive only**: if platform build surfaces a Tally bug, fix it; no proactive Tally feature work
- **Skytale upgrades**: monitor Skytale releases; coordinate with Tally if breaking changes affect MLS group state
- **Pre-launch decision**: Tally production deployment shape for the platform (gap D.2). Options: personal account stays; new Pronoic account; custom domain (e.g., `tally.pronoic.app`). Decide by week 19.

**Implicit dependency risks:**
- Cloudflare Workers limits — current usage well within Paid tier
- Cloudflare deprecates Durable Objects — extremely unlikely; Phase 3 contingency
- Skytale MLS protocol stability — RFC 9420 is finalized; OpenMLS implementation is the moving piece
- Tally's `set_alarm` fix (PR #25) and harness cleanup (PR #27) were both load-bearing; verify integration test coverage doesn't regress against the fixed behavior

## Risks register

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| 1 | Modal cold starts >10s | Low | Medium (UX) | Monitor; switch to Modal warm-pool config if needed |
| 2 | Convex pricing scales unexpectedly | Low | Medium | Monitor usage; cap free-tier users if needed |
| 3 | Maple AI dependency (shutdown, breaking changes) | Low-medium | High | OpenAI-compatible API means swap to alternative TEE provider possible; pre-identify backup vendor (Phala, AWS Nitro Enclaves with hosted LLM) |
| 4 | OpenHands SDK breaking changes | Medium (active development) | Medium | Pin version; upgrade deliberately; subscribe to releases |
| 5 | Tally Cloudflare Workers limits hit | Low | High | Currently well within Paid tier; monitor request volume |
| 6 | Skytale breaking changes affecting Tally | Low-medium | Medium-High | Pin Tally version that targets known-good Skytale; verify before upgrading substrate |
| 7 | Architecture-decision contradictions surface mid-build | Medium | Medium | Per gaps doc: technical reconciliations applied; resurface if new inconsistencies appear |
| 8 | Security audit findings | Medium | Medium (delays launch) | Schedule vendor by week 10; audit week 16 |

## Stop-and-surface triggers

Patterns from Phase 1B Tally work that apply here. Surface to user before proceeding if:

1. **Week 1 spike fails fundamentally** — OpenHands SDK + Maple Proxy don't integrate cleanly. Rethink stack.
2. **OpenHands SDK has subagent primitive that obsoletes Tally** — discovered in week 2. Decide whether Tally integration is dropped or kept.
3. **Modal cold starts make agent UX painful** — observed during week 4-5. Investigate warm-pool config or alternative runtime.
4. **Architectural assumption surfaces wrong mid-build** — same shape as Tally's `set_alarm` finding. Apply API-contract-comments-are-unverified discipline; verify against current external service docs.
5. **Skytale-via-Tally surface error** — e.g., MLS group state issue on the relay observed under load. Surface; coordinate Tally fix.
6. **Security audit finds material issue** — week 16. Assess impact; may delay launch.

## Forward sequencing (post-v1.0)

Phase 2 / v1.5 candidates:

- **Skytale relay → Cloudflare Durable Objects** — true serverless rewrite of the Skytale relay. Each MLS group becomes a Durable Object; Iroh QUIC transport replaced with Cloudflare-native WebSocket/HTTP; relay state lives in DO storage. Estimated 6-10 weeks of work. Unlocks: fully serverless infrastructure (no long-running servers operated by Pronoic); same Cloudflare ecosystem as Tally Workers; global auto-scaling. Cost trade-off: re-implementing the traffic-analysis-resistance stack (Padme padding, cover traffic, BSL-licensed differentiator) on Cloudflare's edge primitives. **Decision locked 2026-05-16: keep Skytale relay + API as-is through Tally Coding v1.0 launch; begin Path B (Durable Objects rewrite) post-launch.**
- **Skytale API → Cloud Run or Cloudflare Workers** — alongside the relay rewrite. Containerize Axum on Cloud Run + Neon Postgres (1-week migration), or rewrite for `worker-rs` + Hyperdrive Postgres (~3-4 weeks). Lower priority than relay rewrite; do whichever fits the broader ops simplification.
- **Chat polish** — reactions, message editing/deletion, read receipts, file sharing, link previews, full-text search (client-side index)
- **Mobile push notifications** — PWA push first; native iOS / Android apps later
- **Local sandboxing** — `tally-cli serve` daemon runs OpenHands inside a local Docker container (Modal Sandbox equivalent for local)
- **OpenHands Agent Server adapter** — alternative daemon for power users; cloud orchestrator uses `RemoteWorkspace` connection
- **Multi-tenancy / team accounts** — org-level permissions; multiple humans on one team natively
- **Multi-LLM-provider choice** — BYO TEE-attested provider per user
- **Marketplace of agents / custom agent roles** — user-defined agents beyond defaults
- **Real-time voice/audio** — voice intervention in agent conversations
- **Non-GitHub source control** — GitLab, Bitbucket, Gitea integration
- **Public API for third-party integration** — webhooks, programmatic agent dispatch
- **Self-hosted on-premises (enterprise tier)** — Phase 3

## Methodology notes (Phase 1B discipline carry-forward)

Patterns from Tally Phase 1B work that apply to platform build:

- **Verify before drafting** — verify external service claims (Modal, Maple, Convex, Clerk, Skytale, Tally) against current documentation before committing to roadmap weeks
- **Specific signatures are evidence** — when a numerical/structural value matches a constraint to within small tolerance, the specificity is itself diagnostic
- **API-contract comments are unverified** — load-bearing API contract claims in code comments are unverified narrative; verify against actual library source
- **Stop-and-surface on substantive findings** — pre-implementation lock-then-execute; surface deviations explicitly
- **Cycle count as observation not judgment** — multi-iteration counts are "N layers surfaced," not "should be done by N"

These are the disciplines that surfaced the alarm-fire root cause across 8 cycles during Phase 1B; same discipline applies here.

## Provenance

Synthesized 2026-05-15; revised 2026-05-16 to focus on technical content (stack composition, critical path, technical decision points, technical risks). This document should be re-read whenever source artifacts are revised.
