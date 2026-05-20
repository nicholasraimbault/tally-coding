"""Sprint 46: architect honors model_allowlist (Checkpoint 3)."""
from unittest.mock import patch
from tally_orchestrator.architect import architect_team


def test_allowlist_overrides_architect_model_picks(monkeypatch):
    # Architect returns a team that picks a premium model
    raw_team = (
        '{"agents": [{"role": "Coder", "model": "moonshotai/kimi-k2.6-instruct"}], '
        '"workflow": "Coder"}'
    )
    monkeypatch.setattr(
        "tally_orchestrator.architect._call_redpill",
        lambda **kw: (raw_team, {"prompt_tokens": 10, "completion_tokens": 20, "total_tokens": 30}),
    )
    palette = [
        {"name": "Coder", "description": "writes code", "default_model": "moonshotai/kimi-k2.6-instruct",
         "default_tools": ["bash"], "system_prompt": "code please"},
    ]
    out = architect_team(
        description="implement foo",
        palette=palette,
        redpill_key="k",
        model_allowlist={"meta-llama/llama-3.3-70b-instruct"},
    )
    # All agents should have been forced to the allowlist model
    for agent in out["agents"]:
        assert agent["model"] == "meta-llama/llama-3.3-70b-instruct"


def test_no_allowlist_keeps_architect_picks(monkeypatch):
    raw_team = (
        '{"agents": [{"role": "Coder", "model": "moonshotai/kimi-k2.6-instruct"}], '
        '"workflow": "Coder"}'
    )
    monkeypatch.setattr(
        "tally_orchestrator.architect._call_redpill",
        lambda **kw: (raw_team, {"total_tokens": 30}),
    )
    palette = [
        {"name": "Coder", "description": "writes code", "default_model": "moonshotai/kimi-k2.6-instruct",
         "default_tools": ["bash"], "system_prompt": "code please"},
    ]
    out = architect_team(
        description="implement foo",
        palette=palette,
        redpill_key="k",
        model_allowlist=None,
    )
    assert out["agents"][0]["model"] == "moonshotai/kimi-k2.6-instruct"
