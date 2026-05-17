"""Two-party MLS session helper over Skytale's PyMlsEngine.

Wraps the raw MLS primitives for the worker/orchestrator pattern:
- Orchestrator creates the group and adds the worker via Welcome
- Worker joins via Welcome
- Both encrypt/decrypt application messages against the established group

The bootstrap dance (KeyPackage exchange + Welcome delivery) happens out-of-band
over Tally Workers wakes — public MLS artifacts only; no secrets leak through
the wake-routing layer.
"""

from __future__ import annotations

from skytale_sdk import MlsEngine


class MlsSessionError(Exception):
    pass


class MlsSession:
    """2-party MLS session backed by Skytale's MlsEngine.

    Both parties construct with the same ``group_id`` and their own identity bytes.
    The creator calls :meth:`create_and_add` with the joiner's KeyPackage to get a
    Welcome; the joiner calls :meth:`join` with that Welcome. After bootstrap,
    both can :meth:`encrypt` and :meth:`decrypt`.
    """

    def __init__(self, data_dir: str, identity: bytes, group_id: bytes) -> None:
        self.engine = MlsEngine(data_dir, identity)
        self.group_id = group_id
        self._bootstrapped = False

    def my_key_package(self) -> bytes:
        return self.engine.generate_key_package()

    def create_and_add(self, peer_key_package: bytes) -> bytes:
        """Creator path: build the group, add the peer, return the Welcome."""
        self.engine.create_group(self.group_id)
        _commit, welcome = self.engine.add_member(self.group_id, peer_key_package)
        self._bootstrapped = True
        return welcome

    def join(self, welcome_bytes: bytes) -> None:
        """Joiner path: process the Welcome and join the group it describes."""
        joined_group_id = self.engine.join_from_welcome(welcome_bytes)
        # The Welcome's embedded group_id is authoritative — adopt it.
        self.group_id = joined_group_id
        self._bootstrapped = True

    def encrypt(self, plaintext: bytes) -> bytes:
        if not self._bootstrapped:
            raise MlsSessionError("session not bootstrapped; call create_and_add or join first")
        return self.engine.encrypt(self.group_id, plaintext)

    def decrypt(self, ciphertext: bytes) -> bytes:
        if not self._bootstrapped:
            raise MlsSessionError("session not bootstrapped; call create_and_add or join first")
        return self.engine.decrypt(self.group_id, ciphertext)

    @property
    def bootstrapped(self) -> bool:
        return self._bootstrapped
