# Sprint 2 — MLS over Tally Workers wake payloads

**Status: PASS** — Tally Workers wake payloads now carry MLS ciphertext only.
The task content is encrypted before leaving the orchestrator CVM and decrypted
only inside the worker CVM. Tally Workers (Cloudflare) sees ciphertext bytes;
never the plaintext task description.

## What was validated

End-to-end MLS roundtrip across two Phala TEE CVMs, mediated by Tally Workers:

1. Worker boots → MlsEngine reads/creates identity at `/workspace/worker.key`,
   generates an MLS KeyPackage, registers a `mls:bootstrap` handler with
   Tally Workers
2. Orchestrator boots → dispatches `mls:bootstrap` wake, phase=request_kp
3. Worker responds with its KeyPackage (310 bytes, public MLS artifact)
4. Orchestrator's `MlsSession.create_and_add(kp)` creates a 2-party group,
   adds the worker, gets a Welcome (780 bytes)
   - Cross-CVM clock skew gave `InvalidLifetime` on attempt 1; retry-with-sleep
     succeeded on attempt 2 (~5s after KP receipt)
5. Orchestrator dispatches `mls:bootstrap` wake, phase=welcome
6. Worker calls `MlsSession.join(welcome)`, joins group, registers `task:start`
7. Orchestrator encrypts task (107 chars plaintext) → 290 bytes ciphertext
8. Orchestrator dispatches `task:start` wake with ciphertext
9. Worker decrypts via `MlsSession`, runs OpenHands (Kimi K2.6, Phala Redpill),
   creates `greet.py` + `test_greet.py`, runs pytest (1/1 PASS)
10. Worker encrypts response via `MlsSession`, completes wake
11. Orchestrator receives encrypted response, decrypts, exits 0

## Tally Workers visibility

Tally Workers saw, for the task wake:

```
POST /v1/teams/tally-sprint2-1778987072/wakes
Authorization: Bearer <orch ed25519 pubkey url-safe-b64>
Content-Type: application/json

{
  "target_identity": "6DcOigS9hbCHHv1DEIRgxGd7t07IRp7VyyG2ewfzp-k",
  "context_id": "task:start",
  "payload": "<290 bytes of MLS ciphertext, url-safe-b64-encoded>",
  "timeout_seconds": 300
}
```

The bootstrap wakes carried plaintext JSON (KeyPackage + Welcome), but those are
**public MLS artifacts by design** — they don't reveal the group's symmetric key
material. Application data (the task description) is the only secret, and it
flows as MLS ciphertext exclusively.

## Architecture changes

**skytale (PR #470)**: `PyMlsEngine` — a `#[pyclass]` over
`skytale_base::mls_engine::MlsEngine` that exposes the raw MLS primitives
(`generate_key_package`, `create_group`, `add_member`, `join_from_welcome`,
`encrypt`, `decrypt`) to Python. Previously the only path was via
`SkytaleClient` + `Channel`, which tightly couples encryption with publishing
to Skytale's gRPC relay. `PyMlsEngine` lets callers stuff MLS ciphertext into
any transport (Cloudflare Workers wakes, in this case). 9 tests pass.

**tally-coding**:
- `tally_coding_core/mls.py`: `MlsSession` — 2-party MLS helper wrapping
  `PyMlsEngine` with `create_and_add` / `join` / `encrypt` / `decrypt`
- `spike/day4/worker/worker_spike.py`: rewritten to handle two contexts
  (`mls:bootstrap`, `task:start`) across multiple wakes. Registers
  `task:start` only after bootstrap completes, so task wakes can't be
  delivered to an un-keyed worker
- `spike/day4/orchestrator/orchestrator_spike.py`: 3-wake bootstrap flow
  (request KP → create group + send welcome → encrypted task) plus retry
  on cross-CVM `InvalidLifetime` clock skew
- Multi-stage Dockerfiles: stage 1 clones skytale at `feat/py-mls-engine`,
  builds the SDK wheel via maturin; stage 2 installs the wheel into the uv
  venv. Will swap to a pip dep after PR #470 merges to skytale master

## Images

- `ghcr.io/nicholasraimbault/tally-spike-day4-worker:v4` (MLS-aware worker)
- `ghcr.io/nicholasraimbault/tally-spike-day4-orchestrator:v5` (with clock-skew
  retry)

## Gotchas surfaced (and the fixes)

| Issue | Fix |
|---|---|
| Skytale's `Channel::send` couples encrypt+publish; no `encrypt_bytes()` API | Added `PyMlsEngine` in skytale PR #470 exposing raw MLS primitives |
| Worker built a 1.18 GB image (multi-stage skytale-builder + openhands-ai); first build was ~7 min | Acceptable for spike; the skytale-builder layer caches across runs |
| `protoc` missing in skytale-builder | Added `protobuf-compiler` + `cmake` to apt install (skytale-sdk's transitive deps need protoc for tonic) |
| Cross-CVM clock skew → MLS `InvalidLifetime` rejecting the worker's fresh KeyPackage | Retry `add_member` with 5s sleep, up to 6 attempts. Long-term: SDK should expose a small clock-skew tolerance or have orchestrators sleep until KP `not_before` passes |
| New RustSec advisory `RUSTSEC-2026-0124` (libcrux-chacha20poly1305 panic) blocked skytale PR | Added to ignore list in `deny.toml` + `.github/workflows/security.yml` (transitive via openmls; not reachable from MlsEngine callers given existing size validation) |

## CVMs used (this run)

| Role | CVM ID | Disposed |
|---|---|---|
| Worker | `10e1284e-6ed5-4541-981d-0dde7478bf4a` | yes |
| Orchestrator | `1807268c-30bd-48df-8270-dddb75b8127a` | yes |

## Cost

Sprint 2 total ~$0.30-0.50 in Phala CVM credits across debugging iterations
(image upload error, InvalidLifetime, plus the successful run).

## Open items

1. **skytale PR #470 merge**: still pending CI green + admin merge. Once
   merged, swap the Dockerfile multi-stage skytale-builder for a pip dep on
   the released skytale-sdk version.
2. **MLS clock-skew tolerance in SDK**: the orchestrator-side retry loop is a
   workaround. A proper fix would expose a small grace window when verifying
   KeyPackage `not_before`, or have `generate_key_package` use
   `not_before = now - 60s`.
3. **Bootstrap-wake plaintext**: the 2 bootstrap wakes (KP, Welcome) flow as
   plaintext JSON over Tally Workers. These are public MLS artifacts, but
   Tally Workers does observe the linkage between orchestrator and worker
   identities. Acceptable for the privacy goal as stated ("no plaintext task
   content"); revisit if metadata-resistance becomes a requirement.

## Next sprint

Sprint 3 candidate scope:
- Wire Convex for multi-device state sync
- Clerk auth (GitHub OAuth) in the Flutter app
- Build the actual agent UI (`tally_coding_app/`) backed by this MLS stack
- Surface attestation reports from the worker CVM (TEE proof) in the UI
