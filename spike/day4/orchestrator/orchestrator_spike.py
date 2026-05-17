"""Day 4 orchestrator — dispatches a coding task to worker via Tally Workers."""

from __future__ import annotations

import base64
import json
import os
import sys

from tally_coding_core.identity import bearer_from_pubkey, load_or_create_identity
from tally_coding_core.tally_workers import TallyWorkersClient


def main() -> int:
    tally_url = os.environ.get("TALLY_WORKERS_URL", "https://tally.nraimbault16.workers.dev")
    team_id = os.environ["TEAM_ID"]
    worker_identity = os.environ["WORKER_IDENTITY_B64"]
    identity_path = os.environ.get("ORCHESTRATOR_IDENTITY_PATH", "/data/orchestrator.key")
    task_description = os.environ.get(
        "TASK",
        "Create greet.py that prints 'hello, world' and a test_greet.py with pytest. Install pytest, run it, report.",
    )

    _privkey, pubkey = load_or_create_identity(identity_path)
    bearer = bearer_from_pubkey(pubkey)

    client = TallyWorkersClient(base_url=tally_url)
    client.team_init(team_id, bearer=bearer)
    print(f"[orchestrator] dispatching task to worker={worker_identity[:8]}...", flush=True)

    payload_obj = {"task": task_description}
    # Tally Workers requires url-safe base64 *without* padding ('=' chars rejected).
    payload_b64 = base64.urlsafe_b64encode(json.dumps(payload_obj).encode("utf-8")).decode("ascii").rstrip("=")

    result = client.dispatch_wake(
        team_id=team_id,
        target_identity=worker_identity,
        context_id="task:start",
        payload=payload_b64,
        timeout_seconds=300,  # Tally Workers hard-caps at 300s (5 min)
        bearer=bearer,
    )

    # Response also comes back url-safe-b64 without padding; pad back before decoding.
    raw = result["response"]
    raw += "=" * (-len(raw) % 4)
    response_json = base64.urlsafe_b64decode(raw).decode("utf-8")
    response = json.loads(response_json)

    print(f"[orchestrator] wake completed wake_id={result['wake_id']}", flush=True)
    print(f"[orchestrator] worker reported: {json.dumps(response, indent=2)}", flush=True)

    return 0 if response.get("success") else 1


if __name__ == "__main__":
    sys.exit(main())
