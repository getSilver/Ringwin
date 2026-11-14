"""Synthetic development evidence; never market qualification."""
from dataclasses import replace
from pathlib import Path
import tempfile
import unittest
from fractions import Fraction as F
import json

from strategies.cross_venue import arbitrage_baseline as b
from strategies.cross_venue import arbitrage_research as r


def protocol(**changes):
    values = dict(version="research-1", data_hash="a"*64, code_hash="b"*64,
                  dependency_ref="python-3.9-stdlib", seed=7,
                  intervals=((0, 100), (120, 220), (240, 340), (360, 460)),
                  max_span_ns=20, candidates=("c"*64, "d"*64), max_trials=2,
                  min_blocks=2, min_cycles=2, max_drawdown_atoms=20,
                  max_tail_loss_atoms=15, coverage_ppm=900000, min_profit_atoms=1)
    values.update(changes)
    return r.Protocol(**values)


def sample(at, nav, flow=0):
    return r.Equity(at, nav, flow)


def outcome(identity, start, end, block, profit=5):
    return r.Outcome(identity, "pair-A", start, end, block, profit, 7, 9,
                     True, True, False, False)


def report_inputs():
    return dict(equity=(sample(240, 100), sample(260, 130, 20), sample(339, 125, 20)),
                cycles=(outcome("one", 245, 255, "block-1"),
                        outcome("two", 270, 280, "block-2", -5)))


class ResearchTests(unittest.TestCase):
    def test_temporal_partition_is_global_and_purges_incomplete_intervals(self):
        p = protocol()
        self.assertEqual(p.partition(20, 40, 40), "train")
        self.assertEqual(p.partition(90, 100, 100), None)
        self.assertEqual(p.partition(120, 140, 139), None)
        self.assertEqual(p.partition(100, 110, 110), None)
        with self.assertRaisesRegex(b.Rejected, "isolation"):
            protocol(intervals=((0, 100), (119, 220), (240, 340), (360, 460)))

    def test_actual_label_tracker_output_is_mature_before_partitioning(self):
        s = b.SECOND
        policy = protocol(intervals=tuple((a*s, z*s) for a, z in
                          ((0, 400), (700, 1100), (1400, 1800), (2100, 2500))), max_span_ns=300*s)
        model = b.AR1(1, 0, 0., .9, .01, .01, .001, .001)
        tracker = b.LabelTracker(4)
        tracker.add(model.predict(b.Point(10*s, 1, .1), 300, 1))
        label = tracker.advance(b.Point(310*s, 2, .05))[0]
        self.assertEqual(policy.label_partition(label, at_ns=310*s), "train")
        self.assertIsNone(policy.label_partition(label, at_ns=309*s))
        tracker.add(model.predict(b.Point(320*s, 3, .1), 300, 1))
        crossing = tracker.advance(b.Point(620*s, 4, .05))[0]
        self.assertIsNone(policy.label_partition(crossing, at_ns=620*s))

    def test_full_equity_keeps_external_flows_losses_and_synthetic_status(self):
        result = r.summarize(protocol(), "validation", "c"*64, **report_inputs())
        self.assertEqual((result.profit_atoms, result.drawdown_atoms, result.tail_loss_atoms), (5, 5, 5))
        self.assertEqual(result.plan_overestimate_atoms, F(7))
        self.assertEqual((result.complete_cycles, result.declared_blocks), (2, 2))
        self.assertEqual(result.equity, report_inputs()["equity"])
        self.assertFalse(result.economic_qualified)
        self.assertIn("synthetic_input", result.failures)

    def test_unknown_cross_boundary_rejections_and_downtime_are_retained(self):
        inputs = report_inputs()
        inputs["cycles"] += (replace(outcome("unknown", 300, None, "block-3", None),
                                      profit_atoms=None, entry_hit=None, hold_hit=None),
                             outcome("crossing", 330, 350, "block-4"),
                             replace(outcome("reject", 290, 291, "block-5", 0), rejected=True, stopped=True),
                             outcome("carry-in", 230, 250, "block-6"))
        result = r.summarize(protocol(), "validation", "c"*64, **inputs)
        self.assertEqual((result.unresolved_cycles, result.rejections, result.stops), (3, 1, 1))
        self.assertIn("unresolved_risk", result.failures)
        self.assertEqual(len(result.cycles), 6)
        self.assertEqual(result.occupancy_upper_ns, None)

    def test_insufficient_or_absent_real_evidence_never_qualifies(self):
        result = r.summarize(protocol(min_blocks=3), "validation", "c"*64,
                             source_kind="historical", **report_inputs())
        self.assertIn("insufficient_blocks", result.failures)
        self.assertIn("external_qualification_required", result.failures)
        self.assertFalse(result.economic_qualified)
        with self.assertRaisesRegex(b.Rejected, "equity_coverage"):
            r.summarize(protocol(), "validation", "c"*64, equity=(), cycles=())
        for change in ({"profit_atoms": 0.5}, {"entry_hit": 1}, {"end_ns": 244}):
            with self.assertRaises(ValueError):
                replace(outcome("bad", 245, 255, "block"), **change)

    def test_frozen_selection_and_holdout_consumption_survive_restart_and_rename(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = Path(directory)/"research.json"
            r.Study.create(journal)
            study = r.Study(protocol(), journal)
            study.validate("c"*64, **report_inputs())
            study.validate("d"*64, **report_inputs())
            self.assertEqual(study.freeze(), "c"*64)
            with self.assertRaisesRegex(b.Rejected, "frozen"):
                study.validate("c"*64, **report_inputs())
            inputs = report_inputs()
            inputs["equity"] = tuple(replace(x, at_ns=x.at_ns+120) for x in inputs["equity"])
            inputs["cycles"] = tuple(replace(x, start_ns=x.start_ns+120, end_ns=x.end_ns+120)
                                     for x in inputs["cycles"])
            result = r.Study(protocol(), journal).holdout(**inputs)
            self.assertFalse(result.economic_qualified)
            for next_protocol in (protocol(), protocol(version="renamed")):
                next_study = r.Study(next_protocol, journal)
                if next_protocol.version == "renamed":
                    next_study.validate("c"*64, **report_inputs())
                    next_study.freeze()
                with self.assertRaisesRegex(b.Rejected, "seen_holdout"):
                    next_study.holdout(**inputs)

    def test_failed_holdout_is_spent_and_bad_validation_counts_as_an_attempt(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = Path(directory)/"research.json"
            r.Study.create(journal)
            study = r.Study(protocol(), journal)
            with self.assertRaises(b.Rejected):
                study.validate("c"*64, equity=(), cycles=())
            study.validate("c"*64, **report_inputs())
            with self.assertRaisesRegex(b.Rejected, "trial_limit"):
                study.validate("d"*64, **report_inputs())
            study.freeze()
            with self.assertRaisesRegex(b.Rejected, "equity_coverage"):
                study.holdout(equity=(), cycles=())
            with self.assertRaisesRegex(b.Rejected, "seen_holdout"):
                r.Study(protocol(), journal).holdout(equity=(), cycles=())

    def test_risk_rejection_empty_search_and_immutable_input_history(self):
        inputs = report_inputs()
        curve = list(inputs["equity"])
        result = r.summarize(protocol(max_drawdown_atoms=4), "validation", "c"*64,
                             equity=curve, cycles=inputs["cycles"])
        curve.clear()
        self.assertEqual(len(result.equity), 3)
        self.assertIn("drawdown_limit", result.failures)
        with tempfile.TemporaryDirectory() as directory:
            journal = Path(directory)/"research.json"
            r.Study.create(journal)
            study = r.Study(protocol(max_drawdown_atoms=4), journal)
            study.validate("c"*64, **inputs)
            with self.assertRaisesRegex(b.Rejected, "no_eligible_candidate"):
                study.freeze()
            with self.assertRaisesRegex(b.Rejected, "not_frozen"):
                study.holdout(equity=(), cycles=())

    def test_new_version_cannot_relabel_previously_declared_calibration_as_unseen(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = Path(directory)/"research.json"
            r.Study.create(journal)
            r.Study(protocol(), journal)
            changed = protocol(version="new", intervals=((0, 20), (40, 60), (80, 100), (120, 160)))
            study = r.Study(changed, journal)
            inputs = dict(equity=(sample(80, 100), sample(99, 105)),
                          cycles=(outcome("a", 81, 82, "a"), outcome("b", 83, 84, "b")))
            study.validate("c"*64, **inputs)
            study.freeze()
            with self.assertRaisesRegex(b.Rejected, "seen_holdout"):
                study.holdout(equity=(), cycles=())

    def test_journal_capacity_rejection_preserves_previously_committed_records(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = Path(directory)/"research.json"
            r.Study.create(journal)
            r.Study(protocol(), journal)
            data = json.loads(journal.read_text())
            original = next(iter(data["studies"].values()))
            data["studies"] = {str(i): original for i in range(1024)}
            journal.write_text(json.dumps(data))
            before = journal.read_bytes()
            with self.assertRaisesRegex(b.Rejected, "journal_capacity"):
                r.Study(protocol(version="overflow"), journal)
            self.assertEqual(journal.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
