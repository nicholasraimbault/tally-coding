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
from typing import Any, Callable

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
    templates: list[dict] | None = None,
    cost_recorder: Callable[[str, dict], None] | None = None,
    model_allowlist: set[str] | None = None,
) -> dict:
    """Ask Tally to build a custom team for this task.

    Sprint 29: `templates` is an optional list of saved teams the user
    has promoted from previous tasks. The architect can pick one verbatim
    (setting `template_used`) when it's a clean match, or build fresh.

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
    template_names = {t["name"] for t in (templates or [])}
    prompt = _build_prompt(description, palette, templates or [])
    try:
        raw, usage = _call_redpill(
            prompt=prompt,
            redpill_key=redpill_key,
            redpill_base=redpill_base,
            model=model,
        )
    except Exception as exc:
        logger.warning("architect Red Pill call failed: %s; using fallback", exc)
        return dict(FALLBACK_TEAM)
    # Sprint 39: hand the cost back to the caller for accounting.
    # Recorder is best-effort — accounting failures must not affect
    # the task pipeline.
    if cost_recorder is not None and usage:
        try:
            cost_recorder(model, usage)
        except Exception as exc:
            logger.warning("cost_recorder raised; ignoring: %s", exc)
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
    # Sprint 46: free tier restricts to llama-only.  If the architect
    # picked anything else, silently override each agent's model.  The
    # allowlist's first member is the fallback target.
    if model_allowlist:
        fallback_model = next(iter(model_allowlist))
        for agent in cleaned.get("agents", []):
            picked = agent.get("model")
            if picked is not None and picked not in model_allowlist:
                logger.info(
                    "allowlist: replacing architect's pick %r with %r for role=%s",
                    picked, fallback_model, agent.get("role"),
                )
                agent["model"] = fallback_model
    # Sprint 29: carry forward template_used IFF the model named a real
    # template AND the team matches that template's shape (cheap sanity
    # check; the orchestrator validates fully before bumping use_count).
    template_used = parsed.get("template_used")
    if isinstance(template_used, str) and template_used in template_names:
        cleaned["template_used"] = template_used
        logger.info("architect picked %d agent(s) via template `%s`: %s",
                    len(cleaned["agents"]), template_used,
                    " → ".join(a["role"] for a in cleaned["agents"]))
    else:
        logger.info("architect picked %d agent(s): %s",
                    len(cleaned["agents"]),
                    " → ".join(a["role"] for a in cleaned["agents"]))
    return cleaned


def _build_prompt(description: str, palette: list[dict], templates: list[dict]) -> str:
    """Build the architect prompt. Asks for *strict* JSON output —
    `_extract_json` tolerates a leading paragraph of reasoning if the
    model can't help itself, but pulling the JSON out is cheaper when
    the model cooperates."""
    role_lines = []
    for r in palette:
        role_lines.append(f"- **{r['name']}**: {r['description']}")
    roles_block = "\n".join(role_lines)
    # Sprint 29: surface saved templates. The architect can reuse one
    # verbatim (set `template_used`) or take inspiration and emit a
    # fresh team. Limit per-template payload so the prompt doesn't
    # balloon when the user has dozens of saved teams.
    templates_block = ""
    if templates:
        rows: list[str] = []
        for t in templates[:12]:  # cap
            spec = t.get("team_spec") or {}
            agents = spec.get("agents") or []
            agent_summary = " → ".join(a.get("role", "?") for a in agents) or "?"
            note = t.get("note") or ""
            uses = t.get("use_count", 0)
            label = f"- **{t['name']}** ({agent_summary}; used {uses}×)"
            if note:
                label += f" — {note[:120]}"
            rows.append(label)
        templates_block = (
            "\n\nSaved teams (promoted from prior successful tasks):\n"
            + "\n".join(rows)
            + "\n\nIf one of these saved teams is a CLEAN MATCH for the current task,"
              " reuse it: emit its agents/stages/workflow verbatim AND set"
              ' `"template_used": "<name>"` in the output. Otherwise build fresh and'
              " omit `template_used`. Prefer fresh-build when the task shape is novel —"
              " forced reuse is worse than a tailored team."
        )
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

Sprint 42 — per-agent model selection:

Each agent runs against an LLM that you pick per-agent.  Default is
the role's `default_model` if you omit `model`.  You CAN override per
agent based on the task's complexity to save cost on easy work +
spend more on hard work.  Pick from this catalogue (cost in
USD per million tokens, prompt / completion):

- `meta-llama/llama-3.3-70b-instruct` (0.59 / 0.79) — fast, cheap,
  good for straightforward CRUD, short scripts, documentation.
  Default for most agents — pick another only when the task is
  clearly harder.
- `moonshotai/kimi-k2.6-instruct` (0.60 / 2.50) — strong on
  multi-file refactors, library design, ambiguous specs.  Use for
  Coder when the task is non-trivial.
- `deepseek/deepseek-r1-0528` (0.55 / 2.19) — reasoning model.
  Use for Reviewer / SecReviewer / Planner on tricky problems
  where you want it to think step-by-step before answering.
- `deepseek/deepseek-v3.2` (0.27 / 1.10) — cheapest; OK quality on
  simple code/docs.  Use for DocWriter and other low-stakes agents.

Heuristics:
- "write hello world", "rename a variable", short single-file edits
  → all llama-3.3-70b.
- "build a feature with tests", "refactor across multiple files"
  → Coder gets kimi-k2.6; Reviewer gets deepseek-r1; DocWriter
  (if any) stays on llama-3.3-70b.
- "design a complex algorithm / system", "find subtle bugs"
  → Coder = kimi-k2.6, Planner/Reviewer/SecReviewer = deepseek-r1.

Return per-agent `model` ONLY when you're deliberately overriding
the role default for cost or capability reasons.  When in doubt,
omit `model` and let the role default carry.{templates_block}

Task: {description}

Return JSON ONLY."""


def _call_redpill(
    *, prompt: str, redpill_key: str, redpill_base: str, model: str
) -> tuple[str, dict]:
    """One synchronous chat-completions call. Returns
    ``(content, usage_dict)`` so the caller can do cost accounting.

    Stream=False because we want the full response in one shot for
    JSON parsing.  ``usage_dict`` mirrors the OpenAI-compatible shape:
    ``{prompt_tokens, completion_tokens, total_tokens}``.  Empty dict
    when the provider omits ``usage`` (older proxies; degraded mode).
    """
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
    content = data["choices"][0]["message"]["content"]
    usage = data.get("usage") or {}
    return content, usage


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
    # Sprint 42: defense-in-depth allow-list for architect-picked models.
    # Even though the prompt tells the architect which models to pick,
    # we don't trust the LLM to stay inside the catalogue — hallucinated
    # names would crash at dispatch time.  Validation here drops the
    # offending value so the role's default_model takes over.
    _allowed_models = {
        "meta-llama/llama-3.3-70b-instruct",
        "moonshotai/kimi-k2-instruct",
        "moonshotai/kimi-k2.6-instruct",
        "deepseek/deepseek-r1-0528",
        "deepseek/deepseek-r1",
        "deepseek/deepseek-v3.2",
        "deepseek/deepseek-v3",
    }
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
        # Sprint 42: carry forward per-agent model when the architect
        # picked one we recognise.  Unknown models drop silently; the
        # dispatch path then uses the role's default_model.
        model = a.get("model")
        if isinstance(model, str) and model in _allowed_models:
            cleaned["model"] = model
        elif isinstance(model, str) and model:
            logger.info(
                "architect picked unknown model %r for role %s; dropping (will use role default)",
                model, role,
            )
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
