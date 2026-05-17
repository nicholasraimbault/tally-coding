# Day 2 — OpenHands + Phala Redpill inside a Phala TEE CVM

**Status: PASS**

## What was validated

The Day 1 spike (OpenHands agent + Phala Redpill LLM doing a real coding task)
was containerized and executed inside a Phala Cloud TDX-attested CVM. The
agent's full task — create `greet.py`, write `test_greet.py`, install pytest,
run the tests — completed successfully **inside the TEE**, end to end.

## CVM details

```
CVM ID:    2159af14-8fe2-4f12-81dc-f02886fa7f9c
Name:      spike-day2-v2-1778979245
App ID:    5a707219f724464b1cdd096ba7a0a3339f7b833f
Instance:  tdx.small (1 vCPU / 2 GB / 20 GB disk)
Node:      prod5 (US-WEST-1)
OS:        dstack-dev-0.5.9
KMS:       phala
Compose:   image=ghcr.io/nicholasraimbault/tally-spike-day2:v1
LLM:       moonshotai/kimi-k2.6 via api.redpill.ai/v1 (TEE-attested)
```

## TEE container log excerpt

```
test_greet.py::test_greet_with_name PASSED              [ 50%]
test_greet.py::test_greet_without_name PASSED           [100%]
============================== 2 passed in 0.05s ==============================
...
Finish with message:
Task completed successfully.
- Created `greet.py` ... defaulting to `hello, world` ...
- Created `test_greet.py` with two pytest tests ...
- Installed pytest ...
- Ran pytest; **both tests passed**.

============================================================
[spike-day2] RESULT
============================================================
  greet.py: created
  test_greet.py: created
```

## Gotchas surfaced

1. **`build:` in compose does not work** on Phala CVMs. Phala uploads only
   `docker-compose.yml`, not the build context. Pre-build the image locally
   and reference it via `image: ghcr.io/...`.
2. **GHCR packages are private by default.** Phala can't pull them. Either
   make the package public via the UI (no REST/GraphQL endpoint exists for
   that toggle), or add `LABEL org.opencontainers.image.source=...` to the
   Dockerfile *before first push* so the package inherits the source repo's
   visibility automatically.
3. **`phala cvms logs` returns "No containers found"** after the container
   has exited cleanly. Capture logs while the CVM is still `running`, or use
   `phala cvms serial-logs` for VM-level boot diagnostics.
4. **`phala deploy` needs the `-c <compose>` flag explicitly** in v1.1.x —
   omitting it errors with "Docker Compose file is required" even though
   `docker-compose.yml` is in the working directory.

## Verification commands

```bash
# Re-deploy
cd ~/Projects/pronoic/tally-coding/spike/day2
phala deploy -c docker-compose.yml -e ../../scripts/.env --name spike-day2-v3

# Watch progress
phala cvms get <cvm_id>
phala cvms logs <cvm_id>     # while status=running
```

## Cost

~$0.01-0.02 per spike run on tdx.small at $0.058/vCPU-hour
(provision + ~5 min running). The Day 2 v1 (failed build) and v2 (this
success) both consumed a few cents each.

## Next: Day 4

Day 4 takes this pattern further — two CVMs, worker + orchestrator,
coordinating via Tally Workers wakes.
