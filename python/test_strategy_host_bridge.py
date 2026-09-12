"""Boundary checks for the framed StrategyHost pipe."""

import io
import unittest

import strategy_host as host


class BridgeFrameTests(unittest.TestCase):
    def test_recovery_frame_above_64_kib_round_trips(self):
        stream = io.BytesIO()
        payload = b"x" * (65_536 + 1)
        host.write_frame(stream, host.BEGIN_RECOVERY, (1, 0, 1), 1, payload)
        stream.seek(0)
        kind, session, sequence, actual = host.read_frame(stream)
        self.assertEqual((kind, session, sequence, actual), (host.BEGIN_RECOVERY, (1, 0, 1), 1, payload))

    def test_oversized_frame_rejected_before_payload_read(self):
        stream = io.BytesIO((host.HEADER_LEN + host.MAX_BRIDGE_PAYLOAD + 1).to_bytes(4, "little"))
        with self.assertRaisesRegex(ValueError, "invalid bridge frame length"):
            host.read_frame(stream)


if __name__ == "__main__":
    unittest.main()
