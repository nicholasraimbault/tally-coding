"""Identity helpers: AgentIdentity loader + Tally Bearer derivation."""

from __future__ import annotations

import base64


def bearer_from_pubkey(pubkey: bytes) -> str:
    """Compute Tally Workers Bearer token from an Ed25519 public key.

    MVP bearer semantics (per Tally Phase 1B D5): Bearer = url_safe_b64(pubkey),
    no padding. Phase 2 will replace this with real API keys; wire contract
    stable across the transition.
    """
    if len(pubkey) != 32:
        raise ValueError(f"expected 32-byte Ed25519 pubkey; got {len(pubkey)} bytes")
    return base64.urlsafe_b64encode(pubkey).decode().rstrip("=")


def load_or_create_identity(path: str) -> tuple[bytes, bytes]:
    """Load (privkey, pubkey) Ed25519 pair from disk; create if missing.

    Returns 32-byte private key, 32-byte public key.
    """
    import pathlib

    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    p = pathlib.Path(path)
    if p.exists():
        privkey = p.read_bytes()
        pkey_obj = Ed25519PrivateKey.from_private_bytes(privkey)
        pubkey = pkey_obj.public_key().public_bytes_raw()
    else:
        pkey_obj = Ed25519PrivateKey.generate()
        privkey = pkey_obj.private_bytes_raw()
        pubkey = pkey_obj.public_key().public_bytes_raw()
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(privkey)
        p.chmod(0o600)
    return privkey, pubkey
