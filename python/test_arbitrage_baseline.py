"""Public offline baseline contracts; no trading authority or market qualification."""
import math
from decimal import Decimal, localcontext
from dataclasses import replace, FrozenInstanceError
from fractions import Fraction as F
import struct
import random
import unittest

import arbitrage_baseline as b
from arbitrage_economics import InstrumentRules


def rules(instrument, tick=F(1)):
    return InstrumentRules(instrument, 1, 10, 20, tick, F(1), 1, 1, 0, 10_000*b.SECOND)


def wire(instrument, sequence, visible_ns, mid):
    payload = bytearray(704)
    payload[:16] = instrument.to_bytes(16, "little")
    struct.pack_into("<QQQ", payload, 16, 1, sequence, visible_ns)
    payload[40:42] = bytes((1, 1))
    for i, ticks in enumerate((mid-1, mid+1)):
        offset = 64+i*8*40
        payload[offset:offset+16] = ticks.to_bytes(16, "little", signed=True)
        payload[offset+16] = 1
        payload[offset+24:offset+40] = (10).to_bytes(16, "little", signed=True)
    return bytes(payload)


class GridTests(unittest.TestCase):
    def sampler(self, age=2*b.SECOND, skew=b.SECOND):
        return b.GridSampler(rules(1), rules(2), version=1, max_age_ns=age, max_skew_ns=skew)

    def test_receive_cutoff_and_late_arrival_never_rewrite_previous_grid(self):
        sampler = self.sampler()
        sampler.observe(0, wire(1, 100, 0, 100), cursor=1, admitted_at_ns=0,
                        healthy=True, continuous=True)
        sampler.observe(1, wire(2, 200, 0, 103), cursor=2, admitted_at_ns=0,
                        healthy=True, continuous=True)
        point = sampler.sample(b.SECOND, cursor=3)
        self.assertAlmostEqual(point.value, math.log(1.03))
        # The source timestamp was earlier; actual admission was after the first grid.
        sampler.observe(1, wire(2, 205, b.SECOND//2, 110), cursor=4,
                        admitted_at_ns=b.SECOND+1, healthy=True, continuous=True)
        following = sampler.sample(2*b.SECOND, cursor=5)
        self.assertAlmostEqual(following.value, math.log(1.1))
        self.assertAlmostEqual(point.value, math.log(1.03))
        self.assertEqual(point.evidence[3], 100)

    def test_missing_stale_skew_and_recovered_gap_have_explicit_evidence(self):
        sampler = self.sampler(age=b.SECOND, skew=0)
        self.assertEqual(sampler.sample(0, cursor=1).reason, "missing_book")
        sampler.observe(0, wire(1, 1, b.SECOND, 100), cursor=2, admitted_at_ns=b.SECOND,
                        healthy=True, continuous=True)
        sampler.observe(1, wire(2, 1, b.SECOND-1, 103), cursor=3, admitted_at_ns=b.SECOND,
                        healthy=True, continuous=True)
        self.assertEqual(sampler.sample(b.SECOND, cursor=4).reason, "leg_skew")
        self.assertEqual(sampler.sample(3*b.SECOND, cursor=5).reason, "stale_book")
        sampler.observe(0, wire(1, 5, 4*b.SECOND, 100), cursor=6, admitted_at_ns=4*b.SECOND,
                        healthy=False, continuous=False)
        sampler.observe(0, wire(1, 8, 4*b.SECOND, 100), cursor=7, admitted_at_ns=4*b.SECOND,
                        healthy=True, continuous=True)
        sampler.observe(1, wire(2, 9, 4*b.SECOND, 103), cursor=8, admitted_at_ns=4*b.SECOND,
                        healthy=True, continuous=True)
        recovered = sampler.sample(4*b.SECOND, cursor=9)
        self.assertTrue(recovered.break_before)
        self.assertIsNotNone(recovered.value)

    def test_instrument_tick_conversion_and_grid_order(self):
        sampler = b.GridSampler(rules(1), rules(2, F(1, 2)), version=1,
                                max_age_ns=b.SECOND, max_skew_ns=0)
        for leg, mid in ((0, 100), (1, 206)):
            sampler.observe(leg, wire(leg+1, 1, 0, mid), cursor=leg+1, admitted_at_ns=0,
                            healthy=True, continuous=True)
        point = sampler.sample(0, cursor=3)
        self.assertAlmostEqual(point.value, math.log(1.03))
        with self.assertRaisesRegex(b.Rejected, "grid_order"):
            sampler.sample(0, cursor=4)

    def test_canonical_gap_event_breaks_even_if_both_books_recover_before_next_grid(self):
        sampler = self.sampler()
        for leg in (0, 1):
            sampler.observe(leg, wire(leg+1, 1, 0, 100+leg), cursor=leg+1,
                            admitted_at_ns=0, healthy=True, continuous=True)
        first = sampler.sample(0, cursor=3)
        sampler.invalidate(0, cursor=4, at_ns=1)
        sampler.observe(0, wire(1, 10, b.SECOND, 102), cursor=5,
                        admitted_at_ns=b.SECOND, healthy=True, continuous=True)
        recovered = sampler.sample(b.SECOND, cursor=6)
        self.assertTrue(recovered.break_before)
        window = b.RollingWindow(b.WindowSpec(1, 3, 2, 1e-15, 0.))
        window.push(first)
        window.push(recovered)
        with self.assertRaisesRegex(b.Rejected, "insufficient_samples"):
            window.statistics()

    def test_future_scope_expiry_bad_framing_and_event_order_reject(self):
        sampler = self.sampler()
        for payload, now in ((wire(1, 1, 1, 100), 0), (wire(3, 1, 0, 100), 0), (b"", 0)):
            with self.subTest(payload=payload[:16]), self.assertRaises(b.Rejected):
                sampler.observe(0, payload, cursor=1, admitted_at_ns=now, healthy=True, continuous=True)
        sampler.observe(0, wire(1, 1, 0, 100), cursor=1, admitted_at_ns=0, healthy=True, continuous=True)
        with self.assertRaisesRegex(b.Rejected, "event_order"):
            sampler.observe(1, wire(2, 1, 0, 100), cursor=1, admitted_at_ns=0, healthy=True, continuous=True)
        sampler.observe(1, wire(2, 1, 0, 100), cursor=2, admitted_at_ns=0, healthy=True, continuous=True)
        self.assertEqual(sampler.sample(10_000*b.SECOND, cursor=3).reason, "expired_rules")

    def test_legal_large_ticks_do_not_overflow_before_exact_midpoint_reduction(self):
        sampler = self.sampler()
        for leg in (0, 1):
            sampler.observe(leg, wire(leg+1, 1, 0, 1 << 126), cursor=leg+1,
                            admitted_at_ns=0, healthy=True, continuous=True)
        self.assertEqual(sampler.sample(0, cursor=3).value, 0.)


class AR1Tests(unittest.TestCase):
    def test_conditional_moments_and_half_life_match_literal_solution(self):
        model = b.AR1(version=1, trained_until_ns=0, center=1., phi=.5,
                      innovation_variance=.75, min_reversion=1e-15, min_variance=1e-20,
                      min_abs_deviation=0.)
        prediction = model.predict(b.Point(0, 1, 3.), 300, 1)
        self.assertAlmostEqual(prediction.mean, 1.)
        self.assertAlmostEqual(prediction.variance, 1.)
        self.assertEqual(prediction.half_life_seconds, 1.)
        self.assertEqual(prediction.directional_change, 2.)
        reverse = model.predict(b.Point(0, 1, 3.), 300, -1)
        self.assertEqual(reverse.directional_change, -2.)

    def test_near_unit_root_moments_match_stepwise_recursion(self):
        for phi in (.999999999999, .9):
            model = b.AR1(1, 0, .01, phi, .0001, 1e-15, 1e-20, 0.)
            for horizon in b.HORIZONS:
                with localcontext() as ctx:
                    ctx.prec = 60
                    p, mean, variance = Decimal.from_float(phi), Decimal.from_float(.03), Decimal(0)
                    center, noise = Decimal.from_float(.01), Decimal.from_float(.0001)
                    for _ in range(horizon):
                        mean = center+p*(mean-center)
                        variance = p*p*variance+noise
                    expected_half = Decimal(2).ln()/(-p.ln())
                result = model.predict(b.Point(0, 1, .03), horizon, 1)
                self.assertAlmostEqual(result.mean, float(mean), delta=1e-14)
                self.assertAlmostEqual(result.variance, float(variance), delta=1e-12)
                self.assertAlmostEqual(result.half_life_seconds/float(expected_half), 1., delta=1e-14)

    def test_fit_uses_only_contiguous_training_pairs_and_freezes_parameters(self):
        points = tuple(b.Point(i*b.SECOND, i+1, float(x)) for i, x in enumerate((0, 1, 2, 2, 3)))
        kwargs = dict(version=1, training_end_ns=5*b.SECOND, min_pairs=4,
                      min_reversion=1e-12, min_variance=1e-15, min_abs_deviation=0.)
        fitted = b.fit_ar1(points, **kwargs)
        self.assertAlmostEqual(fitted.phi, 8/11)
        self.assertAlmostEqual(fitted.center, 4.)
        self.assertAlmostEqual(fitted.innovation_variance, 3/11)
        with_future = b.fit_ar1(points+(b.Point(5*b.SECOND, 6, 1e10),), **kwargs)
        self.assertEqual(fitted, with_future)
        before = fitted.content_hash
        for i in range(5, 10):
            fitted.predict(b.Point(i*b.SECOND, i+1, 3.), 300, 1)
        self.assertEqual(fitted.content_hash, before)
        broken = points[:2]+(b.Point(2*b.SECOND, 3, None, "data_gap"),)+points[3:]
        with self.assertRaisesRegex(b.Rejected, "insufficient_pairs"):
            b.fit_ar1(broken, **kwargs)


class RollingTests(unittest.TestCase):
    def test_rolling_sample_statistics_and_gap_reset(self):
        window = b.RollingWindow(b.WindowSpec(1, 3, 3, 1e-15, 0.))
        for i, x in enumerate((1., 2., 3.)):
            window.push(b.Point(i*b.SECOND, i+1, x))
        stats = window.statistics()
        self.assertEqual((stats.mean, stats.variance, stats.z_score), (2., 1., 1.))
        window.push(b.Point(4*b.SECOND, 4, 4.))
        with self.assertRaisesRegex(b.Rejected, "insufficient_samples"):
            window.statistics()
        window.push(b.Point(5*b.SECOND, 5, 5.))
        window.push(b.Point(6*b.SECOND, 6, 6.))
        self.assertEqual(window.statistics().mean, 5.)
        window.push(b.Point(7*b.SECOND, 7, None, "data_gap"))
        with self.assertRaisesRegex(b.Rejected, "data_gap"):
            window.statistics()

    def test_trained_bucket_mean_uses_only_mature_in_partition_labels(self):
        # A bounded linear training sequence: every mature 300-step change is exactly 300.
        points = tuple(b.Point(i*b.SECOND, i+1, float(i)) for i in range(305))
        model = b.fit_rolling(points, spec=b.WindowSpec(1, 3, 3, 1e-15, 0.),
                              version=1, training_end_ns=305*b.SECOND,
                              deviation_edges=(0.,), volatility_edges=(2.,), min_samples=2)
        online = b.RollingWindow(model.spec)
        for i in range(305, 308):
            online.push(b.Point(i*b.SECOND, i+1, float(i)))
        result = model.predict(online.statistics(), 300, 1)
        self.assertEqual(result.mean, 607.)
        self.assertEqual(result.variance, 0.)
        self.assertGreater(model.excluded_labels, 0)
        with self.assertRaisesRegex(b.Rejected, "empty_bucket"):
            model.predict(online.statistics(), 900, 1)

    def test_bucket_sample_shortage_scope_and_future_data_are_explicit(self):
        spec = b.WindowSpec(1, 3, 3, 1e-15, 0.)
        points = tuple(b.Point(i*b.SECOND, i+1, float(i)) for i in range(305))
        args = dict(spec=spec, version=1, training_end_ns=305*b.SECOND,
                    deviation_edges=(0.,), volatility_edges=(2.,), min_samples=4)
        model = b.fit_rolling(points, **args)
        changed = b.fit_rolling(points+(b.Point(305*b.SECOND, 306, 1e10),), **args)
        self.assertEqual(model, changed)
        online = b.RollingWindow(spec)
        for i in range(305, 308):
            online.push(b.Point(i*b.SECOND, i+1, float(i)))
        with self.assertRaisesRegex(b.Rejected, "insufficient_bucket_samples"):
            model.predict(online.statistics(), 300, 1)
        wrong = replace(online.statistics(), spec_hash="other")
        with self.assertRaisesRegex(b.Rejected, "window_scope"):
            model.predict(wrong, 300, 1)

    def test_rolling_missing_labels_counted_without_changing_origin_eligibility(self):
        points = [b.Point(i*b.SECOND, i+1, float(i)) for i in range(310)]
        points[303] = b.Point(303*b.SECOND, 304, None, "data_gap")
        model = b.fit_rolling(tuple(points), spec=b.WindowSpec(1, 3, 3, 1e-15, 0.),
                              version=1, training_end_ns=310*b.SECOND,
                              deviation_edges=(), volatility_edges=(), min_samples=2)
        self.assertEqual(model.missing_labels, 1)


class LabelTests(unittest.TestCase):
    def forecast(self, cursor=1):
        return b.AR1(1, 0, 0., .8, .01, 1e-12, 1e-15, 0.).predict(b.Point(0, cursor, .1), 300, 1)

    def test_labels_mature_only_at_exact_due_grid_with_observed_evidence(self):
        tracker = b.LabelTracker(2)
        forecast = self.forecast()
        tracker.add(forecast)
        self.assertEqual(tracker.advance(b.Point(299*b.SECOND, 2, .04)), ())
        self.assertEqual(len(tracker.pending), 1)
        labels = tracker.advance(b.Point(300*b.SECOND, 3, .03))
        self.assertEqual(labels[0].status, "mature")
        self.assertAlmostEqual(labels[0].change, -.07)
        self.assertEqual(labels[0].observed_cursor, 3)
        self.assertEqual(labels[0].observed_at_ns, 300*b.SECOND)
        self.assertEqual(tracker.pending, ())

    def test_missing_labels_capacity_and_duplicate_rejection_keep_pending_evidence(self):
        for endpoint in (b.Point(300*b.SECOND, 2, None, "data_gap"),
                         b.Point(301*b.SECOND, 2, .03)):
            tracker = b.LabelTracker(1)
            forecast = self.forecast()
            tracker.add(forecast)
            with self.assertRaisesRegex(b.Rejected, "duplicate_prediction"):
                tracker.add(forecast)
            with self.assertRaisesRegex(b.Rejected, "capacity"):
                tracker.add(self.forecast(cursor=2))
            self.assertEqual(tracker.pending, (forecast,))
            result = tracker.advance(endpoint)[0]
            self.assertEqual(result.status, "missing")
            self.assertIsNone(result.change)

    def test_labels_reject_causally_earlier_observation(self):
        tracker = b.LabelTracker(1)
        tracker.add(self.forecast(cursor=10))
        with self.assertRaisesRegex(b.Rejected, "label_causality"):
            tracker.advance(b.Point(300*b.SECOND, 2, .03))
        self.assertEqual(len(tracker.pending), 1)

    def test_all_registered_horizons_keep_their_original_maturity(self):
        model = b.AR1(1, 0, 0., .8, .01, 1e-12, 1e-15, 0.)
        tracker = b.LabelTracker(3)
        for horizon in b.HORIZONS:
            tracker.add(model.predict(b.Point(0, 1, .1), horizon, 1))
        for cursor, horizon in enumerate(b.HORIZONS, 2):
            result = tracker.advance(b.Point(horizon*b.SECOND, cursor, .02))
            self.assertEqual(len(result), 1)
            self.assertEqual(result[0].prediction.horizon_seconds, horizon)
        self.assertEqual(tracker.pending, ())


class ReplayTests(unittest.TestCase):
    def test_canonical_grid_window_prediction_and_label_replay_is_deterministic(self):
        def replay(chunk_size):
            sampler = b.GridSampler(rules(1), rules(2), version=1,
                                    max_age_ns=b.SECOND, max_skew_ns=0)
            window = b.RollingWindow(b.WindowSpec(1, 10, 3, 1e-15, 0.))
            model = b.AR1(1, 0, 0., .8, .01, 1e-12, 1e-15, 0.)
            tracker = b.LabelTracker(1)
            points, forecasts, labels = [], [], []
            for start in range(0, 304, chunk_size):
                for i in range(start, min(304, start+chunk_size)):
                    for leg in (0, 1):
                        mid = 100 if leg == 0 else 103+i % 5
                        sampler.observe(leg, wire(leg+1, 100+5*i, i*b.SECOND, mid),
                                        cursor=3*i+leg+1, admitted_at_ns=i*b.SECOND,
                                        healthy=i != 200, continuous=i != 200)
                    point = sampler.sample(i*b.SECOND, cursor=3*i+3)
                    points.append(point)
                    window.push(point)
                    labels.extend(tracker.advance(point))
                    if i == 3:
                        stats = window.statistics()
                        self.assertEqual(stats.count, 4)
                        forecast = model.predict(point, 300, 1)
                        forecasts.append(forecast)
                        tracker.add(forecast)
            self.assertEqual(labels[0].status, "mature")
            return tuple(points), tuple(forecasts), tuple(labels)
        self.assertEqual(replay(1), replay(17))


class BoundaryTests(unittest.TestCase):
    def model(self):
        return b.AR1(1, 0, 0., .8, .01, 1e-12, 1e-15, 0.)

    def test_invalid_phi_variance_near_center_and_nonfinite_reject_without_clipping(self):
        model = self.model()
        for phi in (-.1, 0., 1., 1.1, math.nan, math.inf):
            with self.subTest(phi=phi), self.assertRaises(b.Rejected):
                replace(model, phi=phi)
        with self.assertRaisesRegex(b.Rejected, "near_unit_root"):
            replace(model, phi=1-1e-13)
        for variance in (0., -1., 1e-20, math.nan, math.inf):
            with self.subTest(variance=variance), self.assertRaises(b.Rejected):
                replace(model, innovation_variance=variance)
        with self.assertRaisesRegex(b.Rejected, "near_center"):
            model.predict(b.Point(0, 1, 0.), 300, 1)
        with self.assertRaises(FrozenInstanceError):
            model.phi = .9

    def test_invalid_units_window_capacity_and_order(self):
        model = self.model()
        for horizon in (1, 300., 300_000, True):
            with self.subTest(horizon=horizon), self.assertRaises(b.Rejected):
                model.predict(b.Point(0, 1, .1), horizon, 1)
        for value in (math.nan, math.inf, True, "1"):
            with self.subTest(value=value), self.assertRaises(b.Rejected):
                b.Point(0, 1, value)
        with self.assertRaises(b.Rejected):
            b.Point(1, 1, .1)
        for cap, warmup in ((3601, 2), (2, 3), (1, 1)):
            with self.assertRaises(b.Rejected):
                b.WindowSpec(1, cap, warmup, 1e-15, 0.)
        with self.assertRaises(b.Rejected):
            b.LabelTracker(257)
        window = b.RollingWindow(b.WindowSpec(1, 2, 2, 1e-15, 0.))
        window.push(b.Point(0, 1, .1))
        with self.assertRaisesRegex(b.Rejected, "observation_order"):
            window.push(b.Point(0, 1, .1))

    def test_degenerate_training_and_numeric_overflow_fail_closed(self):
        kwargs = dict(version=1, training_end_ns=10*b.SECOND, min_pairs=3,
                      min_reversion=1e-12, min_variance=1e-15, min_abs_deviation=0.)
        points = tuple(b.Point(i*b.SECOND, i+1, 1.) for i in range(5))
        with self.assertRaisesRegex(b.Rejected, "degenerate_variance"):
            b.fit_ar1(points, **kwargs)
        explosive = tuple(b.Point(i*b.SECOND, i+1, float(2**i)) for i in range(5))
        with self.assertRaisesRegex(b.Rejected, "non_stationary_phi"):
            b.fit_ar1(explosive, **kwargs)
        huge = tuple(b.Point(i*b.SECOND, i+1, x) for i, x in enumerate((1e308, -1e308, 1e308, -1e308)))
        with self.assertRaises(b.Rejected):
            b.fit_ar1(huge, **kwargs)
        window = b.RollingWindow(b.WindowSpec(1, 3, 3, 1e-15, 0.))
        for point in huge[:3]:
            window.push(point)
        with self.assertRaises(b.Rejected):
            window.statistics()


def synthetic_report(seed=7304):
    generator = random.Random(seed)
    current, center, phi, sigma = .01, .01, .8, .02
    values = []
    for i in range(17_000):
        current = center+phi*(current-center)+generator.gauss(0., sigma)
        if i >= 1000:
            values.append(current)
    points = tuple(b.Point(i*b.SECOND, i+1, value) for i, value in enumerate(values))
    model = b.fit_ar1(points, version=1, training_end_ns=12_000*b.SECOND,
                      min_pairs=10_000, min_reversion=1e-12,
                      min_variance=1e-15, min_abs_deviation=0.)
    # Deliberately nonoverlapping 300-second forecast endpoints; still not independent market evidence.
    errors = [points[i+300].value-model.predict(points[i], 300, 1).mean
              for i in range(12_000, 15_700, 300)]
    return dict(seed=seed, training_points=12_000, forecast_labels=len(errors),
                phi=model.phi, center=model.center, innovation_variance=model.innovation_variance,
                mean_error=math.fsum(errors)/len(errors),
                rmse=math.sqrt(math.fsum(x*x for x in errors)/len(errors)))


class SyntheticTests(unittest.TestCase):
    def test_known_process_fit_and_future_errors_with_preregistered_tolerances(self):
        result = synthetic_report()
        self.assertAlmostEqual(result["phi"], .8, delta=.02)
        self.assertAlmostEqual(result["center"], .01, delta=.002)
        self.assertAlmostEqual(result["innovation_variance"], .0004, delta=.000025)
        self.assertLess(abs(result["mean_error"]), .03)
        self.assertLess(result["rmse"], .06)
        self.assertEqual(result, synthetic_report())


if __name__ == "__main__":
    unittest.main()
