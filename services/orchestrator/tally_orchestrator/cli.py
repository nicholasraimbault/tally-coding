"""tally — CLI for the Tally orchestration service.

Usage:
    tally task submit "create a hello-world flask app"
    tally task list
    tally task get <id>
    tally task tail <id>

Env vars:
  TALLY_ORCH_URL    base URL (default: http://127.0.0.1:8080)
  TALLY_API_TOKEN   bearer token required by the service since sprint 10
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime

import httpx


DEFAULT_URL = os.environ.get("TALLY_ORCH_URL", "http://127.0.0.1:8080")


def _client(args: argparse.Namespace) -> httpx.Client:
    token = args.token or os.environ.get("TALLY_API_TOKEN", "")
    headers = {"authorization": f"Bearer {token}"} if token else {}
    return httpx.Client(base_url=args.url, headers=headers, timeout=10)


def _handle_resp(r: httpx.Response) -> None:
    if r.status_code == 401:
        print("error: 401 unauthorized — set TALLY_API_TOKEN", file=sys.stderr)
        sys.exit(1)
    r.raise_for_status()


def fmt_ts(ts: float) -> str:
    return datetime.fromtimestamp(ts).strftime("%H:%M:%S")


def fmt_status(s: str) -> str:
    icons = {"pending": "·", "running": "▸", "completed": "✓", "failed": "✗"}
    return f"{icons.get(s, '?')} {s}"


def cmd_submit(args: argparse.Namespace) -> int:
    with _client(args) as c:
        r = c.post("/tasks", json={"description": args.description})
    _handle_resp(r)
    task = r.json()
    print(f"submitted task {task['id']}")
    if args.tail:
        return tail_task(args, task["id"])
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    with _client(args) as c:
        r = c.get("/tasks")
    _handle_resp(r)
    tasks = r.json()
    if not tasks:
        print("no tasks")
        return 0
    print(f"{'id':<12} {'status':<14} {'updated':<10} {'description'}")
    for t in tasks:
        desc = t["description"]
        if len(desc) > 60:
            desc = desc[:57] + "..."
        print(f"{t['id'][:10]:<12} {fmt_status(t['status']):<14} {fmt_ts(t['updated_at']):<10} {desc}")
    return 0


def cmd_get(args: argparse.Namespace) -> int:
    with _client(args) as c:
        r = c.get(f"/tasks/{args.id}")
    if r.status_code == 404:
        print(f"task {args.id} not found", file=sys.stderr)
        return 1
    _handle_resp(r)
    task = r.json()
    print(json.dumps(task, indent=2))
    return 0 if task["status"] == "completed" else 1


def cmd_tail(args: argparse.Namespace) -> int:
    return tail_task(args, args.id)


def cmd_pool_status(args: argparse.Namespace) -> int:
    with _client(args) as c:
        r = c.get("/admin/pool/status")
    _handle_resp(r)
    body = r.json()
    w = body.get("worker")
    if not w:
        print("no active worker")
        return 1
    uptime = int(w.get("uptime_seconds", 0))
    print(f"active worker:")
    print(f"  cvm_id:   {w['cvm_id']}")
    print(f"  team_id:  {w['team_id']}")
    print(f"  identity: {w['identity'][:12]}...")
    print(f"  uptime:   {uptime // 60}m {uptime % 60}s")
    return 0


def cmd_pool_rotate(args: argparse.Namespace) -> int:
    print("provisioning new worker (this takes ~3-5 min)...")
    # The service exits after responding, so this request may time out at the
    # transport layer; we still want to read the body if it came through first.
    try:
        with _client(args) as c:
            r = c.post("/admin/pool/rotate", timeout=600)
    except Exception as e:
        print(f"warning: connection reset (expected — service restarting): {e}")
        return 0
    _handle_resp(r)
    body = r.json()
    new = body["new_worker"]
    print(f"new worker provisioned:")
    print(f"  cvm_id:   {new['cvm_id']}")
    print(f"  team_id:  {new['team_id']}")
    print(f"  identity: {new['identity'][:12]}...")
    print(f"service exiting in {body.get('respawn_in_seconds', 2)}s; systemd will respawn.")
    return 0


def tail_task(args: argparse.Namespace, task_id: str, poll_seconds: float = 2.0) -> int:
    last_status = None
    with _client(args) as c:
        while True:
            r = c.get(f"/tasks/{task_id}")
            if r.status_code == 404:
                print(f"task {task_id} not found", file=sys.stderr)
                return 1
            _handle_resp(r)
            task = r.json()
            if task["status"] != last_status:
                print(f"[{fmt_ts(time.time())}] {fmt_status(task['status'])}")
                last_status = task["status"]
            if task["status"] in ("completed", "failed"):
                print()
                if task["status"] == "completed":
                    print("result:")
                    print(json.dumps(task["result"], indent=2))
                    return 0
                print(f"error: {task.get('error')}", file=sys.stderr)
                return 1
            time.sleep(poll_seconds)


def main() -> int:
    parser = argparse.ArgumentParser(prog="tally", description="Tally orchestration CLI")
    parser.add_argument("--url", default=DEFAULT_URL, help=f"orchestrator service URL (default: {DEFAULT_URL})")
    parser.add_argument("--token", default="", help="bearer token (or env TALLY_API_TOKEN)")
    sub = parser.add_subparsers(dest="cmd", required=True)

    task = sub.add_parser("task", help="task operations")
    task_sub = task.add_subparsers(dest="task_cmd", required=True)

    submit = task_sub.add_parser("submit", help="submit a new task")
    submit.add_argument("description", help="task description (free-form)")
    submit.add_argument("--tail", action="store_true", help="follow task until completion")
    submit.set_defaults(func=cmd_submit)

    lst = task_sub.add_parser("list", help="list recent tasks")
    lst.set_defaults(func=cmd_list)

    get = task_sub.add_parser("get", help="get one task")
    get.add_argument("id")
    get.set_defaults(func=cmd_get)

    tail = task_sub.add_parser("tail", help="follow a task until completion")
    tail.add_argument("id")
    tail.set_defaults(func=cmd_tail)

    pool = sub.add_parser("pool", help="worker pool operations")
    pool_sub = pool.add_subparsers(dest="pool_cmd", required=True)
    pool_status = pool_sub.add_parser("status", help="show the active worker")
    pool_status.set_defaults(func=cmd_pool_status)
    pool_rotate = pool_sub.add_parser("rotate", help="provision a new worker; service will respawn")
    pool_rotate.set_defaults(func=cmd_pool_rotate)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
