"""State-space public filtering contracts and independent matrix oracles."""
from dataclasses import replace
from decimal import Decimal, localcontext
import math
import random
import unittest

from strategies.cross_venue import arbitrage_baseline as b
from strategies.cross_venue import arbitrage_state_space as s


def parameters(**changes):
    values = dict(version=1, trained_until_ns=0, phi=.5, q=(.01, 0., 0., .02),
                  r=1., prior_mean=(0., 0.), prior_covariance=(1., 0., 0., 1.),
                  warmup=2, min_reversion=1e-15, max_covariance=100.,
                  min_abs_deviation=0., covariance_tolerance=1e-12)
    values.update(changes)
    return s.Parameters(**values)


def reference(points, params, horizon=0):
    """60-digit generic matrices; update uses conditional covariance subtraction."""
    with localcontext() as ctx:
        ctx.prec = 60
        d = lambda value: Decimal.from_float(float(value))
        f = [[Decimal(1), Decimal(0)], [Decimal(0), d(params.phi)]]
        q = [[d(params.q[2*i+j]) for j in range(2)] for i in range(2)]
        mean = [d(x) for x in params.prior_mean]
        covariance = [[d(params.prior_covariance[2*i+j]) for j in range(2)] for i in range(2)]
        def matmul(a, z):
            return [[sum(a[i][k]*z[k][j] for k in range(2)) for j in range(2)] for i in range(2)]
        def project(mean, covariance):
            m = [sum(f[i][k]*mean[k] for k in range(2)) for i in range(2)]
            v = matmul(matmul(f, covariance), [[f[j][i] for j in range(2)] for i in range(2)])
            return m, [[v[i][j]+q[i][j] for j in range(2)] for i in range(2)]
        for index, point in enumerate(points):
            if index:
                mean, covariance = project(mean, covariance)
            innovation = d(point.value)-sum(mean)
            ph = [sum(row) for row in covariance]
            variance = sum(ph)+d(params.r)
            mean = [mean[i]+ph[i]*innovation/variance for i in range(2)]
            covariance = [[covariance[i][j]-ph[i]*ph[j]/variance for j in range(2)] for i in range(2)]
        for _ in range(horizon):
            mean, covariance = project(mean, covariance)
        return tuple(map(float, mean)), tuple(float(x) for row in covariance for x in row), float(sum(sum(row) for row in covariance)+d(params.r))


class FilteringTests(unittest.TestCase):
    def test_first_measurement_uses_registered_prior_and_joseph_covariance(self):
        model = s.Filter(parameters())
        state = model.push(b.Point(0, 1, 3.))
        self.assertEqual(state.mean, (1., 1.))
        for actual, expected in zip(state.covariance, (2/3, -1/3, -1/3, 2/3)):
            self.assertAlmostEqual(actual, expected, delta=2e-16)
        self.assertEqual(state.count, 1)
        self.assertAlmostEqual(state.log_likelihood, -.5*(math.log(6*math.pi)+3))
        with self.assertRaisesRegex(b.Rejected, "warming"):
            model.predict(300, 1)

    def test_filter_and_all_horizon_predictions_match_independent_decimal_matrices(self):
        params = parameters(phi=.93, q=(.01, .002, .002, .02), r=.05)
        points = tuple(b.Point(i*b.SECOND, i+1, math.sin(i*.31)*.1+.01*i) for i in range(40))
        model = s.Filter(params)
        for i, point in enumerate(points):
            state = model.push(point)
            mean, covariance, _ = reference(points[:i+1], params)
            for actual, expected in zip(state.mean+state.covariance, mean+covariance):
                self.assertAlmostEqual(actual, expected, delta=2e-13)
            self.assertEqual(state.covariance[1], state.covariance[2])
        for horizon in b.HORIZONS:
            expected_mean, _, expected_variance = reference(points, params, horizon)
            prediction = model.predict(horizon, 1)
            self.assertAlmostEqual(prediction.mean, sum(expected_mean), delta=2e-13)
            self.assertAlmostEqual(prediction.variance, expected_variance, delta=2e-10)
            self.assertEqual(prediction.source, points[-1])
            self.assertEqual(prediction.model_kind, "state_space")

    def test_gap_rewarms_from_registered_prior_and_never_refits(self):
        params = parameters()
        model = s.Filter(params)
        model.push(b.Point(0, 1, 3.))
        model.push(b.Point(b.SECOND, 2, 2.))
        before = params.content_hash
        gap = model.push(b.Point(2*b.SECOND, 3, None, "data_gap"))
        self.assertEqual((gap.mean, gap.covariance, gap.count), (params.prior_mean, params.prior_covariance, 0))
        recovered = model.push(b.Point(3*b.SECOND, 4, 3.))
        self.assertEqual(recovered.mean, (1., 1.))
        with self.assertRaisesRegex(b.Rejected, "warming"):
            model.predict(300, 1)
        self.assertEqual(params.content_hash, before)

    def test_prefix_filter_is_causal_and_center_only_motion_is_not_reversion(self):
        prefix = [b.Point(i*b.SECOND, i+1, float(i % 3)) for i in range(10)]
        first, second = s.Filter(parameters()), s.Filter(parameters())
        for point in prefix:
            self.assertEqual(first.push(point), second.push(point))
        fixed = first.state
        second.push(b.Point(10*b.SECOND, 11, 10000.))
        self.assertEqual(first.state, fixed)
        center_only = s.Filter(parameters(q=(.1, 0., 0., 0.), prior_covariance=(1., 0., 0., 0.)))
        for point in prefix:
            center_only.push(point)
        with self.assertRaisesRegex(b.Rejected, "near_center"):
            center_only.predict(300, 1)


def synthetic(seed=7505, count=400):
    generator = random.Random(seed)
    center, deviation = .01, .02
    points, states = [], []
    for i in range(count):
        if i:
            center += generator.gauss(0., .001)
            deviation = .8*deviation+generator.gauss(0., .02)
        value = center+deviation+generator.gauss(0., .005)
        points.append(b.Point(i*b.SECOND, i+1, value))
        states.append((center, deviation))
    return tuple(points), tuple(states)


def fit_policy(**changes):
    values = dict(steps=(.5, .5, .5, .2, .5), contraction=.5, minimum_step=.1,
                  iterations=10, max_evaluations=300, min_points=30,
                  profile_steps=(.2, .2, .2, .1, .2), identifiability_delta=.5,
                  alternative_distance=.5, degeneracy_fraction=.001, improvement_tolerance=1e-10)
    values.update(changes)
    return s.FitPolicy(**values)


class FittingTests(unittest.TestCase):
    def test_metadata_aliases_cannot_masquerade_as_distinct_statistical_starts(self):
        points, _ = synthetic(count=40)
        first = parameters()
        for alias in (replace(first, version=2), replace(first, trained_until_ns=123)):
            with self.assertRaisesRegex(b.Rejected, "distinct_starts_required"):
                s.fit(points, (first, alias), training_end_ns=40*b.SECOND,
                      version=3, policy=fit_policy(iterations=1))
        with self.assertRaisesRegex(b.Rejected, "fit_policy_scope"):
            s.fit(points, (first, replace(first, phi=.8, max_covariance=200.)),
                  training_end_ns=40*b.SECOND, version=3, policy=fit_policy(iterations=1))

    def test_multistart_fit_is_frozen_reproducible_and_reports_ambiguity(self):
        points, _ = synthetic(count=60)
        first = parameters(phi=.7, q=(1e-6, 0., 0., .0004), r=.000025,
                           prior_mean=(.01, .02), prior_covariance=(.0001, 0., 0., .001))
        starts = (first, replace(first, phi=.9, r=.0001))
        args = dict(training_end_ns=50*b.SECOND, version=2, policy=fit_policy(iterations=3))
        report = s.fit(points, starts, **args)
        again = s.fit(points[:50]+(b.Point(50*b.SECOND, 51, 1e10),), starts, **args)
        self.assertEqual(report, again)
        self.assertEqual(len(report.runs), 2)
        self.assertIsNotNone(report.selected)
        self.assertEqual(report.selected.trained_until_ns, 50*b.SECOND)
        self.assertEqual(report.selected.version, 2)
        self.assertGreater(report.evaluations, 2)
        self.assertTrue(type(report.identifiable) is bool)
        for run in report.runs:
            self.assertLessEqual(run.final_nll, run.initial_nll+1e-10)
        self.assertEqual(starts[0], first)

    def test_degenerate_start_and_capacity_are_explicit(self):
        points, _ = synthetic(count=40)
        valid = parameters(q=(1e-6, 0., 0., .0004), r=.000025)
        degenerate = replace(valid, q=(0., 0., 0., .0004))
        report = s.fit(points, (valid, degenerate), training_end_ns=40*b.SECOND,
                       version=1, policy=fit_policy(iterations=1))
        self.assertEqual(report.runs[1].reason, "degenerate_start")
        with self.assertRaisesRegex(b.Rejected, "fit_capacity"):
            s.fit(points, (valid, replace(valid, phi=.8)), training_end_ns=40*b.SECOND,
                  version=1, policy=fit_policy(max_evaluations=2))

    def test_flat_and_degenerate_noise_diagnostics_do_not_grant_identifiability(self):
        points, _ = synthetic(count=40)
        first = parameters(q=(1e-12, 0., 0., .0004), r=.000025)
        report = s.fit(points, (first, replace(first, phi=.8)), training_end_ns=40*b.SECOND,
                       version=1, policy=fit_policy(iterations=1, identifiability_delta=100.))
        self.assertIn("q_center", report.degeneracies)
        self.assertTrue(report.flat_coordinates)
        self.assertFalse(report.identifiable)


def synthetic_report():
    points, truth = synthetic()
    params = parameters(phi=.8, q=(1e-6, 0., 0., .0004), r=.000025,
                        prior_mean=(.01, .02), prior_covariance=(.0001, 0., 0., .001), warmup=20)
    model = s.Filter(params)
    errors = []
    for point, hidden in zip(points, truth):
        state = model.push(point)
        if point.grid_ns >= 200*b.SECOND:
            errors.append((state.mean[0]-hidden[0], state.mean[1]-hidden[1], sum(state.mean)-sum(hidden)))
    report = s.fit(points, (replace(params, phi=.6), replace(params, phi=.95)),
                   training_end_ns=160*b.SECOND, version=2,
                   policy=fit_policy(iterations=12, max_evaluations=1000))
    return dict(seed=7505, training_points=160, validation_points=200,
                filtered_center_rmse=math.sqrt(math.fsum(e[0]**2 for e in errors)/len(errors)),
                filtered_deviation_rmse=math.sqrt(math.fsum(e[1]**2 for e in errors)/len(errors)),
                filtered_sum_rmse=math.sqrt(math.fsum(e[2]**2 for e in errors)/len(errors)),
                fitted_phi=report.selected.phi, fitted_q=report.selected.q, fitted_r=report.selected.r,
                fit_evaluations=report.evaluations, flat=report.flat_coordinates,
                ambiguous=report.ambiguous_starts, degenerate=report.degeneracies,
                identifiable=report.identifiable)


class BoundaryTests(unittest.TestCase):
    def test_covariance_scope_nonfinite_phi_and_capacity_reject(self):
        for changes in (dict(phi=0.), dict(phi=1.), dict(phi=1-1e-16), dict(r=0.),
                        dict(q=(-1., 0., 0., 1.)), dict(q=(1., 2., 2., 1.)),
                        dict(q=(1., .1, 0., 1.)), dict(q=(1., math.nan, math.nan, 1.)),
                        dict(prior_mean=[0., 0.]), dict(prior_covariance=(1., 2., 2., 1.)),
                        dict(warmup=3601), dict(covariance_tolerance=0.)):
            with self.subTest(changes=changes), self.assertRaises(b.Rejected):
                parameters(**changes)

    def test_event_order_covariance_limit_and_training_leakage_reject(self):
        model = s.Filter(parameters(trained_until_ns=10*b.SECOND))
        model.push(b.Point(0, 1, 3.))
        model.push(b.Point(b.SECOND, 2, 2.))
        before = model.state
        with self.assertRaisesRegex(b.Rejected, "training_leakage"):
            model.predict(300, 1)
        with self.assertRaisesRegex(b.Rejected, "observation_order"):
            model.push(b.Point(b.SECOND, 2, 5.))
        self.assertEqual(model.state, before)
        tight = s.Filter(parameters(max_covariance=.001))
        tight.push(b.Point(0, 1, 3.))
        tight.push(b.Point(b.SECOND, 2, 2.))
        with self.assertRaisesRegex(b.Rejected, "covariance_limit"):
            tight.predict(300, 1)

    def test_fixed_input_chunking_and_common_label_interface(self):
        points, _ = synthetic(count=310)
        def replay(chunk):
            model = s.Filter(parameters(phi=.8, q=(1e-6, 0., 0., .0004), r=.000025))
            tracker = b.LabelTracker(1)
            history, labels = [], []
            for start in range(0, len(points), chunk):
                for i in range(start, min(start+chunk, len(points))):
                    history.append(model.push(points[i]))
                    labels.extend(tracker.advance(points[i]))
                    if i == 2:
                        tracker.add(model.predict(300, 1))
            self.assertEqual(labels[0].status, "mature")
            return tuple(history), tuple(labels)
        self.assertEqual(replay(1), replay(23))

    def test_synthetic_hidden_state_errors_have_explicit_finite_sample_tolerances(self):
        report = synthetic_report()
        self.assertLess(report["filtered_center_rmse"], .02)
        self.assertLess(report["filtered_deviation_rmse"], .02)
        self.assertLess(report["filtered_sum_rmse"], .01)
        self.assertGreater(report["fit_evaluations"], 2)
        self.assertFalse(report["identifiable"])


if __name__ == "__main__":
    unittest.main()
