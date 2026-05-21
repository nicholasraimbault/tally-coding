"""Sprint 48: flat team_spec → nodes_v1 conversion."""
from tally_orchestrator.team_spec_compat import normalize, is_nodes_v1


def test_is_nodes_v1_detects_format():
    assert is_nodes_v1({"nodes": [], "edges": []}) is True
    assert is_nodes_v1({"agents": [], "stages": []}) is False
    assert is_nodes_v1({}) is False


def test_normalize_passes_through_nodes_v1():
    spec = {"nodes": [{"id": "n1", "kind": "agent", "role": "Coder"}], "edges": [], "format": "nodes_v1"}
    assert normalize(spec) == spec


def test_normalize_flat_single_agent():
    flat = {"agents": [{"role": "Coder", "spec": "do x"}], "stages": [[0]], "workflow": "sequential"}
    result = normalize(flat)
    assert result["format"] == "nodes_v1"
    assert len(result["nodes"]) == 2  # 1 agent + 1 output
    assert result["nodes"][0]["kind"] == "agent"
    assert result["nodes"][0]["role"] == "Coder"
    assert result["nodes"][1]["kind"] == "output"
    assert len(result["edges"]) == 1
    assert result["edges"][0]["from"] == "s0a0"
    assert result["edges"][0]["to"] == "out"


def test_normalize_flat_sequential():
    flat = {
        "agents": [{"role": "Coder", "spec": "a"}, {"role": "Reviewer", "spec": "b"}],
        "stages": [[0], [1]],
        "workflow": "sequential",
    }
    result = normalize(flat)
    assert len(result["nodes"]) == 3  # 2 agents + output
    edge_pairs = {(e["from"], e["to"]) for e in result["edges"]}
    assert ("s0a0", "s1a0") in edge_pairs
    assert ("s1a0", "out") in edge_pairs


def test_normalize_flat_parallel_within_stage():
    flat = {
        "agents": [{"role": "Coder"}, {"role": "Tester"}, {"role": "Reviewer"}],
        "stages": [[0, 1], [2]],
        "workflow": "sequential",
    }
    result = normalize(flat)
    edge_pairs = {(e["from"], e["to"]) for e in result["edges"]}
    assert ("s0a0", "s1a0") in edge_pairs
    assert ("s0a1", "s1a0") in edge_pairs
    assert ("s1a0", "out") in edge_pairs
    assert ("s0a0", "s0a1") not in edge_pairs
    assert ("s0a1", "s0a0") not in edge_pairs


def test_normalize_preserves_agent_fields():
    flat = {
        "agents": [{"role": "Coder", "model": "llama-3", "spec": "do x", "worker_affinity": "tee"}],
        "stages": [[0]],
        "workflow": "sequential",
    }
    result = normalize(flat)
    n = result["nodes"][0]
    assert n["role"] == "Coder"
    assert n["model"] == "llama-3"
    assert n["spec"] == "do x"
    assert n["worker_affinity"] == "tee"
