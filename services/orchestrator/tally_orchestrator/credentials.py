"""Sprint 38: encrypted per-user credentials store.

The orchestrator holds two kinds of sensitive per-user data:

  - **GitHub PAT** (Sprint 38): the user's personal access token for
    pushing project workspaces to a GitHub repo of their choice.
  - (Future) other long-lived credentials the user might paste in.

These need to be:

  - **Encrypted at rest** so a disk leak (despite TDX) doesn't expose
    PATs in plaintext.
  - **Never logged** at any level.  Even token prefixes risk
    correlation; we redact unconditionally.
  - **Decrypted only at point of use** — i.e. immediately before the
    HTTP call that uses them, never cached in memory.

Implementation: ``cryptography.fernet.Fernet`` with a master key
from ``CREDENTIALS_KEY`` env var.  Fernet bundles HMAC-SHA256 + AES-
128-CBC and is the recommended Python symmetric-encryption primitive
for this exact pattern.  Without ``CREDENTIALS_KEY`` set, the
``CredentialsManager`` reports ``configured=False`` and the related
endpoints 503 (so the orchestrator boots in lower-trust environments
without forcing operators to manage another key).
"""
from __future__ import annotations

import logging
import os
from dataclasses import dataclass

from cryptography.fernet import Fernet, InvalidToken

logger = logging.getLogger("tally.credentials")


@dataclass
class StoredCredential:
    user_id: str
    kind: str
    created_at: float
    updated_at: float


class CredentialsManager:
    """Owns the Fernet master key and the encrypt/decrypt path.

    Operators provide ``CREDENTIALS_KEY`` (urlsafe-base64-encoded
    32 bytes; ``Fernet.generate_key()`` is the canonical way to
    produce one).  Rotation requires re-encrypting existing rows
    against the new key — out of scope for v1, documented in the
    sprint open items.
    """

    def __init__(self) -> None:
        raw = os.environ.get("CREDENTIALS_KEY", "").strip()
        self._fernet: Fernet | None = None
        if not raw:
            logger.info(
                "CREDENTIALS_KEY not set; /github/* + other "
                "credential-backed routes will 503"
            )
            return
        try:
            self._fernet = Fernet(raw.encode())
        except Exception as exc:
            logger.error(
                "CREDENTIALS_KEY is invalid (must be urlsafe-base64-encoded "
                "32 bytes — use cryptography.fernet.Fernet.generate_key()): %s",
                exc,
            )

    @property
    def configured(self) -> bool:
        return self._fernet is not None

    def encrypt(self, plaintext: str) -> bytes:
        if self._fernet is None:
            raise RuntimeError("CREDENTIALS_KEY not configured")
        return self._fernet.encrypt(plaintext.encode("utf-8"))

    def decrypt(self, ciphertext: bytes) -> str:
        if self._fernet is None:
            raise RuntimeError("CREDENTIALS_KEY not configured")
        try:
            return self._fernet.decrypt(ciphertext).decode("utf-8")
        except InvalidToken as exc:
            raise ValueError(
                "credential decrypt failed — was CREDENTIALS_KEY rotated "
                "without re-encrypting stored rows?"
            ) from exc


def redact_token(token: str) -> str:
    """Safe-for-logs version: '<masked, len=N>' — never leaks any
    bytes of the secret, even prefixes.  GitHub PATs follow
    predictable formats (``ghp_*``, ``github_pat_*``) that aren't
    sensitive on their own, but treating all tokens uniformly avoids
    accidental partial exposure when a new token format ships."""
    if not token:
        return "<empty>"
    return f"<masked, len={len(token)}>"


def fernet_key_help() -> str:
    """Operator-facing string explaining how to generate a key.
    Surfaced in the 503 response detail so operators don't have to
    consult docs to fix the configuration."""
    return (
        "Generate one with: "
        "python -c 'from cryptography.fernet import Fernet; "
        "print(Fernet.generate_key().decode())' "
        "and set as CREDENTIALS_KEY on the orchestrator."
    )
