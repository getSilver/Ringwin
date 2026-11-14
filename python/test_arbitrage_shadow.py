"""Synthetic public read-only driver regressions; no market qualification."""
import copy
from dataclasses import replace
from fractions import Fraction as F
import json
import unittest
from unittest.mock import patch

from strategies.cross_venue import arbitrage_shadow as shadow
from strategies.cross_venue import arbitrage_signals as signals
from test_arbitrage_admission import inputs, ready
from test_arbitrage_checkpoint import meta


def fixture():
    obs, option, cfg, approval, facts = inputs()
    state = signals.Signal(ready(option.plan, cfg).scope, cfg.signal, identity=(9, 1, 1))
    state.activate("web-activation", 0)
    state.observe(1, facts.at_ns-1, 0, qualified=True, cursor=5)
    state.observe(2, facts.at_ns, 3, qualified=True, cursor=6)
    monitor = signals.Monitor((signals.Metric("error", 1, 2, 3, 1, 100),),
                              warn_windows=1, fail_windows=1, clear_windows=1)
    protocol = shadow.Protocol("synthetic-v1", "a"*64, "pending-12", 1, 1,
                               10**10, 32, 10**6, 10**6, 0, 1)
    frame = shadow.Frame(obs, (option,), (approval,), facts, (),
                         (signals.Window("error", 1, facts.at_ns, F(0), 1, True),), True)
    def session(**changes):
        return shadow.Session(replace(protocol, **changes), cfg, (state,), monitor, meta(cursor=6))
    return session, frame, state


class ShadowTests(unittest.TestCase):
    def test_real_scan_and_whitelist_recheck_are_read_only_and_replay_detects_divergence(self):
        factory, frame, original = fixture()
        before = copy.deepcopy(vars(original))
        run = factory()
        row = run.step(frame)
        self.assertEqual(row["suggestion"]["plan_atoms"], 8_000_000)
        self.assertEqual(row["candidates"][0]["mode"], "taker_taker")
        self.assertFalse(row["trading_qualified"])
        self.assertEqual(vars(original), before)
        self.assertEqual(row["monitor_actions"], [])
        capture = run.capture_json()
        self.assertEqual(shadow.replay(capture, (frame,), factory)["matched"], 1)
        changed = json.loads(capture)
        changed["records"][0]["decision"]["suggestion"]["plan_atoms"] = 1
        with self.assertRaisesRegex(ValueError, "decision:0"):
            shadow.replay(json.dumps(changed), (frame,), factory)
        changed["records"][0]["decision"]["suggestion"]["plan_atoms"] = 8_000_000.0
        with self.assertRaisesRegex(ValueError, "decision:0"):
            shadow.replay(json.dumps(changed), (frame,), factory)
        denied = factory().step(replace(frame, approvals=()))
        self.assertIsNone(denied["suggestion"])
        self.assertIn("not_approved", [x[1] for x in denied["rejections"]])

    def test_restart_uses_actual_checkpoint_and_monitor_remains_latched(self):
        factory, frame, _ = fixture()
        run = factory()
        first = replace(frame, windows=(replace(frame.windows[0], value=F(3)),))
        self.assertIsNone(run.step(first)["suggestion"])
        second = replace(frame, facts=replace(frame.facts, cursor=8, at_ns=frame.facts.at_ns+1),
                         windows=(replace(frame.windows[0], sequence=2, cutoff_ns=frame.facts.at_ns+1),), restart=True)
        row = run.step(second)
        self.assertEqual(row["monitor_state"], "InvalidLatched")
        self.assertEqual(row["monitor_actions"], ["stop_new_cycles", "cancel_entry", "controlled_exit"])
        self.assertEqual(row["error"], "")
        self.assertEqual(run.report()["restarts"], 1)
        self.assertIn("monitor_health", run.report()["reasons"])
        self.assertEqual(shadow.replay(run.capture_json(), (first, second), factory)["matched"], 2)

    def test_gaps_staleness_version_and_load_are_reported_without_qualification(self):
        factory, frame, _ = fixture()
        run = factory()
        run.step(replace(frame, observations=(replace(frame.observations[0], continuous=False), frame.observations[1])))
        second = replace(frame, facts=replace(frame.facts, cursor=8, at_ns=frame.facts.at_ns+11),
                         approvals=(replace(frame.approvals[0], policy_version=2),),
                         windows=(replace(frame.windows[0], sequence=2, cutoff_ns=frame.facts.at_ns+11),))
        row = run.step(second)
        self.assertIn("approval_version", [x[1] for x in row["rejections"]])
        report = run.report()
        self.assertEqual((report["gap_frames"], report["version_changes"]), (1, 1))
        self.assertFalse(report["qualification"])
        self.assertEqual(report["real_host"], "not_run")
        self.assertIn("gaps", report["reasons"])
        # Tight preregistered freshness limit, independent of scanner's threshold.
        tight = factory(max_age_ns=1, min_options_per_frame=2)
        tight.step(replace(frame, facts=replace(frame.facts, at_ns=frame.facts.at_ns+1)))
        self.assertIn("load", tight.report()["reasons"])
        self.assertIn("freshness", tight.report()["reasons"])

    def test_capture_limit_latches_failure_and_never_silently_discards(self):
        factory, frame, _ = fixture()
        run = factory(max_capture_bytes=10)
        with self.assertRaisesRegex(ValueError, "shadow_capture_capacity"):
            run.step(frame)
        self.assertEqual(run.report()["frames"], 0)
        self.assertIn("capture_capacity", run.report()["reasons"])
        with self.assertRaisesRegex(ValueError, "shadow_capture_capacity"):
            run.step(frame)

    def test_bad_input_and_replay_shape_fail_closed(self):
        factory, frame, _ = fixture()
        with self.assertRaisesRegex(ValueError, "shadow_signal_input"):
            replace(frame, scores=((),))
        run = factory()
        run.step(frame)
        with self.assertRaisesRegex(ValueError, "shadow_order"):
            run.step(frame)
        with self.assertRaisesRegex(ValueError, "input:0"):
            shadow.replay(run.capture_json(), (replace(frame, approvals=()),), factory)
        with self.assertRaisesRegex(ValueError, "shadow_capture_shape"):
            shadow.replay(run.capture_json(), (), factory)

    def test_component_rejection_is_visible_and_synthetic_gates_never_authorize(self):
        factory, frame, _ = fixture()
        run = factory()
        bad = replace(frame, observations=(frame.observations[0],)*2)
        row = run.step(bad)
        self.assertEqual(row["error"], "duplicate_observation")
        self.assertIn("input_or_component_error", run.report()["reasons"])
        self.assertIsNone(row["suggestion"])
        self.assertEqual(row["monitor_state"], "Normal")
        self.assertNotIn("controlled_exit", row["monitor_actions"])

    def test_whitelist_revocation_cannot_resurrect_cached_signal(self):
        factory, frame, _ = fixture()
        run = factory()
        run.step(replace(frame, approvals=()))
        second = replace(frame, facts=replace(frame.facts, cursor=8), restart=True)
        row = run.step(second)
        self.assertIn("signal_not_ready", [x[1] for x in row["rejections"]])
        self.assertIsNone(row["suggestion"])

    def test_signal_rearms_only_from_new_grid_evidence_after_restart(self):
        factory, frame, _ = fixture()
        run = factory()
        revoked = replace(frame, approvals=())
        run.step(revoked)
        scope = ready(frame.options[0].plan, run.config).scope
        reset = replace(frame, facts=replace(frame.facts, cursor=8, at_ns=frame.facts.at_ns+1),
                        scores=((scope, 3, F(0), True),), restart=True,
                        windows=(replace(frame.windows[0], sequence=2, cutoff_ns=frame.facts.at_ns+1),))
        self.assertIn("signal_not_ready", [x[1] for x in run.step(reset)["rejections"]])
        trigger = replace(reset, facts=replace(reset.facts, cursor=9, at_ns=frame.facts.at_ns+2),
                          scores=((scope, 4, F(3), True),), restart=False,
                          windows=(replace(frame.windows[0], sequence=3, cutoff_ns=frame.facts.at_ns+2),))
        # Newly triggered signal reaches real scanner's stale-plan cutoff check.
        self.assertIn("evaluation_cutoff", [x[1] for x in run.step(trigger)["rejections"]])
        self.assertEqual(shadow.replay(run.capture_json(), (revoked, reset, trigger), factory)["matched"], 3)

    def test_explicit_budget_gates_and_passing_synthetic_run_still_unqualified(self):
        factory, frame, _ = fixture()
        run = factory()
        run.step(frame)
        second = replace(frame, facts=replace(frame.facts, cursor=8, at_ns=frame.facts.at_ns+1),
                         windows=(replace(frame.windows[0], sequence=2, cutoff_ns=frame.facts.at_ns+1),))
        run.step(second)
        self.assertTrue(run.report()["operational_gates_met"])
        self.assertFalse(run.report()["qualification"])
        slow = factory(max_compute_ns=1)
        slow.step(frame)
        self.assertIn("compute", slow.report()["reasons"])
        full = factory(max_frames=1)
        full.step(frame)
        with self.assertRaisesRegex(ValueError, "shadow_capture_capacity"):
            full.step(second)
        self.assertEqual(full.report()["frames"], 1)
        self.assertFalse(full.report()["operational_gates_met"])

    def test_capture_encoding_work_counts_toward_computation_budget(self):
        factory, frame, _ = fixture()
        run = factory(max_compute_ns=1)
        clock = [0]
        encode = json.dumps
        def slow_capture(value, **kwargs):
            if isinstance(value, dict) and value.get("schema") == shadow.SCHEMA and "records" in value:
                clock[0] += 1000
            return encode(value, **kwargs)
        # Inject cost at the platform clock/JSON boundary; strategy components stay real.
        with patch.object(shadow, "perf_counter_ns", side_effect=lambda: clock[0]), \
             patch.object(json, "dumps", side_effect=slow_capture):
            self.assertEqual(run.step(frame)["error"], "")
        self.assertIn("compute", run.report()["reasons"])
        self.assertEqual(run.report()["max_compute_ns"], 1000)


if __name__ == "__main__":
    unittest.main()
