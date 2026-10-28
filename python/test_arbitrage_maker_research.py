"""Synthetic Maker public-path research regressions, no real qualification."""
from dataclasses import replace
from fractions import Fraction as F
import tempfile
from pathlib import Path
import unittest

import arbitrage_research as r
import arbitrage_maker_research as mr
import arbitrage_maker as m
from test_arbitrage_maker import maker_plan, quote
from test_arbitrage_cycle import facts, done, market, entry, LIMITS, T
from test_arbitrage_research import protocol


class MakerResearchTests(unittest.TestCase):
    def observation(self, *, filled=3, terminal=True, phase="entry", failure=None):
        cycle = m.Cycle(maker_plan())
        cycle.start(cursor=1, at_ns=T, market=market(0, 1100), quotes=(quote(),))
        if filled:
            cancelled = cycle.apply(facts(2, at_ns=T+1, market=market(1, 1100),
                orders=(done(1, 0, 0, status="sent", possible_lots=10),), model_warning=True))
            self.assertEqual(cancelled.cancels, (1,))
        f = facts(3, at_ns=T+2, market=market(2, 1100), orders=(done(1, 0, filled, status="terminal" if terminal else "sent",
                              possible_lots=0 if terminal else 10-filled),),
                  positions=(F(filled), F(0)), safe_reduce_lots=(filled, 0))
        cycle.apply(f)
        return mr.observe(cycle, f, pair_ref="pair", phase=phase,
                          hedge_failed=failure, hedge_cost_atoms=5,
                          adverse_selection_atoms=7, cancel_fill_lots=1 if filled else 0,
                          queue_prediction=m.QueueResult(0, 2, 8))

    def inputs(self, sample):
        return dict(equity=(r.Equity(T, 100, 0), r.Equity(T+99, 105, 0)),
                    cycles=(r.Outcome("core-cycle", "pair", T, T+10, "block", 5,
                                      7, 9, True, None, False, False),),
                    maker_samples=(sample,))

    def policy(self, sample):
        return protocol(mode="maker_taker", maker_scopes=(sample.scope,), min_blocks=1,
                        min_cycles=1, intervals=((T-240, T-140), (T-120, T-20),
                                                 (T, T+100), (T+120, T+220)))

    def test_partial_cancel_joint_diagnostics_from_real_maker_public_output(self):
        sample = self.observation(failure=True)
        result = r.summarize(self.policy(sample), "validation", "c"*64, **self.inputs(sample))
        cell = result.maker.cells[0]
        self.assertEqual(cell.joint, ((2, False, False, "partial", "failed", True, 1),))
        self.assertEqual((cell.max_adverse_selection_atoms, cell.max_hedge_cost_atoms), (7, 5))
        self.assertEqual(cell.mean_queue_overestimate_lots, F(-1))
        self.assertEqual(cell.hedge_failure_frequency, F(1))
        self.assertIsNone(cell.failure_probability_upper)
        self.assertFalse(result.economic_qualified)

    def test_zero_full_censored_and_unknown_failures_do_not_become_bounds(self):
        for filled, terminal, expected in ((0, True, "zero"), (10, True, "full"), (3, False, "partial")):
            sample = self.observation(filled=filled, terminal=terminal)
            result = r.summarize(self.policy(sample), "validation", "c"*64, **self.inputs(sample))
            cell = result.maker.cells[0]
            self.assertEqual(cell.joint[0][3], expected)
            self.assertEqual(cell.censored_waits, int(not terminal))
            self.assertIsNone(cell.hedge_failure_frequency)
            self.assertIsNone(cell.failure_probability_upper)
        sample = self.observation(failure=False)
        result = r.summarize(self.policy(sample), "validation", "c"*64, **self.inputs(sample))
        self.assertEqual(result.maker.cells[0].hedge_failure_frequency, F(0))
        self.assertIsNone(result.maker.cells[0].failure_probability_upper)

    def test_mode_scope_identity_and_phase_cannot_inherit_taker_results(self):
        sample = self.observation()
        for changed in (replace(sample, cycle_ref="other"),
                        replace(sample, scope=("pair", 1, 10, (1000,), "entry")),
                        replace(sample, observed_ns=T+101)):
            with self.assertRaises(ValueError):
                r.summarize(self.policy(sample), "validation", "c"*64, **self.inputs(changed))
        with self.assertRaises(ValueError):
            r.summarize(protocol(), "validation", "c"*64, **self.inputs(sample))
        with self.assertRaises(ValueError):
            self.observation(phase="hold")
        inputs = self.inputs(sample)
        inputs["maker_samples"] = ()
        with self.assertRaises(ValueError):
            r.summarize(self.policy(sample), "validation", "c"*64, **inputs)

    def test_missing_registered_coverage_blocks_selection_and_reports_separate_errors(self):
        sample = self.observation()
        policy = self.policy(sample)
        policy = replace(policy, maker_scopes=(sample.scope, ("pair", 0, 10, (1001,), "entry")))
        result = r.summarize(policy, "validation", "c"*64, **self.inputs(sample))
        self.assertEqual(len(result.maker.missing_scopes), 1)
        self.assertIn("maker_scope_coverage", result.failures)
        self.assertEqual(result.plan_overestimate_atoms, F(2))
        self.assertIsNone(result.reference_overestimate_atoms)
        with tempfile.TemporaryDirectory() as directory:
            journal = Path(directory)/"study.json"
            r.Study.create(journal)
            study = r.Study(policy, journal)
            study.validate("c"*64, **self.inputs(sample))
            with self.assertRaisesRegex(ValueError, "no_eligible"):
                study.freeze()

    def test_maker_study_persists_independent_scope_and_spends_failed_holdout(self):
        sample = self.observation()
        policy = self.policy(sample)
        with tempfile.TemporaryDirectory() as directory:
            journal = Path(directory)/"study.json"
            r.Study.create(journal)
            study = r.Study(policy, journal)
            study.validate("c"*64, **self.inputs(sample))
            self.assertEqual(study.freeze(), "c"*64)
            with self.assertRaises(ValueError):
                study.holdout(**self.inputs(sample))
            with self.assertRaisesRegex(ValueError, "seen_holdout"):
                r.Study(policy, journal).holdout(**self.inputs(sample))

    def test_invalid_labels_and_duplicate_phase_are_rejected(self):
        sample = self.observation()
        for changes in ({"cancel_fill_lots": 4}, {"filled_lots": 11}, {"wait_ns": 3},
                        {"hedge_status": "not_applicable"}, {"queue_predicted_lots": 11}):
            with self.assertRaises(ValueError):
                replace(sample, **changes)
        inputs = self.inputs(sample)
        inputs["maker_samples"] = (sample, sample)
        with self.assertRaises(ValueError):
            r.summarize(self.policy(sample), "validation", "c"*64, **inputs)

    def test_actual_holding_projection_has_independent_probability_and_profit_diagnostics(self):
        cycle = m.Cycle(maker_plan())
        q = quote()
        cycle.start(cursor=1, at_ns=T, market=q.market, quotes=(q,))
        initial = facts(2, at_ns=T, market=market(0, 1100), orders=(done(1, 0, 10),),
                        positions=(F(10), F(0)), safe_reduce_lots=(10, 0))
        cycle.apply(initial, estimator=q.estimator, limits=LIMITS)
        matched = replace(initial, cursor=3, orders=initial.orders+(done(2, 1, 10),),
                          positions=(F(10), F(10)), safe_reduce_lots=(10, 10), economic_entry=entry(10))
        cycle.apply(matched, estimator=q.estimator, limits=LIMITS)
        self.assertEqual(cycle.phase, "holding")
        sample = mr.observe(cycle, matched, pair_ref="pair", phase="hold", hedge_failed=False)
        inputs = self.inputs(sample)
        inputs["cycles"] = (replace(inputs["cycles"][0], hold_hit=False, reference_profit_atoms=3),)
        result = r.summarize(self.policy(sample), "validation", "c"*64, **inputs)
        cell = result.maker.cells[0]
        self.assertEqual((cell.stage_frequency, cell.plan_overestimate_atoms,
                          cell.reference_overestimate_atoms, cell.declared_blocks), (F(0), F(2), F(6), 1))

    def test_crossing_unresolved_and_overlong_cycles_keep_risk_out_of_calibration_cells(self):
        sample = self.observation()
        for changes in ({"start_ns": T-1}, {"end_ns": T+101},
                        {"end_ns": None, "profit_atoms": None}, {"end_ns": T+21}):
            inputs = self.inputs(sample)
            inputs["cycles"] = (replace(inputs["cycles"][0], **changes),)
            report = r.summarize(self.policy(sample), "validation", "c"*64, **inputs)
            self.assertEqual((report.maker.cells, report.maker.excluded_observations), ((), 1))
            self.assertEqual(len(report.maker.observations), 1)
            self.assertIn("unresolved_risk", report.failures)
        # The reservation can precede the first maker quote; full occupancy stays intact.
        inputs = self.inputs(sample)
        inputs["cycles"] = (replace(inputs["cycles"][0], start_ns=T-1),)
        policy = replace(self.policy(sample), intervals=((T-241, T-141), (T-121, T-21),
                                                        (T-1, T+100), (T+120, T+220)))
        inputs["equity"] = (r.Equity(T-1, 100, 0), r.Equity(T+99, 105, 0))
        report = r.summarize(policy, "validation", "c"*64, **inputs)
        self.assertEqual((report.occupancy_upper_ns, report.maker.excluded_observations), (11, 0))

    def test_unknown_without_applied_fill_is_not_conflated_with_known_zero_fill(self):
        cycle = m.Cycle(maker_plan())
        cycle.start(cursor=1, at_ns=T, market=market(0, 1100), quotes=(quote(),))
        f = facts(orders=(done(1, 0, 0, status="unknown", possible_lots=10, economic_complete=False),),
                  possible_base=((F(0), F(10)), (F(0), F(0))))
        cycle.apply(f)
        sample = mr.observe(cycle, f, pair_ref="pair", phase="entry")
        self.assertTrue(sample.unknown)
        self.assertTrue(sample.wait_censored)
        report = r.summarize(self.policy(sample), "validation", "c"*64, **self.inputs(sample))
        self.assertEqual(report.maker.cells[0].joint[0][:4], (2, True, True, "zero"))


if __name__ == "__main__":
    unittest.main()
