"""Boundary checks for the framed StrategyHost pipe."""

import io
import struct
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


class DepthSnapshotTests(unittest.TestCase):
    def wire(self):
        payload = bytearray(704)
        payload[:16] = (123).to_bytes(16, "little")
        struct.pack_into("<QQQ", payload, 16, 7, 100, 1800000000000000001)
        payload[40:44] = bytes((2, 2, 1, 0))
        for index, (ticks, lots) in enumerate(((999, 4), (998, 5), (1001, 2), (1002, 3))):
            slot = index if index < 2 else index + 6
            offset = 64 + slot * 40
            payload[offset:offset + 16] = ticks.to_bytes(16, "little", signed=True)
            payload[offset + 16] = 1
            payload[offset + 24:offset + 40] = lots.to_bytes(16, "little", signed=True)
        return payload

    def test_host_receives_symmetric_integer_depth_and_coverage(self):
        decoded = host.decode_depth_snapshot(self.wire())
        self.assertEqual(decoded["bids"], ((999, 4), (998, 5)))
        self.assertEqual(decoded["asks"], ((1001, 2), (1002, 3)))
        self.assertEqual((decoded["instrument"], decoded["rules_version"], decoded["sequence"]), (123, 7, 100))
        self.assertTrue(decoded["bids_truncated"])
        self.assertFalse(decoded["asks_truncated"])

    def test_depth_encoder_reuses_canonical_wire_and_rejects_bad_units(self):
        decoded = host.decode_depth_snapshot(self.wire())
        self.assertEqual(host.encode_depth_snapshot(decoded), bytes(self.wire()))
        missing = dict(decoded, asks=((1001, 0), (1002, None)))
        self.assertEqual(host.decode_depth_snapshot(host.encode_depth_snapshot(missing)), missing)
        with self.assertRaises(ValueError):
            host.encode_depth_snapshot(dict(decoded, instrument=True))

    def test_capture_sequence_is_preserved_without_venue_continuity(self):
        payload = self.wire()
        payload[44] = 1
        payload[48:56] = (2).to_bytes(8, "little")
        book = host.decode_depth_snapshot(payload)
        self.assertEqual(book["sequence_kind"], "capture")
        self.assertEqual(book["capture_epoch"], 2)
        self.assertEqual(host.encode_depth_snapshot(book), bytes(payload))

    def test_absent_quantity_is_distinct_from_zero(self):
        payload = self.wire()
        offset = 64 + 9 * 40
        payload[offset + 24:offset + 40] = bytes(16)
        self.assertEqual(host.decode_depth_snapshot(payload)["asks"][1], (1002, 0))
        payload[offset + 16] = 0
        self.assertEqual(host.decode_depth_snapshot(payload)["asks"][1], (1002, None))

    def test_invalid_capacity_partial_tail_and_order_fail_closed(self):
        variants = []
        for field, value in ((40, 9), (41, 0), (42, 2), (44, 2), (64 + 2 * 40, 1)):
            bad = self.wire()
            bad[field] = value
            variants.append(bad)
        variants.append(self.wire()[:-1])
        bad = self.wire()
        bad[64 + 40:64 + 56] = (1000).to_bytes(16, "little")
        variants.append(bad)
        for payload in variants:
            with self.subTest(payload=payload[:44]), self.assertRaises(host.RecoveryNeeded):
                host.decode_depth_snapshot(payload)


if __name__ == "__main__":
    unittest.main()
