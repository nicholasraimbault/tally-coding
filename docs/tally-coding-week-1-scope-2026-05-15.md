# Tally Coding — First-Week Scope

**Date:** 2026-05-15 (drafted); 2026-05-16 (revised for native-only architecture)

## Goal

By end of week 1: A cloud-hosted OpenHands agent running in Modal that uses Maple TEE inference to complete a real coding task on a test GitHub repo. Foundation for everything else.

## Day-by-day

### Day 1 (Monday): Account pre-staging + OpenHands SDK + Maple Proxy local spike

Tasks:
- Sign up for Maple AI Pro plan ($20/mo); get API key
- Sign up for Modal; get API key
- Pre-stage other accounts: Convex, Clerk, Cloudflare (for Tally Workers domain), Stripe (longer verification lead time so start early)
- Buy `tally.codes` (~$30/year at Cloudflare Registrar)
- Initialize Python project; pip install openhands-ai (pin version); skytale-sdk (pin version)
- Install Docker locally; run Maple Proxy via Docker if testing local Maple
- Write `spike.py` — single OpenHands coding agent:
  - Configure LLM with Maple Proxy endpoint; verify TEE attestation
  - Create Agent with `TerminalTool`, `FileEditorTool`, `TaskTrackerTool`
  - Conversation with cwd workspace pointing at a small test repo (clone `octocat/Hello-World` or similar)
  - Send a real task: "Add a Python script `greet.py` that prints 'hello, $NAME' for an env var NAME; add a pytest test in `test_greet.py`; run the test and verify it passes"
  - Run
- Verify: greet.py + test_greet.py created, pytest passed, Maple logs show TEE routing

Output: Local OpenHands agent works end-to-end with Maple TEE.

### Day 2 (Tuesday): Deploy spike to Modal cloud

Tasks:
- Read Modal docs; verify the 24h function-runtime claim against current docs
- Wrap spike.py inside `@app.function(...)` with appropriate Modal Sandbox image (Git, build tools, Python, Node)
- Modal Secret: store Maple API key
- Configure agent to use Maple's hosted endpoint (`https://enclave.trymaple.ai/v1`)
- `modal deploy spike.py`; `modal run spike.py::run_agent`
- Verify cloud execution; verify cost (target: <$0.05 per run)
- Run a more substantial coding task: "Refactor this small Python project to use type hints throughout; verify tests still pass; report changes"

Output: Cloud agent in Modal runs real coding tasks end-to-end.

### Day 3 (Wednesday): Skytale identity + Tally Workers HTTP from Python

Tasks:
- `pip install skytale-sdk`; verify `AgentIdentity.generate()` works
- Derive Tally Workers Bearer = `url_safe_b64(agent.public_key)`
- Pick a Tally Workers `team_id`; `POST /v1/teams/{team_id}/init` (using your existing Tally Workers deployment)
- Register handler: `POST /v1/teams/{team_id}/agents/{bearer}/register` with `{"context_id": "task:start"}`
- Cloud Modal function: load AgentIdentity from secret; poll Tally Workers inbox for wakes
- Local Python test script: dispatch wake to Modal agent via Tally Workers (`POST /v1/teams/{team_id}/wakes`)
- Modal agent receives wake; processes (run a coding task); responds via `/complete`
- Local script's awaiting dispatch returns with the response

Output: Tally Workers request-response dispatch works Modal↔local Python.

### Day 4 (Thursday): Skytale channels + two agents talking

Tasks:
- Generate two AgentIdentities: `alice` (orchestrator) and `bob` (worker)
- Both deploy as Modal functions
- Create Skytale channel `test-team/main` via SkytaleChannelManager (using your platform's Skytale account API key)
- Both subscribe to the channel
- Bob is dispatched a task by Alice (via Tally Workers wake); responds via Skytale channel with `StatusData` updates
- Verify end-to-end: agents coordinate via Skytale-encrypted channel + Tally wakes

Output: Multi-agent coordination across Modal validated end-to-end.

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

- [ ] Maple Proxy + OpenHands SDK working locally (Day 1)
- [ ] Spike running on Modal end-to-end with real coding task (Day 2)
- [ ] Tally Workers dispatch works Modal↔local Python (Day 3)
- [ ] Skytale channels working between two Modal agents (Day 4)
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

1. OpenHands SDK + Maple Proxy integration friction (fundamental validation issue)
2. Modal cold starts >30s or function runtime limits unexpectedly tight (changes infra strategy)
3. Tally Workers API gaps for this use case (fix Tally Workers rather than work around)
4. Skytale Dart binding approach is harder than expected (FFI vs REST decision needs re-evaluation)
5. Flutter macOS build issues (rare but possible; may force different desktop framework)

## Provenance

Drafted 2026-05-15. Revised 2026-05-16 to reflect native-only Flutter + cloud-primary architecture.
