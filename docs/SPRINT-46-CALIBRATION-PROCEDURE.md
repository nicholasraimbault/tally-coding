# Sprint 46 — Cost estimate calibration procedure

**Status:** Pending (to be run post-deploy)
**Why pending:** Requires live Red Pill API + a deployed orchestrator
with real users submitting real tasks. Cannot be done in CI / dev.

## Why this calibration matters

The client-side composer banner and server-side per-team estimator
(`services/orchestrator/tally_orchestrator/cost_estimate.py`) use a
linear heuristic that turns description-length and per-agent model
into a credit estimate.  The constants ship with placeholder values
tuned by hand from a few Sprint 42 sample tasks:

| Constant | Value | Meaning |
|---|---:|---|
| `DEFAULT_PROMPT_TOKENS` | 8000 | Baseline prompt tokens (system prompt + first user turn) |
| `DEFAULT_COMPLETION_TOKENS` | 2000 | Baseline completion tokens per agent |
| `PROMPT_TOKENS_PER_CHAR` | 4 | Linear scale on description length |
| `COMPLETION_TOKENS_PER_CHAR` | 1 | Linear scale on description length |

Real-world median token counts will differ.  This procedure
calibrates the constants against actual usage.

## When to run

After the first ~10 paying users have submitted ~50+ tasks each.
Re-run every quarter or when model prices change in `cost.py`.

## Procedure

### Step 1: Sample tasks

Run these 10 tasks via the Flutter app (or `curl POST /tasks`) on
the production deployment.  Tag them with `[s46-calib]` in the
description so they're easy to find in logs.

**4 simple (llama-only):**

1. `[s46-calib] write a python function that reverses a string`
2. `[s46-calib] what is the time complexity of bubble sort?`
3. `[s46-calib] convert 100 fahrenheit to celsius in python`
4. `[s46-calib] regex for matching e164 phone numbers`

**4 medium (kimi + llama):**

5. `[s46-calib] implement merge-sort with a unit test`
6. `[s46-calib] write a Flask endpoint that proxies GET requests to JSONPlaceholder`
7. `[s46-calib] refactor a 200-line python function into smaller helpers`
8. `[s46-calib] write a typescript class that wraps Redis pub/sub`

**2 hard (full S42 routing):**

9. `[s46-calib] build a CLI tool that ingests a CSV and inserts into Postgres with idempotency`
10. `[s46-calib] implement a tiny lisp evaluator with let, lambda, and if`

### Step 2: Pull cost_events from the live DB

SSH to the orchestrator host (see `CLAUDE.local.md`) and dump the
relevant rows:

```bash
sqlite3 /var/lib/tally/orchestrator.db \
  "SELECT task_id, kind, model, prompt_tokens, completion_tokens, total_tokens, cost_micro_usd \
   FROM cost_events WHERE ts > $(date -d '24 hours ago' +%s) \
   ORDER BY task_id, ts" > /tmp/s46-calib-events.tsv
```

Copy the TSV back to your local machine for analysis.

### Step 3: Compute medians per (model, task-class)

In a local Python repl:

```python
import statistics
from collections import defaultdict
import csv

rows = list(csv.reader(open('/tmp/s46-calib-events.tsv'), delimiter='|'))
by_model = defaultdict(lambda: {'prompt': [], 'completion': []})
for r in rows:
    model = r[2]
    by_model[model]['prompt'].append(int(r[3]))
    by_model[model]['completion'].append(int(r[4]))

for model, data in by_model.items():
    p_median = statistics.median(data['prompt'])
    c_median = statistics.median(data['completion'])
    print(f"{model}: prompt median = {p_median}, completion median = {c_median}, n = {len(data['prompt'])}")
```

### Step 4: Update `cost_estimate.py` constants

Take the LARGER of `DEFAULT_*` (per model) as the constants — the
estimator should never under-estimate for the most-expensive paths.
Example update if llama medians are 2500/700 and kimi medians are
4500/1200:

```python
# Calibrated from 10 sample tasks on YYYY-MM-DD.  Constants chosen
# as max-per-model so the estimator never under-estimates.
DEFAULT_PROMPT_TOKENS = 4500
DEFAULT_COMPLETION_TOKENS = 1200
PROMPT_TOKENS_PER_CHAR = 4   # unchanged unless task-description length distribution shifts
COMPLETION_TOKENS_PER_CHAR = 1
```

### Step 5: Sanity-check + ship

Run the orchestrator pytest suite — `cost_estimate` tests are
inequality-based, so calibration changes shouldn't break them.

Build a `tally-orch:v26.1` image with the new constants and deploy.

### Step 6: Append a calibration log row

Add an entry below in this same file:

```
## Calibration history

| Date | Sample size | Median (llama p/c) | Median (kimi p/c) | Constants chosen | Operator |
|---|---:|---:|---:|---|---|
| YYYY-MM-DD | 10 tasks | ... | ... | 4500 / 1200 | (you) |
```

## Calibration history

| Date | Sample size | Median (llama p/c) | Median (kimi p/c) | Constants chosen | Operator |
|---|---:|---:|---:|---|---|
| 2026-05-20 | placeholder | -- | -- | 8000 / 2000 | (initial sprint estimate) |
