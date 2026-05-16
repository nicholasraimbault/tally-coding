"""Tests for identity helpers."""

from tally_coding_core.identity import bearer_from_pubkey


def test_bearer_from_pubkey_is_url_safe_base64_no_padding():
    pubkey = b"\x00" * 32  # 32 zero bytes
    bearer = bearer_from_pubkey(pubkey)
    # 32 bytes -> 44 base64 chars w/ padding; we strip = chars
    assert "=" not in bearer
    assert "+" not in bearer
    assert "/" not in bearer
    assert len(bearer) == 43  # 32 * 8 / 6 = 42.67 -> 43


def test_bearer_round_trip_with_known_pubkey():
    # 32 known bytes
    pubkey = bytes(range(32))
    bearer = bearer_from_pubkey(pubkey)
    # Decode back
    import base64
    decoded = base64.urlsafe_b64decode(bearer + "=" * (-len(bearer) % 4))
    assert decoded == pubkey
