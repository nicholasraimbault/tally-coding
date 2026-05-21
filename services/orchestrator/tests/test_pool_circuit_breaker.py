"""Sprint 53: pool circuit breaker on /health.

Covers the three states surfaced by ``GET /health`` after the
circuit-breaker change:

  1. Healthy:    first_failure_ts is None → unhealthy_since_seconds is None,
                 circuit_open is false.
  2. Degraded:   first_failure_ts is recent (< threshold) → unhealthy_since
                 is a positive int, circuit_open is still false.
  3. Open:       first_failure_ts is old (> threshold) → circuit_open is true.

We don't exercise the bootstrap-loop helpers (_record_bootstrap_failure /
_record_bootstrap_success) directly because they live inside the lifespan
closure; the more valuable contract is what /health exposes to external
monitors, which is what these tests verify.
"""
import time

import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch, tmp_db_path):
    monkeypatch.setenv("ORCH_DB_PATH", tmp_db_path)
    monkeypatch.setenv("TALLY_API_TOKEN", "test-token")
    monkeypatch.setenv("REDPILL_API_KEY", "")
    # Use a small threshold so we don't have to sleep for half an hour
    # to exercise the open state. /health reads the env var at request
    # time so this is enough — no orchestrator reload needed.
    monkeypatch.setenv("POOL_CIRCUIT_BREAKER_SECONDS", "60")
    import importlib
    import tally_orchestrator.service as svc
    importlib.reload(svc)

    db = svc.Db(tmp_db_path)
    event_bus = svc.EventBus()
    orchestrator = svc.Orchestrator(
        tally_url="http://localhost:9999",
        identity_path=tmp_db_path + ".orch.key",
        mls_state_base_dir=tmp_db_path + ".mls",
        db=db,
        event_bus=event_bus,
    )
    orchestrator.redpill_key = None
    svc.state["db"] = db
    svc.state["orchestrator"] = orchestrator
    svc.state["event_bus"] = event_bus
    svc.state["api_token"] = "test-token"
    svc.state["pool_ready"] = True
    svc.state["pool_status"] = {
        "target_size": 1,
        "joined": 1,
        "last_error": None,
        "first_failure_ts": None,
        "circuit_open_logged": False,
    }
    yield TestClient(svc.app)
    svc.app.dependency_overrides.clear()


def test_health_healthy_state(client):
    """Sprint 53: when first_failure_ts is None, unhealthy_since is null
    and circuit_open is false."""
    r = client.get("/health")
    assert r.status_code == 200
    body = r.json()
    assert body["pool_ready"] is True
    assert body["pool_unhealthy_since_seconds"] is None
    assert body["pool_circuit_open"] is False


def test_health_degraded_recent(client):
    """Sprint 53: a fresh failure (within threshold) surfaces an integer
    duration but keeps circuit_open=false."""
    import tally_orchestrator.service as svc
    svc.state["pool_status"]["first_failure_ts"] = time.time() - 5  # 5s ago
    svc.state["pool_ready"] = False
    r = client.get("/health")
    body = r.json()
    assert body["pool_ready"] is False
    assert isinstance(body["pool_unhealthy_since_seconds"], int)
    assert 4 <= body["pool_unhealthy_since_seconds"] <= 7
    assert body["pool_circuit_open"] is False


def test_health_circuit_open_after_threshold(client):
    """Sprint 53: a sustained failure (> threshold) trips circuit_open=true."""
    import tally_orchestrator.service as svc
    # Threshold is 60s from the fixture's POOL_CIRCUIT_BREAKER_SECONDS env.
    svc.state["pool_status"]["first_failure_ts"] = time.time() - 120  # 2 min ago
    svc.state["pool_ready"] = False
    r = client.get("/health")
    body = r.json()
    assert body["pool_circuit_open"] is True
    assert body["pool_unhealthy_since_seconds"] >= 120
