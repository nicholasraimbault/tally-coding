"""Sprint 48: workflow executor in nodes_v1 mode — pure helpers."""


def test_nodes_v1_entry_points_are_no_incoming_edge():
    """Nodes with no incoming edges are the entry set (dispatched first)."""
    from tally_orchestrator.service import _nodes_v1_entry_nodes
    spec = {
        "nodes": [{"id": "n1"}, {"id": "n2"}, {"id": "out"}],
        "edges": [{"from": "n1", "to": "n2"}, {"from": "n2", "to": "out"}],
    }
    entries = _nodes_v1_entry_nodes(spec)
    assert entries == {"n1"}


def test_nodes_v1_two_entries_parallel():
    from tally_orchestrator.service import _nodes_v1_entry_nodes
    spec = {
        "nodes": [{"id": "a"}, {"id": "b"}, {"id": "out"}],
        "edges": [{"from": "a", "to": "out"}, {"from": "b", "to": "out"}],
    }
    entries = _nodes_v1_entry_nodes(spec)
    assert entries == {"a", "b"}


def test_nodes_v1_next_ready_after_completion():
    """After 'n1' completes successfully, 'n2' is ready (if edge condition matches)."""
    from tally_orchestrator.service import _nodes_v1_next_ready
    spec = {
        "nodes": [{"id": "n1"}, {"id": "n2"}, {"id": "out"}],
        "edges": [
            {"from": "n1", "to": "n2", "condition": "if_succeeded"},
            {"from": "n2", "to": "out"},
        ],
    }
    completed = {"n1": "succeeded"}
    ready = _nodes_v1_next_ready(spec, completed)
    assert "n2" in ready


def test_nodes_v1_skip_failed_branch():
    """if_succeeded edge from a failed node doesn't fire."""
    from tally_orchestrator.service import _nodes_v1_next_ready
    spec = {
        "nodes": [{"id": "n1"}, {"id": "n2"}, {"id": "out"}],
        "edges": [
            {"from": "n1", "to": "n2", "condition": "if_succeeded"},
            {"from": "n2", "to": "out"},
        ],
    }
    completed = {"n1": "failed"}
    ready = _nodes_v1_next_ready(spec, completed)
    assert "n2" not in ready


def test_nodes_v1_if_failed_fires():
    """if_failed edge from a failed node fires (loop/fallback semantic)."""
    from tally_orchestrator.service import _nodes_v1_next_ready
    spec = {
        "nodes": [{"id": "n1"}, {"id": "fallback"}],
        "edges": [
            {"from": "n1", "to": "fallback", "condition": "if_failed"},
        ],
    }
    completed = {"n1": "failed"}
    ready = _nodes_v1_next_ready(spec, completed)
    assert "fallback" in ready


def test_nodes_v1_always_condition_default():
    """Edge with no `condition` defaults to 'always' (fires regardless)."""
    from tally_orchestrator.service import _nodes_v1_next_ready
    spec = {
        "nodes": [{"id": "n1"}, {"id": "n2"}],
        "edges": [{"from": "n1", "to": "n2"}],
    }
    # Whether n1 succeeded or failed, n2 fires under 'always'
    assert "n2" in _nodes_v1_next_ready(spec, {"n1": "succeeded"})
    assert "n2" in _nodes_v1_next_ready(spec, {"n1": "failed"})


def test_nodes_v1_and_semantics_across_incoming_edges():
    """Multiple incoming edges = AND (all must fire) for node to be ready."""
    from tally_orchestrator.service import _nodes_v1_next_ready
    spec = {
        "nodes": [{"id": "a"}, {"id": "b"}, {"id": "c"}],
        "edges": [
            {"from": "a", "to": "c"},
            {"from": "b", "to": "c"},
        ],
    }
    # Only a complete: c not ready (waiting on b)
    assert "c" not in _nodes_v1_next_ready(spec, {"a": "succeeded"})
    # Both complete: c ready
    assert "c" in _nodes_v1_next_ready(spec, {"a": "succeeded", "b": "succeeded"})
