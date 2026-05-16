# Gaps and Open Questions

**Date:** 2026-05-15 (drafted); 2026-05-16 (revised — technical only, post-research verification)
**Purpose:** Technical inconsistencies, under-specified decisions, missing pieces, and critical-path gaps across the source artifacts.

Technical meta-analysis; not strategic content. Many gaps from the original synthesis have been resolved via two rounds of source-level research across Skytale, Tally, and OpenHands SDK. Remaining gaps are surfaced below.

## A. Inconsistencies — resolved

All A-class inconsistencies from the original synthesis have been resolved in the source documents. Remaining item:

### A.1 — Phala Redpill API hosting topology

- **Architecture**: "Configuration deferred to first-week implementation: hosted endpoint vs self-hosted sidecar (trial both)"
- **Week 1 scope** (day 2): Recommends hosted endpoint via `https://api.redpill.ai`

Week-1 recommendation is a starting trial decision; operator can switch. Confirm during week 1 day 2.

## B. Under-specified decisions

Decisions surfaced during research that need answering before specific weeks.

### B.1 — Workspace mode (week 1-2)

**Resolved direction (2026-05-16):** Cloud agents use Phala CVM direct (`workspace=os.getcwd()` inside the Phala CVM). Event streaming via OpenHands `callbacks=[fn]` → Convex. The desktop Flutter app's opt-in local execution mode also uses `workspace=os.getcwd()` but with cwd = user's local working directory.

OpenHands Agent Server's `RemoteWorkspace` primitive is a Phase 2 / v1.5 power-user option for users who want to drive their daemon from external tools (e.g., a separate CLI talking to a long-running Agent Server on their desktop).

### B.2 — Board internal deliberation format (week 5)

What does board internal deliberation look like (format, structure, frequency)? Likely emerges from week-5 experimentation. The `OrchestrationAgent`'s message types (`decision_request`, `decision_record`) provide the protocol; the UX is what's open.

### B.3 — Communicator surface (week 5)

What does the communicator surface (final consensus only, or mid-deliberation visibility)? Affects UX of "go" flow. Probably implement final-consensus-only first; gather signal on whether mid-deliberation visibility adds value.

### B.4 — Layer autonomy boundary (week 7-8)

What can each layer decide unilaterally? Escalation table addresses part of this; "unilateral decision authority" goes beyond escalation thresholds — affects sandboxing decisions, permission model, audit log scope.

### B.5 — Orchestrator decomposition strategy (week 6)

How does the orchestrator decompose work? Likely "board-shaped plan from week 5; orchestrator decomposes into Tally wake dispatches" — but stated implicitly. Lock in week 6.

### B.6 — Multi-channel topology (week 5 v0.1; v1.0 transition)

v0.1: single per-user channel `{user_id}/main` for all agent coordination.

v1.0: split into per-purpose channels:
- `{user_id}/board/deliberation`
- `{user_id}/board/user`
- `{user_id}/projects/{project_id}/main`
- (etc.)

When and how this split happens: decide during week 5; transition during weeks 11-12.

### B.7 — Role pack location (week 5-6)

Where do the YAML role packs for board/worker behavior live?
- Repository (versioned with platform code)?
- Per-user customization layer?
- Default-with-override pattern?

Affects user customization model.

### B.8 — Flutter app distribution + auto-update (weeks 21-22)

Distribution paths:
- **macOS**: Apple App Store + Mac App Store + direct .dmg download (notarized) + Homebrew Cask
- **iOS**: Apple App Store
- **Linux**: deb (Debian/Ubuntu) + rpm (Fedora) + Flatpak + AppImage + Snap
- **Windows**: MSI direct + Microsoft Store
- **Android**: Google Play Store + APK direct download

Code signing:
- Apple Developer Program ($99/year) — required for macOS/iOS distribution and notarization
- Microsoft code signing cert ($200-500/year via DigiCert / Sectigo) — for Windows MSI
- Google Play (no separate cert; uses your Google Play account)

Auto-update: app stores handle their channels. For direct downloads (.dmg, MSI, .deb, etc.), use Sparkle (macOS), squirrel (Windows), or in-app notify-on-new-version + manual download.

### B.9 — Local execution trust model in desktop Flutter app (week 8)

The Flutter desktop app embeds a Python OpenHands subprocess when local execution is enabled. Trust discipline:
- First-time tool grants (user approves which OpenHands tools can run; e.g., `bash` execution, Git operations, package install)
- Pre-execution prompts for sensitive commands (`rm -rf`, `sudo`, network mods) — configurable
- Audit log: local SQLite + Skytale channel event (cryptographically signed by agent identity)
- Sandboxing via local Docker: v1.5+ polish (v1.0 ships with user-approved tool grants + per-execution prompts)

### B.10 — Chat search architecture (v1.5+)

Full-text search on E2E-encrypted messages is genuinely hard:
- Server can't index ciphertext
- Client-side index in app local storage (SQLite via sqflite for Flutter) requires downloading + decrypting all history
- Searchable-encryption schemes exist but are complex

v1.0 ships without search; decide v1.5 implementation approach.

### B.11 — Convex from Flutter (Dart) integration (week 5)

Convex is TypeScript-first; Dart support is less mature. Options:
- Build a Convex Dart client via WebSocket + REST wrapper (~1-2 weeks)
- Use a community-built Dart Convex client (verify quality first)
- Switch to Supabase (first-party Dart SDK; similar reactive primitives via PostgreSQL realtime)
- Switch to a custom backend (more control; more work)

**Decide week 5.** Default to building a Convex Dart wrapper unless it's painful.

### B.12 — Skytale Dart SDK strategy (week 2)

Build by operator as part of v0.1. Two strategies:
- **Option A**: `dart:ffi` to Rust skytale-sdk. Best performance; reuses existing Rust MLS impl. ~3-4 weeks.
- **Option B**: Dart wrapper around Skytale REST + gRPC. ~2-3 weeks; less feature-complete but works.

**Decide week 1.** Option A preferred long-term; Option B faster to ship for v0.1 if needed.

### B.13 — Clerk Flutter SDK maturity (week 4)

Clerk has a Flutter SDK but it's less mature than React. Possible workarounds if it doesn't work cleanly:
- Use OAuth flow: open browser briefly for Clerk auth; return to Flutter app with token via deep link
- Use Clerk's API directly from Dart with a thin wrapper

**Verify week 4.**

## C. Technical missing pieces

### C.1 — Convex / Clerk JWT integration verification (week 3)

Documents say "Convex integrates via JWT verification". Worth verifying against current Clerk + Convex docs before week 3 — API surfaces drift.

### C.2 — Failure mode contingencies (Phase 2)

Risk register mentions Phala Cloud (Redpill) dependency, Phala CVM cold starts, etc., but no concrete contingency plans:
- Phala Cloud (Redpill) shutdown — which TEE alternative? Migration time?
- Phala Cloud price spike — where do agents run?
- Cloudflare deprecates DOs — where does Tally migrate?

Overkill for v0.1; note for v1.0 readiness.

### C.3 — Skytale SDK semi-public API (week 2)

`OrchestrationAgent` lives in `skytale_sdk.integrations._orchestration` — underscore-prefixed module. The Skytale team treats this as semi-public. Platform should:
- Pin a specific Skytale SDK release
- Monitor Skytale changelogs for breaking changes to `_orchestration.py`
- Avoid reaching into `_orchestration_context.py` / `_orchestration_store.py` internals unless absolutely necessary

### C.4 — Master key custodianship (v0.1 → v1.0)

For encryption-at-rest of agent private keys in Convex:
- v0.1: Phala Cloud secret (acceptable for single-user demo)
- v1.0: dedicated KMS (AWS KMS, GCP KMS, HashiCorp Vault)

Decide migration timing during weeks 11-12 hardening.

### C.5 — Skytale-account partitioning model (Phase 2)

**Resolved direction (2026-05-16):** The platform operates a single Skytale account (operator-owned) and partitions users via `team_id`, channel namespaces, and per-user agent identities. Customers never sign up for Skytale.

Open implementation question for Phase 2 (when user count scales): if many users on one Skytale account creates cost-attribution / abuse-isolation / quota-fairness issues, how do we partition? Options: multiple platform Skytale accounts sharded by user; per-tenant sub-accounts; channel-namespace quota tracking. Defer until demand surfaces.

## D. Critical-path / external-dependency gaps

### D.1 — Account setup pre-staging (pre-week-1)

Pre-stage all v0.1 + v1.0 accounts in one ~30-min session before week 1:
- Phala Cloud (Redpill) Pro plan
- Phala Cloud (CVM + Redpill)
- Convex
- Clerk
- Vercel
- Stripe (longer business verification lead time)
- Sentry / observability vendor
- Custom domain for production

### D.2 — Tally production deployment shape (week 19)

Tally is at `https://tally.nraimbault16.workers.dev` (personal Cloudflare). For platform commercial use:
- Same deployment? Different Cloudflare account?
- Custom domain (e.g., `tally.pronoic.app`)?
- Tier capacity (Worker requests, DO storage)?

Decide before commercial launch.

### D.3 — OpenHands SDK version pinning (pre-week-1)

Pin specific OpenHands SDK version. Upgrade deliberately; never on auto-update.

### D.4 — Phala CVM long-running function support (week 1 day 2)

Verify 24h function-runtime claim against current Phala Cloud docs. What happens at the limit (auto-restart? lose state?). The platform's persistence-via-Phala-CVM-storage pattern means state survives function restarts; need to confirm.

### D.5 — Phala Cloud (Redpill) plan billing structure (week 13)

**Resolved direction (2026-05-16):** Platform pays Phala wholesale (one platform Phala Redpill subscription / enterprise plan); customers pay Tally retail. Customers never have a Phala Redpill subscription. Same pattern as Skytale per Scenario B.

Open question: at what scale does the platform need to move from Pro plan ($20/mo) to a Phala enterprise plan? Plus the cost-attribution piece — how does the platform internally track per-user LLM spend to inform pricing? Both decide by week 13 (billing) or earlier if costs scale.

## Resolved during research (no longer open)

The following items from the original synthesis were resolved by source-level research:

- **A.1 (multi-tenancy contradiction)** — resolved in milestones doc (renamed to "User isolation + production hardening"; vision's single-user-account framing is canonical)
- **A.2 (pricing range)** — strategic content removed; pricing is TBD outside technical docs
- **A.3 (Sub-PR 4 status framing)** — milestones doc aligned to vision's "deferred indefinitely"
- **A.5 (schema sketch drift)** — `executions` added to week 3 schema
- **B.5 in original (OpenHands subagent vs Tally)** — OpenHands has no built-in subagent primitive; Tally is the right abstraction. Verified via context7 docs query.
- **C.8 in original (Convex/Clerk JWT)** — moved to C.1 here; still pending week-3 verification
- **C.9 in original (Tally MCP plugin redundancy)** — Sub-PR 2 deferred per vision; the platform builds its own OpenHands integration, not relying on the MCP plugin
- **C.10 in original (architecture diagram fidelity)** — fixed in architecture doc

## Pre-week-1 cleanup (~2 hours)

Items to resolve before week 1 day 1 begins:

1. Pre-stage accounts (D.1) — Convex, Clerk, Vercel, Stripe (long lead time), Sentry, custom domain
2. Pin OpenHands SDK version (D.3) — lock to specific release
3. Pin Skytale SDK version (C.3) — lock to specific release
4. Verify Phala CVM runtime limits (D.4)
5. Decide Phala Redpill API topology (A.1)

## Summary table: gaps by week

| Gap | Type | Decide before | Affects |
|---|---|---|---|
| Phala Redpill API topology (A.1) | Inconsistency | Week 1 day 2 | LLM integration |
| Workspace mode (B.1) | Under-specified | Week 1-2 | Agent hosting topology |
| Board deliberation format (B.2) | Under-specified | Week 5 | UX of "go" flow |
| Communicator surface (B.3) | Under-specified | Week 5 | UX |
| Layer autonomy (B.4) | Under-specified | Week 7-8 | Permission model |
| Decomposition strategy (B.5) | Under-specified | Week 6 | Orchestrator-worker dispatch |
| Multi-channel topology (B.6) | Under-specified | Week 5 / weeks 11-12 | Channel model |
| Role pack location (B.7) | Under-specified | Week 5-6 | Customization model |
| Daemon distribution + auto-update (B.8) | Under-specified | Weeks 13-14 | tally-cli install + upgrade UX |
| Daemon trust model (B.9) | Under-specified | Week 14 | Local execution safety |
| Chat search architecture (B.10) | Under-specified | v1.5+ | Search UX |
| Convex/Clerk JWT verification (C.1) | Missing | Week 3 | Auth implementation |
| Failure contingencies (C.2) | Missing | Phase 2 | v1.0 readiness |
| Skytale semi-public API (C.3) | Missing | Week 2 | Version pinning policy |
| Master key custodianship (C.4) | Missing | Weeks 11-12 | v1.0 hardening |
| Skytale-account partitioning (C.5) | Phase 2 | Defer until demand surfaces | Cost attribution + quota fairness |
| Account setup pre-staging (D.1) | Critical-path | Week 1 day 1 | Per-week blockers |
| Tally production deployment (D.2) | Critical-path | Week 19 | Commercial launch |
| OpenHands SDK version pin (D.3) | Critical-path | Week 1 day 1 | API stability |
| Phala CVM runtime limits (D.4) | Critical-path | Week 1 day 2 | Long-running agents |
| Phala Redpill plan billing structure (D.5) | Critical-path | Week 13 | Pricing model |

## Provenance

Drafted 2026-05-15 (Claude Code synthesis pass over the 5 source artifacts). Revised 2026-05-16 after two rounds of source-level research across the Skytale repo, Tally repo, and OpenHands SDK docs (via context7). Updated 2026-05-16 to add B.8-B.10 (daemon distribution, trust model, chat search) after the multi-runtime + human-collaboration architecture was locked. Re-read whenever source artifacts are revised.
