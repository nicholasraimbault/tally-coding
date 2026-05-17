"""Worker pool — provisions and retires Phala TEE worker CVMs via the phala CLI.

Single-worker for now (Sprint 12). Multi-worker pool with per-session
MLS handles lands in Sprint 13+.

The orchestrator calls these synchronously through asyncio.to_thread; the
underlying `phala` invocations are subprocess calls that block on CVM
provisioning (~3 minutes) and identity-emission (~30s after running).
"""

from __future__ import annotations

import logging
import re
import secrets
import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

logger = logging.getLogger(__name__)

# Where the worker spike lives (Dockerfile + docker-compose.yml). The pool's
# phala-deploy invocation runs from this directory.
WORKER_DIR = Path(__file__).resolve().parents[3] / "spike" / "day4" / "worker"

# Base image that every per-deploy alias tag points at. Sprint 16 pushes a
# `v10-<team_id>` tag for each provision so parallel deploys end up with
# distinct App IDs (Phala derives the App ID from the compose hash, and
# `image:` is one of the few fields that survives Phala's normalization).
BASE_IMAGE = "ghcr.io/nicholasraimbault/tally-spike-day4-worker:v13"

# GHCR package name for the worker image (used by Sprint 17's GC).
GHCR_OWNER = "nicholasraimbault"
GHCR_PACKAGE = "tally-spike-day4-worker"
# Per-deploy tag prefix. GC targets only these — anything without this
# prefix (e.g. `v13`, `v12`, `v11`, `v10`) is preserved. Each base bump
# leaves the prior prefix behind for cleanup of leftover tags.
DEPLOY_TAG_PREFIX_V10 = "v10-tally-auto-"
DEPLOY_TAG_PREFIX_V11 = "v11-tally-auto-"
DEPLOY_TAG_PREFIX_V12 = "v12-tally-auto-"
DEPLOY_TAG_PREFIX = "v13-tally-auto-"


def _phala_binary() -> str:
    """Locate the phala CLI. systemd user units inherit the user's PATH;
    fall back to ~/.npm-global/bin if PATH doesn't pick it up."""
    on_path = shutil.which("phala")
    if on_path:
        return on_path
    fallback = Path.home() / ".npm-global" / "bin" / "phala"
    if fallback.exists():
        return str(fallback)
    raise RuntimeError(
        "phala CLI not found; install with: "
        "npm install --prefix ~/.npm-global -g phala"
    )


@dataclass
class WorkerInfo:
    cvm_id: str
    app_id: str | None
    team_id: str
    identity: str | None  # filled in after the worker prints its KeyPackage
    created_at: float


class WorkerPool:
    """Single-worker pool: one CVM at a time, swap on rotate or death."""

    def __init__(self, *, scripts_env_path: str, deploy_timeout_s: int = 180, identity_timeout_s: int = 300) -> None:
        self.scripts_env_path = scripts_env_path
        self.deploy_timeout_s = deploy_timeout_s
        self.identity_timeout_s = identity_timeout_s

    def provision(self) -> WorkerInfo:
        """Deploy a new worker CVM with a pre-generated Ed25519 keypair
        passed via env, against a per-deploy image tag pushed to GHCR. The
        unique image reference is what gives each CVM its own Phala App ID
        — Sprint 14 found that container_name, labels, volumes and command
        all get stripped from the compose before hashing, but `image:`
        survives, so swapping the tag is the cheapest way to bust the
        hash."""
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

        suffix = secrets.token_hex(3)
        team_id = f"tally-auto-{int(time.time())}-{suffix}"
        worker_name = f"tally-worker-{int(time.time())}-{suffix}"
        priv_obj = Ed25519PrivateKey.generate()
        privkey_hex = priv_obj.private_bytes_raw().hex()
        image_ref = self._ensure_unique_image_tag(team_id)
        env_file = self._build_env_file(team_id, privkey_hex)
        compose_file = self._build_compose_file(team_id, image_ref)
        info = self._deploy(worker_name, env_file, compose_file)
        info.team_id = team_id
        info.identity = self._await_identity(info.cvm_id)
        logger.info("worker %s ready: team=%s identity=%s...",
                    info.cvm_id[:8], team_id, (info.identity or "")[:12])
        return info

    def _ensure_unique_image_tag(self, team_id: str) -> str:
        """Build + push a *digest-distinct* per-deploy image to GHCR.

        Phala derives the App ID from a compose hash that resolves
        `image:` to its registry digest — so swapping the *tag* alone
        (pointing at the same manifest) doesn't change the App ID. We
        observed two parallel deploys with `v10-7ad21b` and `v10-02e174`
        both landing on the same App ID and the second failing with
        "This app_id already has an active CVM with a different
        configuration."

        The fix: add a tiny one-line layer (`LABEL`) on top of the base
        image. The label has no runtime effect but does change the
        manifest digest. Each `docker build` of `FROM v10 + LABEL=X`
        finishes in ~1s (no rebuild of underlying layers) and pushes
        in ~1s (only the new manifest + tiny layer).
        """
        safe = re.sub(r"[^a-zA-Z0-9_.-]", "-", team_id)
        tag_name = f"v13-{safe}"
        new_ref = f"ghcr.io/nicholasraimbault/tally-spike-day4-worker:{tag_name}"
        # Ensure the base image is locally cached so the FROM in the
        # one-line Dockerfile resolves.
        res = subprocess.run(
            ["docker", "pull", BASE_IMAGE],
            capture_output=True, text=True, timeout=300,
        )
        if res.returncode != 0:
            raise RuntimeError(f"docker pull failed for {BASE_IMAGE}:\n{res.stdout}\n{res.stderr}")
        # Per-deploy build context as a tiny Dockerfile passed via stdin.
        # The LABEL forces a new layer → new image digest → new compose
        # hash → new Phala App ID.
        dockerfile = (
            f"FROM {BASE_IMAGE}\n"
            f"LABEL tally.deploy_id=\"{team_id}\"\n"
        )
        res = subprocess.run(
            ["docker", "build", "-t", new_ref, "-"],
            input=dockerfile, capture_output=True, text=True, timeout=120,
        )
        if res.returncode != 0:
            raise RuntimeError(f"docker build failed for {new_ref}:\n{res.stdout}\n{res.stderr}")
        res = subprocess.run(
            ["docker", "push", new_ref],
            capture_output=True, text=True, timeout=120,
        )
        if res.returncode != 0:
            raise RuntimeError(f"docker push failed for {new_ref}:\n{res.stdout}\n{res.stderr}")
        logger.info("pushed per-deploy image %s (digest-distinct)", tag_name)
        return new_ref

    def _build_compose_file(self, team_id: str, image_ref: str) -> Path:
        """Generate a per-deploy compose with the per-team image ref
        substituted into the `image:` line. Phala's KMS hashes the compose
        into the App ID; swapping the image tag changes the hash so
        parallel deploys land in distinct App IDs (and therefore distinct
        KMS nonce records, avoiding the UNIQUE(address) race that bit
        Sprint 14's serial workaround)."""
        src = WORKER_DIR / "docker-compose.yml"
        target = Path("/tmp") / f"tally-auto-compose-{team_id}.yml"
        content = src.read_text()
        # Replace the base image ref with the per-deploy alias. Match the
        # full registry+name+tag form so we don't accidentally rewrite a
        # comment or a different field.
        content = re.sub(
            r"image:\s*ghcr\.io/nicholasraimbault/tally-spike-day4-worker:[a-zA-Z0-9_.-]+",
            f"image: {image_ref}",
            content,
        )
        target.write_text(content)
        return target

    def gc_image_versions(
        self,
        *,
        keep_team_ids: set[str],
        older_than_seconds: int = 3600,
        dry_run: bool = False,
    ) -> dict:
        """Garbage-collect stale package versions from GHCR.

        Two categories of cruft accumulate after Sprint 16's per-deploy
        build flow:

        1. **Per-deploy tagged versions** (`v10-tally-auto-<team_id>`) whose
           owning worker has been retired. Each pool.provision pushes one
           new tag; retired workers' tags linger forever without cleanup.
        2. **Orphaned untagged versions** — manifests that had a tag at
           push time but got overwritten by a later push of the same tag.
           These accumulate silently and don't help anyone.

        `keep_team_ids` is the set of `team_id`s that map to currently
        active workers — their tags are preserved no matter how old.
        `older_than_seconds` guards against deleting a tag whose worker
        just got retired (e.g. mid-rotation). The default 1h is enough
        for normal turnover.

        Uses `gh api` for the GHCR REST calls — the orchestrator host
        already has `gh` authed for `docker push` to land. Returns a
        dict summarising kept / removed / would-remove versions."""
        # gh is the authenticated GitHub CLI. The keyring token is fine for
        # listing versions, but DELETE requires `delete:packages` scope
        # which gh's default auth doesn't have. If
        # `~/.config/tally-orch/ghcr-token` exists, we point GH_TOKEN at it
        # (the user creates a PAT with the delete:packages scope via the
        # zenity flow documented in SPRINT-17-COMPLETE.md).
        gh = shutil.which("gh")
        if gh is None:
            raise RuntimeError("gh CLI not found; cannot reach GHCR API")
        env = None
        token_path = Path.home() / ".config" / "tally-orch" / "ghcr-token"
        if token_path.exists():
            import os
            env = {**os.environ, "GH_TOKEN": token_path.read_text().strip()}
        # List all versions (paginated). Each entry has `id`, `name`
        # (sha256:...), `created_at`, `updated_at`, and
        # `metadata.container.tags` (list).
        res = subprocess.run(
            [gh, "api", "--paginate",
             f"/user/packages/container/{GHCR_PACKAGE}/versions"],
            capture_output=True, text=True, timeout=60, env=env,
        )
        if res.returncode != 0:
            raise RuntimeError(f"gh api list versions failed:\n{res.stderr}")
        import json
        versions = json.loads(res.stdout)
        now_ms = int(time.time() * 1000)

        def _is_older(ts_iso: str) -> bool:
            # GHCR returns ISO-8601 with trailing Z.
            from datetime import datetime, timezone
            dt = datetime.strptime(ts_iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
            return (now_ms - int(dt.timestamp() * 1000)) > older_than_seconds * 1000

        eligible: list[dict] = []
        kept_for_active: list[dict] = []
        kept_for_protected_tag: list[dict] = []
        kept_for_age: list[dict] = []
        for v in versions:
            tags = v.get("metadata", {}).get("container", {}).get("tags", []) or []
            updated = v.get("updated_at") or v.get("created_at")
            summary = {"id": v["id"], "digest": v["name"][:19], "tags": tags, "updated": updated}
            # Tagged version: only auto-deploy tags are GC targets.
            if tags:
                auto_prefixes = (DEPLOY_TAG_PREFIX, DEPLOY_TAG_PREFIX_V12,
                                 DEPLOY_TAG_PREFIX_V11, DEPLOY_TAG_PREFIX_V10)
                def _is_auto(t: str) -> bool:
                    return any(t.startswith(p) for p in auto_prefixes)
                has_protected = any(not _is_auto(t) for t in tags)
                if has_protected:
                    kept_for_protected_tag.append(summary)
                    continue
                # Map tag → team_id (`v{N}-tally-auto-<team_id>`).
                # Skip if any tag's team_id is in the active set.
                def _team_id(t: str) -> str:
                    for p in auto_prefixes:
                        if t.startswith(p):
                            return t[len(p):]
                    return ""
                team_ids = [_team_id(t) for t in tags if _is_auto(t)]
                if any(t in keep_team_ids for t in team_ids):
                    kept_for_active.append(summary)
                    continue
            if not _is_older(updated):
                kept_for_age.append(summary)
                continue
            eligible.append(summary)

        removed: list[dict] = []
        errors: list[dict] = []
        if not dry_run:
            for v in eligible:
                res = subprocess.run(
                    [gh, "api", "-X", "DELETE",
                     f"/user/packages/container/{GHCR_PACKAGE}/versions/{v['id']}"],
                    capture_output=True, text=True, timeout=30, env=env,
                )
                if res.returncode != 0:
                    errors.append({**v, "error": res.stderr.strip()})
                else:
                    removed.append(v)
        return {
            "dry_run": dry_run,
            "total_versions": len(versions),
            "eligible": eligible if dry_run else [],
            "removed": removed,
            "errors": errors,
            "kept": {
                "active_worker_tag": len(kept_for_active),
                "protected_tag": len(kept_for_protected_tag),
                "too_recent": len(kept_for_age),
            },
        }

    def delete(self, cvm_id: str) -> None:
        """Tear down a CVM. Non-fatal if it's already gone."""
        try:
            # `phala cvms delete` prompts y/N; pipe "y" in.
            subprocess.run(
                [_phala_binary(), "cvms", "delete", "--cvm-id", cvm_id],
                input="y\n", text=True, timeout=60, capture_output=True, check=False,
            )
            logger.info("deleted CVM %s", cvm_id[:8])
        except subprocess.TimeoutExpired:
            logger.warning("delete CVM %s timed out (may still be in progress on Phala side)", cvm_id[:8])

    def _build_env_file(self, team_id: str, privkey_hex: str) -> Path:
        """Build a per-deploy env file with TEAM_ID + pre-generated worker
        private key (hex). Sprint 14: passing the privkey via env removes any
        dependence on per-CVM disk state — Phala shares /workspace across
        CVMs in the same app, and the docker-compose ${VAR:-default}
        interpolation doesn't get the env file's vars at the right phase,
        so file-based key isolation was unreliable. The env value, by
        contrast, ends up in the container directly via the `phala deploy -e`
        flow and is the source of truth for the worker's identity.
        """
        target = Path("/tmp") / f"tally-auto-{team_id}.env"
        with open(self.scripts_env_path) as src:
            base = src.read()
        target.write_text(
            base.rstrip()
            + f"\nTEAM_ID={team_id}"
            + f"\nWORKER_PRIVKEY_HEX={privkey_hex}\n"
        )
        target.chmod(0o600)
        return target

    def _deploy(self, name: str, env_file: Path, compose_file: Path) -> WorkerInfo:
        """Run `phala deploy` from the worker spike dir; parse CVM id + app id."""
        if not WORKER_DIR.exists():
            raise RuntimeError(f"worker spike dir missing: {WORKER_DIR}")
        cmd = [
            _phala_binary(), "deploy",
            "-c", str(compose_file),
            "-e", str(env_file),
            "--name", name,
        ]
        logger.info("provisioning worker %s via phala deploy...", name)
        res = subprocess.run(
            cmd, cwd=str(WORKER_DIR), capture_output=True, text=True,
            timeout=self.deploy_timeout_s,
        )
        if res.returncode != 0:
            raise RuntimeError(f"phala deploy failed (rc={res.returncode}):\n{res.stdout}\n{res.stderr}")
        cvm_id = self._parse_field(res.stdout, "CVM ID:")
        app_id = self._parse_field(res.stdout, "App ID:")
        if not cvm_id:
            raise RuntimeError(f"phala deploy output didn't include CVM ID:\n{res.stdout}")
        return WorkerInfo(cvm_id=cvm_id, app_id=app_id, team_id="", identity=None, created_at=time.time())

    def _await_identity(self, cvm_id: str) -> str:
        """Poll `phala cvms logs` for the worker's identity= line."""
        deadline = time.monotonic() + self.identity_timeout_s
        identity_re = re.compile(r"identity=([A-Za-z0-9_-]{40,})")
        while time.monotonic() < deadline:
            res = subprocess.run(
                [_phala_binary(), "cvms", "logs", cvm_id],
                capture_output=True, text=True, timeout=30, check=False,
            )
            # `phala cvms logs` returns nonzero with "No containers found" while
            # the container is still starting; that's expected.
            m = identity_re.search(res.stdout or "")
            if m:
                return m.group(1)
            # Surface obvious crash signatures so we don't keep polling forever
            if any(s in (res.stdout or "") for s in ("Traceback", "PermissionError", "ModuleNotFoundError")):
                raise RuntimeError(f"worker {cvm_id[:8]} crashed before emitting identity:\n{res.stdout[-2000:]}")
            time.sleep(8)
        raise TimeoutError(f"worker {cvm_id[:8]} did not emit identity within {self.identity_timeout_s}s")

    @staticmethod
    def _parse_field(text: str, label: str) -> str | None:
        for line in text.splitlines():
            if line.strip().startswith(label):
                return line.split(":", 1)[1].strip()
        return None
