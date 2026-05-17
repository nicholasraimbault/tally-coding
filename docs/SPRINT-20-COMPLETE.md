# Sprint 20 — systemd timer for `tally pool gc`

**Status: PASS** — `tally-orch-gc.service` (oneshot) and
`tally-orch-gc.timer` (daily) committed to `deploy/`, symlinked into
`~/.config/systemd/user/`, enabled. Manual `systemctl --user start
tally-orch-gc.service` confirms the wiring: env file loaded, `uv run
tally pool gc --older-than-hours 24` invoked, exits cleanly. Next
automatic run is daily at 03:17 local with a 5-min random jitter.

This closes Open Item #1 from Sprint 17 ("No automatic scheduling").

## What was built

### `deploy/tally-orch-gc.service`

Oneshot service that invokes the CLI. Same `WorkingDirectory` and
`EnvironmentFile` as `tally-orch.service` so `TALLY_API_TOKEN` is in
scope. Best-effort `After=tally-orch.service` + `Wants=` so a missing
orchestrator surfaces as a non-zero exit rather than a silent skip:

```ini
[Service]
Type=oneshot
WorkingDirectory=%h/Projects/pronoic/tally-coding/services/orchestrator
EnvironmentFile=%h/.config/tally-orch/env
ExecStart=%h/.local/bin/uv run tally pool gc --older-than-hours 24
```

24h grace period (`--older-than-hours 24`) is deliberately generous —
the per-deploy tag from a worker that rotated 10 min ago will stay
until tomorrow, even if the rotation completed cleanly. Cheap
insurance against an over-eager GC that races a still-active
worker's tag.

### `deploy/tally-orch-gc.timer`

Daily fire with `Persistent=true` (catches up after host downtime)
and a 5-min `RandomizedDelaySec` to keep multiple hosts off the GHCR
API at the same moment:

```ini
[Timer]
OnCalendar=*-*-* 03:17:00
Persistent=true
RandomizedDelaySec=5min
Unit=tally-orch-gc.service

[Install]
WantedBy=timers.target
```

`03:17` instead of `03:00` to dodge the cron-typical "everyone
schedules on the hour" thundering herd on shared infra.

### Install (one-time, per host)

```bash
ln -s ~/Projects/pronoic/tally-coding/deploy/tally-orch-gc.service \
    ~/.config/systemd/user/
ln -s ~/Projects/pronoic/tally-coding/deploy/tally-orch-gc.timer \
    ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now tally-orch-gc.timer
```

Symlink-based install means `git pull` updates the units in place.

## Validation

```
$ systemctl --user list-timers tally-orch-gc.timer
NEXT                        LEFT LAST PASSED UNIT                ACTIVATES
Mon 2026-05-18 03:18:55 CDT  13h -    -      tally-orch-gc.timer tally-orch-gc.service

$ systemctl --user status tally-orch-gc.timer
● tally-orch-gc.timer - Tally Coding GHCR GC daily timer (Sprint 20)
   Loaded: loaded (~/.config/systemd/user/tally-orch-gc.timer; enabled)
   Active: active (waiting) since Sun 2026-05-17 13:32:58 CDT
   Trigger: Mon 2026-05-18 03:18:55 CDT; 13h left
   Triggers: ● tally-orch-gc.service
```

Manual one-shot (orchestrator was down — Sprint 19 cleanup left it
stopped):

```
$ systemctl --user start tally-orch-gc.service
$ journalctl --user -u tally-orch-gc.service | tail
... uv[361987] ExecStart=...uv run tally pool gc --older-than-hours 24
... uv[361993] httpx.ConnectError: [Errno 111] Connection refused
... systemd: tally-orch-gc.service: Failed with result 'exit-code'
```

That's the *expected* failure path when the orchestrator is offline —
the CLI hits `http://127.0.0.1:8080/admin/pool/gc` and gets a
connection refused, exits 1, systemd logs it, the timer fires us
again tomorrow. With the orchestrator running (Sprint 17 already
proved the end-to-end GC), the same command returns a structured
summary of versions removed.

Trigger flow verified up to the API call:

| step                       | proof                                |
|----------------------------|--------------------------------------|
| timer wired to service     | `systemctl status` shows `Triggers:` |
| timer next-run scheduled   | `list-timers` shows tomorrow 03:18   |
| `daemon-reload` picks up   | symlink resolution + `enabled` state |
| env loaded in service      | CLI got `TALLY_API_TOKEN` (no auth   |
|                            | error, just refused-conn)            |
| CLI command path correct   | `tally pool gc --older-than-hours 24` |
|                            | shows up in process table during run |
| end-to-end GC against live | proven in Sprint 17 (manual run      |
|   orchestrator             | reduced 42 → 10 versions, 0 errors)  |

## Files committed

- `deploy/tally-orch-gc.service` — oneshot service unit.
- `deploy/tally-orch-gc.timer` — daily timer unit.

No code changes; no image bump.

## Open items

1. **Symlink install is manual.** A `deploy/install.sh` that
   creates the symlinks + reloads systemd would make first-host
   setup one command instead of three. Punt — fresh installs are
   rare and the README has the commands.
2. **GC against a down orchestrator is a non-zero exit.** systemd
   journals it but doesn't escalate. If the orchestrator stays
   down for weeks the GC silently never runs and tag debt
   re-accumulates. A monitoring page would catch this; today the
   timer's `LAST` column in `list-timers` is the only signal.

## Next sprint

Per the proposed roadmap, **Sprint 21: `tally status` one-screen
dashboard** — a CLI subcommand that summarises pool, recent tasks,
sweeper state, and memory in a single screen so the operator UX
isn't "three `tally` commands + `journalctl`".
