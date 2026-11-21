"""Crash and replay a persisted Venue input through the formal Linux roles."""

from contextlib import contextmanager
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time

from venue_recovery import recover_market_inputs
from verify_production_strategy_web import child, receive


@contextmanager
def role(binary, name, state, control):
    command = [binary, "--production-role", name, "--socket", str(control), "--state-dir", str(state)]
    with child(command) as process, socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(20)
        for _ in range(100):
            try:
                connection.connect(str(control))
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if process.poll() is not None:
                    raise RuntimeError(f"{name} exited during startup")
                time.sleep(0.05)
        else:
            raise RuntimeError(f"{name} control socket did not start")
        assert receive(connection, 2) == (b"HV" if name == "engine" else b"HR")
        yield process, connection


def read_committed(engine, cursor):
    records = []
    while True:
        engine.sendall(b"C" + struct.pack("<Q", cursor))
        sequence, size = struct.unpack("<QI", receive(engine, 12))
        if size == 0:
            assert sequence == cursor
            return cursor, records
        assert sequence == cursor + 1
        records.append(bytes(receive(engine, 41 + size)))
        cursor = sequence


def main(binary, provision):
    with tempfile.TemporaryDirectory(prefix="rw07-recovery-") as directory:
        root = Path(directory)
        core, feed = root / "core", root / "feed"
        core.mkdir()
        feed.mkdir()
        engine_socket, feed_socket = root / "engine.sock", root / "market.sock"
        setup = subprocess.run([provision, str(core), "--with-recovery"],
                               stderr=subprocess.PIPE, text=True, check=True, timeout=30)
        start = int(setup.stderr.strip().split("=")[-1])
        with role(binary, "engine", core, engine_socket) as (process, engine):
            before, _ = read_committed(engine, start)
            engine.sendall(b"U" + struct.pack("<QQQQI", 1, 77, 9000, 2, 0))
            assert receive(engine, 1) == b"V"
            with role(binary, "market_feed", feed, feed_socket) as (_, market):
                assert recover_market_inputs(engine, market) == (0, b"V")
            assert read_committed(engine, before) == (before, [])
            subprocess.run([provision, "--capture", str(feed)], check=True, timeout=30)
            assert read_committed(engine, before) == (before, [])
            process.kill()
            process.wait(timeout=15)

        with role(binary, "market_feed", feed, feed_socket) as (_, market):
            with role(binary, "engine", core, engine_socket) as (_, engine):
                assert read_committed(engine, before) == (before, [])
                assert recover_market_inputs(engine, market) == (2, b"R")
                committed, records = read_committed(engine, before)
                venue_inputs = [record for record in records if (record[4] & 1) and record[41] == 2]
                assert len(venue_inputs) == 3
            with role(binary, "engine", core, engine_socket) as (_, engine):
                assert recover_market_inputs(engine, market) == (2, b"R")
                assert read_committed(engine, before) == (committed, records)
                assert read_committed(engine, committed) == (committed, [])

        print(f"production_venue_recovery: raw=2 canonical=3 writer_before={before} writer_after={committed} "
              "repeated_recovery=identical empty_and_missing_capture=RecoveryOnly")


if __name__ == "__main__":
    main(*map(os.path.abspath, sys.argv[1:]))
