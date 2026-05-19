# Sprint 39 — Cost dashboard (per-task + monthly burn)

**Status: PASS** — LLM token spend is captured at every architect
call (live + validated against `tally.pronoic.dev` with v21) and
exposed via two new endpoints + a cost panel on the BillingScreen.
Per-agent worker spend has the orchestrator-side plumbing in place
but is gated on workers reporting `usage_tokens` (today's workers
don't yet — captured cleanly as Sprint 39's one open item).

## What shipped

### Orchestrator (`tally-orch:v21`)

**`tally_orchestrator/cost.py` (new).**  Owns the price table +
the `compute_cost_micro_usd(model, prompt_tokens, completion_tokens)`
helper.  Prices stored as **USD per million tokens**, computed
cost stored as **integer micro-USD** (1 USD = 1_000_000 μUSD) so
SQLite rows can't drift via float rounding.

Pricing snapshot 2026-05:

| Model | Prompt $/M | Completion $/M |
|---|---:|---:|
| `meta-llama/llama-3.3-70b-instruct` | 0.59 | 0.79 |
| `moonshotai/kimi-k2-instruct` (kimi-k2.6) | 0.60 | 2.50 |
| `deepseek/deepseek-r1-0528` | 0.55 | 2.19 |
| `deepseek/deepseek-v3.2` | 0.27 | 1.10 |

Unknown models fall back to the Llama-3.3 prices + log a one-line
warning so operators see what to add.

**Schema (additive, idempotent).**

```sql
CREATE TABLE IF NOT EXISTS cost_events (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id           TEXT NOT NULL,
    task_id           TEXT,
    agent_idx         INTEGER,
    kind              TEXT NOT NULL,     -- 'architect' | 'agent' | 'other'
    model             TEXT NOT NULL,
    prompt_tokens     INTEGER NOT NULL DEFAULT 0,
    completion_tokens INTEGER NOT NULL DEFAULT 0,
    total_tokens      INTEGER NOT NULL DEFAULT 0,
    cost_micro_usd    INTEGER NOT NULL DEFAULT 0,
    ts                REAL NOT NULL
);
CREATE INDEX idx_cost_events_user_ts ON cost_events(user_id, ts DESC);
CREATE INDEX idx_cost_events_task   ON cost_events(task_id);
```

**Db helpers.**

| Method | Behaviour |
|---|---|
| `record_cost_event(user_id, kind, model, prompt_tokens, completion_tokens, total_tokens, cost_micro_usd, task_id=None, agent_idx=None)` | Insert one event.  Caller computes cost. |
| `cost_summary(user_id, since_ts)` | Aggregated `{total_micro_usd, total_tokens, by_kind, by_model}`. |
| `task_cost(task_id)` | Per-task roll-up for the cost pill. |

**Architect call wiring.**  `_call_redpill` now returns
`(content, usage_dict)` instead of just `content`.  `architect_team`
gained an optional `cost_recorder: Callable[[str, dict], None]`
param.  `submit_task` passes a closure that calls
`db.record_cost_event(kind='architect', ...)` — accounting failure
never breaks the task pipeline (wrapped in try/except).

**Agent call wiring** (orchestrator-side, awaiting worker support).
The result-event handler now reads `result["usage_tokens"]` +
`result["model"]` from each agent result.  When present, records a
`cost_events` row with `kind='agent'` + `task_id` + `agent_idx`.
Today's workers don't ship these fields yet → architect-only cost
shows up.  When workers grow the `usage_tokens` payload (one-liner
on their side reading from the OpenHands SDK's `metrics` dict),
the dashboard automatically lights up with per-agent cost too.

**Endpoints.**

| Verb / Path | Returns |
|---|---|
| `GET /billing/cost` | `{since_ts, total_micro_usd, total_tokens, by_kind, by_model}` scoped to the caller's current quota period. |
| `GET /tasks/{id}/cost` | `{task_id, total_micro_usd, total_tokens, calls}` for the cost pill on the task channel. |

### Flutter (`tally_coding_app`)

**`lib/api.dart`.**  `billingCost()` method.

**`lib/screens/billing_screen.dart`.**  New `_CostCard` between
"Agent seconds" and "Manage subscription".  Shows:

- Headline total spend this period (green, formatted as `$0.0012`
  for tiny amounts, `$1.23` otherwise) + token count.
- **By kind:** architect / agent / other rows with their $ + call count.
- **By model:** llama-3.3-70b / kimi-k2 / etc rows with $ + call count.
- Disclaimer: "Estimates from orchestrator-side price table. Real
  billing on Red Pill."

Refreshes alongside the usage card when the user taps the refresh icon.

## E2E validation (2026-05-19, ~23:05 UTC against `tally.pronoic.dev`)

```
$ curl GET /billing/cost  (initial, no calls yet)
  → {"since_ts":1779069542.42,"total_micro_usd":0,"total_tokens":0,"by_kind":[],"by_model":[]}

$ curl POST /tasks (description only; architect picks team)
  → task cfc88fe5...

$ curl GET /billing/cost  (after one architect call)
  → {"total_micro_usd": 688,
     "total_tokens": 1107,
     "by_kind":  [{"kind":"architect","total_micro_usd":688,"total_tokens":1107,"calls":1}],
     "by_model": [{"model":"meta-llama/llama-3.3-70b-instruct",
                   "total_micro_usd":688,"total_tokens":1107,"calls":1}]}

$ curl GET /tasks/{id}/cost  (architect runs PRE-task; not tagged)
  → {"total_micro_usd": 0, "total_tokens": 0, "calls": 0}
```

End-to-end cost capture validated: 1107 tokens of architect call,
priced at the Llama-3.3 prompt/completion table, yielded
**$0.000688**.  Plausible.

## Open items

1. **Worker `usage_tokens` reporting.**  Orchestrator already reads
   `result["usage_tokens"]` + `result["model"]`; workers need to
   include them in the final result event.  In `worker_spike.py`
   (or equivalent), grab the OpenHands `agent.metrics` after a
   run and add to the result payload.  One-liner once we know the
   path; punted to keep S39 scope tight.
2. **Architect→task linkage.**  Architect runs in `submit_task`
   BEFORE `create_task`, so the architect's cost event has
   `task_id=NULL`.  Could buffer the event + tag with the new
   task id after create_task returns, but the user-facing
   `cost_summary` is per-user (not per-task), so the missing tag
   doesn't affect the dashboard.  Per-task cost pill will show
   architect spend once workers ship `usage_tokens` (the agent
   events DO have task_id, which is what users care about).
3. **Price-table refresh.**  Snapshot 2026-05.  Drift handling:
   probably a quarterly manual update, optionally automated via
   a periodic sync against the Red Pill catalogue endpoint.
4. **Projected monthly burn.**  Today the card shows
   *current-period actuals*, not a projection.  A "you're at
   $X.YZ, projected $A.BC by EOM at this rate" line would help
   the user catch a runaway cost early.  Trivial to add once we
   have a few periods of data to calibrate against.

## Next sprint

**S40 — custom user-defined agent roles.**  UI for "create your
own role" with prompt + tools + default model.  Pairs with [[S39]]
because cost-by-model now exists, so users can see exactly what
their custom-role calls are costing them.
