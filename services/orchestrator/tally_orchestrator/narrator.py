# services/orchestrator/tally_orchestrator/narrator.py
"""B4: Tally narrator — generates plain-language status updates via Red Pill.

Tally never codes directly. This module produces high-level status narration
only: what happened, what the team is doing, where things stand.

Voice constraints:
- Conversational: "Diagnosed the daily-deals bug" not "Task #142: diagnosis complete."
- Honest about problems: "ran into a flaky test, retrying once."
- 80-160 chars target; hard cap at NARRATOR_MAX_CHARS.
- No technical IDs in the output (no task UUIDs, no agent indices).
"""
from __future__ import annotations

import logging
import time

import httpx

logger = logging.getLogger("tally.narrator")

NARRATOR_MODEL = "meta-llama/llama-3.3-70b-instruct"
NARRATOR_TIMEOUT_S = 30
NARRATOR_MAX_OUTPUT_TOKENS = 60   # ~160 chars — keep it brief
NARRATOR_MAX_CHARS = 160

_FALLBACK_BY_EVENT: dict[str, str] = {
    "task_started": "Team is on it.",
    "agent_stuck": "Agent hit a snag — Tally is looking into it.",
    "task_completed": "Done.",
    "task_failed": "Something went wrong — check the task channel.",
    "escalation_needed": "Tally needs your input.",
    "periodic": "Still working on it.",
}

_SYSTEM_PROMPT = (
    "You are Tally, the orchestrator for a multi-agent coding team. "
    "Write a single brief status update (80–160 chars) in plain conversational English. "
    "Never mention task IDs, agent indices, or technical jargon. "
    "No leading 'Tally:' prefix. Output ONLY the update text."
)

_USER_PROMPT_TEMPLATE = (
    "Task: {task_description}\n"
    "Event: {event}\n"
    "{context_block}"
    "Write the status update."
)


def generate_narrator_update(
    *,
    task_description: str,
    event: str,
    context: dict,
    redpill_key: str,
    redpill_base: str = "https://api.redpill.ai/v1",
    model: str = NARRATOR_MODEL,
) -> str:
    """Call Red Pill and return a narrator string.

    Returns a fallback string (never raises) on network/parse failure.

    Args:
        task_description: Short description of the task (e.g. "Fix daily-deals").
        event: One of task_started | agent_stuck | task_completed | task_failed |
               escalation_needed | periodic.
        context: Optional extra context dict (e.g. {"agent_role": "Coder",
                 "error_hint": "flaky test"}).
        redpill_key: API key for Red Pill.
        redpill_base: Base URL for Red Pill API.
        model: Override the default narrator model.

    Example::

        msg = generate_narrator_update(
            task_description="Fix daily-deals rounding",
            event="task_started",
            context={"agents": ["Coder", "Tester"]},
            redpill_key="rp-...",
        )
        # "Team is picking up the daily-deals rounding fix."
    """
    fallback = _FALLBACK_BY_EVENT.get(event, "Working on it.")
    context_lines = [f"{k}: {v}" for k, v in context.items() if v]
    context_block = ("Context:\n" + "\n".join(context_lines) + "\n") if context_lines else ""
    prompt = _USER_PROMPT_TEMPLATE.format(
        task_description=task_description[:120],
        event=event,
        context_block=context_block,
    )
    url = redpill_base.rstrip("/") + "/chat/completions"
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": _SYSTEM_PROMPT},
            {"role": "user", "content": prompt},
        ],
        "temperature": 0.7,      # slightly creative — narrator voice, not JSON
        "max_tokens": NARRATOR_MAX_OUTPUT_TOKENS,
        "stream": False,
    }
    headers = {
        "Authorization": f"Bearer {redpill_key}",
        "Content-Type": "application/json",
    }
    try:
        with httpx.Client(timeout=NARRATOR_TIMEOUT_S) as client:
            resp = client.post(url, json=body, headers=headers)
            resp.raise_for_status()
            data = resp.json()
        content: str = data["choices"][0]["message"]["content"].strip()
        # Strip leading/trailing quotes if the model wraps in them
        content = content.strip('"').strip("'").strip()
        if not content:
            return fallback
        # Hard cap with ellipsis
        if len(content) > NARRATOR_MAX_CHARS:
            content = content[: NARRATOR_MAX_CHARS - 1] + "…"
        return content
    except Exception as exc:
        logger.warning("narrator Red Pill call failed (event=%s): %s", event, exc)
        return fallback


class NarratorSpendGuard:
    """In-process daily token spend guard.

    Prevents runaway narrator LLM spend when tasks are stuck in tight loops.
    State is in-memory — resets on process restart (acceptable; the daily cap
    is a safety valve, not accounting).

    Example::

        guard = NarratorSpendGuard(daily_cap=50_000)
        if guard.can_spend(estimated_tokens):
            msg = generate_narrator_update(...)
            guard.record(actual_tokens_used)
    """

    def __init__(self, daily_cap: int = 50_000) -> None:
        self._daily_cap = daily_cap
        self._used_today: int = 0
        self._today: str | None = None   # "YYYY-MM-DD"

    def _maybe_reset(self) -> None:
        from datetime import datetime, timezone
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        if self._today != today:
            self._today = today
            self._used_today = 0

    def can_spend(self, tokens: int) -> bool:
        """Return True if spending `tokens` more would not exceed the daily cap."""
        self._maybe_reset()
        return (self._used_today + tokens) <= self._daily_cap

    def record(self, tokens: int) -> None:
        """Record actual tokens spent."""
        self._maybe_reset()
        self._used_today += tokens

    @property
    def used_today(self) -> int:
        self._maybe_reset()
        return self._used_today
