# Tally Coding — Week 1 Complete

Full Tally Coding cloud stack proven end-to-end. All five day-spikes pass.

| Day | Goal | Result | Detail |
|---|---|---|---|
| 1 | OpenHands + Phala Redpill local spike | ✓ PASS | `spike/day1/RESULT.md` |
| 2 | Run Day 1 inside a Phala TEE CVM | ✓ PASS | `spike/day2/RESULT.md` |
| 3 | Tally Workers integration tests (live deployment) | ✓ PASS (4/4) | `tests/RESULT-day3.md` |
| 4 | Two-CVM roundtrip: orchestrator → tally-workers → worker → OpenHands → response | ✓ PASS | `spike/day4/RESULT.md` |
| 5 | Flutter app scaffold (multiplatform, skytale_sdk pinned) | ✓ PASS | `tally_coding_app/RESULT-day5.md` |

## What's proven

```
                 ┌──────────────────────────────┐
                 │     Flutter app (Day 5)       │  ← scaffold ready
                 │  iOS / Android / Linux /      │     skytale_sdk pinned to PR
                 │  macOS / Windows              │     #469 (dart-sdk-skeleton)
                 └─────────────┬────────────────┘
                               │
                               │  (next sprint: Convex + Clerk + agent UI)
                               │
                 ┌─────────────▼────────────────┐
                 │  Tally Workers (Cloudflare)   │  ← wake routing (Day 3, 4)
                 │  tally.nraimbault16.workers   │     8 routes, ULID wake IDs
                 │  .dev                         │     Bearer(ed25519 pubkey) auth
                 └─────────────┬────────────────┘
                               │
            ┌──────────────────┴──────────────────┐
            │                                     │
   ┌────────▼─────────┐                ┌─────────▼────────┐
   │  Orchestrator    │  ──dispatch──> │   Worker          │
   │  Phala TEE CVM   │   <──complete──│   Phala TEE CVM   │
   │  (Day 4)         │                │   OpenHands SDK   │
   │                  │                │   + Phala Redpill │
   │                  │                │   Kimi K2.6 (TEE) │
   └──────────────────┘                └──────────────────┘
                                                 │
                                                 ▼
                                       ┌──────────────────┐
                                       │  Phala Redpill    │
                                       │  api.redpill.ai   │  ← TEE-attested LLM
                                       │  (Day 1, 2, 4)    │     inference
                                       └──────────────────┘
```

All compute paths are TEE-attested. The orchestrator → worker hop carries the
task payload over plain HTTPS today; Skytale MLS encryption of those wakes is
the next sprint's job (requires the merge of skytale Dart SDK PR #469 + parallel
work to wrap `dispatch_wake` / `complete_wake` in MLS).

## Three privacy pillars (all live in this week's stack)

1. **TEE-attested LLM inference** — Phala Redpill, Kimi K2.6 via api.redpill.ai
2. **TEE-attested agent compute** — Phala Cloud TDX CVMs (`tdx.small`, `prod5` node)
3. **Wake-based agent coordination** — Tally Workers on Cloudflare, ed25519
   bearer auth, ULID wake IDs

## Cost spent

~$1.50 total in Phala CVM credits across all Day 2 + Day 4 attempts (multiple
iterations debugging Dockerfile + b64 encoding + timeout cap).

## What's next sprint

- Skytale Dart SDK PR #469 merge → swap git: dep for path: or pub.dev
- Wrap wake payloads in MLS (skytale-sdk) so tally-workers never sees plaintext
- Convex backend for multi-device state sync
- Clerk auth (GitHub OAuth) wired into the Flutter app
- Real agent UI in `tally_coding_app/` — task creation, live status, results
