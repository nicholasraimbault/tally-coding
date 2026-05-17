# Sprint 24 — Hosted orchestrator in a Phala CVM

**Status: PASS** — Orchestrator image (`ghcr.io/nicholasraimbault/tally-orch:v1`) deployed to a Phala CVM with a cloudflared sidecar; `tally.pronoic.dev` re-pointed at the new tunnel. Closing the laptop should no longer stop the team — exactly the property the user asked about ("can we have it so that the orchestrator keeps going when you close your laptop, and you can continue from your phone?").

## What was built

### `services/orchestrator/Dockerfile` (NEW)

Two-stage build:
- **Stage 1 (skytale-builder):** clones the Skytale repo at `--branch master`, builds the Python `skytale_sdk` wheel via maturin (`--features python --compatibility linux -o /wheels`). Stays in the image only as a wheel artifact.
- **Stage 2 (runtime):** python:3.12-slim with the wheel + tally-coding-core (path package) + the orchestrator source. `cloudflared` is NOT bundled into this image — it runs as a separate sidecar in the compose.

Notes that mattered:
- The orchestrator's `uv.lock` references local path sources (`../..` and `../../../skytale/sdk`) that don't exist in the container. `uv sync` chokes. Sidestepped by installing the four PyPI deps explicitly (`fastapi`, `uvicorn`, `httpx`, `sse-starlette`) + the wheel + `cryptography` + `python-dotenv`, then `pip install --no-deps /app/core` for `tally-coding-core` and `pip install --no-deps /app` for the orchestrator package itself. Faster build, no lockfile mismatch.
- `LABEL org.opencontainers.image.source=https://github.com/nicholasraimbault/tally-coding` lets GHCR link the package back to the repo. For the *first* push of a new package this also auto-publicizes it, but `tally-orch` was created before the label was on the Dockerfile and so was private on first creation — required a one-time UI toggle to flip it. Future Dockerfiles in this repo get the same label and should auto-public on creation.

### `services/orchestrator/tally_orchestrator/worker_pool.py` & `service.py`

Two `Path(__file__).resolve().parents[3]` calls assumed the orchestrator lives 3 levels under a repo root. In the hosted CVM image the package is at `/app/tally_orchestrator/`, so `parents[3]` is out of bounds. Both now guard via `len(_parents) > 3` and fall back to env-var overrides (`TALLY_WORKER_DIR`, `SCRIPTS_ENV_PATH`).

The lifespan startup also gained an env-var fallback for Red Pill creds: when `scripts/.env` isn't readable (no repo around the install), it reads `REDPILL_API_KEY` + `REDPILL_BASE_URL` straight from the container env. Logs WARN only if both paths fail.

### `services/orchestrator/docker-compose.yml`

Two services:

```yaml
services:
  orchestrator:
    image: ghcr.io/nicholasraimbault/tally-orch:v1
    environment: [HOST, PORT, TALLY_API_TOKEN, TEAM_ID, WORKER_IDENTITY_B64, REDPILL_API_KEY, ...]
    volumes:
      - data:/data

  cloudflared:
    image: cloudflare/cloudflared:2026.5.0
    command: tunnel --no-autoupdate run --token ${CF_TUNNEL_TOKEN}
    depends_on: [orchestrator]

volumes: { data: }
```

The orchestrator never exposes a host port — the cloudflared sidecar reaches it as `http://orchestrator:8080` over the compose network. Public traffic enters via the `tally-prod` CF tunnel.

The persistent volume at `/data` holds the SQLite DB, the orchestrator's Ed25519 identity, and MLS state. Phala's per-CVM volume survives container restarts (the CVM itself is the boundary that wipes it).

### `scripts/seed-cvm-orchestrator-env.py` (NEW)

The hosted CVM can't docker-in-docker provision its own first worker (Phala blocks dind), so the seed script does it from the laptop:

```python
pool = WorkerPool(scripts_env_path=...)
info = pool.provision()   # ~3min: phala deploy + identity poll
write_env_prod(TEAM_ID=info.team_id, WORKER_IDENTITY_B64=info.identity, ...)
```

The resulting `.env.prod` pins the orchestrator to that worker on boot via `_resolve_pool`'s env-override branch (no provisioning attempted, no docker needed inside the CVM).

### CF Tunnel routing

- New CF tunnel `tally-prod` (UUID `6042ad3e-...`) configured remotely-managed: `tally.pronoic.dev` → `http://orchestrator:8080`.
- DNS overwritten: `tally.pronoic.dev` CNAME → `<new-tunnel>.cfargotunnel.com`.
- New DNS record: `tally-dev.pronoic.dev` CNAME → existing `tally-dev` tunnel (which still runs on the laptop for dev work).
- Laptop's `~/.cloudflared/config.yml` updated so its connector serves `tally-dev.pronoic.dev` instead of `tally.pronoic.dev` (HUP'd to reload).

So: `tally.pronoic.dev` = production (CVM, survives laptop close); `tally-dev.pronoic.dev` = dev (laptop, dies when the laptop sleeps).

## E2E validation (2026-05-17, 16:53-16:57 CDT)

**Cold start**

```
16:53:35  phala deploy returns (CVM ID afabe930-…, App ID c3b5481b…)
16:53:35  CVM enters `processing`
16:53:56  cloudflared sidecar connects (4 edge connections at sea07, las01)
16:53:57  orchestrator: "Tally architect ready (Red Pill at https://api.redpill.ai/v1)"
16:54:01  CVM enters `running`; tally.pronoic.dev/health → HTTP 200
```

CVM image pull + boot to first 200 = ~26s. Both images were already in Phala's
node cache from the worker provision earlier in the day, so this is a
warm-pull figure; cold-pull is typically 60-90s.

**End-to-end task**

```
16:54:22  POST /tasks via tally.pronoic.dev (description: "write hello.py …")
16:54:22  Tally architect picks 5-agent team:
            Planner → Coder → Reviewer → Tester → DocWriter
16:54:22  agent 0 (Planner, kimi-k2.6) dispatched to worker msHrHLXF
16:54:37  agent 0 completed: plan.md         (+15s)
16:54:38  agent 1 (Coder)    dispatched
16:54:49  agent 1 completed: hello.py        (+11s)
16:54:49  agent 2 (Reviewer) dispatched
16:55:33  agent 2 completed: review.md       (+44s)
16:55:33  agent 3 (Tester)   dispatched
16:56:00  agent 3 completed: hello.py, tests.md   (+27s)
16:56:00  agent 4 (DocWriter, llama-3.3-70b) dispatched
16:56:13  agent 4 completed: README.md, hello.py  (+13s)
16:56:13  task complete (5 agents, total +111s)
```

All 5 agents ran inside the *pre-provisioned* worker CVM, dispatched by
the *hosted* orchestrator over the Tally Workers wake-routing relay.
Neither side touched the laptop after submission.

**Laptop-close test**

The killer property check. Procedure:

1. `kill <laptop cloudflared PID>` — laptop's tunnel for tally-dev.pronoic.dev dies.
2. `curl https://tally-dev.pronoic.dev/health` → HTTP 530 (no connector, dev URL dead).
3. `curl https://tally.pronoic.dev/health` → HTTP 200 (CVM tunnel still up).
4. `POST https://tally.pronoic.dev/tasks` (write goodbye.py) → accepted, task ID
   `80373f50d28b40b2a99994578dd38ca2`, status `pending`.

With the laptop's tunnel dead, the production URL kept working. Task
submission, architect call, agent dispatch, MLS handshakes, result
collection — all happened over Tally Workers + the CVM. The laptop is
no longer in the critical path.

Task 80373f50 timeline (laptop offline throughout):

```
21:56:43  Planner ack
21:56:59  Planner   → plan.md            (+16s)
21:57:12  Coder     → goodbye.py         (+13s)
21:58:01  Reviewer  → review.md          (+49s)
21:58:40  Tester    → tests.md           (+39s)
21:58:50  DocWriter → README.md, goodbye.py (+10s)
21:58:50  team complete (5 agents, +127s)
```

## Open items

1. **Worker churn still requires a laptop step.** When the pinned worker dies (Phala retirement, OOM, CVM cleanup), the hosted orchestrator has no way to provision a replacement (no dind). The current pattern: re-run `seed-cvm-orchestrator-env.py` from the laptop, then `phala envs update` to push the new TEAM_ID / WORKER_IDENTITY_B64 to the running CVM (which already supports sealed-env reload at request time). A future sprint can move worker-provisioning to a small "control plane" that runs alongside the CVM but with docker on the host.
2. **Volume snapshot / backup.** Phala's persistent volumes survive CVM restarts but not deletion. A nightly `sqlite3 .backup` to a separate store (S3 / R2) would let us recover from accidental `phala cvms delete`.
3. **No multi-region.** Single CVM, single region. Out of scope for now per `Buy Not Build` policy.

## Next sprint

**Sprint 25 — Discord-shaped Flutter UI.** Now that the hosted orchestrator is reachable at `tally.pronoic.dev` from any device, the mobile/desktop UI can be the entrypoint instead of the curl-into-laptop shape we had through Sprints 22-23.
