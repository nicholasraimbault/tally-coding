# Day 1 Spike — OpenHands SDK + Phala Redpill TEE inference

## What this validates

End-to-end: one OpenHands coding agent + Phala Redpill (Kimi K2.6, TEE-attested) + real coding task in a fresh workspace.

Specifically:
- OpenHands SDK installs + imports correctly on Python 3.12
- Phala Redpill is reachable + accepts OpenAI-compatible requests
- The agent can use `TerminalTool` (run shell commands) and `FileEditorTool` (write files)
- A real coding task (create file + write test + run pytest) completes
- TEE attestation routing happens

If this works, the cloud-side stack is validated and Day 2 (deploying to Phala CVM) can begin.

## Setup

```bash
cd ~/Projects/pronoic/tally-coding/spike/day1

# Copy env template and add your Phala API key
cp .env.example .env
# Edit .env: set REDPILL_API_KEY to your actual Phala API key

# Install dependencies (uv recommended; falls back to pip if no uv)
uv sync       # creates .venv/ with openhands-ai + python-dotenv
```

If you don't have `uv`:
```bash
brew install uv     # macOS
# or: pip install uv
```

## Run

```bash
uv run python spike.py
```

You should see:
1. The agent receiving the task
2. It thinking + invoking TerminalTool + FileEditorTool
3. Files getting created in the workspace
4. pytest running + passing
5. A final `[spike] RESULT` block showing success

## Expected output

```
[spike] workspace: /tmp/tally-spike-day1-<random>/
... (agent activity stream)
============================================================
[spike] RESULT
============================================================
[ok ] greet.py created (N bytes)
      content:
import os
name = os.environ.get("NAME", "")
print(f"hello, {name if name else 'world'}")

[ok ] test_greet.py created (N bytes)

[spike] workspace preserved at: /tmp/tally-spike-day1-<random>
[spike] inspect manually; delete when done.
```

## Cost

Per run, ~$0.01-0.10 with Kimi K2.6 (most expensive Phala model). Typical task ~10-50K tokens. Phala's $20 starting credit covers many spike iterations.

## If it doesn't work

Common issues + fixes:

| Symptom | Likely cause | Fix |
|---|---|---|
| `REDPILL_API_KEY not set` | `.env` not populated | Edit `.env`; set actual key |
| `401 Unauthorized` | Invalid Phala API key | Verify key at phala.com dashboard |
| `404 Not Found` model | Wrong model ID | Check Phala Redpill model catalog; update `REDPILL_MODEL` in `.env` |
| `Connection refused` | Wrong base URL | Verify `REDPILL_BASE_URL=https://api.redpill.ai/v1` |
| OpenHands import errors | SDK version drift | Check `pyproject.toml` pins; run `uv lock --upgrade` deliberately |
| Agent doesn't run pytest | Tools missing | Verify `TerminalTool`, `FileEditorTool`, `TaskTrackerTool` are passed to Agent |
| Files not created | Agent stuck or LLM weak | Check the agent's reasoning in stdout; if confused, try smaller task |

## Next: Day 2

After Day 1 succeeds: containerize this spike + deploy to Phala Cloud CVM (Day 2 of `tally-coding/docs/tally-coding-week-1-scope-2026-05-15.md`).
