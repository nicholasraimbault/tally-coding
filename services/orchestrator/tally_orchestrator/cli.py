"""tally — CLI for the Tally orchestration service.

Usage:
    tally task submit "create a hello-world flask app"
    tally task list
    tally task get <id>
    tally task tail <id>

The orchestrator service URL defaults to http://127.0.0.1:8080; override with
TALLY_ORCH_URL.
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


def fmt_ts(ts: float) -> str:
    return datetime.fromtimestamp(ts).strftime("%H:%M:%S")


def fmt_status(s: str) -> str:
    icons = {"pending": "·", "running": "▸", "completed": "✓", "failed": "✗"}
    return f"{icons.get(s, '?')} {s}"


def cmd_submit(args: argparse.Namespace) -> int:
    r = httpx.post(f"{args.url}/tasks", json={"description": args.description}, timeout=10)
    r.raise_for_status()
    task = r.json()
    print(f"submitted task {task['id']}")
    if args.tail:
        return tail_task(args.url, task["id"])
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    r = httpx.get(f"{args.url}/tasks", timeout=10)
    r.raise_for_status()
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
    r = httpx.get(f"{args.url}/tasks/{args.id}", timeout=10)
    if r.status_code == 404:
        print(f"task {args.id} not found", file=sys.stderr)
        return 1
    r.raise_for_status()
    task = r.json()
    print(json.dumps(task, indent=2))
    return 0 if task["status"] == "completed" else 1


def cmd_tail(args: argparse.Namespace) -> int:
    return tail_task(args.url, args.id)


def tail_task(url: str, task_id: str, poll_seconds: float = 2.0) -> int:
    last_status = None
    while True:
        r = httpx.get(f"{url}/tasks/{task_id}", timeout=10)
        if r.status_code == 404:
            print(f"task {task_id} not found", file=sys.stderr)
            return 1
        r.raise_for_status()
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

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
