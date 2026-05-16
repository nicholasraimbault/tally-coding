# Tally Coding — First-Week Scope

**Date:** 2026-05-15 (drafted); 2026-05-16 (revised for native-only architecture)

## Goal

By end of week 1: A cloud-hosted OpenHands agent running in Phala Cloud that uses Phala TEE inference to complete a real coding task on a test GitHub repo. Foundation for everything else.

## Day-by-day

### Day 1 (Monday): Account pre-staging + OpenHands SDK + Phala Redpill API local spike

Tasks:
- Sign up for Phala Cloud (Redpill) Pro plan ($20/mo); get API key
- Sign up for Phala Cloud; get API key
- Pre-stage other accounts: Convex, Clerk, Cloudflare (for Tally Workers domain), Stripe (longer verification lead time so start early)
- Buy `tally.codes` (~$30/year at Cloudflare Registrar)
- Initialize Python project; pip install openhands-ai (pin version); skytale-sdk (pin version)
- Install Docker locally; use Phala Redpill hosted API directly (no local proxy needed)
- Write `spike.py` — single OpenHands coding agent:
  - Configure LLM with Phala Redpill API endpoint; verify TEE attestation
  - Create Agent with `TerminalTool`, `FileEditorTool`, `TaskTrackerTool`
  - Conversation with cwd workspace pointing at a small test repo (clone `octocat/Hello-World` or similar)
  - Send a real task: "Add a Python script `greet.py` that prints 'hello, $NAME' for an env var NAME; add a pytest test in `test_greet.py`; run the test and verify it passes"
  - Run
- Verify: greet.py + test_greet.py created, pytest passed, Phala Redpill attestation visible in response headers

Output: Local OpenHands agent works end-to-end with Phala TEE inference.

### Day 2 (Tuesday): Deploy spike to Phala Cloud cloud

Tasks:
- Read Phala Cloud docs; verify the 24h function-runtime claim against current docs
- Wrap spike.py inside `@app.function(...)` with appropriate Phala CVM image (Git, build tools, Python, Node)
- Phala Cloud (CVM + Redpill) Secret: store Phala Redpill API key
- Configure agent to use Phala Redpill hosted endpoint (`https://api.redpill.ai/v1`)
- `phala cvm deploy --compose docker-compose.yml`; invoke via the CVM's HTTP endpoint (precise CLI/API in Phala Cloud docs; verify during week 1)
- Verify cloud execution; verify cost (target: <$0.05 per run)
- Run a more substantial coding task: "Refactor this small Python project to use type hints throughout; verify tests still pass; report changes"

Output: Cloud agent in Phala Cloud runs real coding tasks end-to-end.

### Day 3 (Wednesday): Skytale identity + Tally Workers HTTP from Python

Tasks:
- `pip install skytale-sdk`; verify `AgentIdentity.generate()` works
- Derive Tally Workers Bearer = `url_safe_b64(agent.public_key)`
- Pick a Tally Workers `team_id`; `POST /v1/teams/{team_id}/init` (using your existing Tally Workers deployment)
- Register handler: `POST /v1/teams/{team_id}/agents/{bearer}/register` with `{"context_id": "task:start"}`
- Cloud Phala CVM: load AgentIdentity from secret; poll Tally Workers inbox for wakes
- Local Python test script: dispatch wake to Phala Cloud agent via Tally Workers (`POST /v1/teams/{team_id}/wakes`)
- Phala Cloud (CVM + Redpill) agent receives wake; processes (run a coding task); responds via `/complete`
- Local script's awaiting dispatch returns with the response

Output: Tally Workers request-response dispatch works Phala Cloud↔local Python.

### Day 4 (Thursday): Skytale channels + two agents talking

Tasks:
- Generate two AgentIdentities: `alice` (orchestrator) and `bob` (worker)
- Both deploy as Phala CVMs
- Create Skytale channel `test-team/main` via SkytaleChannelManager (using your platform's Skytale account API key)
- Both subscribe to the channel
- Bob is dispatched a task by Alice (via Tally Workers wake); responds via Skytale channel with `StatusData` updates
- Verify end-to-end: agents coordinate via Skytale-encrypted channel + Tally wakes

Output: Multi-agent coordination across Phala Cloud validated end-to-end.

### Day 5 (Friday): Flutter scaffold + Dart SDK skeleton

Tasks:
- Install Flutter SDK (use FVM for version management)
- Initialize a new Flutter project: `flutter create tally_coding_app`
- Configure macOS desktop target; verify it builds and runs as a native macOS app
- Start the Skytale Dart SDK skeleton:
  - Create a separate Cargo workspace in skytale repo for Dart bindings (`sdk/dart/`)
  - Decide binding strategy: `dart:ffi` to Rust skytale-sdk OR Dart wrapper around Skytale REST/gRPC
  - Implement minimal `AgentIdentity.generate()` in Dart; verify it produces the same `did:key` format as Python
- Stub out a Flutter UI screen showing "Hello, Tally Coding" with a button "Generate test identity" that creates an AgentIdentity and prints the DID

Output: Flutter app builds + runs on macOS; basic Skytale Dart binding scaffold exists.

### Weekend (Sat/Sun): Decompression

Tasks:
- Brief reflection: what worked, what didn't, what surprised
- Update architecture doc with any changed decisions
- Plan week 2 based on actual velocity
- Step away from project ≥24h

## Week 1 success criteria

- [ ] Phala Redpill API + OpenHands SDK working locally (Day 1)
- [ ] Spike running on Phala Cloud end-to-end with real coding task (Day 2)
- [ ] Tally Workers dispatch works Phala Cloud↔local Python (Day 3)
- [ ] Skytale channels working between two Phala CVM agents (Day 4)
- [ ] Flutter macOS app builds + runs; Dart SDK skeleton in place (Day 5)

If any incomplete by Friday: signal explicitly. Don't push into weekend. Investigate why.

## What's NOT in week 1

- Flutter UI for chat / dashboard (week 4-6)
- Convex integration from Flutter (week 5)
- Mobile builds (iOS / Android) (week 13-14)
- Multi-agent board logic (week 6)
- Worker sandboxing for multi-language repos (week 7)
- Anything resembling polish
- Any commercialization work

## Stop-and-surface triggers

1. OpenHands SDK + Phala Redpill API integration friction (fundamental validation issue)
2. Phala CVM cold starts >30s or function runtime limits unexpectedly tight (changes infra strategy)
3. Tally Workers API gaps for this use case (fix Tally Workers rather than work around)
4. Skytale Dart binding approach is harder than expected (FFI vs REST decision needs re-evaluation)
5. Flutter macOS build issues (rare but possible; may force different desktop framework)

## Provenance

Drafted 2026-05-15. Revised 2026-05-16 to reflect native-only Flutter + cloud-primary architecture.
