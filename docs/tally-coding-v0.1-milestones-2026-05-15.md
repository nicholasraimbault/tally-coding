# Tally Coding — v0.1 → v1.0 Milestone Breakdown

**Date:** 2026-05-15 (drafted); 2026-05-16 (revised for native-only + cloud-primary architecture)
**Prerequisite:** tally-coding-architecture-2026-05-15.md, tally-coding-human-collaboration-2026-05-16.md

## Scope reminder

**v0.1** = internal demo (single user = Nick). Native desktop app on macOS that talks to cloud agents + does opt-in local execution. ~3 months estimate.

**v1.0** = commercial launch. Flutter app on all 5 platforms (macOS, Linux, Windows, iOS, Android), full chat, humans-as-team-members, push notifications, app store distribution. ~6 months from start.

## Timeline assumptions

- Solo founder
- Realistic dev time: 15-25 hours/week
- Cloud agents in Modal handle the always-on execution; native app handles UX
- Skytale Dart SDK is built by operator (you) as part of v0.1 since Skytale is operator-owned

## v0.1 weeks (~12 weeks)

### Week 1: Foundation + OpenHands/Maple spike (cloud-side)
- Pre-stage all accounts: Maple AI Pro, Modal, Convex, Clerk, Cloudflare, GitHub App, custom domain
- Pin OpenHands SDK + Skytale SDK + Flutter SDK versions
- "Hello agent" spike: OpenHands SDK locally; LLM via Maple Proxy; deploy single agent to Modal
- Generate first `AgentIdentity` via Skytale Python SDK to validate `did:key` shape
- Deploy a simple cloud agent that runs a real coding task in Modal Sandbox (clones small repo, edits a file, runs pytest, commits)

Output: Cloud agent runs a real coding task in Modal using Maple TEE inference.

### Week 2: Skytale Dart SDK foundation
- Choose binding strategy: `dart:ffi` to Rust skytale-sdk, OR Dart wrapper around Skytale REST + gRPC
- Implement core types in Dart: `AgentIdentity`, `Identity`, `TeamId`, `Envelope`
- Implement `SkytaleClient` Dart class: connect to relay, create/join channels, send/receive messages
- Cross-platform tests: identity generation matches across Python and Dart

Output: Skytale Dart SDK alpha — can generate identities, encrypt/decrypt messages, send via relay.

### Week 3: Tally Workers Dart client + Cloud agent + Dart agent round-trip
- Implement Tally Workers HTTP client in Dart (8 routes; URL-safe-base64 helpers; ULID parsing)
- Cloud-side: agent in Modal dispatches a wake to a target identity
- Dart-side (in a test harness, not yet Flutter UI): receive the wake via Tally Workers inbox poll; decrypt with Skytale Dart SDK; respond via Tally complete
- Verify end-to-end: cloud agent ↔ Dart client roundtrip works

Output: Dart client can fully participate as a Tally Workers agent.

### Week 4: Flutter app scaffold + auth
- Initialize Flutter project; targets macOS first, others later
- Integrate Clerk Flutter SDK; OAuth flow (browser opens; returns to app)
- On first sign-in, generate `AgentIdentity` for the user in-app (Dart); store private key in macOS Keychain / Linux Secret Service / Windows Credential Manager
- Basic shell UI: signed-in landing page; "your team" placeholder

Output: User can sign up via Clerk; app generates an AgentIdentity; private key stored in OS keychain.

### Week 5: Convex from Flutter + team provisioning
- Convex Dart client (REST + WebSocket subscription wrapper; or use Supabase Dart SDK as alternative)
- Convex schema: `users`, `agents`, `conversations`, `messages`, `events`, `executions`
- On signup, Convex action `bootstrap_user_team`: provisions the user's agent identities (7 board + worker), Tally Workers `team_id` + handler registrations, default Skytale channels
- Flutter app subscribes to `users.{me}.agents`; renders the team roster

Output: Flutter shows the user's 7 cloud agents in a roster after signup.

### Week 6: Skytale channel UI + AI agent dispatch
- Flutter UI: chat surface for the user's main channel (`{user_id}/main`)
- Subscribe to Skytale channel via Dart SDK; render messages
- "Send message" button dispatches user input as a chat message; cloud orchestrator receives it
- Cloud orchestrator (Modal function): subscribes to the channel; on user input, dispatches board agents to deliberate
- Board agents post status/decision_request messages back; Flutter UI shows them in real-time

Output: User can describe a task in Flutter; sees board deliberating in real time.

### Week 7: Workers in Modal Sandbox + GitHub integration
- Cloud orchestrator dispatches a wake to a cloud worker (Modal function)
- Worker spins up a Modal Sandbox container with Git, Node, Python, build tools
- Worker authenticates to user's GitHub via stored OAuth token
- Worker clones the user's selected repo, uses `FileEditorTool`/`TerminalTool` to make changes, runs tests, commits, opens PR via `gh pr create`
- Worker posts `StatusData` + `PrUpdateData` messages back to the channel

Output: Full end-to-end coding loop: user → board → orchestrator → cloud worker → PR opened.

### Week 8: Local execution in Flutter desktop app (opt-in)
- Flutter desktop app: settings panel with "Enable local execution on this machine" toggle
- When enabled: spawn Python subprocess running OpenHands + Tally Workers inbox poller
- Subprocess registers as agent `worker:nick-macbook` in the user's team
- Orchestrator can target this agent for tasks (per-task choice in UI)
- Worker executes against the user's local cwd; results stream back via Skytale channel

Output: Desktop app can be both UI and local agent. User picks per-task: cloud or local.

### Week 9: Conversation persistence + multi-device sync
- OpenHands `persistence_dir` for cloud workers on Modal volumes
- Convex syncs conversation events across user's devices
- User can close laptop; agents continue in cloud; user opens phone (Flutter mobile) and sees current state
- Tested: dispatch task on laptop, monitor on phone, approve from phone, see PR open from anywhere

Output: True multi-device experience: agents persist; UI catches up on any device.

### Week 10: Robustness + escalation hierarchy
- Workers ↔ orchestrator escalation via Tally wakes (block/unblock messages)
- Orchestrator ↔ board escalation
- Board ↔ user escalation (decision_request surfaces as UI banner on user's devices)
- Error handling: agent failures, Modal failures, LLM errors, test failures
- Per-language test coverage spike: Python pytest, Node.js npm test, Rust cargo test

Output: Reliable enough for real coding work; full escalation hierarchy works.

### Week 11: Cross-platform Flutter (Linux + Windows builds)
- Verify Flutter app builds and runs on Linux + Windows
- Cross-platform keychain abstraction
- Local execution subprocess management on each platform
- App store / package manager prep: deb, rpm, msi packages

Output: Flutter desktop app works on macOS, Linux, Windows.

### Week 12: Dogfooding + v0.1 ready
- Use Tally Coding for real Tally Coding development
- Identify pain points; iterate
- Fix critical bugs from actual usage
- Internal demo prep

Output: v0.1 complete; Nick uses it daily.

## v0.1 → v1.0 (~12 additional weeks)

### Week 13-14: Flutter mobile (iOS + Android) MVP
- Get the Flutter app running on iOS + Android (most code should work; mobile-specific UI tweaks)
- Mobile UX: chat-first interface; agents view; decision-approval banners
- No local execution on mobile (cloud-only)
- iOS Keychain + Android Keystore for AgentIdentity storage

Output: Mobile app shows the same team view as desktop; cloud agents respond to mobile-issued tasks.

### Week 15: User isolation + production hardening
- Multi-user Convex schema (one team per user; isolation rules)
- Encryption-at-rest for agent private keys (server-side; Fernet/libsodium)
- Master key in dedicated KMS (or Modal env for v0.1; KMS migration v1.0)
- Quota tracking per user against platform's Skytale account

### Week 16: Humans as team members + DM channels
- Invite flow: user generates Skytale invite token; sends to teammate; teammate signs up; joins the team
- Roster shows AI agents + humans
- 1:1 DM channels between any two team members (Skytale 2-member group)
- Group channels (custom-named, 3+ members)

### Week 17: Chat polish
- @mentions (autocomplete + parsing)
- Threading via `reply_to`
- Markdown rendering (code blocks with syntax highlighting)
- In-app notification banners + sound

### Week 18: Push notifications
- iOS APNs integration (content-free)
- Android FCM integration (content-free)
- Desktop native OS notifications via Flutter (macOS Notification Center, Linux notify-osd, Windows Toast)
- Server-side push trigger: when wake is dispatched at a user; when a chat message mentions them
- Privacy property: notifications never reveal message content

### Week 19: Billing + onboarding + security audit
- Stripe via Convex; subscription tier infrastructure (pricing TBD; usage tracking; trial period)
- Onboarding flow: signup → install app → connect GitHub → first-task walkthrough
- Pen test / external review of crypto stack
- GDPR compliance check

### Week 20: Documentation + marketing
- User docs (in-app + at `docs.tally.codes`)
- Marketing pages (landing, pricing, features)
- Demo video / screenshots
- Skytale Dart SDK upstreamed as a contribution to skytale-sh

### Week 21-22: App store distribution
- Apple App Store + Mac App Store submissions (code signing, notarization, review)
- Google Play Store submission
- Linux: deb / rpm / Flatpak / AppImage builds
- Windows: MSI installer + Microsoft Store
- Auto-update mechanism (separate from app stores; for users who install via direct download)

### Week 23: Beta testing
- 5-10 beta users from network
- Each installs the app on their devices; invites at least one teammate; uses end-to-end
- Feedback gathering; iteration

### Week 24: Launch prep + launch
- Pricing finalized; payment processing live
- Landing page polish
- Launch channels (TBD)
- Support (Discord + email)
- v1.0 LIVE

## Timeline ranges

Realistic ranges (vs optimistic estimates above):
- v0.1: 12-16 weeks
- v0.1 → v1.0: 12-16 additional weeks
- Total: 6-8 months for v1.0

Slowdown factors:
- Third-party service issues (Modal, Convex, Maple, Cloudflare outages)
- Architectural assumptions that don't hold
- Chat UI polish takes longer than expected
- App store review cycles (Apple typically 1-3 days; can be longer for first submissions)
- Skytale Dart SDK edge cases (especially MLS group state)
- Flutter cross-platform gotchas (Windows-specific issues, Linux distros)

## Phase 1B Tally implications

Sub-PR 2 (MCP plugin) and Sub-PR 4 (docs + dogfooding) deferred indefinitely. Tally Workers is consumed by Tally Coding as substrate without modification.

## Provenance

Drafted 2026-05-15. Revised 2026-05-16 for native-only + cloud-primary architecture. Estimates based on solo-founder velocity from existing Pronoic project work.
