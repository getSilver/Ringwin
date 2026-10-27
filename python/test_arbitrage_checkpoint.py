"""Actual strategy objects continue through the Host checkpoint boundary."""
import unittest
from dataclasses import replace
from fractions import Fraction as F
import copy
import math
import io
import struct
import subprocess
import sys

import arbitrage_baseline as b
import arbitrage_checkpoint as recovery
import arbitrage_state_space as ss
import arbitrage_signals as signals
import arbitrage_admission as admission
import arbitrage_cycle as cycle
import arbitrage_evaluation as evaluation
import strategy_host as host
from test_strategy_checkpoint import metadata
from test_arbitrage_state_space import parameters
from test_arbitrage_admission import signal_policy, inputs, ready
from test_arbitrage_cycle import plan, facts, done, T, entry, market, estimator_for, path, LIMITS
from test_arbitrage_evaluation import policy, calibration, EXACT


def meta(cursor=0, next_intent=1, strategy=9):
    result = metadata()
    result.update(state_schema_version=2, cursor=cursor, next_intent=next_intent, strategy=strategy)
    return result


def roundtrip(components, cursor=0, next_intent=1):
    return recovery.restore(recovery.checkpoint(meta(cursor, next_intent), components), components)[1]


class RecoveryTests(unittest.TestCase):
    def test_rolling_continues_with_exact_state_and_statistics(self):
        import arbitrage_checkpoint as recovery
        window = b.RollingWindow(b.WindowSpec(1, 3, 2, .001, 0.))
        for i, value in enumerate((.1, .2, .4), 1):
            window.push(b.Point(i*b.SECOND, i, value))
        meta = metadata()
        meta.update(state_schema_version=2, cursor=3, next_intent=1)
        components = {"window": window}
        saved = recovery.checkpoint(meta, components)
        restored_meta, restored = recovery.restore(saved, components)
        self.assertEqual(restored_meta, meta)
        self.assertEqual(restored["window"].statistics(), window.statistics())
        point = b.Point(4*b.SECOND, 4, .7)
        window.push(point)
        restored["window"].push(point)
        meta["cursor"] = restored_meta["cursor"] = 4
        self.assertEqual(recovery.checkpoint(meta, components),
                         recovery.checkpoint(restored_meta, restored))
        self.assertEqual(window.statistics(), restored["window"].statistics())

    def test_filter_and_ar1_predictions_labels_match_at_every_cut(self):
        ar1 = b.AR1(1, 0, 0., .5, .1, 1e-8, 1e-9, 0.)
        for cut in range(7):
            original = {"filter": ss.Filter(parameters()), "labels": b.LabelTracker(4), "ar1": ar1}
            restored = None
            for i, value in enumerate((3., 2., 1., None, 2., 1.), 1):
                if i-1 == cut:
                    restored = roundtrip(original, i-1)
                point = b.Point((i-1)*b.SECOND, i, value, "gap" if value is None else "")
                outcomes = []
                for objects in (original,) if restored is None else (original, restored):
                    state = objects["filter"].push(point)
                    labels = objects["labels"].advance(point)
                    forecast = None
                    if not state.reason:
                        forecast = objects["filter"].predict(300, 1)
                        objects["labels"].add(forecast)
                    outcomes.append((state, forecast, labels))
                if restored is not None:
                    self.assertEqual(outcomes[0], outcomes[1])
                    self.assertEqual(recovery.checkpoint(meta(i), original), recovery.checkpoint(meta(i), restored))
            if cut == 6:
                restored = roundtrip(original, 6)
            due = b.Point(305*b.SECOND, 7, .5)
            self.assertEqual(original["labels"].advance(due), restored["labels"].advance(due))
            self.assertEqual(original["ar1"].predict(due, 300, 1), restored["ar1"].predict(due, 300, 1))

    def test_opportunity_keeps_deadline_evaluations_and_explicit_trigger_sequence(self):
        signal = signals.Signal("pair-direction", signal_policy(), identity=(9, 1, 1))
        for i, score in enumerate((F(8, 10), F(9, 10), F(15, 10), F(21, 10), F(22, 10))):
            signal.observe(i, 96+i, score, qualified=True, cursor=10+i)
        self.assertTrue(signal.evaluate(100))
        self.assertTrue(signal.evaluate(103))
        restored = roundtrip({"signal": signal}, 14)["signal"]
        self.assertEqual((restored.trigger_cursor, restored.trigger_grid), (14, 4))
        self.assertEqual(restored.opportunity, signal.opportunity)
        self.assertEqual(restored.evaluations_used, 2)
        self.assertFalse(restored.evaluate(111))
        self.assertIsNone(restored.opportunity)
        self.assertEqual(restored.evaluations_used, 2)
        legacy = signals.Signal("pair-direction", signal_policy(), identity=(9, 1, 1))
        for i, score in enumerate((0, 0, 1, 3, 3)):
            legacy.observe(i, i, score, qualified=True)
        with self.assertRaises(ValueError):
            recovery.checkpoint(meta(10), {"signal": legacy})

    def test_pending_reservation_is_reattached_to_same_signal_after_recovery(self):
        observations, option, cfg, approval, f = inputs()
        state = ready(option.plan, cfg)
        # The existing helper uses the legacy offline grid entry point.
        state = signals.Signal(state.scope, cfg.signal, identity=(9, 1, 1))
        state.activate("web-activation", 0)
        state.observe(1, T-1, 0, qualified=True, cursor=5)
        state.observe(2, T, 3, qualified=True, cursor=6)
        batch = admission.Admission(cfg)
        request = batch.propose(observations, (option,), (approval,), (state,), f).request
        original = {"admission": batch, "signal": state}
        restored = roundtrip(original, 7)
        self.assertEqual(restored["admission"].propose((), (), (), (), f).query_identity, request.identity)
        for components in (original, restored):
            components["admission"].reply(request.identity, "reserved", cursor=8, fact_ref="reservation-8")
        self.assertEqual(recovery.checkpoint(meta(8), original), recovery.checkpoint(meta(8), restored))
        self.assertEqual(restored["signal"].active, request.identity)
        self.assertIsNone(restored["signal"].pending)

    def test_monitor_duplicate_maturity_and_independent_risk_latches_survive(self):
        monitor = signals.Monitor((signals.Metric("error", 1, 2, 3, 5, 10),),
                                  warn_windows=2, fail_windows=2, clear_windows=2)
        signal = signals.Signal("pair-direction", signal_policy(), identity=(9, 1, 1))
        signal.lock("daily_loss", "loss-fact")
        signal.lock("restart", "restart-fact")
        for i in (1, 2):
            monitor.update((signals.Window("error", i, i, 3, 5, True),), at_ns=i, independent_evidence=True)
        restored = roundtrip({"monitor": monitor, "signal": signal}, 2)
        self.assertEqual(restored["monitor"].state, "InvalidLatched")
        for current in (monitor, restored["monitor"]):
            current.update((signals.Window("error", 2, 2, 3, 5, True),), at_ns=2, independent_evidence=True)
            current.update((signals.Window("error", 3, 3, 0, 5, False),), at_ns=3, independent_evidence=True)
            with self.assertRaises(ValueError):
                current.recover(review_ref="r", reconciliation_ref="c", authorization_ref="a")
        restored["signal"].recover("restart", cause_ref="restart-fact", recovery_ref="review")
        self.assertEqual(restored["signal"].reasons, {"daily_loss": "loss-fact"})

    def test_cycle_all_phases_unknown_and_latched_exit_continue_with_original_identity(self):
        current = cycle.Cycle(plan())
        current.start(cursor=1, at_ns=T)
        position = entry(5)
        estimator = estimator_for((path("holding", position=position),), current.plan.policy, 80_000_000)
        partial = facts(orders=(done(1, 0, 5), done(2, 1, 5)), positions=(F(5), F(5)),
                        safe_reduce_lots=(5, 5), economic_entry=position, market=market(0, 1100), at_ns=T)
        stages = [
            (partial, dict(estimator=estimator, limits=LIMITS)),
            (replace(partial, cursor=3, at_ns=T+1, risk_causes=(("manual", "stop-3"),), reducing_allowed=False), {}),
            (replace(partial, cursor=4, at_ns=T+2, orders=(done(1, 0, 5),
                done(2, 1, 5, status="unknown", possible_lots=0)),
                possible_base=((F(5), F(5)), (F(5), F(5)))), {}),
            (replace(partial, cursor=5, at_ns=T+3), {}),
            (facts(6, orders=(done(1, 0, 5), done(2, 1, 5), done(3, 0, 5), done(4, 1, 5))), {}),
            (facts(7, orders=(done(1, 0, 5), done(2, 1, 5), done(3, 0, 5), done(4, 1, 5)), closed_ref="closed-7"), {}),
        ]
        for f, kwargs in stages:
            restored = roundtrip({"cycle": current}, current.cursor, current.next_sequence)["cycle"]
            self.assertEqual(current.apply(f, **kwargs), restored.apply(f, **kwargs))
            self.assertEqual(recovery.checkpoint(meta(f.cursor, current.next_sequence), {"cycle": current}),
                             recovery.checkpoint(meta(f.cursor, restored.next_sequence), {"cycle": restored}))
            self.assertEqual(restored.apply(f).reason, "duplicate_cursor")
            with self.assertRaises(ValueError):
                restored.apply(replace(f, economic_ref="conflicting-content"))
        self.assertEqual(current.phase, "completed")
        self.assertEqual(current.first_exit, ("manual", 3))
        self.assertEqual(current.target_atoms, 40_000_000)

    def test_repair_and_downtime_keep_original_deadlines_and_budgets(self):
        current = cycle.Cycle(plan())
        current.start(cursor=1, at_ns=T)
        partial = facts(orders=(done(1, 0, 10), done(2, 1, 6)), positions=(F(10), F(6)), safe_reduce_lots=(10, 6))
        current.apply(partial)
        restored = roundtrip({"cycle": current}, 2, 4)["cycle"]
        self.assertEqual(restored.repair_used, 1)
        timed_out = replace(partial, cursor=3, at_ns=T+151,
                            orders=partial.orders+(done(3, 1, 0),))
        a, z = current.apply(timed_out), restored.apply(timed_out)
        self.assertEqual(a, z)
        self.assertTrue(z.escalate)
        self.assertFalse(z.intents)
        self.assertEqual(restored.first_exit, ("deadline", 3))

    def test_unknown_after_exit_preserves_settling_and_completed_stages(self):
        current = cycle.Cycle(plan())
        current.start(cursor=1, at_ns=T)
        position = entry(5)
        estimator = estimator_for((path("holding", position=position),), current.plan.policy, 80_000_000)
        holding = facts(orders=(done(1, 0, 5), done(2, 1, 5)), positions=(F(5), F(5)),
                        safe_reduce_lots=(5, 5), economic_entry=position, market=market(0, 1100), at_ns=T)
        current.apply(holding, estimator=estimator, limits=LIMITS)
        current.apply(replace(holding, cursor=3, at_ns=T+1, market=market(1, 1000)))
        flat = facts(4, orders=holding.orders+(done(3, 0, 5), done(4, 1, 5)))
        for closed in (None, "closed-4"):
            selected = copy.deepcopy(current)
            selected.apply(replace(flat, closed_ref=closed))
            before = selected.phase
            unknown = replace(flat, cursor=5, at_ns=T+5, admission="unknown", closed_ref=closed,
                              possible_base=((F(0), F(0)), (F(0), F(0))))
            selected.apply(unknown)
            restored = roundtrip({"cycle": selected}, 5, 5)["cycle"]
            self.assertEqual(restored.before_reconciling, before)
            self.assertEqual(restored.first_exit, ("take_profit", 3))
            known = replace(flat, cursor=6, at_ns=T+6, closed_ref=closed)
            self.assertEqual(selected.apply(known), restored.apply(known))

    def test_checkpoint_rejects_dependency_version_and_impossible_state_without_mutating_templates(self):
        current = cycle.Cycle(plan())
        current.start(cursor=1, at_ns=T)
        saved = recovery.checkpoint(meta(1, 3), {"cycle": current})
        wrong = cycle.Cycle(replace(plan(), exit_deadline_ns=T+200))
        with self.assertRaises(ValueError):
            recovery.restore(saved, {"cycle": wrong})
        self.assertEqual(wrong.phase, "idle")
        metadata_, state = host.decode_checkpoint(saved)
        def reject(change):
            broken = copy.deepcopy(state)
            change(broken["components"][0]["state"])
            with self.assertRaises(ValueError):
                recovery.restore(host.encode_checkpoint(metadata_, broken), {"cycle": current})
        reject(lambda v: v.update(phase="holding"))
        reject(lambda v: v.update(next_sequence=4))
        reject(lambda v: v.update(repair_used=3))
        reject(lambda v: v.update(pending=[7]))
        reject(lambda v: v.update(before_reconciling={"tag": "present", "value": "exiting"}))
        reject(lambda v: v.update(unknown_field=0))
        metadata_["state_schema_version"] = 3
        with self.assertRaises(ValueError):
            host.encode_checkpoint(metadata_, state)

    def test_silent_signal_and_admission_cannot_restore_under_other_strategy_or_config(self):
        signal = signals.Signal("pair", signal_policy(), identity=(8, 1, 1))
        with self.assertRaises(ValueError):
            recovery.checkpoint(meta(strategy=9), {"signal": signal})
        _, _, cfg, _, _ = inputs()
        wrong = meta()
        wrong["config_version"] = 2
        with self.assertRaises(ValueError):
            recovery.checkpoint(wrong, {"admission": admission.Admission(cfg)})

    def test_monitor_cannot_recover_with_fabricated_health_without_mature_windows(self):
        monitor = signals.Monitor((signals.Metric("error", 1, 2, 3, 5, 10),),
                                  warn_windows=2, fail_windows=2, clear_windows=2)
        saved = recovery.checkpoint(meta(), {"monitor": monitor})
        metadata_, state = host.decode_checkpoint(saved)
        state["components"][0]["state"].update(state="InvalidLatched", qualified=True, good_windows=2)
        with self.assertRaises(ValueError):
            recovery.restore(host.encode_checkpoint(metadata_, state), {"monitor": monitor})

    def test_filter_prior_uses_binary64_semantics_before_first_observation(self):
        model = ss.Filter(parameters(prior_mean=((1 << 53)+1, 0)))
        restored = roundtrip({"model": model})["model"]
        self.assertEqual(model.state, restored.state)
        self.assertEqual(model.push(b.Point(0, 1, 1.)), restored.push(b.Point(0, 1, 1.)))

    def test_real_host_transports_actual_components_and_rejects_old_session_and_missing_tail(self):
        current = cycle.Cycle(plan())
        current.start(cursor=1, at_ns=T)
        saved = recovery.checkpoint(meta(1, 3), {"cycle": current})
        session = (1, 0, 1)
        def run(*, wrong_session=False, barrier=1):
            wire = io.BytesIO()
            plan_bytes = bytearray(176)
            struct.pack_into("<QI4xQ", plan_bytes, 48, *session)
            host.write_frame(wire, host.SESSION_PLAN, session, 1, plan_bytes)
            host.write_frame(wire, host.BEGIN_RECOVERY, session, 2, struct.pack("<Q", barrier)+saved)
            host.write_frame(wire, host.REQUEST_CHECKPOINT, (2, 0, 1) if wrong_session else session,
                             3, struct.pack("<QQ", 1, 1))
            host.write_frame(wire, host.SHUTDOWN, session, 4)
            return subprocess.run([sys.executable, host.__file__, "--mode", "portable", "--strategy-identity", "9"],
                                  input=wire.getvalue(), capture_output=True, timeout=20)
        result = run()
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        frames = io.BytesIO(result.stdout)
        output = [host.read_frame(frames) for _ in range(5)]
        self.assertEqual([x[0] for x in output], [host.HOST_HELLO, host.HOST_HEARTBEAT,
                         host.STRATEGY_RECOVERED, host.CHECKPOINT_CONTENT, host.SHUTDOWN_ACK])
        restored_meta, restored = recovery.restore(output[3][3][8:], {"cycle": cycle.Cycle(plan())})
        self.assertEqual(recovery.checkpoint(restored_meta, restored), saved)
        self.assertNotEqual(run(wrong_session=True).returncode, 0)
        self.assertNotEqual(run(barrier=2).returncode, 0)

    def test_model_bits_and_nonfinite_negative_covariance_capacity_are_checked(self):
        model = ss.Filter(parameters(prior_mean=(-0., float.fromhex("0x0.0000000000001p-1022"))))
        components = {"model": model}
        saved = recovery.checkpoint(meta(), components)
        restored = recovery.restore(saved, components)[1]
        self.assertEqual(recovery.checkpoint(meta(), restored), saved)
        metadata_, state = host.decode_checkpoint(saved)
        for bad in ("7ff0000000000000", "fff8000000000000", "bff0000000000000"):
            broken = copy.deepcopy(state)
            broken["components"][0]["state"]["_state"]["covariance"][0] = bad
            with self.assertRaises(ValueError):
                host.encode_checkpoint(metadata_, broken)
        broken = copy.deepcopy(state)
        broken["components"] *= 65
        with self.assertRaises(ValueError):
            host.encode_checkpoint(metadata_, broken)

    def test_integer_observations_have_binary64_semantics_before_and_after_checkpoint(self):
        tracker = b.LabelTracker(2)
        first = b.Point(0, 1, (1 << 53)+1)
        model = b.AR1(1, 0, 0., .5, .1, 1e-8, 1e-9, 0.)
        tracker.add(model.predict(first, 300, 1))
        restored = roundtrip({"labels": tracker}, 1)["labels"]
        end = b.Point(300*b.SECOND, 2, (1 << 53)+2)
        self.assertEqual(tracker.advance(end), restored.advance(end))

    def test_different_batch_boundaries_checkpoint_cuts_and_duplicate_signal_grids(self):
        events = [(i, 96+i, F(score)) for i, score in enumerate((0, 0, 1, 3, 3, 3, 3))]
        baseline = signals.Signal("pair", signal_policy(), identity=(9, 1, 1))
        for grid, at_ns, score in events:
            baseline.observe(grid, at_ns, score, qualified=True, cursor=grid+1)
        expected = recovery.checkpoint(meta(7), {"signal": baseline})
        for cut in range(8):
            current = signals.Signal("pair", signal_policy(), identity=(9, 1, 1))
            for batch in (events[:cut], events[cut:]):
                for grid, at_ns, score in batch:
                    current.observe(grid, at_ns, score, qualified=True, cursor=grid+1)
                    current.observe(grid, at_ns, score, qualified=True, cursor=grid+1)
                cursor = 0 if not batch and cut == 0 else (batch[-1][0]+1 if batch else 7)
                current = roundtrip({"signal": current}, cursor)["signal"]
            self.assertEqual(recovery.checkpoint(meta(7), {"signal": current}), expected)

    def test_current_permission_and_activation_are_not_restored_by_private_checkpoint(self):
        observations, option, cfg, approval, f = inputs()
        state = signals.Signal(admission.signal_scope(option.plan.pair, option.plan.policy.direction), cfg.signal, identity=(9, 1, 1))
        state.activate("web-activation", 0)
        state.observe(1, T-1, 0, qualified=True, cursor=5)
        state.observe(2, T, 3, qualified=True, cursor=6)
        restored = roundtrip({"signal": state, "admission": admission.Admission(cfg)}, 6)
        # A checkpoint's old activation is not a current opening fact.
        denied = restored["admission"].propose(observations, (option,), (approval,),
            (restored["signal"],), replace(f, opening_allowed=False))
        self.assertIsNone(denied.request)
        self.assertIsNone(restored["signal"].opportunity)
        restored["signal"].activate("new-web-activation", T+1)
        self.assertIsNone(restored["signal"].opportunity)

    def test_probability_ppm_and_tick_target_atomic_boundaries_have_identical_decisions(self):
        for ppm in (679_999, 680_000, 680_001):
            for target_delta in (-1, 0, 1):
                frozen = policy(min_entry_probability=F(ppm, 1_000_000))
                scenario = path("boundary")
                estimator = estimator_for((scenario,), frozen)
                artifact = calibration(scope=evaluation.probability_scope(frozen, 8_000_000, F(1), T),
                    margin=F(7, 100), model_hash=frozen.model_hash,
                    simulation_hash=estimator.probability_model_hash(frozen))
                components = {"estimator": estimator, "calibration": artifact}
                restored = roundtrip(components)
                expected = evaluation.evaluate((scenario,), frozen, estimator, artifact, EXACT, LIMITS)
                actual = evaluation.evaluate((scenario,), frozen, restored["estimator"], restored["calibration"], EXACT, LIMITS)
                self.assertEqual(actual, expected)
                self.assertEqual(actual.allowed, ppm <= 680_000)
                # A one-atom target moves the equality comparison at a fixed tick.
                current = cycle.Cycle(plan(target_atoms=80_000_000+2*target_delta))
                current.start(cursor=1, at_ns=T)
                position = entry(5)
                holding = facts(orders=(done(1, 0, 5), done(2, 1, 5)), positions=(F(5), F(5)),
                    safe_reduce_lots=(5, 5), economic_entry=position, market=market(0, 1100), at_ns=T)
                frozen_estimator = estimator_for((path("holding", position=position),), current.plan.policy,
                                                current.plan.target_atoms)
                current.apply(holding, estimator=frozen_estimator, limits=LIMITS)
                restored_cycle = roundtrip({"cycle": current}, 2, 3)["cycle"]
                for tick in (1019, 1020, 1021):
                    # Independent copies make each comparison start at Holding.
                    original_copy, recovered_copy = copy.deepcopy(current), copy.deepcopy(restored_cycle)
                    f = replace(holding, cursor=3, at_ns=T+1, market=market(1, tick))
                    self.assertEqual(original_copy.apply(f), recovered_copy.apply(f))
                    net = evaluation.value_exit(position, f.market, current.plan.policy, normal=True).net_atoms
                    self.assertEqual(recovered_copy.phase == "exiting", net >= current.target_atoms)
