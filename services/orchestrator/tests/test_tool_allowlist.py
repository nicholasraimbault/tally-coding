"""Sprint 50: per-node tool_allowlist intersects with role.tools."""


def test_intersect_no_allowlist_returns_role_tools():
    from tally_orchestrator.service import _effective_tools_for_node
    assert _effective_tools_for_node(["a", "b", "c"], None) == ["a", "b", "c"]


def test_intersect_with_allowlist_returns_intersection():
    from tally_orchestrator.service import _effective_tools_for_node
    assert _effective_tools_for_node(["a", "b", "c"], ["b", "d"]) == ["b"]


def test_intersect_with_empty_allowlist_returns_empty():
    """An empty list (vs None) means 'no tools' — deliberate."""
    from tally_orchestrator.service import _effective_tools_for_node
    assert _effective_tools_for_node(["a", "b"], []) == []


def test_intersect_drops_unknown_allowlist_entries():
    from tally_orchestrator.service import _effective_tools_for_node
    assert _effective_tools_for_node(["a", "b"], ["b", "rogue_tool"]) == ["b"]


def test_intersect_preserves_role_tools_order():
    """Output keeps the role's order, not the allowlist's."""
    from tally_orchestrator.service import _effective_tools_for_node
    assert _effective_tools_for_node(["a", "b", "c"], ["c", "a"]) == ["a", "c"]
