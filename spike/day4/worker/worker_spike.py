"""Worker — receives MLS-encrypted task wakes; streams events back to orchestrator.

Bootstrap dance (plaintext, public MLS artifacts only):
  1. Orchestrator dispatches mls:bootstrap with phase=request_kp
  2. Worker responds with its KeyPackage (base64)
  3. Orchestrator dispatches mls:bootstrap with phase=welcome + Welcome bytes
  4. Worker calls MlsSession.join(welcome), registers for task:start

Task delivery (MLS-encrypted):
  5. Orchestrator dispatches task:start with payload =
     MLS-encrypted {"task": "...", "task_id": "...", "orchestrator_bearer": "..."}
  6. Worker decrypts via MlsSession, spins up an event-emitter thread, then runs
     OpenHands. The Conversation callback pushes each event onto a queue; the
     emitter thread MLS-encrypts and dispatches them to the orchestrator's
     bearer as context_id=task:event.
  7. After conversation.run() returns, worker shuts down the emitter and
     completes the original wake with the encrypted final result.
"""

from __future__ import annotations

import base64
import json
import os
import queue
import sys
import threading
import time
from pathlib import Path
from typing import Any

from openhands.sdk import LLM, Agent, Conversation, Tool
from openhands.tools.terminal import TerminalTool
from openhands.tools.file_editor import FileEditorTool
from openhands.tools.task_tracker import TaskTrackerTool

from tally_coding_core.identity import bearer_from_pubkey, load_or_create_identity
from tally_coding_core.mls import MlsSession
from tally_coding_core.tally_workers import TallyWorkersClient


BOOTSTRAP_CONTEXT_ID = "mls:bootstrap"
TASK_CONTEXT_ID = "task:start"
EVENT_CONTEXT_ID = "task:event"
FS_LIST_CONTEXT_ID = "task:fs:list"
FS_READ_CONTEXT_ID = "task:fs:read"
MAX_FILE_READ_BYTES = 256 * 1024  # 256 KiB safety cap on workspace reads

# Sentinel pushed on the event queue to tell the emitter thread to exit.
_EMITTER_SHUTDOWN = object()


def b64url_no_pad(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def b64url_decode(s: str) -> bytes:
    s = s + "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s)


def build_llm() -> LLM:
    api_key = os.environ.get("REDPILL_API_KEY")
    if not api_key:
        sys.exit("REDPILL_API_KEY not set")
    base_url = os.environ.get("REDPILL_BASE_URL", "https://api.redpill.ai/v1")
    model_name = os.environ.get("REDPILL_MODEL", "moonshotai/kimi-k2.6")
    # stream=True so token_callbacks fire per chunk; required for the
    # TokenBatcher → orchestrator → Flutter streaming pipeline.
    return LLM(model=f"openai/{model_name}", api_key=api_key, base_url=base_url, stream=True)


def event_summary(event: Any) -> dict:
    """Reduce a verbose OpenHands event to a UI-friendly dict.

    Keeps the wake payload small and avoids leaking full LLM completion bodies
    over the wire. Truncates content fields at 500 chars.
    """
    summary: dict[str, Any] = {"type": type(event).__name__, "ts": time.time()}
    # Plain message
    if hasattr(event, "content") and not hasattr(event, "action") and not hasattr(event, "observation"):
        summary["content"] = str(event.content)[:500]
    # Action event (agent did something)
    if hasattr(event, "action"):
        action = event.action
        summary["action_type"] = type(action).__name__
        for attr in ("command", "path", "message", "thought", "file_text"):
            if hasattr(action, attr):
                val = getattr(action, attr)
                if val:
                    summary[attr] = str(val)[:500]
    # Observation event (tool returned something)
    if hasattr(event, "observation"):
        obs = event.observation
        summary["observation_type"] = type(obs).__name__
        for attr in ("content", "output", "exit_code"):
            if hasattr(obs, attr):
                val = getattr(obs, attr)
                if val is not None:
                    summary[attr] = str(val)[:500]
    return summary


def run_event_emitter(
    *,
    event_queue: queue.Queue,
    session: MlsSession,
    client: TallyWorkersClient,
    team_id: str,
    bearer: str,
    target_identity: str,
    task_id: str,
) -> None:
    """Background thread: pulls events off the queue, MLS-encrypts each one,
    dispatches as a task:event wake to the orchestrator's bearer.

    Wire envelope (sprint 14): plaintext JSON wrapper around the MLS ciphertext
    so an orchestrator with N>1 worker sessions can route incoming events to
    the right session by worker_identity. Field layout:
        { worker_identity, task_id, seq, encrypted_b64 }
    The encrypted_b64 field's plaintext is unchanged: {task_id, seq, event}."""
    seq = 0
    while True:
        item = event_queue.get()
        if item is _EMITTER_SHUTDOWN:
            return
        try:
            inner = json.dumps({"task_id": task_id, "seq": seq, "event": item}).encode("utf-8")
            ciphertext = session.encrypt(inner)
            envelope = {
                "worker_identity": bearer,
                "task_id": task_id,
                "seq": seq,
                "encrypted_b64": b64url_no_pad(ciphertext),
            }
            client.dispatch_wake(
                team_id=team_id,
                target_identity=target_identity,
                context_id=EVENT_CONTEXT_ID,
                payload=b64url_no_pad(json.dumps(envelope).encode("utf-8")),
                timeout_seconds=60,
                bearer=bearer,
            )
            seq += 1
        except Exception as exc:
            print(f"[worker] event emit failed seq={seq}: {exc}", flush=True)


class TokenBatcher:
    """Buffers OpenHands token_callbacks deltas and flushes them as a single
    TokenBatch event every ~250ms or 200 chars (whichever first). Without
    batching, a 50-tok/s stream would mean 50 wakes/sec — too noisy for the
    transport. With batching, ~4 wakes/sec at typical model speeds."""

    def __init__(self, event_queue, flush_interval_s: float = 0.25, flush_chars: int = 200) -> None:
        self._event_queue = event_queue
        self._buffer: list[str] = []
        self._lock = threading.Lock()
        self._last_flush = time.monotonic()
        self._flush_interval = flush_interval_s
        self._flush_chars = flush_chars
        self._stop = threading.Event()
        self._timer = threading.Thread(target=self._timer_loop, daemon=True, name="token-batcher")
        self._timer.start()

    def on_chunk(self, chunk) -> None:
        """Token callback. `chunk` is a litellm ModelResponseStream."""
        try:
            delta = chunk.choices[0].delta
            content = getattr(delta, "content", None) or ""
        except (AttributeError, IndexError):
            return
        if not content:
            return
        with self._lock:
            self._buffer.append(content)
            if self._should_flush_locked():
                self._flush_locked()

    def flush(self) -> None:
        with self._lock:
            self._flush_locked()

    def stop(self) -> None:
        self._stop.set()
        self.flush()

    def _should_flush_locked(self) -> bool:
        if not self._buffer:
            return False
        if time.monotonic() - self._last_flush >= self._flush_interval:
            return True
        if sum(len(c) for c in self._buffer) >= self._flush_chars:
            return True
        return False

    def _flush_locked(self) -> None:
        if not self._buffer:
            return
        text = "".join(self._buffer)
        self._buffer.clear()
        self._last_flush = time.monotonic()
        self._event_queue.put({"type": "TokenBatch", "content": text, "ts": time.time()})

    def _timer_loop(self) -> None:
        while not self._stop.is_set():
            time.sleep(0.1)
            with self._lock:
                if self._should_flush_locked():
                    self._flush_locked()


def perform_task(
    *,
    task_description: str,
    workspace: Path,
    event_callback,
    token_callback=None,
) -> dict:
    """Run OpenHands agent in workspace with event + token callbacks streaming
    to the orchestrator via the emitter thread."""
    llm = build_llm()
    agent = Agent(
        llm=llm,
        tools=[
            Tool(name=TerminalTool.name),
            Tool(name=FileEditorTool.name),
            Tool(name=TaskTrackerTool.name),
        ],
    )
    kwargs: dict[str, Any] = {"agent": agent, "workspace": str(workspace), "callbacks": [event_callback]}
    if token_callback is not None:
        kwargs["token_callbacks"] = [token_callback]
    conversation = Conversation(**kwargs)
    conversation.send_message(task_description)
    conversation.run()
    files_created = sorted(
        str(p.relative_to(workspace)) for p in workspace.rglob("*") if p.is_file()
    )
    return {"success": True, "files_created": files_created}


def handle_fs_list_wake(session: MlsSession, payload: bytes, workspace_root: Path) -> bytes:
    """List files in a task's workspace. Payload: {"task_id": "..."}
    Response: {"entries": [{"path": "...", "size": N, "is_dir": bool}, ...]}"""
    plaintext = session.decrypt(payload).decode("utf-8")
    req = json.loads(plaintext)
    task_id = req["task_id"]
    root = workspace_root / f"task-{task_id[:12]}"
    if not root.exists():
        resp = {"error": f"workspace not found for task {task_id[:8]}"}
    else:
        entries = []
        for p in sorted(root.rglob("*")):
            try:
                rel = p.relative_to(root)
            except ValueError:
                continue
            entries.append({
                "path": str(rel),
                "size": p.stat().st_size if p.is_file() else 0,
                "is_dir": p.is_dir(),
            })
        resp = {"task_id": task_id, "entries": entries}
    return session.encrypt(json.dumps(resp).encode("utf-8"))


def handle_fs_read_wake(session: MlsSession, payload: bytes, workspace_root: Path) -> bytes:
    """Read a single file from a task's workspace. Payload:
    {"task_id": "...", "path": "..."}. Path is relative to the task workspace
    and rejected if it tries to escape via '..'. Response: {"content_b64": ...}
    or {"error": "..."}. Files larger than MAX_FILE_READ_BYTES are truncated."""
    plaintext = session.decrypt(payload).decode("utf-8")
    req = json.loads(plaintext)
    task_id = req["task_id"]
    rel_path = req["path"]
    root = (workspace_root / f"task-{task_id[:12]}").resolve()
    target = (root / rel_path).resolve()
    # Refuse paths that try to escape the task workspace.
    if not str(target).startswith(str(root) + "/") and target != root:
        resp = {"error": "path traversal blocked"}
    elif not target.exists():
        resp = {"error": f"not found: {rel_path}"}
    elif target.is_dir():
        resp = {"error": f"is a directory: {rel_path}"}
    else:
        data = target.read_bytes()[:MAX_FILE_READ_BYTES]
        resp = {
            "task_id": task_id,
            "path": rel_path,
            "content_b64": base64.b64encode(data).decode("ascii"),
            "size": target.stat().st_size,
            "truncated": target.stat().st_size > MAX_FILE_READ_BYTES,
        }
    return session.encrypt(json.dumps(resp).encode("utf-8"))


def handle_bootstrap_wake(session: MlsSession, payload: bytes) -> tuple[bytes, bool]:
    msg = json.loads(payload.decode("utf-8"))
    phase = msg.get("phase")
    if phase == "request_kp":
        kp = session.my_key_package()
        print(f"[worker] bootstrap: returning key_package ({len(kp)} bytes)", flush=True)
        return json.dumps({"key_package": b64url_no_pad(kp)}).encode("utf-8"), False
    elif phase == "welcome":
        welcome = b64url_decode(msg["welcome"])
        session.join(welcome)
        print(f"[worker] bootstrap: joined group via welcome ({len(welcome)} bytes)", flush=True)
        return json.dumps({"ok": True}).encode("utf-8"), True
    else:
        return json.dumps({"error": f"unknown phase: {phase}"}).encode("utf-8"), False


def handle_task_wake(
    *,
    session: MlsSession,
    client: TallyWorkersClient,
    team_id: str,
    bearer: str,
    payload: bytes,
    workspace_root: Path,
    wake_id: str,
) -> bytes:
    plaintext_json = session.decrypt(payload).decode("utf-8")
    task_spec = json.loads(plaintext_json)
    task_description = task_spec["task"]
    task_id = task_spec.get("task_id", wake_id)
    orchestrator_bearer = task_spec.get("orchestrator_bearer")
    print(f"[worker] task {task_id[:8]} (decrypted): {task_description[:80]}...", flush=True)
    # Workspace dir keyed by task_id (not wake_id) so fs:list/fs:read can find
    # it later by the same task_id the orchestrator + UI use.
    task_workspace = workspace_root / f"task-{task_id[:12]}"
    task_workspace.mkdir(parents=True, exist_ok=True)

    event_queue: queue.Queue = queue.Queue()
    emitter_thread = None
    if orchestrator_bearer:
        emitter_thread = threading.Thread(
            target=run_event_emitter,
            kwargs={
                "event_queue": event_queue,
                "session": session,
                "client": client,
                "team_id": team_id,
                "bearer": bearer,
                "target_identity": orchestrator_bearer,
                "task_id": task_id,
            },
            daemon=True,
            name="event-emitter",
        )
        emitter_thread.start()
        print(f"[worker] streaming events to {orchestrator_bearer[:12]}...", flush=True)

    batcher: TokenBatcher | None = None
    if orchestrator_bearer:
        batcher = TokenBatcher(event_queue)

    def on_event(event):
        try:
            # Drain pending token deltas first so they appear in causal order
            # relative to the action/observation event that follows.
            if batcher is not None:
                batcher.flush()
            event_queue.put_nowait(event_summary(event))
        except Exception as exc:
            print(f"[worker] event callback failed: {exc}", flush=True)

    result: dict = {"success": False, "error": "task did not return a result"}
    try:
        result = perform_task(
            task_description=task_description,
            workspace=task_workspace,
            event_callback=on_event,
            token_callback=batcher.on_chunk if batcher is not None else None,
        )
    except Exception as exc:
        result = {"success": False, "error": f"{type(exc).__name__}: {exc}"}
        print(f"[worker] perform_task raised: {exc}", flush=True)
    finally:
        if batcher is not None:
            batcher.stop()
        # Sprint 18: push the final result onto the event queue (in
        # addition to returning it via complete_wake) so an orchestrator
        # that crashes between task:start dispatch and result-receipt can
        # recover the result from its persisted inbox on next startup.
        # tally-workers retains undelivered wakes at-least-once until the
        # orchestrator acks them via complete_wake, so the result event
        # survives an arbitrarily long orchestrator downtime.
        if emitter_thread is not None and orchestrator_bearer:
            try:
                # Note: send the result event BEFORE the shutdown sentinel
                # so the emitter has a chance to dispatch it.
                event_queue.put({"kind": "result", "task_id": task_id, "result": result})
            except Exception as exc:
                print(f"[worker] failed to enqueue result event: {exc}", flush=True)
            event_queue.put(_EMITTER_SHUTDOWN)
            emitter_thread.join(timeout=15)
    return session.encrypt(json.dumps(result).encode("utf-8"))


def main() -> int:
    tally_url = os.environ.get("TALLY_WORKERS_URL", "https://tally.nraimbault16.workers.dev")
    team_id = os.environ["TEAM_ID"]
    identity_path = os.environ.get("WORKER_IDENTITY_PATH", "/data/worker.key")
    mls_state_dir = os.environ.get("WORKER_MLS_STATE_DIR", "/workspace/mls-state")

    workspace = Path(os.environ.get("WORKSPACE_DIR", "/workspace"))
    workspace.mkdir(parents=True, exist_ok=True)
    Path(mls_state_dir).mkdir(parents=True, exist_ok=True)

    # Sprint 14: when N>1 worker CVMs share an app, Phala may share docker
    # volumes (or strip per-CVM env substitution) so the file-based key falls
    # into a single shared `/workspace/worker.key`. If the orchestrator wants
    # to force a unique identity per CVM, it passes WORKER_PRIVKEY_HEX in the
    # env file; we use that directly and write it to disk so any later code
    # path that reads identity_path still works.
    privkey_hex = os.environ.get("WORKER_PRIVKEY_HEX", "").strip()
    if privkey_hex:
        import binascii
        priv_bytes = binascii.unhexlify(privkey_hex)
        path = Path(identity_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(priv_bytes)
        path.chmod(0o600)
    _privkey, pubkey = load_or_create_identity(identity_path)
    bearer = bearer_from_pubkey(pubkey)

    client = TallyWorkersClient(base_url=tally_url)
    client.team_init(team_id, bearer=bearer)
    client.register(team_id, bearer, bearer=bearer, context_id=BOOTSTRAP_CONTEXT_ID)
    print(f"[worker] ready; team={team_id}; identity={bearer}", flush=True)

    session = MlsSession(
        data_dir=mls_state_dir,
        identity=pubkey,
        group_id=b"pending-bootstrap",
    )

    task_handler_registered = False

    while True:
        resp = client.read_inbox(team_id, bearer, bearer=bearer, wait_seconds=30)
        wakes = resp.get("wakes", [])
        if not wakes:
            print("[worker] inbox empty; continuing to poll...", flush=True)
            continue
        wake = wakes[0]
        wake_id = wake["wake_id"]
        context_id = wake.get("context_id", "?")
        print(f"[worker] received wake_id={wake_id[:8]} context={context_id}", flush=True)

        payload = b64url_decode(wake["payload"])
        try:
            if context_id == BOOTSTRAP_CONTEXT_ID:
                response_bytes, bootstrapped_now = handle_bootstrap_wake(session, payload)
                if bootstrapped_now and not task_handler_registered:
                    # Register all per-task contexts (task work + fs browse) at once.
                    for ctx in (TASK_CONTEXT_ID, FS_LIST_CONTEXT_ID, FS_READ_CONTEXT_ID):
                        client.register(team_id, bearer, bearer=bearer, context_id=ctx)
                    task_handler_registered = True
                    print("[worker] registered task + fs handlers post-bootstrap", flush=True)
            elif context_id == TASK_CONTEXT_ID:
                if not session.bootstrapped:
                    raise RuntimeError("task wake received before MLS bootstrap")
                response_bytes = handle_task_wake(
                    session=session,
                    client=client,
                    team_id=team_id,
                    bearer=bearer,
                    payload=payload,
                    workspace_root=workspace,
                    wake_id=wake_id,
                )
            elif context_id == FS_LIST_CONTEXT_ID:
                response_bytes = handle_fs_list_wake(session, payload, workspace)
            elif context_id == FS_READ_CONTEXT_ID:
                response_bytes = handle_fs_read_wake(session, payload, workspace)
            else:
                raise RuntimeError(f"unknown context_id: {context_id}")
        except Exception as exc:
            print(f"[worker] wake handler failed: {exc}", flush=True)
            response_bytes = json.dumps({"success": False, "error": str(exc)}).encode("utf-8")

        client.complete_wake(team_id, wake_id, b64url_no_pad(response_bytes), bearer=bearer)
        print(f"[worker] completed wake_id={wake_id[:8]}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
