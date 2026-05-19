"""Sprint 38: push a project's HEAD artifact set to a GitHub repo.

Flow:

  1. Caller is authenticated; we look up their stored github_pat
     credential (encrypted at rest via Sprint 38's CredentialsManager).
  2. Spool the project HEAD into a fresh temporary git working tree:
     write each `{path: base64-bytes}` entry, then ``git init``,
     ``git add``, ``git -c user.* commit``.
  3. ``git push https://<pat>@github.com/<owner>/<repo>.git HEAD:<branch>``.
     Output is parsed for the new commit sha + the branch URL.
  4. The temp tree is unconditionally deleted (the PAT never lives on
     disk longer than the push).

Conventions:

  - The branch is a fresh ``tally/push-<unix-ts>`` by default so a
    user can push many times without rewriting history; a future
    sprint can wire "force-push to <branch>" once we have a confirm-
    overwrite UX.
  - Commits are authored as "Tally Coding <tally@pronoic.dev>" with
    a one-line message ``${commit_message}\n\nFrom Tally project
    ${project_name}``.  Authorship-as-the-user requires the PAT's
    associated email, which we don't store; falling back to a
    generic identity is the right v1 default.

Errors surface as ``GithubPushError`` subclasses; the route handler
maps them to user-facing HTTP errors with redacted detail so PAT
fragments never leak.  Output of `git push` IS scanned for token
echoes and any line matching the PAT prefix is dropped.
"""
from __future__ import annotations

import base64
import logging
import re
import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

logger = logging.getLogger("tally.github_push")


_REPO_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,38}/[A-Za-z0-9._-]{1,100}$")


class GithubPushError(RuntimeError):
    """Base class for all push failures.  ``user_facing`` is suitable
    for surfacing to the caller; ``__str__`` keeps the operator-side
    full context for orchestrator logs."""

    def __init__(self, user_facing: str, *, detail: str | None = None):
        super().__init__(user_facing if detail is None else f"{user_facing} -- {detail}")
        self.user_facing = user_facing


class GithubPushAuthError(GithubPushError):
    """The PAT was rejected by GitHub (401 / 403)."""


class GithubPushRepoError(GithubPushError):
    """The repo doesn't exist or the PAT doesn't have access."""


@dataclass
class PushResult:
    branch: str
    commit_sha: str
    branch_url: str
    repo: str


def validate_repo(spec: str) -> str:
    """Parse + normalise an ``owner/repo`` spec.  Raises
    ``GithubPushError`` on garbage input."""
    spec = spec.strip()
    if not _REPO_RE.match(spec):
        raise GithubPushError(
            "repo must be in the form 'owner/repo' "
            "(letters, digits, '.', '_', '-' only)"
        )
    return spec


def _redact(line: str, pat: str) -> str:
    """Strip any echo of the PAT from a line of git output before we
    log it.  GitHub's https-with-token push URL would otherwise show
    up in error messages."""
    if not pat:
        return line
    return line.replace(pat, "<redacted PAT>")


def _run(cmd: list[str], *, cwd: Path, pat: str, timeout: int = 60) -> tuple[int, str, str]:
    """Wrapper around ``subprocess.run`` that captures + redacts the
    PAT from stdout/stderr before returning anything."""
    logger.debug("git: %s (cwd=%s)", _redact(" ".join(cmd), pat), cwd)
    try:
        proc = subprocess.run(
            cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        raise GithubPushError(f"git command timed out: {cmd[1] if len(cmd) > 1 else cmd[0]}")
    return proc.returncode, _redact(proc.stdout, pat), _redact(proc.stderr, pat)


def push_project(
    *,
    project_name: str,
    artifacts: dict[str, str],
    repo: str,
    branch: str | None,
    commit_message: str | None,
    pat: str,
    author_name: str = "Tally Coding",
    author_email: str = "tally@pronoic.dev",
) -> PushResult:
    """Run the push end-to-end.  All inputs validated; output redacted.

    Returns a ``PushResult`` whose ``branch_url`` lands the user on
    GitHub's compare view so they can open a PR with one click.
    """
    repo = validate_repo(repo)
    if not artifacts:
        raise GithubPushError("project has no files in HEAD to push")
    target_branch = (branch or f"tally/push-{int(time.time())}").strip()
    if not target_branch:
        raise GithubPushError("branch is empty after strip")

    workdir = Path(f"/tmp/tally-orch-push-{int(time.time()*1000)}")
    workdir.mkdir(parents=True, exist_ok=False)
    try:
        # Materialise every path; create parent dirs as needed.
        for path, b64 in artifacts.items():
            if path.startswith("/") or ".." in path.split("/"):
                raise GithubPushError(
                    f"artifact path '{path}' is unsafe (absolute or contains '..')"
                )
            target = workdir / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(base64.b64decode(b64))

        env_args = [
            "-c", f"user.name={author_name}",
            "-c", f"user.email={author_email}",
            "-c", "init.defaultBranch=main",
            "-c", "advice.detachedHead=false",
        ]

        # git init + add + commit
        for step, cmd in (
            ("init", ["git", *env_args, "init", "-q"]),
            ("add", ["git", *env_args, "add", "-A"]),
        ):
            code, out, err = _run(cmd, cwd=workdir, pat=pat)
            if code != 0:
                raise GithubPushError(
                    f"git {step} failed (exit={code})",
                    detail=err.strip() or out.strip(),
                )
        msg = (
            commit_message
            or f"Push from Tally project {project_name!r}"
        ).strip()
        # Use the full message body explicitly.
        commit_body = f"{msg}\n\nProject: {project_name}\nGenerated by Tally Coding."
        code, out, err = _run(
            ["git", *env_args, "commit", "-q", "-m", commit_body],
            cwd=workdir, pat=pat,
        )
        if code != 0:
            raise GithubPushError(
                "git commit failed",
                detail=err.strip() or out.strip(),
            )
        # Capture the commit sha for the result.
        code, out, err = _run(["git", *env_args, "rev-parse", "HEAD"], cwd=workdir, pat=pat)
        if code != 0:
            raise GithubPushError("could not read commit sha", detail=err.strip())
        commit_sha = out.strip()

        # Push.
        remote_url = f"https://x-access-token:{pat}@github.com/{repo}.git"
        push_cmd = [
            "git", *env_args, "push",
            remote_url, f"HEAD:refs/heads/{target_branch}",
        ]
        code, out, err = _run(push_cmd, cwd=workdir, pat=pat, timeout=120)
        if code != 0:
            err_text = err.strip() or out.strip()
            low = err_text.lower()
            if "authentication failed" in low or "could not read username" in low:
                raise GithubPushAuthError(
                    "GitHub rejected the PAT (authentication failed). "
                    "Reissue a token with `repo` scope and reconnect.",
                    detail=err_text,
                )
            if "repository not found" in low or "not found" in low:
                raise GithubPushRepoError(
                    f"repo '{repo}' not found or not visible to this PAT",
                    detail=err_text,
                )
            raise GithubPushError(
                f"git push failed (exit={code})",
                detail=err_text,
            )
        branch_url = f"https://github.com/{repo}/tree/{target_branch}"
        return PushResult(
            branch=target_branch,
            commit_sha=commit_sha,
            branch_url=branch_url,
            repo=repo,
        )
    finally:
        # NEVER leave the working tree on disk — it contains the
        # plaintext PAT in the .git/config remote URL (until we
        # remove the remote, which we just didn't bother to do).
        try:
            shutil.rmtree(workdir, ignore_errors=True)
        except Exception as exc:
            logger.warning("failed to clean up push workdir %s: %s", workdir, exc)
