# Day 3 — Tally Workers Integration

**Status: PASS** (4/4 tests, 1.57s)

## What was validated

Direct integration with the live Tally Workers deployment at
`https://tally.nraimbault16.workers.dev`, using `tally_coding_core` as the
client library.

| Test | Endpoint | Result |
|---|---|---|
| `test_health_endpoint` | `GET /v1/health` | PASS — returns `{status: ok}` with version |
| `test_team_init_idempotent` | `POST /v1/teams/{id}/init` (×2) | PASS — second call returns same `initialized_at` |
| `test_register_handler` | `POST /v1/teams/{id}/handlers` | PASS — registration accepted, listed |
| `test_team_delete_cleans_up` | `DELETE /v1/teams/{id}` | PASS — team and its handlers removed |

## Run command

```bash
cd ~/Projects/pronoic/tally-coding/tally_coding_core
uv run pytest ../tests/test_tally_workers.py -v
```

## Output

```
============================= test session starts ==============================
platform linux -- Python 3.14.4, pytest-9.0.3, pluggy-1.6.0
configfile: pyproject.toml
plugins: libtmux-0.56.0, anyio-4.9.0
collected 4 items

../tests/test_tally_workers.py::test_health_endpoint PASSED              [ 25%]
../tests/test_tally_workers.py::test_team_init_idempotent PASSED         [ 50%]
../tests/test_tally_workers.py::test_register_handler PASSED             [ 75%]
../tests/test_tally_workers.py::test_team_delete_cleans_up PASSED        [100%]
============================== 4 passed in 1.57s ===============================
```

## Implication

The `TallyWorkersClient` (`tally_coding_core/tally_workers.py`) speaks the
deployed worker's HTTP API correctly. Bearer auth via
`url_safe_b64(ed25519_pubkey)` is accepted. The 4 endpoints exercised here are
the minimum surface needed for Day 4's worker↔orchestrator roundtrip; the
remaining endpoints (`dispatch_wake`, `read_inbox`, `complete_wake`) get
exercised in Day 4 against the same deployment.
