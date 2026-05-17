"""Sprint 23: Tally architect — the LLM that builds a custom team
per task from the agent palette.

The orchestrator calls `architect_team(description, palette, ...)` at
task-create time when the client doesn't supply a `team_spec`. The
architect returns a `{agents, workflow, reasoning}` dict matching the
shape the orchestrator's `_start_team` already consumes (Sprint 22).

Failure modes — bad JSON, unknown role, empty agent list — all fall
back to a Solo Coder team so the task still runs. The architect is
the "default-on autopilot" with a safe fallback; users can always
override by submitting `team_spec` explicitly.

Uses Red Pill (Phala TEE) for the LLM call. Never calls non-TEE
providers — that would break the privacy chain (see
project_tally_coding_architecture memory).
"""
from __future__ import annotations

import json
import logging
import re
from typing import Any

import httpx

logger = logging.getLogger("tally.architect")

# Llama-3.3-70B is a good architect model on Red Pill — fast (~500ms),
# clean JSON output, no reasoning trace that bloats the response.
# Kimi-K2.6 also works but adds 5-10s of "thinking" before the JSON
# emerges. The architect's job is a quick structured decision; we want
# low latency here so users don't see a perceptible pause between
# typing a task and seeing a team form.
ARCHITECT_MODEL = "meta-llama/llama-3.3-70b-instruct"
ARCHITECT_TIMEOUT_S = 60
ARCHITECT_MAX_OUTPUT_TOKENS = 800

FALLBACK_TEAM = {
    "agents": [
        {
            "role": "Coder",
            "spec": "Implement the task end-to-end. Run any tests you write.",
        }
    ],
    "workflow": "Coder",
    "stages": [[0]],
    "reasoning": "Architect call failed or returned malformed output; falling back to Solo Coder.",
}


def architect_team(
    *,
    description: str,
    palette: list[dict],
    redpill_key: str,
    redpill_base: str = "https://api.redpill.ai/v1",
    model: str = ARCHITECT_MODEL,
) -> dict:
    """Ask Tally to build a custom team for this task.

    Returns a dict in the shape `_start_team` consumes. On any failure
    (network, bad JSON, unknown role, empty list), returns the fallback
    Solo-Coder team and logs the reason — the task should still run.
    """
    if not palette:
        logger.warning("architect called with empty palette; using fallback")
        return dict(FALLBACK_TEAM)
    if not description or not description.strip():
        logger.warning("architect called with empty description; using fallback")
        return dict(FALLBACK_TEAM)
    palette_names = {r["name"] for r in palette}
    prompt = _build_prompt(description, palette)
    try:
        raw = _call_redpill(
            prompt=prompt,
            redpill_key=redpill_key,
            redpill_base=redpill_base,
            model=model,
        )
    except Exception as exc:
        logger.warning("architect Red Pill call failed: %s; using fallback", exc)
        return dict(FALLBACK_TEAM)
    parsed = _extract_json(raw)
    if parsed is None:
        logger.warning("architect returned non-JSON output; using fallback. raw[:200]=%r",
                       raw[:200] if raw else "")
        return dict(FALLBACK_TEAM)
    cleaned = _validate_team_spec(parsed, palette_names)
    if cleaned is None:
        logger.warning("architect returned invalid team_spec; using fallback. raw[:200]=%r",
                       raw[:200] if raw else "")
        return dict(FALLBACK_TEAM)
    logger.info("architect picked %d agent(s): %s",
                len(cleaned["agents"]),
                " → ".join(a["role"] for a in cleaned["agents"]))
    return cleaned


def _build_prompt(description: str, palette: list[dict]) -> str:
    """Build the architect prompt. Asks for *strict* JSON output —
    `_extract_json` tolerates a leading paragraph of reasoning if the
    model can't help itself, but pulling the JSON out is cheaper when
    the model cooperates."""
    role_lines = []
    for r in palette:
        role_lines.append(f"- **{r['name']}**: {r['description']}")
    roles_block = "\n".join(role_lines)
    return f"""You are Tally, the team architect for a privacy-first AI coding platform. You read a coding task and build a custom team of agents from the available palette below. Output JSON ONLY (no prose before or after).

Available agent roles:
{roles_block}

For each task, decide:
1. Which roles to include (1-6 agents typical; only add roles that add real value).
2. Per-agent `spec` — a short, task-specific instruction for that agent (1-3 sentences).
3. Workflow + stages — agents can run in sequence OR in parallel:
   - Sequential: each agent waits for the previous one to finish. Use one stage per agent.
   - Parallel: independent agents at the same stage run concurrently. Each stage gets a list of agent indices that run together. Stages execute strictly in order.
   - Pick parallel ONLY when the agents truly don't depend on each other's output (e.g. SecReviewer + Tester both reading the Coder's code, independent FE Coder + BE Coder, etc.). When in doubt, stay sequential.
4. Reasoning — one short sentence explaining the team composition AND the parallelism choice.

Output schema (return EXACTLY this JSON shape):
{{
  "agents": [
    {{"role": "Planner", "spec": "..."}},
    {{"role": "Coder",   "spec": "..."}},
    {{"role": "Reviewer","spec": "..."}},
    {{"role": "Tester",  "spec": "..."}}
  ],
  "stages": [[0], [1], [2, 3]],
  "workflow": "Planner -> Coder -> (Reviewer || Tester)",
  "reasoning": "..."
}}

Stages reference agents by their index in the `agents` array (0-based).
Every agent index must appear in `stages` exactly once. Use one-element
lists for serial steps and multi-element lists for parallel steps.

Constraints:
- Each agent's `role` MUST match one of the available role names exactly.
- Do not invent new roles; only use names from the palette.
- Do not include agents whose role you don't have available.
- Keep spec strings short and actionable.
- The workflow string is human-readable; `stages` is the authoritative graph.

Optional per-agent fields:
- `worker_affinity`: where this agent should run.
  - `"tee"`         — must run in a Phala TEE worker (default for Coder/SecReviewer/anything writing secrets-adjacent code).
  - `"local"`       — must run on the user's local-worker daemon (requires `tally-agent` installed; rare; for FS-touching tasks).
  - `"local_if_available"` — prefer local; fall back to TEE if local isn't online. Good default for Tester (runs against the user's real environment).
  - `"any"` (or absent) — let the orchestrator decide.

Output `worker_affinity` only when you have a real reason; defaults are fine for most tasks.

Task: {description}

Return JSON ONLY."""


def _call_redpill(*, prompt: str, redpill_key: str, redpill_base: str, model: str) -> str:
    """One synchronous chat-completions call. Returns the assistant
    message content. Stream=False because we want the full response
    in one shot for JSON parsing."""
    url = redpill_base.rstrip("/") + "/chat/completions"
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": "You output strict JSON. No prose before or after."},
            {"role": "user", "content": prompt},
        ],
        "temperature": 0.2,  # low — we want consistent dispatching
        "max_tokens": ARCHITECT_MAX_OUTPUT_TOKENS,
        "stream": False,
    }
    headers = {
        "Authorization": f"Bearer {redpill_key}",
        "Content-Type": "application/json",
    }
    with httpx.Client(timeout=ARCHITECT_TIMEOUT_S) as client:
        resp = client.post(url, json=body, headers=headers)
        resp.raise_for_status()
        data = resp.json()
    return data["choices"][0]["message"]["content"]


_JSON_BLOCK_RE = re.compile(r"\{.*\}", re.DOTALL)


def _extract_json(raw: str) -> dict | None:
    """Tolerant JSON extractor — handles three common forms:
    (a) raw JSON,
    (b) JSON wrapped in ```json...``` fenced code blocks,
    (c) JSON with a leading paragraph before it.

    Returns the parsed dict on success, None on failure."""
    if not raw:
        return None
    raw = raw.strip()
    # Strip fenced code blocks if present.
    if raw.startswith("```"):
        # ```json\n{...}\n```  → keep middle
        lines = raw.split("\n")
        # drop first ```... and trailing ```
        if lines[-1].strip().startswith("```"):
            lines = lines[:-1]
        lines = lines[1:]
        raw = "\n".join(lines).strip()
    # Try direct parse first.
    try:
        parsed = json.loads(raw)
        return parsed if isinstance(parsed, dict) else None
    except json.JSONDecodeError:
        pass
    # Regex-extract the first {...} block.
    match = _JSON_BLOCK_RE.search(raw)
    if not match:
        return None
    try:
        parsed = json.loads(match.group(0))
        return parsed if isinstance(parsed, dict) else None
    except json.JSONDecodeError:
        return None


def _validate_team_spec(raw: dict, valid_roles: set[str]) -> dict | None:
    """Sanity-check the architect's output. Returns the cleaned spec
    on success, None if anything's off. We don't try to repair —
    fallback is safer than a half-parsed team."""
    agents = raw.get("agents")
    if not isinstance(agents, list) or not agents:
        return None
    cleaned_agents: list[dict[str, Any]] = []
    _valid_affinities = {"any", "tee", "local", "local_if_available"}
    for a in agents:
        if not isinstance(a, dict):
            return None
        role = a.get("role")
        if role not in valid_roles:
            return None
        spec = a.get("spec", "")
        if not isinstance(spec, str):
            return None
        cleaned = {"role": role, "spec": spec[:1000]}
        # Sprint 28: worker_affinity is optional; only carry forward when
        # the architect picked a non-default value. Garbage / unknown
        # values silently drop to default ("any"), so the orchestrator
        # never has to handle malformed affinities at dispatch time.
        aff = a.get("worker_affinity")
        if isinstance(aff, str) and aff in _valid_affinities and aff != "any":
            cleaned["worker_affinity"] = aff
        cleaned_agents.append(cleaned)
    workflow = raw.get("workflow")
    if not isinstance(workflow, str):
        workflow = " -> ".join(a["role"] for a in cleaned_agents)
    reasoning = raw.get("reasoning", "")
    if not isinstance(reasoning, str):
        reasoning = ""
    # Sprint 27: optional `stages` — list[list[int]]. Each inner list is
    # a stage; agents in the same stage run concurrently. Sequential
    # behavior is the default when stages is missing or invalid.
    stages = _validate_stages(raw.get("stages"), len(cleaned_agents))
    return {
        "agents": cleaned_agents,
        "workflow": workflow,
        "stages": stages,
        "reasoning": reasoning[:500],
    }


def _validate_stages(raw_stages: Any, n_agents: int) -> list[list[int]]:
    """Sprint 27: validate the architect's stage graph.

    Required invariants for a valid `stages`:
      - list of lists of ints
      - every agent idx in [0, n_agents) appears exactly once
      - no negative/oob indices, no duplicates within or across stages

    Returns the cleaned stages on success; on any violation, returns the
    fully-sequential default `[[0], [1], ..., [n-1]]` so the task still
    runs (we're lenient — the dispatcher path is the same code regardless
    of the architect's parallelism choice).
    """
    default = [[i] for i in range(n_agents)]
    if not isinstance(raw_stages, list) or not raw_stages:
        return default
    seen: set[int] = set()
    cleaned: list[list[int]] = []
    for stage in raw_stages:
        if not isinstance(stage, list) or not stage:
            return default
        cleaned_stage: list[int] = []
        for idx in stage:
            if not isinstance(idx, int) or idx < 0 or idx >= n_agents or idx in seen:
                return default
            seen.add(idx)
            cleaned_stage.append(idx)
        cleaned.append(cleaned_stage)
    if seen != set(range(n_agents)):
        return default
    return cleaned
