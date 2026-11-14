"""Rolling scanner history uses process memory, never a database or replay log."""
import hashlib
import unittest

from opportunity_scanner.scanner_history import History

DAY = 86_400_000
THRESHOLD = dict(version="1", min_profit_atoms="0", min_probability_ppm=0)


def candidate(identity="pair", **changes):
    return dict(id=identity, status="evaluated", recommended=True, reason="", plan_atoms="8000000",
        probability_lower_ppm=680000, quantity_base=["1", "1"], model_hash="model", policy_version="1",
        calibration_version="1", base_asset="2", quote_asset="1", pair=[["1", "20", "101"], ["21", "30", "102"]],
        mode="taker_taker", maker_leg=None, direction=1, **changes)


def envelope(sequence, wall_ms, rows):
    return dict(session="session", sequence=str(sequence), config_version="1", evidence=[],
        snapshot=dict(at_ns=str(wall_ms*1_000_000), candidates=rows))


class HistoryTests(unittest.TestCase):
    def make(self, **options):
        now = [0]
        history = History(clock=lambda: now[0], **options)
        self.addCleanup(history.close)
        return history, now

    def batch(self, history, sequence, at, rows, evidence=None):
        message = envelope(sequence, at, rows)
        message["evidence"] = list(evidence or {})
        history.batch(message, wall_ms=at, threshold=THRESHOLD, evidence=evidence or {})
        return message

    def test_no_restart_history_and_rolling_24_hour_expiry(self):
        history, now = self.make()
        self.batch(history, 1, 0, [candidate()])
        history.interrupt("session", "stopped")
        now[0] = DAY
        self.assertEqual(len(history.query("events")), 1)  # inclusive lower bound
        now[0] += 1
        self.assertEqual(history.query("events"), [])
        self.assertEqual(history.summarize()["groups"], {})
        self.assertEqual(History(clock=lambda: now[0]).query("events"), [])

    def test_event_crossing_window_is_counted_once_with_clipped_duration(self):
        history, now = self.make()
        self.batch(history, 1, 0, [candidate()])
        now[0] = 23*3_600_000
        self.batch(history, 2, now[0], [candidate()])
        now[0] = 25*3_600_000
        row, = history.query("events")
        self.assertTrue(row["started_before_window"])
        self.assertEqual(row["window_duration_ns"], str(22*3_600_000*1_000_000))
        summary = history.summarize()
        self.assertEqual(sum(g["events"] for g in summary["groups"].values()), 1)
        self.assertEqual(sum(g["carried_in"] for g in summary["groups"].values()), 1)
        self.assertEqual(summary["window_start_wall_ms"], str(3_600_000))
        self.assertEqual(summary, history.summarize())

    def test_duplicate_conflict_and_bad_evidence_leave_history_unchanged(self):
        history, now = self.make()
        message = self.batch(history, 1, 0, [candidate()])
        history.batch(message, wall_ms=0, threshold=THRESHOLD, evidence={})
        self.assertEqual(len(history.query("events")), 1)
        with self.assertRaisesRegex(ValueError, "conflict"):
            history.batch(dict(message, config_version="2"), wall_ms=0, threshold=THRESHOLD, evidence={})
        with self.assertRaisesRegex(ValueError, "digest"):
            self.batch(history, 2, 1, [candidate("other")], {"bad": "material"})
        self.assertEqual(len(history.query("events")), 1)
        self.assertEqual(len(history.query("batches")), 1)

    def test_threshold_end_and_interruption_have_different_duration_semantics(self):
        history, now = self.make()
        self.batch(history, 1, 0, [candidate()])
        now[0] = 10
        self.batch(history, 2, 10, [{**candidate(), "recommended": False}])
        row, = history.query("events")
        self.assertFalse(row["right_censored"])
        self.assertEqual(row["duration_ns"], "10000000")
        now[0] = 20
        self.batch(history, 3, 20, [candidate()])
        now[0] = 30
        self.batch(history, 4, 30, [{**candidate(), "recommended": False, "reason": "expired", "status": "pending"}])
        row = history.query("events")[-1]
        self.assertTrue(row["right_censored"])
        self.assertEqual(row["duration_ns"], "0")

    def test_evidence_and_batch_cache_eviction_preserve_event_statistics(self):
        history, now = self.make(max_batches=1, max_evidence_bytes=8)
        first = "first"
        digest = hashlib.sha256(first.encode()).hexdigest()
        self.batch(history, 1, 0, [candidate()], {digest: first})
        now[0] = 1
        second = "other"
        self.batch(history, 2, 1, [candidate()], {hashlib.sha256(second.encode()).hexdigest(): second})
        row, = history.query("events")
        self.assertFalse(row["replayable"])
        self.assertEqual(len(history.query("batches")), 1)
        self.assertIsNone(history.artifact(digest))
        self.assertEqual(sum(g["events"] for g in history.summarize()["groups"].values()), 1)
        self.assertEqual(history.status()["gaps"], [])

    def test_capacity_loss_is_reported_without_claiming_complete_history(self):
        history, now = self.make(max_records=2)
        self.batch(history, 1, 0, [candidate("a"), candidate("b"), candidate("c")])
        self.assertLessEqual(len(history.query("events")), 2)
        self.assertTrue(history.status()["gaps"])
        self.assertFalse(history.summarize()["coverage_complete"])

    def test_filters_pagination_and_materials_are_detached_from_callers(self):
        history, now = self.make()
        rows = [candidate("a"), {**candidate("b"), "direction": -1}]
        self.batch(history, 1, 0, rows)
        rows[0]["plan_atoms"] = "0"
        selected = history.query("events", direction=-1, asset="2", venue="21")
        self.assertEqual(selected[0]["payload"]["candidate"]["id"], "b")
        selected[0]["payload"]["candidate"]["id"] = "changed"
        self.assertEqual(history.query("events", direction=-1)[0]["payload"]["candidate"]["id"], "b")
        pages = history.query("events", limit=1)+history.query("events", offset=1, limit=1)
        self.assertEqual({row["payload"]["candidate"]["id"] for row in pages}, {"a", "b"})

    def test_request_identity_state_is_bounded_and_separate_from_24h_history(self):
        history, now = self.make(max_requests=1)
        history.request("1", {"selector": "pair"}, {"status": "unknown"})
        now[0] = DAY+1
        self.assertEqual(history.request("1")["response"]["status"], "unknown")
        with self.assertRaisesRegex(ValueError, "conflict"):
            history.request("1", {"selector": "different"})
        with self.assertRaisesRegex(OSError, "request capacity"):
            history.request("2", {"selector": "other"}, {"status": "pending"})
        history.request("1", response={"status": "accepted"})
        self.assertEqual(history.request("1")["response"]["status"], "accepted")
        with self.assertRaisesRegex(ValueError, "unknown scanner request"):
            History(clock=lambda: now[0]).request("1")

    def test_expired_closed_event_does_not_detach_reopened_event(self):
        history, now = self.make()
        self.batch(history, 1, 0, [candidate()])
        now[0] = 1
        self.batch(history, 2, 1, [{**candidate(), "recommended": False}])
        now[0] = 2
        self.batch(history, 3, 2, [candidate()])
        now[0] = DAY
        self.batch(history, 4, DAY, [candidate()])
        now[0] = DAY+2
        self.assertEqual(len(history.query("events")), 1)
        self.batch(history, 5, now[0], [candidate()])
        self.assertEqual(len(history.query("events")), 1)

    def test_changed_threshold_conflicts_even_after_batch_cache_eviction(self):
        history, now = self.make(max_batches=1)
        message = self.batch(history, 1, 0, [candidate()])
        with self.assertRaisesRegex(ValueError, "conflict"):
            history.batch(message, wall_ms=0, threshold={**THRESHOLD, "min_profit_atoms": "1"}, evidence={})
        now[0] = 1
        latest = self.batch(history, 2, 1, [candidate()])
        # Byte pressure can remove the raw batch but must retain its identity head.
        history.max_bytes = 1
        history.record("operations", "op", {})
        with self.assertRaisesRegex(ValueError, "conflict"):
            history.batch(latest, wall_ms=1, threshold={**THRESHOLD, "min_profit_atoms": "1"}, evidence={})


if __name__ == "__main__":
    unittest.main()
