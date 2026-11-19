"""Linux role control acceptance against the compiled native executable."""
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform.startswith("linux"), "native Linux Unix-domain roles")
class LinuxProcessChainTests(unittest.TestCase):
    def setUp(self):
        self.engine = Path(os.environ.get("RINGWIN_LINUX_ENGINE", "zig-out/bin/ringwin")).resolve()
        self.assertTrue(self.engine.is_file(), "build the Linux ringwin executable first")
        directory = tempfile.TemporaryDirectory(prefix="rw-role-")
        self.addCleanup(directory.cleanup)
        self.state = Path(directory.name)
        self.endpoint = str(self.state / "control.sock")

    def spawn(self, *startup, role="engine", endpoint=None, cwd=ROOT):
        child = subprocess.Popen([str(self.engine), "--production-role", role,
            "--socket", endpoint or self.endpoint, *startup],
            cwd=cwd,
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(self.stop_child, child)
        return child

    def start(self, *startup):
        self.child = self.spawn(*(startup or ("--generation", "1")))
        self.peer = self.connect(self.child, self.endpoint)
        self.assertEqual(self.peer.recv(1), b"H")
        self.assertEqual(self.peer.recv(1), b"R")

    def connect(self, child, endpoint):
        peer = socket.socket(socket.AF_UNIX)
        self.addCleanup(peer.close)
        peer.settimeout(10)
        deadline = time.monotonic() + 5
        while True:
            try:
                peer.connect(endpoint)
                return peer
            except (FileNotFoundError, ConnectionRefusedError):
                if child.poll() is not None or time.monotonic() >= deadline:
                    self.fail("role did not listen before its startup deadline")
                time.sleep(0.02)

    @staticmethod
    def stop_child(child):
        if child.poll() is None:
            child.kill()
        child.wait(timeout=5)

    def command(self, command, expected):
        self.peer.sendall(command)
        self.assertEqual(self.peer.recv(1), expected)

    def test_risk_is_revoked_before_orderly_control_stop(self):
        self.start()
        self.command(b"A", b"A")
        self.command(b"D", b"G")
        self.command(b"S", b"T")
        self.assertEqual(self.child.wait(timeout=5), 0)

    def test_repeated_drain_cannot_extend_the_shutdown_deadline(self):
        self.start()
        self.command(b"A", b"A")
        self.command(b"D", b"G")
        self.command(b"D", b"X")
        self.assertNotEqual(self.child.wait(timeout=5), 0)

    def test_invalid_control_frame_fails_closed(self):
        self.start()
        self.command(b"?", b"X")
        self.assertNotEqual(self.child.wait(timeout=5), 0)

    def test_fixture_rejects_same_uid_process_other_than_parent(self):
        child = self.spawn("--generation", "1")
        deadline = time.monotonic() + 5
        while not Path(self.endpoint).exists():
            if child.poll() is not None or time.monotonic() >= deadline:
                self.fail("role did not listen before its startup deadline")
            time.sleep(0.02)
        subprocess.run([sys.executable, "-c",
            "import socket,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(2); "
            "s.connect(sys.argv[1]); assert s.recv(1) == b''", self.endpoint],
            check=True, timeout=5)
        self.assertNotEqual(child.wait(timeout=5), 0)

    @unittest.skipUnless(sys.platform.startswith("linux") and os.geteuid() == 0,
                         "managed controller requires root")
    def test_managed_generation_serializes_restarts_and_blocks_unsigned_enable(self):
        startup = ("--state-dir", str(self.state))
        generation = self.state / "generation"
        self.start(*startup)
        self.assertEqual(int.from_bytes(generation.read_bytes(), "little"), 1)
        self.assertNotEqual(self.spawn(*startup).wait(timeout=5), 0)
        self.command(b"A", b"X")
        self.assertNotEqual(self.child.wait(timeout=5), 0)
        self.start(*startup)
        self.assertEqual(int.from_bytes(generation.read_bytes(), "little"), 2)
        self.command(b"D", b"G")
        self.command(b"S", b"T")
        self.assertEqual(self.child.wait(timeout=5), 0)
        generation.write_bytes(b"invalid")
        self.assertNotEqual(self.spawn(*startup).wait(timeout=5), 0)
        self.assertEqual(generation.read_bytes(), b"invalid")

    @unittest.skipUnless(sys.platform.startswith("linux") and os.geteuid() == 0,
                         "managed controller requires root")
    def test_managed_generation_advances_after_controller_loses_the_role(self):
        startup = ("--state-dir", str(self.state))
        generation = self.state / "generation"
        self.start(*startup)
        self.child.kill()
        self.assertLess(self.child.wait(timeout=5), 0)
        self.start(*startup)
        self.assertEqual(int.from_bytes(generation.read_bytes(), "little"), 2)
        self.command(b"D", b"G")
        self.command(b"S", b"T")
        self.assertEqual(self.child.wait(timeout=5), 0)

    @unittest.skipUnless(sys.platform.startswith("linux") and os.geteuid() == 0,
                         "requires a distinct non-root peer")
    def test_managed_role_rejects_nonroot_peer_even_when_socket_is_accessible(self):
        child = self.spawn("--state-dir", str(self.state))
        deadline = time.monotonic() + 5
        while not Path(self.endpoint).exists():
            if child.poll() is not None or time.monotonic() >= deadline:
                self.fail("role did not listen before its startup deadline")
            time.sleep(0.02)
        self.state.chmod(0o755)
        Path(self.endpoint).chmod(0o777)
        subprocess.run([sys.executable, "-c",
            "import socket,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(2); "
            "s.connect(sys.argv[1]); assert s.recv(1) == b''", self.endpoint],
            user=65534, group=65534, extra_groups=[], check=True, timeout=5)
        self.assertNotEqual(child.wait(timeout=5), 0)

    def test_five_roles_commit_and_replay_fills_during_drain(self):
        run = subprocess.run([str(self.engine), "--production-chain-test"], cwd=ROOT,
                             capture_output=True, text=True, timeout=60)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        report = next(line for line in run.stdout.splitlines()
                      if line.startswith("production_chain: "))
        fields = dict(field.split("=", 1) for field in report.split()[1:])
        for key, value in {"venue": "SimulatedVenue", "roles": "5", "drain": "5",
                           "host": "python", "durable_fills": "2",
                           "risk_authorized": "false"}.items():
            self.assertEqual(fields.get(key), value, report)

    def test_engine_cannot_dispatch_when_strategy_host_fails_to_start(self):
        child = self.spawn("--generation", "1", cwd=self.state)
        peer = self.connect(child, self.endpoint)
        self.assertEqual(peer.recv(1), b"H")
        self.assertEqual(peer.recv(1), b"R")
        peer.sendall(b"A")
        self.assertEqual(peer.recv(1), b"A")
        # The isolated working directory has no Python Host entry point.
        peer.sendall(b"B")
        self.write_frame(peer, struct.pack("<QB", 50_000_000_000, 1))
        self.assertEqual(peer.recv(1), b"")
        self.assertNotEqual(child.wait(timeout=5), 0)

    @staticmethod
    def write_frame(peer, data):
        peer.sendall(struct.pack("<I", len(data)) + data)

    def read_frame(self, reader):
        header = reader.read(4)
        self.assertEqual(len(header), 4)
        size, = struct.unpack("<I", header)
        self.assertGreater(size, 0)
        self.assertLessEqual(size, 65536)
        data = reader.read(size)
        self.assertEqual(len(data), size)
        return data

    def test_pending_execution_output_prevents_orderly_stop(self):
        self.start()
        self.command(b"A", b"A")
        endpoint = str(self.state / "gateway.sock")
        gateway = self.spawn("--generation", "1", role="execution_gateway", endpoint=endpoint)
        peer = self.connect(gateway, endpoint)
        self.assertEqual(peer.recv(1), b"H")
        self.assertEqual(peer.recv(1), b"R")
        peer.sendall(b"A")
        self.assertEqual(peer.recv(1), b"A")

        self.peer.sendall(b"B")
        self.write_frame(self.peer, struct.pack("<QB", 50_000_000_000, 1))
        with self.peer.makefile("rb") as engine_reader, peer.makefile("rb") as gateway_reader:
            submission = self.read_frame(engine_reader)
            peer.sendall(b"B")
            self.write_frame(peer, submission)
            self.assertEqual(self.read_frame(gateway_reader), b"A")
            self.write_frame(self.peer, b"A")
            self.assertEqual(self.read_frame(engine_reader), b"A")

        self.command(b"D", b"G")
        peer.sendall(b"D")
        self.assertEqual(peer.recv(1), b"G")
        self.command(b"S", b"F")
        peer.sendall(b"S")
        self.assertEqual(peer.recv(1), b"F")
        self.assertNotEqual(self.child.wait(timeout=5), 0)
        self.assertNotEqual(gateway.wait(timeout=5), 0)


if __name__ == "__main__":
    unittest.main()
