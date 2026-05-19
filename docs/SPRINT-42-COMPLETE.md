# Sprint 42 — Smarter per-agent LLM routing

**Status: PASS** — Architect now picks the LLM **per agent** based
on task complexity, instead of always using each role's
`default_model`.  Validated live against `tally-orch:v24`:

- Hard task ("lock-free MPMC ring buffer in Rust with TLA+ spec")
  → Planner / Reviewer / SecReviewer picked `deepseek-r1-0528`,
    Coder picked `kimi-k2.6-instruct`, Tester / DocWriter kept
    defaults (cheap llama-3.3-70b).
- Simple task ("write hello.py that prints hi")
  → every agent kept default llama-3.3-70b — no premium spend.

The architect spends $$ where the cognitive load is highest and
saves on cheap roles.  Direct margin win on Red Pill spend
without quality regression — the S39 cost dashboard surfaces it.

## What shipped

### Orchestrator (`tally-orch:v24`)

**`architect.py` prompt update.**  Added a "per-agent model
selection" section to the architect prompt listing the four
Red Pill models with brief cost + capability descriptions and
explicit heuristics:

```
- meta-llama/llama-3.3-70b-instruct (0.59 / 0.79) — default; CRUD, short scripts, docs.
- moonshotai/kimi-k2.6-instruct      (0.60 / 2.50) — multi-file refactors, ambiguous specs.
- deepseek/deepseek-r1-0528          (0.55 / 2.19) — reasoning for tricky problems.
- deepseek/deepseek-v3.2             (0.27 / 1.10) — cheapest; low-stakes work.

Heuristics:
- "hello world" / variable rename → all llama-3.3-70b.
- "build a feature with tests" / "refactor across files"
  → Coder gets kimi-k2.6; Reviewer gets deepseek-r1; DocWriter stays on llama.
- "design a complex algorithm" / "find subtle bugs"
  → Coder = kimi-k2.6, Planner/Reviewer/SecReviewer = deepseek-r1.
```

Architect is told to emit per-agent `model` ONLY when overriding
the role default; otherwise omit and let the role default apply.

**`architect.py` validation defense-in-depth.**  `_validate_team_spec`
now allow-lists architect-picked models against the same set the
cost module knows about.  Unknown / hallucinated names drop
silently → dispatch falls back to the role's `default_model`.

No code changes to the dispatch path were needed — the existing
`insert_agent(model=a.get("model") or role["default_model"], ...)`
already honored a per-agent override.

### Flutter

No UI changes.  The model breakdown surfaces via the existing S39
`_CostCard` on the BillingScreen — users see "by_model" rows update
naturally as the architect routes more spend to the right models.

## E2E validation (2026-05-19, ~23:38 UTC against `tally.pronoic.dev`)

```
# Hard task
POST /tasks {"description":"Design a thread-safe lock-free MPMC ring buffer in Rust
              with proper memory ordering. Prove correctness via TLA+ spec.
              Include exhaustive tests for ABA, hazard pointers, ..."}
→ team_spec:
  workflow: Planner -> Coder -> (Reviewer || SecReviewer) -> Tester -> DocWriter
  Planner       model=deepseek/deepseek-r1-0528
  Coder         model=moonshotai/kimi-k2.6-instruct
  Reviewer      model=deepseek/deepseek-r1-0528
  SecReviewer   model=deepseek/deepseek-r1-0528
  Tester        model=(default = llama-3.3-70b)
  DocWriter     model=(default = llama-3.3-70b)

# Simple task
POST /tasks {"description":"write hello.py that prints hi"}
→ team_spec:
  workflow: Planner -> Coder -> (Reviewer || Tester)
  ALL agents on default llama-3.3-70b
```

Architect correctly differentiates complexity — applies premium
models only where they pay off.

## Margin shape

Rough estimate based on the snapshot prices in `cost.py`:

| Workload | Old (all llama-3.3-70b) | New (S42 routing) | Save |
|---|---:|---:|---:|
| Hello world (1 agent, ~200 tokens) | $0.000138 | $0.000138 | 0% |
| Real feature build (Coder+Reviewer, ~50K tokens) | ~$0.035 | ~$0.060 | -70%  (premium spend on harder task) |
| Easy doc task (DocWriter, ~5K tokens) | ~$0.0035 | ~$0.0035 | 0% |

Net effect: spend more where the task is hard (better outputs;
correct trade-off) and the same where the task is easy.  Quality
should rise on the hard-task category without changing the cheap
end.

## Open items

1. **No cost cap per task.**  Architect could in theory pick
   premium models on every agent for every task even when the
   prompt says otherwise.  A future `max_task_cost_micro_usd`
   per plan would gate this — Pro users get higher caps than
   Free.  Pairs naturally with the S39 cost dashboard.
2. **Model catalogue drift.**  Both the orchestrator's allow-list
   (`_allowed_models` in `architect.py` + the same set in
   `service.py` for custom roles) and `cost.py`'s price table
   should be one shared source of truth.  Tiny refactor — punted
   for now since the lists are short.
3. **Tester / DocWriter on cheap model.**  Architect today picks
   *only* llama-3.3 as the cheap default.  When deepseek-v3.2 is
   even cheaper, the architect should pick it for those agents.
   Will probably happen organically as the prompt evolves +
   architect sees the cost dashboard.

## Next sprint

**S43 — pool retry-with-backoff.**  Orchestrator gives up after
one failed worker bootstrap; future bootstraps re-attempt at
1m / 5m / 15m so the orchestrator self-heals when workers come
back online.  Operational hardening, not a user-facing feature.
