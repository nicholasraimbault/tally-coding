"""Sprint 48: bidirectional compatibility between flat team_spec (Sprint
22-29) and nodes_v1 team_spec (Sprint 48+).

Flat form:
  {"agents": [...], "stages": [[idx,...], ...], "workflow": "sequential"}

Nodes_v1 form:
  {"nodes": [...], "edges": [...], "format": "nodes_v1"}

The orchestrator's executor handles both formats by checking `format`.
On read, flat specs are converted on-the-fly via `normalize()`.  The
conversion is NOT persisted in Sprint 48; Sprint 49 will add a one-time
backfill that persists nodes_v1.
"""
from __future__ import annotations

from typing import Any


def is_nodes_v1(spec: dict[str, Any]) -> bool:
    """True if `spec` is already in nodes_v1 form."""
    return "nodes" in spec and isinstance(spec.get("nodes"), list)


def normalize(spec: dict[str, Any]) -> dict[str, Any]:
    """Return a nodes_v1 representation of `spec`.

    Passes through if already nodes_v1.  Converts flat form by mapping
    each stage's agents to nodes and connecting consecutive stages with
    'always' edges.  Agents within a stage have NO edges between them
    (parallel-by-default in the new executor).
    """
    if is_nodes_v1(spec):
        return spec
    nodes: list[dict[str, Any]] = []
    edges: list[dict[str, Any]] = []
    stages = spec.get("stages", [])
    agents = spec.get("agents", [])
    for i, stage in enumerate(stages):
        for j, agent_idx in enumerate(stage):
            agent = agents[agent_idx] if 0 <= agent_idx < len(agents) else {}
            node: dict[str, Any] = {"id": f"s{i}a{j}", "kind": "agent"}
            for field in ("role", "model", "spec", "worker_affinity"):
                if field in agent and agent[field] not in (None, ""):
                    node[field] = agent[field]
            nodes.append(node)
    for i in range(len(stages) - 1):
        for j_src, _ in enumerate(stages[i]):
            for j_dst, _ in enumerate(stages[i + 1]):
                edges.append({"from": f"s{i}a{j_src}", "to": f"s{i+1}a{j_dst}"})
    nodes.append({"id": "out", "kind": "output"})
    if stages:
        for j_src, _ in enumerate(stages[-1]):
            edges.append({"from": f"s{len(stages)-1}a{j_src}", "to": "out"})
    return {"nodes": nodes, "edges": edges, "format": "nodes_v1"}
