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
        passed via env. The CVM uses this directly as its MLS identity, so
        two parallel provisions land in distinct identities even when Phala
        collapses their docker-compose into a single shared App ID."""
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

        suffix = secrets.token_hex(3)
        team_id = f"tally-auto-{int(time.time())}-{suffix}"
        worker_name = f"tally-worker-{int(time.time())}-{suffix}"
        priv_obj = Ed25519PrivateKey.generate()
        privkey_hex = priv_obj.private_bytes_raw().hex()
        env_file = self._build_env_file(team_id, privkey_hex)
        compose_file = self._build_compose_file(team_id)
        info = self._deploy(worker_name, env_file, compose_file)
        info.team_id = team_id
        info.identity = self._await_identity(info.cvm_id)
        logger.info("worker %s ready: team=%s identity=%s...",
                    info.cvm_id[:8], team_id, (info.identity or "")[:12])
        return info

    def _build_compose_file(self, team_id: str) -> Path:
        """Generate a per-deploy compose. With Sprint 14's WORKER_PRIVKEY_HEX
        env-passing model (worker:v10+) the compose doesn't need to differ
        between deploys for correctness — Phala's app dedup is fine here
        since each CVM gets its own env + key via the env file. We still
        write a per-team file just to keep the deploy-time inputs isolated
        and easy to inspect at /tmp/tally-auto-compose-*.yml."""
        src = WORKER_DIR / "docker-compose.yml"
        target = Path("/tmp") / f"tally-auto-compose-{team_id}.yml"
        target.write_text(src.read_text())
        return target

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
