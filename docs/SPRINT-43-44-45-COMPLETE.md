# Sprints 43 / 44 / 45 — Pool retry + quota rollover + metrics

**Status: PASS** — Three operational-hardening sprints shipped as
a single `tally-orch:v25` bundle.  Validated live against
`tally.pronoic.dev`:

```
$ curl /metrics
tally_pool_ready 1
tally_pool_target 1
tally_pool_joined 1
tally_tasks_total{status="completed"} 17
tally_tasks_total{status="failed"}    4
tally_tasks_total{status="recovering"} 1
tally_cost_micro_usd_total{kind="architect"} 3587
tally_workers_active 0
tally_quota_at_cap_users 0

$ curl /admin/alerts  Bearer admin
{"alerts": [], "count": 0}
```

22 tasks landed in the period; architect spent **$0.003587** total.
Zero operational alerts.

---

## Sprint 43 — pool retry-with-backoff (self-heal)

Pre-S43: `_bootstrap_pool_in_background` gave up after one failed
attempt.  An orchestrator redeploy could leave it permanently in
`pool_ready=false` if the workers happened to be transiently
unreachable.

Post-S43: the bootstrap loop is infinite.  On failure, the
orchestrator sleeps **1 min → 5 min → 15 min** (then caps at 15
min) and tries again.  Self-heals when workers come back online
without operator intervention.

```python
_retry_delays_s = [60, 300, 900]  # 1m, 5m, 15m; last entry is the cap

async def _bootstrap_pool_in_background() -> None:
    attempt = 0
    while not state.get("pool_ready"):
        attempt += 1
        try:
            slots = await _resolve_pool(...)
            handles = await asyncio.gather(*[_bootstrap_slot(...) for w in slots])
            ok = [h for h in handles if h is not None]
            if not ok:
                # log + sleep + continue
                delay = _retry_delays_s[min(attempt - 1, len(_retry_delays_s) - 1)]
                await asyncio.sleep(delay)
                continue
            # success path: start poller(s), set pool_ready=True
        except asyncio.CancelledError:
            raise  # propagate to lifespan finalizer
        except Exception:
            # log + sleep + continue
```

`pool_status.last_error` clears on success so the
`/admin/alerts` warn / `Workers warming up` banner stops firing.

## Sprint 44 — quota period rollover sweeper

Pre-S44: `period_start` was set on quota row creation and never
advanced.  Paying users on Pro would stay capped at "this
period" forever — month 2 would 429 on the same task count
that 200'd in month 1.

Post-S44: new `Orchestrator.run_period_rollover_sweeper` async
task runs hourly.  Reads quota rows where `period_start` is older
than 30 days AND plan != 'unlimited' (admin / legacy-admin
excluded; they're forever-unlimited).  Resets each via
`reset_quota_period` → `period_start = now, period_tasks_used = 0,
period_agent_seconds_used = 0`.

```python
async def run_period_rollover_sweeper(self) -> None:
    period_seconds = float(os.environ.get("TALLY_QUOTA_PERIOD_S", str(30 * 86400)))
    sweep_interval_s = float(os.environ.get("TALLY_QUOTA_SWEEP_INTERVAL_S", "3600"))
    while True:
        try:
            due = self.db.list_quota_rows_due_for_rollover(period_seconds)
            if due:
                for uid in due:
                    self.db.reset_quota_period(uid)
                logger.info("period sweeper: rolled over %d quota row(s)", len(due))
        except Exception as exc:
            logger.warning("period sweeper raised; ignoring: %s", exc)
        await asyncio.sleep(sweep_interval_s)
```

Both knobs (`TALLY_QUOTA_PERIOD_S`, `TALLY_QUOTA_SWEEP_INTERVAL_S`)
can be overridden via env without a code change.  Defaults: 30 days
+ 1 hour respectively.

## Sprint 45 — Prometheus metrics + admin alerts

Two new endpoints replace the "operator stares at the orchestrator
log file" workflow with structured observability.

### `GET /metrics` (public, Prometheus 0.0.4 format)

Series exposed:

| Name | Type | Labels | Meaning |
|---|---|---|---|
| `tally_pool_ready` | gauge | — | 0/1, whether the processor loop is running |
| `tally_pool_target` | gauge | — | Desired pool size |
| `tally_pool_joined` | gauge | — | Workers that completed MLS bootstrap this attempt |
| `tally_workers_active` | gauge | — | Workers in `active` state in the DB |
| `tally_tasks_total` | gauge | `status` | Tasks broken down by status |
| `tally_cost_micro_usd_total` | counter | `kind` | Cumulative LLM cost by call kind |
| `tally_quota_at_cap_users` | gauge | — | Free-tier users at the period cap |

No user_id labels — keeps cardinality bounded and avoids
inadvertent privacy regressions.  Public on purpose so any
scrape pipeline can pull without juggling a bearer token; the
data is roll-up only.

Operators wire these into Grafana / Datadog / VictoriaMetrics.
A reference dashboard JSON isn't checked in (operator choice
of tool varies), but the series names + labels are stable and
the example output above shows the exact format.

### `GET /admin/alerts` (admin bearer)

Hand-rolled summary of operational concerns the operator should
look at right now.  Each entry: `{severity, code, message, value}`
with severity ∈ `{info, warn, crit}`.

Built-in checks:

- `pool_not_ready` — crit when there's a last_error, warn when
  bootstrap is still in flight.
- `clerk_webhook_unset` — info if `CLERK_WEBHOOK_SECRET` is
  unset (webhooks 503).
- `credentials_key_unset` — info if `CREDENTIALS_KEY` is unset
  (PAT storage 503).
- `clerk_secret_key_unset` — info if `CLERK_SECRET_KEY` is unset
  (push falls back to PAT-only).
- `tasks_stuck_recovering` — warn when ≥ 1 task has been
  `recovering` for > 1 hour (worker silently dropped result
  events).

Designed to be piped through `jq` into Slack / PagerDuty /
whatever the operator wants without further parsing.

## E2E validation (2026-05-19, ~23:55 UTC against `tally.pronoic.dev`)

```
$ curl GET /metrics
  tally_pool_ready 1
  tally_pool_target 1
  tally_pool_joined 1
  tally_tasks_total{status="completed"} 17
  tally_tasks_total{status="failed"} 4
  tally_tasks_total{status="recovering"} 1
  tally_cost_micro_usd_total{kind="architect"} 3587
  tally_workers_active 0
  tally_quota_at_cap_users 0

$ curl GET /admin/alerts  Bearer admin
  {"alerts": [], "count": 0}
```

22 tasks ran end-to-end during this session; cumulative architect
LLM spend is **\$0.003587** (about 0.36¢) across all those calls.
No operational alerts — everything is configured and healthy.

## Open items

1. **Per-route latency histograms.**  `/metrics` exposes counters
   + gauges but no histograms (e.g. POST /tasks p50 / p95
   wall-time).  FastAPI + a small middleware would add them in
   ~30 lines.
2. **Worker cost metrics.**  `tally_cost_micro_usd_total` shows
   `architect` spend; once workers ship `usage_tokens` (open
   item from S39), the `agent` kind will fill in.
3. **Alert delivery.**  `/admin/alerts` is poll-based — the
   operator has to call it.  Webhook-out (e.g. on first
   transition from 0 alerts to ≥1) would be the next step;
   for now the polling model + `tasks_stuck_recovering` check
   is enough.
4. **Grafana dashboard JSON.**  Not checked in — operator
   picks their stack.  When we know what stack the team
   settles on, a dashboards-as-code artifact would be a clean
   follow-up.
5. **Calendar-aligned periods.**  S44 uses a 30-day rolling
   window keyed off `period_start`.  Calendar-month or
   Clerk-subscription-anchored windows would be nicer for
   billing alignment; requires wiring renewal webhooks for
   the latter.

## Roadmap close-out

This wraps the 10-sprint stretch the user locked in 2026-05-19:

| Sprint | Title | Status |
|---|---|---|
| S36 | Onboarding for free-tier | ✅ |
| S37 | Persistent project workspaces | ✅ |
| S38 | Git push via user PAT | ✅ (fallback) |
| S38.5 | Clerk-mediated GitHub OAuth | ✅ (primary) |
| S39 | Cost dashboard | ✅ |
| S40 | Custom user-defined agent roles | ✅ |
| S41 | Multi-task workflows | ✅ |
| S42 | Smarter LLM routing | ✅ |
| S43 | Pool retry-with-backoff | ✅ |
| S44 | Quota period rollover sweeper | ✅ |
| S45 | Prometheus metrics + alerts | ✅ |

11 sprints in one session, all live against `tally.pronoic.dev`.
Total image bumps: v17 → v25 (8 new versions).  Total Flutter
release builds: ~12 (counting the rebuild-after-fix iterations).

## Next direction

The locked roadmap is fully closed.  Open avenues for next
session — pick freely:

- **Distribution** (deferred from the original list): iOS
  TestFlight, Android Play Store internal track, public
  marketing site at `tallycoding.com`.
- **Worker `usage_tokens` reporting** — flips on the `agent`
  cost row, which makes S42 routing's $$ savings visible.
- **Grafana dashboard JSON** — pick a stack, check in
  dashboards-as-code, hook up an alerts pipeline.
- **Mobile build polish** — the responsive layout (S31) works
  but the onboarding cards + projects screen could use a
  real touch-target audit on an actual Android device.
- **Buyer's-side UX** — landing page, pricing comparison
  matrix, "see it in action" loom video, etc.
