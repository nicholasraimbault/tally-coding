"""Day 3 spike — dispatch a wake via Tally Workers + receive it back.

Validates the orchestrator/worker pattern end-to-end in a single process.
"""

from __future__ import annotations

import base64
import os
import sys
import threading
import time

from dotenv import load_dotenv

from tally_coding_core.identity import bearer_from_pubkey, load_or_create_identity
from tally_coding_core.tally_workers import TallyWorkersClient


def main() -> int:
    load_dotenv()

    tally_url = os.environ.get("TALLY_WORKERS_URL", "https://tally.nraimbault16.workers.dev")
    team_id = os.environ.get("TEST_TEAM_ID", "tally-coding-day3-spike")

    # Provision two identities for the spike
    alice_priv, alice_pub = load_or_create_identity(".identities/alice.key")
    bob_priv, bob_pub = load_or_create_identity(".identities/bob.key")
    alice_bearer = bearer_from_pubkey(alice_pub)
    bob_bearer = bearer_from_pubkey(bob_pub)

    client = TallyWorkersClient(base_url=tally_url)

    # Init team + register handlers
    client.team_init(team_id, bearer=alice_bearer)
    client.register(team_id, bob_bearer, bearer=bob_bearer, context_id="echo")
    print(f"[day3] team={team_id}; alice={alice_bearer[:8]}...; bob={bob_bearer[:8]}...")

    # Bob listens in background
    def bob_listen():
        while True:
            resp = client.read_inbox(team_id, bob_bearer, bearer=bob_bearer, wait_seconds=30)
            for wake in resp.get("wakes", []):
                print(f"[day3] bob received wake_id={wake['wake_id'][:8]} payload={wake['payload'][:20]}...")
                # Echo: reverse the bytes
                payload_bytes = base64.b64decode(wake["payload"])
                echo_bytes = payload_bytes[::-1]
                echo_b64 = base64.b64encode(echo_bytes).decode()
                client.complete_wake(team_id, wake["wake_id"], echo_b64, bearer=bob_bearer)
                print(f"[day3] bob completed wake_id={wake['wake_id'][:8]}")
                return  # one wake handled; exit listener

    listener = threading.Thread(target=bob_listen, daemon=True)
    listener.start()
    time.sleep(1)  # give listener a beat to start

    # Alice dispatches a wake
    payload = base64.b64encode(b"hello tally").decode()
    print(f"[day3] alice dispatching wake to bob...")
    result = client.dispatch_wake(
        team_id=team_id,
        target_identity=bob_bearer,
        context_id="echo",
        payload=payload,
        timeout_seconds=30,
        bearer=alice_bearer,
    )

    response_bytes = base64.b64decode(result["response"])
    expected = b"hello tally"[::-1]

    print(f"[day3] alice got response wake_id={result['wake_id'][:8]} response={response_bytes}")
    print(f"[day3] expected reversed: {expected}")

    listener.join(timeout=2)

    if response_bytes == expected:
        print("[day3] SUCCESS")
        return 0
    else:
        print("[day3] FAILURE")
        return 1


if __name__ == "__main__":
    sys.exit(main())
