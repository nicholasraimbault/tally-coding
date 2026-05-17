# Day 4 — Multi-agent CVM roundtrip (worker + orchestrator)

**Status: PASS** — full Tally Coding stack proven end-to-end.

## What was validated

Two independent Phala TEE CVMs coordinated through Tally Workers to complete a
coding task. No shared filesystem, no shared process — only the wake-routing
HTTP API between them. The agent ran inside the worker's TEE, the orchestrator
inside its own TEE, both authenticated with separate ed25519 identities.

## Topology

```
   ┌──────────────────────────┐                  ┌──────────────────────────┐
   │ Orchestrator CVM          │                  │ Worker CVM                │
   │ (Phala TEE / tdx.small)   │ ── dispatch ──>  │ (Phala TEE / tdx.small)   │
   │ identity: <bearer>        │                  │ identity:                 │
   │ orchestrator_spike.py     │                  │  CgXoh8SWeO3uGSLi…U1fc    │
   └──────────────────────────┘                  │ worker_spike.py +         │
              ▲                                   │  OpenHands + Phala Redpill│
              │     wake (HTTPS, Bearer auth)     └──────────────────────────┘
              │                                              │
              │                                              │
   ┌──────────┴──────────────────────────────────────────────┴──────────┐
   │ Tally Workers (Cloudflare Workers + Durable Objects)              │
   │ https://tally.nraimbault16.workers.dev                            │
   └────────────────────────────────────────────────────────────────────┘
```

## Trace

1. Worker CVM boots → loads/creates ed25519 identity in `/workspace/worker.key`
2. Worker calls `POST /v1/teams/{id}/init` + `POST /v1/teams/{id}/handlers`
   (registers itself for context_id `task:start`)
3. Worker long-polls `POST /v1/teams/{id}/inbox` (wait_seconds=30)
4. Orchestrator CVM boots → its own ed25519 identity in `/tmp/orchestrator.key`
5. Orchestrator calls `POST /v1/teams/{id}/wakes` with target_identity = worker's
   bearer, context_id = `task:start`, payload = url-safe-b64 of
   `{"task": "Create greet.py..."}`
6. Tally Workers delivers the wake to the worker's inbox
7. Worker decodes payload, runs `perform_task(task_description, /workspace)` —
   OpenHands agent with Kimi K2.6 via Phala Redpill
8. Agent creates `greet.py` + `test_greet.py`, installs pytest, runs tests
9. Worker calls `POST /v1/teams/{id}/wakes/{wake_id}/complete` with the result
10. Orchestrator's blocking dispatch returns with the response
11. Orchestrator prints success and exits cleanly

## Container output excerpts

**Orchestrator:**
```
[orchestrator] dispatching task to worker=CgXoh8SW...
[orchestrator] wake completed wake_id=01KRST8MYYKR0FJV8ZKDW0C6M0
[orchestrator] worker reported: {
  "success": true,
  "files_created": ["greet.py", "test_greet.py", ".pytest_cache/...", ...]
}
```

**Worker:**
```
[worker] ready; team=tally-day4-1778982633; identity=CgXoh8SWeO3uGSLi1EdICogYp3BgBAOEEtY4uaLU1fc
[worker] inbox empty; continuing to poll...
[worker] received wake_id=01KRST8M
[worker] task: Create greet.py...
(OpenHands agent runs)
test_greet.py::test_greet PASSED
============================== 1 passed in 0.01s ==============================
[worker] completed wake_id=01KRST8M; result={'success': True, ...}
```

## Gotchas surfaced (and the fixes)

| Issue | Fix |
|---|---|
| `phala deploy` rejected `build:` directive — no build context uploaded | Pre-build images, push to GHCR, reference via `image: ghcr.io/...` |
| GHCR packages private by default → Phala can't pull | `LABEL org.opencontainers.image.source=https://github.com/.../tally-coding` in Dockerfiles; first-push auto-inherits public visibility from public repo |
| Non-root `appuser` couldn't create `/data/worker.key` → restart-loop | Set `WORKER_IDENTITY_PATH=/workspace/worker.key` in compose env (writable volume) |
| Worker only printed `bearer[:8]...` — useless to orchestrator | Print full bearer, rebuild as `:v3` |
| Tally Workers `/wakes` returns 422 on standard b64 (`=` padding) | Encode as **url-safe base64 without padding** (`urlsafe_b64encode().rstrip('=')`); decode by padding back to `% 4 == 0` |
| Tally Workers `/wakes` returns 400 "timeout must be > 0" for any `timeout_seconds > 300` | Hard cap is **300s**; orchestrator was sending 1800. The error message is misleading. |

## Images

- `ghcr.io/nicholasraimbault/tally-spike-day4-worker:v3` (public)
- `ghcr.io/nicholasraimbault/tally-spike-day4-orchestrator:v3` (public)

## CVMs used (this run)

| Role | CVM ID | Disposed |
|---|---|---|
| Worker | `747f7e61-b25f-4735-a0ce-a4bd1b5f6b82` | yes |
| Orchestrator | `0459ec98-d698-40e1-be04-8f6857175fdd` | yes |

## Cost

Total Day 4 spike consumption ~$0.05-0.15 (two tdx.small CVMs at $0.058/vCPU-hr,
running ~3 min each across multiple failed/succeeded attempts).

## Next

The cloud-side stack is now proven: TEE LLM (Redpill), TEE agent compute
(Phala CVMs), wake-routing (Tally Workers), and end-to-end multi-agent
coordination. The remaining sprint surface — Skytale MLS encryption of the wake
payloads, Convex state, Clerk auth — fits cleanly on top of this skeleton.
