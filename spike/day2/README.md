# Day 2 Spike — Containerized OpenHands + Phala CVM deployment

## What this validates

Same task as Day 1 (OpenHands SDK + Phala Redpill coding agent) but containerized and running inside a Phala Cloud Trusted Execution Environment (CVM). A successful run confirms the cloud-side stack is operational end-to-end: Docker image builds, `REDPILL_API_KEY` arrives encrypted via Phala's env injection, the agent executes inside a TEE, and logs are retrievable. It also captures the measurement data needed for gaps B.14 (CVM cold-start time) and B.16 (per-task vs pooled CVM lifecycle) from `docs/gaps-and-open-questions.md`.

Architecture context: `docs/tally-coding-stack-integration-2026-05-16.md`.

## Prerequisites

- Phala Cloud account with CVM access (not just Redpill)
- Phala CLI installed: `npm install -g phala`
- Authenticated: `phala login` (follow browser OAuth flow)
- `REDPILL_API_KEY` from the Phala Cloud dashboard
- `uv` installed locally (for generating `uv.lock` before deploy)

## Files in this directory

| File | Description |
|---|---|
| `Dockerfile` | Python 3.12-slim image; installs uv, copies `pyproject.toml` + `uv.lock`, runs `uv sync --frozen`, executes `spike.py` |
| `docker-compose.yml` | Phala-compatible compose spec; injects env vars; mounts `/workspace` volume |
| `spike.py` | Same coding task as Day 1 — agent creates `greet.py` + `test_greet.py`, runs pytest |
| `pyproject.toml` | `openhands-ai` dependency declaration |
| `uv.lock` | Locked dependency manifest; generated locally before deploy (`uv sync`) |
| `README.md` | This file — deployment runbook + data-capture template |

## Pre-deploy setup

```bash
cd ~/Projects/pronoic/tally-coding/spike/day2

# Generate uv.lock (required by Dockerfile's `uv sync --frozen`)
uv sync

# Create .env from Day 1 template
cp ../day1/.env.example .env
# Edit .env: set REDPILL_API_KEY to your actual key
```

`.env` contents:

```bash
REDPILL_API_KEY=your_phala_redpill_api_key_here
REDPILL_BASE_URL=https://api.redpill.ai/v1
REDPILL_MODEL=moonshotai/Kimi-K2-6
```

## Deploy

**Note the wall-clock time at this exact moment** (start time for gap B.14):

```bash
date   # record this timestamp
phala deploy -e .env
```

`-e .env` encrypts the env file contents and injects them into the CVM as secrets. The CVM never sees the plaintext values outside the TEE.

The command will:
1. Build or pull the Docker image from `docker-compose.yml`
2. Push image to Phala's registry
3. Provision a CVM with TEE attestation
4. Start the container with your encrypted env vars

On success it prints an app-id (format: `app-<hex>`). Save this:

```bash
export PHALA_APP_ID=app-<hex>   # substitute the actual value
```

If the CLI surface differs from the above (flags, output format), update this README during your first deploy.

## Log retrieval

```bash
phala logs $PHALA_APP_ID
```

Logs stream from container stdout. The spike prints all agent activity to stdout. Add `--follow` to tail in real time if the CLI supports it.

To find the app-id if you didn't save it:

```bash
phala cvms list
```

## Verification

A successful run produces this block at the end of the logs:

```
[spike-day2] workspace: /workspace
... (agent activity — tool calls, LLM responses)
============================================================
[spike-day2] RESULT
============================================================
  greet.py: created
  test_greet.py: created
```

Exit code 0 = both files created. Exit code 1 = one or both missing (agent did not complete the task).

## Capture data for gaps

### B.14 — CVM cold-start time

Record: **wall-clock from `phala deploy` invocation to first log line appearing in `phala logs`**.

```
deploy_invoked_at:   <ISO 8601 timestamp from `date` above>
first_log_line_at:   <timestamp of first line in `phala logs` output>
cold_start_seconds:  <difference in seconds>
```

Decision rule (from `docs/gaps-and-open-questions.md` §B.14): if cold start exceeds 15s consistently across 3 runs, switch to pooled-worker pattern in the week 2 architecture. Record at least 2 runs.

### B.16 — Per-task vs pooled CVM lifecycle

Observe and record after the spike completes:

```
container_exited_at:       <timestamp when spike.py finished, from logs>
cvm_auto_terminated:       yes / no / unknown
  # Did the CVM shut itself down after the container exited?
  # Check: does `phala cvms list` still show the app-id?
cvm_state_after_exit:      running / stopped / terminated / <other>
restart_on_container_exit: yes / no / unknown
  # Did the CVM restart the container after exit code 0?
observation_notes:         <anything else; e.g., CVM billed after exit?>
```

This data drives the week 2 architecture decision (§B.16): per-task ephemeral (v0.1 default) vs pooled long-running.

## Teardown

```bash
phala cvms delete $PHALA_APP_ID
```

Confirm deletion with `phala cvms list`. Stops billing for the CVM.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `REDPILL_API_KEY not set` in logs | `.env` not passed or not sourced | Confirm `phala deploy -e .env` was run with the right path |
| `401 Unauthorized` from Redpill | Invalid API key | Verify key in Phala Cloud dashboard |
| `404 Not Found` for model | Wrong model ID | Check Phala Redpill model catalog; update `REDPILL_MODEL` in `.env` |
| `uv.lock` missing or stale | Forgot `uv sync` | Run `uv sync` in this directory then redeploy |
| Deploy hangs at image push | Network / registry issue | Retry; check Phala Cloud status page |
| CVM cold-start > 60s | TEE attestation overhead or queue | Wait it out; record the time for B.14; if consistent, flag for week 2 architecture review |
| No logs appear | App-id wrong or CVM not running | `phala cvms list` to confirm state; re-run `phala logs <correct-id>` |
| Agent doesn't complete task | LLM issue or tool failure | Read agent reasoning in logs; check if pytest installed; try re-running the spike |

## Next: Day 3

After Day 2 succeeds and gap data is recorded: review B.14 + B.16 findings against the thresholds in `docs/gaps-and-open-questions.md` and confirm the week 2 architecture direction (per-task ephemeral vs pooled).
