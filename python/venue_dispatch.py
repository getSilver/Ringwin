"""Relay committed execution commands over trusted Linux role connections."""

import struct

from venue_recovery import _receive

MAX_SNAPSHOT_BYTES = 32 * 1024 * 1024
MAX_CANONICAL_BYTES = 16 * 1024


def read_committed_snapshot(engine):
    engine.sendall(b"X")
    size, = struct.unpack("<I", _receive(engine, 4))
    if not 0 < size <= MAX_SNAPSHOT_BYTES:
        raise ValueError("invalid committed Writer snapshot size")
    return _receive(engine, size)


def relay_committed_commands(engine, gateway, command_ids):
    """Dispatch a bounded group and commit the receipts at the same Writer.

    The caller supplies identities observed at its committed Writer cutoff.
    A lost reply leaves the outcome unknown. The caller must reconcile before
    resuming this group.
    """
    ids = tuple(command_ids)
    if not 1 <= len(ids) <= 2 or len(set(ids)) != len(ids) or any(
            type(identity) is not int or not 0 < identity < 1 << 64 for identity in ids):
        raise ValueError("invalid committed command identities")
    snapshot = read_committed_snapshot(engine)
    receipts = []
    for identity in ids:
        gateway.sendall(b"Y" + struct.pack("<QI", identity, len(snapshot)))
        gateway.sendall(snapshot)
        if _receive(gateway, 4) != struct.pack("<I", 1):
            raise ValueError("invalid Gateway receipt count frame")
        count = _receive(gateway, 1)[0]
        if not 0 < count <= 64:
            raise ValueError("invalid Gateway receipt count")
        for _ in range(count):
            size, = struct.unpack("<I", _receive(gateway, 4))
            if not 0 < size < MAX_CANONICAL_BYTES:
                raise ValueError("invalid canonical receipt size")
            receipts.append(_receive(gateway, size))
    barrier = 0
    for receipt in receipts:
        engine.sendall(b"I" + struct.pack("<I", len(receipt)) + receipt)
        committed, extra = struct.unpack("<QI", _receive(engine, 12))
        if extra or committed < barrier:
            raise ValueError("invalid Writer receipt acknowledgment")
        barrier = committed
    return barrier
