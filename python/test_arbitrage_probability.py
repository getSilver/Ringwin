"""Exact probability gates on versioned, time-isolated calibration blocks."""
from dataclasses import replace
from fractions import Fraction as F
import unittest

from strategies.cross_venue import arbitrage_probability as p
from strategies.cross_venue import arbitrage_baseline as b


def calibration(stage="entry", calibrated=F(3, 4), margin=F(6, 100), blocks=500, scope="fixture",
                model_hash="11"*32, simulation_hash="22"*32, *, training_end_ns=200, valid_until_ns=1_000_000):
    records = tuple(p.Block(str(i), training_end_ns+10+i*10, training_end_ns+20+i*10, F(4, 5),
                            tuple(j < calibrated.numerator for j in range(calibrated.denominator)))
                    for i in range(blocks))
    return p.calibrate(records, version=1, stage=stage, mode="taker_taker", scope=scope,
                       model_hash=model_hash, training_end_ns=training_end_ns, embargo_ns=10,
                       label_span_ns=10, valid_from_ns=training_end_ns+20+blocks*10, valid_until_ns=valid_until_ns,
                       bin_edges=(F(0), F(1)), min_blocks=100, min_labels=100,
                       confidence_error=F(1, 20), declared_margin=margin,
                       independence_ref="fixture-independent-blocks", covers_mc=False, simulation_hash=simulation_hash)


class ProbabilityTests(unittest.TestCase):
    def test_s3c_raw_calibrated_and_error_sources_are_distinct(self):
        artifact = calibration()
        result = p.assess(F(4, 5), artifact, stage="entry", mode="taker_taker", scope="fixture",
                          model_hash="11"*32, simulation_hash="22"*32, at_ns=10_000, min_probability=F(7, 10),
                          mc=p.SimulationError("sampled", 5000, F(1, 20), F(2, 100), "fixture-mc"))
        self.assertEqual((result.raw, result.calibrated, result.lower_ppm), (F(4, 5), F(3, 4), 670_000))
        self.assertFalse(result.passed)
        self.assertEqual(result.reason, "probability")

    def assess(self, artifact, **changes):
        values = dict(stage="entry", mode="taker_taker", scope="fixture", model_hash="11"*32,
                      simulation_hash="22"*32, at_ns=10_000, min_probability=F(65, 100),
                      mc=p.SimulationError("exact_enumeration", 0, F(0), F(0), "exact-fixture"))
        values.update(changes)
        return p.assess(F(4, 5), artifact, **values)

    def test_s3a_s3b_and_s4a_conservative_ppm_boundaries(self):
        passing = self.assess(calibration(margin=F(7, 100)))
        self.assertEqual(passing.lower_ppm, 680_000)
        self.assertTrue(passing.passed)
        self.assertFalse(self.assess(calibration(margin=F(15, 100))).passed)
        boundary = self.assess(calibration(margin=F(999996, 10_000_000)),
                               min_probability=F(6500005, 10_000_000))
        self.assertEqual((boundary.lower_ppm, boundary.threshold_ppm), (650_000, 650_001))
        self.assertFalse(boundary.passed)

    def test_scope_expiry_missing_and_effective_block_counts_fail_closed(self):
        artifact = calibration()
        for changes, reason in ((dict(stage="hold"), "calibration_scope"),
                                (dict(scope="different-quantity-or-deadline"), "calibration_scope"),
                                (dict(simulation_hash="33"*32), "calibration_scope"),
                                (dict(at_ns=artifact.valid_until_ns), "calibration_expired")):
            self.assertEqual(self.assess(artifact, **changes).reason, reason)
        small = self.assess(calibration(blocks=2),
                            mc=p.SimulationError("sampled", 1_000_000, F(1, 20), F(1, 100), "many-simulations"))
        self.assertEqual(small.reason, "insufficient_blocks")
        self.assertIsNone(small.lower_ppm)
        missing_row = replace(artifact.bins[0], missing_labels=1)
        self.assertEqual(self.assess(replace(artifact, bins=(missing_row,))).reason, "missing_labels")
        self.assertEqual(self.assess(replace(artifact, margin=F(0))).reason, "calibration_error_understated")

    def test_block_duplicates_time_isolation_and_incomplete_outcomes_are_not_hidden(self):
        block = p.Block("one", 10, 20, F(4, 5), (True, None))
        kwargs = dict(version=1, stage="entry", mode="taker_taker", scope="fixture", model_hash="11"*32,
                      training_end_ns=0, embargo_ns=10, label_span_ns=10, valid_from_ns=100,
                      valid_until_ns=1000, bin_edges=(F(0), F(1)), min_blocks=1, min_labels=1,
                      confidence_error=F(1, 20), declared_margin=F(1), independence_ref="source", covers_mc=False, simulation_hash="22"*32)
        artifact = p.calibrate((block,), **kwargs)
        self.assertEqual((artifact.bins[0].blocks, artifact.bins[0].mature_labels, artifact.bins[0].missing_labels), (0, 1, 1))
        for blocks in ((block, replace(block, start_ns=20, end_ns=30)),
                       (block, replace(block, identity="two", start_ns=19, end_ns=29))):
            with self.assertRaisesRegex(b.Rejected, "duplicate_or_overlapping_blocks"):
                p.calibrate(blocks, **kwargs)
        with self.assertRaisesRegex(b.Rejected, "time_isolation"):
            p.calibrate((block,), **dict(kwargs, embargo_ns=9))

    def test_error_coverage_and_simulation_bound_cannot_be_omitted(self):
        artifact = calibration()
        mc = p.SimulationError("sampled", 5000, F(1, 20), F(2, 100), "fixture-mc")
        self.assertEqual(self.assess(replace(artifact, covers_mc=True), mc=mc).reason, "duplicate_error_coverage")
        with self.assertRaisesRegex(b.Rejected, "simulation_error_understated"):
            p.SimulationError("sampled", 1, F(1, 20), F(0), "omitted")
        with self.assertRaises(ValueError):
            p.probability(float("nan"))


if __name__ == "__main__":
    unittest.main()
