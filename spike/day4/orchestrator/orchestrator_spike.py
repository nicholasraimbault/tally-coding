"""Sprint 2 orchestrator — MLS-encrypted task dispatch over Tally Workers.

Bootstrap dance (plaintext, public MLS artifacts only):
  1. Dispatch mls:bootstrap {phase: request_kp} → worker returns its KeyPackage
  2. Create MLS group, add worker, get Welcome
  3. Dispatch mls:bootstrap {phase: welcome, welcome: base64} → worker joins

Task dispatch (MLS-encrypted):
  4. Encrypt {"task": "..."} via the established session
  5. Dispatch task:start with the ciphertext
  6. Decrypt the response with the same session
"""

from __future__ import annotations

import base64
import json
import os
import sys

from tally_coding_core.identity import bearer_from_pubkey, load_or_create_identity
from tally_coding_core.mls import MlsSession
from tally_coding_core.tally_workers import TallyWorkersClient


BOOTSTRAP_CONTEXT_ID = "mls:bootstrap"
TASK_CONTEXT_ID = "task:start"


def b64url_no_pad(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def b64url_decode(s: str) -> bytes:
    s = s + "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s)


def dispatch(
    client: TallyWorkersClient,
    *,
    team_id: str,
    target: str,
    context_id: str,
    payload: bytes,
    bearer: str,
    timeout_seconds: int = 60,
) -> bytes:
    """Dispatch a wake, return the response bytes (after b64 decode)."""
    result = client.dispatch_wake(
        team_id=team_id,
        target_identity=target,
        context_id=context_id,
        payload=b64url_no_pad(payload),
        timeout_seconds=timeout_seconds,
        bearer=bearer,
    )
    return b64url_decode(result["response"])


def main() -> int:
    tally_url = os.environ.get("TALLY_WORKERS_URL", "https://tally.nraimbault16.workers.dev")
    team_id = os.environ["TEAM_ID"]
    worker_identity = os.environ["WORKER_IDENTITY_B64"]
    identity_path = os.environ.get("ORCHESTRATOR_IDENTITY_PATH", "/tmp/orchestrator.key")
    mls_state_dir = os.environ.get("ORCH_MLS_STATE_DIR", "/tmp/orch-mls-state")
    task_description = os.environ.get(
        "TASK",
        "Create greet.py that prints 'hello, world' and a test_greet.py with pytest. Install pytest, run it, report.",
    )

    os.makedirs(mls_state_dir, exist_ok=True)

    _privkey, pubkey = load_or_create_identity(identity_path)
    bearer = bearer_from_pubkey(pubkey)

    client = TallyWorkersClient(base_url=tally_url)
    client.team_init(team_id, bearer=bearer)

    # The MLS group_id is created locally; the Welcome embeds it for the worker.
    group_id = f"orch-worker-{team_id}".encode("utf-8")
    session = MlsSession(data_dir=mls_state_dir, identity=pubkey, group_id=group_id)

    # Step 1: ask the worker for its key package.
    print("[orchestrator] bootstrap step 1: requesting worker key package", flush=True)
    bootstrap_req = json.dumps({"phase": "request_kp"}).encode("utf-8")
    resp = dispatch(
        client,
        team_id=team_id,
        target=worker_identity,
        context_id=BOOTSTRAP_CONTEXT_ID,
        payload=bootstrap_req,
        bearer=bearer,
        timeout_seconds=60,
    )
    bootstrap_resp = json.loads(resp.decode("utf-8"))
    worker_kp = b64url_decode(bootstrap_resp["key_package"])
    print(f"[orchestrator] received key package ({len(worker_kp)} bytes)", flush=True)

    # Step 2: create group + add worker locally; get the Welcome.
    welcome_bytes = session.create_and_add(worker_kp)
    print(f"[orchestrator] created group; welcome bundle is {len(welcome_bytes)} bytes", flush=True)

    # Step 3: send the Welcome to the worker.
    print("[orchestrator] bootstrap step 3: sending welcome", flush=True)
    welcome_req = json.dumps({"phase": "welcome", "welcome": b64url_no_pad(welcome_bytes)}).encode("utf-8")
    welcome_ack = dispatch(
        client,
        team_id=team_id,
        target=worker_identity,
        context_id=BOOTSTRAP_CONTEXT_ID,
        payload=welcome_req,
        bearer=bearer,
        timeout_seconds=60,
    )
    welcome_ack_obj = json.loads(welcome_ack.decode("utf-8"))
    if not welcome_ack_obj.get("ok"):
        print(f"[orchestrator] worker rejected welcome: {welcome_ack_obj}", flush=True)
        return 1
    print("[orchestrator] worker joined group; MLS session established", flush=True)

    # Step 4-6: encrypt task, dispatch, decrypt response.
    print(f"[orchestrator] encrypting task ({len(task_description)} chars plaintext)", flush=True)
    task_payload = json.dumps({"task": task_description}).encode("utf-8")
    encrypted_task = session.encrypt(task_payload)
    print(f"[orchestrator] dispatching encrypted task ({len(encrypted_task)} bytes ciphertext)", flush=True)
    encrypted_response = dispatch(
        client,
        team_id=team_id,
        target=worker_identity,
        context_id=TASK_CONTEXT_ID,
        payload=encrypted_task,
        bearer=bearer,
        timeout_seconds=300,  # Tally Workers hard cap
    )
    response_plain = session.decrypt(encrypted_response).decode("utf-8")
    response = json.loads(response_plain)
    print(f"[orchestrator] wake completed; decrypted response:", flush=True)
    print(json.dumps(response, indent=2), flush=True)

    return 0 if response.get("success") else 1


if __name__ == "__main__":
    sys.exit(main())
