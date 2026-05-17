# Sprint 23 — Tally architect (custom team per task)

**Status: PASS** — User submits a free-text task; Tally reads it,
picks a custom team from the agent palette, and the orchestrator
dispatches that team sequentially. End-to-end validation: a "write
hello.py" request produced a 3-agent team (Planner → Coder →
Reviewer) chosen by Tally, all three agents ran to completion in
49.1s, no client-side team configuration required.

This is the moment "zero-config multi-agent" becomes real. Before
Sprint 23: clients had to know the agent shape and POST a team_spec.
After Sprint 23: just describe what you want; Tally architects the
team.

## What was built

### `architect.py` — the Tally architect

A focused module wrapping one LLM call:

```python
def architect_team(*, description, palette, redpill_key, ...) -> dict:
    """Returns {agents, workflow, reasoning}.  Fallback to Solo Coder
    on bad JSON / unknown role / network error."""
```

Architect prompt shows the model the palette + the task and asks for
JSON-only output. The shape matches what `Orchestrator._start_team`
(Sprint 22) consumes — no orchestrator changes needed beyond wiring
the architect into the submit path.

**Model choice:** Llama-3.3-70B on Red Pill. Kimi-K2 also works but
emits a long reasoning trace that pushes per-call latency to 8-15s
and makes JSON extraction fragile. Llama-3.3 has no reasoning_content
field, just answers in ~500ms-3s.

**Output validation:** roles must be in the palette set; workflow must
be a string; agents must be a non-empty list. Anything off → fallback
to a Solo Coder team with explicit reasoning ("Architect call failed
or returned malformed output").

**Tolerant JSON extractor:** handles raw JSON, ```json…``` fenced
blocks, and JSON-with-prose-prefix. Llama-3.3 mostly returns clean
JSON but the extractor protects against future model changes.

### Race fix: atomic `create_task(description, team_spec=...)`

The first integration of the architect hit a race: the processor loop
polls `tasks WHERE status='pending'` every 0.5s, and the architect's
LLM call adds 1-5s of latency. With the previous shape
(`create_task` → architect → `set_task_team_spec`), the processor
could pick up the task as single-agent before `team_spec` landed.

Sprint 23 fixes this by running the architect FIRST and inserting
the task with team_spec already attached in a single SQL INSERT:

```python
team_spec = await asyncio.to_thread(architect_team, ...) if needed
task_id = db.create_task(body.description, team_spec=team_spec)
```

No race — the processor only ever sees a row with team_spec already
set (or `None` if the user explicitly wanted single-agent).

### Lifespan: load Red Pill creds from `scripts/.env`

The orchestrator already reads `SCRIPTS_ENV_PATH` to build per-worker
env files. Sprint 23 reuses that path to pull `REDPILL_API_KEY` and
`REDPILL_BASE_URL` for the architect's own LLM calls. If the key
isn't there, the architect is disabled and tasks fall through to the
single-agent path — explicit WARN at boot so operators can fix it.

## E2E validation (15:50:58 – 15:51:50 CDT 2026-05-17)

Request:

```bash
$ curl -X POST /tasks -d '{"description":"write hello.py that prints hello world. keep it minimal."}'
```

Architect output (~3s synchronous):

```json
{
  "agents": [
    {"role": "Planner",  "spec": "Decompose task into writing a Python script that prints 'hello world'"},
    {"role": "Coder",    "spec": "Write hello.py with a minimal print statement"},
    {"role": "Reviewer", "spec": "Check for syntax errors and code style"}
  ],
  "workflow": "Planner -> Coder -> Reviewer",
  "reasoning": "A planner, coder, and reviewer are sufficient for a simple task like this."
}
```

Execution timeline:

```
15:50:58  POST /tasks  (no team_spec in request)
15:51:01  POST returns task_id (architect ran in ~3s)
15:51:12  Planner running on worker STp1on3B
15:51:27  Planner completed (+20.8s); Coder running
15:51:37  Coder completed (+14.6s); Reviewer running
15:51:50  Reviewer completed (+13.2s); task `completed` at +49.1s
```

The user wrote *one sentence* and got a real 3-agent team running
through Phala TEE workers, with sensible per-agent specs and a
clean linear workflow. That's the user experience the rest of the
platform is built around.

## Architect across task shapes (smoke test)

Three sample tasks, each architected from scratch:

| Task | Team picked | Time |
|---|---|---|
| write fact.py + pytest test | Planner → Coder → Reviewer → Tester | 3.8 s |
| build flask app with /todos POST and GET, sqlite-backed | Planner → DBA → Coder → Tester → Reviewer | 4.9 s |
| review fact.py for off-by-one bugs | Reviewer → SecReviewer → Tester | 3.2 s |

Tally adjusts team composition meaningfully: it adds a DBA when
schema design is implicit; drops Coder when the task is review-only.
All three calls returned valid JSON; no fallback fires were needed.

## Files committed

- `services/orchestrator/tally_orchestrator/architect.py` (NEW, ~180 LoC):
  - `architect_team()` entry point.
  - `_build_prompt`, `_call_redpill`, `_extract_json`,
    `_validate_team_spec` helpers.
  - `FALLBACK_TEAM` Solo Coder for failure modes.
- `services/orchestrator/tally_orchestrator/service.py`:
  - `Orchestrator.redpill_key` + `redpill_base` fields; loaded in
    `lifespan` from `scripts/.env`.
  - `Db.create_task(description, team_spec=None)` — atomic insert
    with optional `team_spec`.
  - `POST /tasks` calls `architect_team` before `create_task` (race
    fix).

No worker / SDK / deploy changes. No image bump.

## Cost shape

Per-task architect call (Llama-3.3-70B on Red Pill):
- ~600 input tokens + ~250 output = ~850 tokens
- ~$0.0003-0.001 per call depending on Red Pill pricing
- Latency: ~500ms-3s typical, 5-7s tail

Compared to total task cost (multi-agent LLM runs + Phala CVM hours
+ network), the architect is effectively free.

## Open items

1. **Pool=2 parallel cold-start hit the Sprint 16 KMS race again.**
   Both `phala deploy` calls computed the same Phala App ID via the
   centralized KMS hash; second deploy failed with the UNIQUE
   constraint on `dstack_app_nonces.address`. Sprint 16's per-deploy
   `LABEL` build IS pushing distinct image digests, but Phala's KMS
   normalization sometimes collapses them anyway. Workaround: ran
   Sprint 23 validation against pool=1 (one CVM died provisioning,
   one survived; bootstrap proceeded "degraded"). A proper fix is
   either (a) serialize provisioning unconditionally, accepting the
   ~2× cold-start time, or (b) get Phala to expose a `--seed` flag
   that varies the App ID computation. Punt to Sprint 23.5.
2. **Architect doesn't have memory across tasks.** Each architect
   call is a fresh prompt; no preference learning, no "you said
   TypeScript earlier" recall. Sprint 26+ (workspace artifact
   passing) opens the door to per-user / per-team memory once
   identities exist. Punt.
3. **Architect emits sequential-only workflows.** Sprint 27 will
   teach Tally to emit `A || B` and branching syntax; the prompt
   currently forbids parallel workflows to keep Sprint 23 focused
   on the basic case.
4. **No client-side override of the architect's choice.** The user
   has to inspect `tasks.team_spec` after submission to see what
   was picked. The Discord UI in Sprint 25 surfaces this as the
   "Tally posted in #general explaining the team" affordance from
   the locked UX; before then, callers can override via
   `POST /tasks {team_spec: {...}}`.

## Next sprint

Per the locked roadmap: **Sprint 24 — Move orchestrator to Phala
CVM.** Once the orchestrator runs in the cloud, closing the laptop
no longer stops the team — exactly the property the user asked
about ("can we have it so that the orchestrator keeps going when
you close your laptop, and you can continue from your phone?").
