"""Synthetic public Maker shadow regressions; no market evidence."""
import copy
from dataclasses import replace
from fractions import Fraction as F
import json
import unittest

from strategies.cross_venue import arbitrage_maker as maker
from strategies.cross_venue import arbitrage_maker_shadow as shadow
from strategies.cross_venue import arbitrage_shadow as taker
from strategies.cross_venue import arbitrage_signals as signals
from test_arbitrage_admission import inputs, ready
from test_arbitrage_scanner import fixture as scan_fixture
from test_arbitrage_maker import maker_plan, quote
from test_arbitrage_cycle import facts, done, market, T
from test_arbitrage_checkpoint import meta


def fixture():
    _, option, cfg, approval, core = inputs()
    obs, plan = scan_fixture("maker_taker", 0)
    option = replace(option, plan=plan)
    approval = replace(approval, key=plan.key)
    state = signals.Signal(ready(plan, cfg).scope, cfg.signal, identity=(9, 1, 1))
    state.activate("web-activation", 0)
    state.observe(1, T-1, 0, qualified=True, cursor=5)
    state.observe(2, T, 3, qualified=True, cursor=6)
    cycle = maker.Cycle(maker_plan())
    cycle.start(cursor=1, at_ns=T, market=market(0, 1100), quotes=(quote(),))
    monitor = signals.Monitor((signals.Metric("error", 1, 2, 3, 1, 100),),
                              warn_windows=1, fail_windows=1, clear_windows=1)
    protocol = taker.Protocol("synthetic-maker", "a"*64, "pending-13", 1, 1,
                              10**10, 32, 10**6, 10**6, 0, 1)
    f = facts(7, at_ns=T, market=market(0, 1100),
              orders=(done(1, 0, 3, status="sent", possible_lots=7),),
              positions=(F(3), F(0)), safe_reduce_lots=(3, 0))
    frame = shadow.Frame(obs, (option,), (approval,), core, (),
                         (signals.Window("error", 1, T, F(0), 1, True),), True,
                         cycle_facts=f)
    def factory(**changes):
        return shadow.Session(replace(protocol, **changes), cfg, (state,), monitor, meta(cursor=6, next_intent=2), cycle)
    return factory, frame, cycle, state


class MakerShadowTests(unittest.TestCase):
    def test_private_cycle_replay_and_counterfactual_hedge_have_no_sendable_output(self):
        factory, frame, cycle, state = fixture()
        before = (copy.deepcopy(vars(cycle)), copy.deepcopy(vars(state)))
        run = factory()
        row = run.step(frame)
        self.assertEqual(row["error"], "")
        self.assertEqual(row["maker"]["reason"], "incremental_hedge")
        self.assertEqual(row["maker"]["orders"][0]["lots"], 3)
        self.assertEqual(row["maker"]["evidence"], "counterfactual_simulation")
        self.assertTrue(all(x["mode"] == "maker_taker" for x in row["candidates"]))
        self.assertFalse(row["trading_qualified"])
        self.assertEqual((vars(cycle), vars(state)), before)
        self.assertEqual(taker.replay(run.capture_json(), (frame,), factory)["matched"], 1)
        self.assertEqual(run.report()["mode"], "maker_taker")
        self.assertFalse(run.report()["qualification"])
        json.dumps(row)

    def test_admitted_idle_cycle_selects_quote_and_denied_whitelist_never_starts(self):
        from strategies.cross_venue import arbitrage_admission as admission
        from opportunity_scanner import arbitrage_scanner as scanner
        factory, frame, _, state = fixture()
        _, _, cfg, approval, core = inputs()
        p = maker_plan(config_hash=cfg.content_hash,
            policy=replace(maker_plan().policy, scope=frame.options[0].plan.policy.scope))
        q = quote(p)
        observations = tuple(replace(o, book=q.market.books[i]) for i, o in enumerate(frame.observations))
        plan = scanner.Plan(tuple(o.identity for o in observations), 0, q.scenarios, p.policy,
                            q.estimator, q.calibration, q.simulation_error, q.limits, T+50, 200_000_000)
        option = replace(frame.options[0], plan=plan, lots=(10, 10))
        request = admission.Admission(cfg).propose(observations, (option,), frame.approvals, (copy.deepcopy(state),), core).request
        self.assertIsNotNone(request)
        p = replace(p, target_atoms=request.target_atoms)
        idle = maker.Cycle(p)
        monitor = signals.Monitor((signals.Metric("error", 1, 2, 3, 1, 100),),
                                 warn_windows=1, fail_windows=1, clear_windows=1)
        def make():
            return shadow.Session(factory().protocol, cfg, (state,), monitor, meta(cursor=6), idle)
        frame = replace(frame, observations=observations, options=(option,), quotes=(q,),
                        cycle_facts=replace(frame.cycle_facts, orders=(), positions=(F(0), F(0)), safe_reduce_lots=(0, 0)))
        row = make().step(frame)
        self.assertEqual(row["error"], "")
        self.assertEqual(row["maker"]["reason"], "maker_quote")
        self.assertEqual(row["maker"]["orders"][0]["time_in_force"], "post-only")
        self.assertEqual(idle.phase, "idle")
        denied = make().step(replace(frame, approvals=()))
        self.assertEqual(denied["maker"]["reason"], "not_admitted")
        self.assertEqual(denied["maker"]["orders"], [])
        run = make()
        run.step(frame)
        self.assertEqual(taker.replay(run.capture_json(), (frame,), make)["matched"], 1)

    def test_restart_recomputes_real_maker_checkpoint_without_duplicate_hedge(self):
        factory, first, _, _ = fixture()
        run = factory()
        run.step(first)
        second = replace(first, facts=replace(first.facts, cursor=8, at_ns=T+1),
            cycle_facts=replace(first.cycle_facts, cursor=8, at_ns=T+1, market=market(1, 1100)),
            observations=tuple(replace(o, book=market(1, 1100).books[i]) for i, o in enumerate(first.observations)),
            windows=(replace(first.windows[0], sequence=2, cutoff_ns=T+1),), restart=True)
        row = run.step(second)
        self.assertEqual(row["error"], "")
        self.assertEqual(row["maker"]["orders"], [])
        self.assertEqual(run.report()["restarts"], 1)
        self.assertEqual(taker.replay(run.capture_json(), (first, second), factory)["matched"], 2)

    def test_whitelist_revocation_health_and_version_cancel_preserve_inflight_hedge(self):
        factory, first, _, _ = fixture()
        for changes in ({"approvals": ()},
                        {"approvals": (replace(first.approvals[0], policy_version=2),)},
                        {"windows": (replace(first.windows[0], value=F(3)),)},
                        {"observations": (replace(first.observations[0], continuous=False), first.observations[1])}):
            run = factory()
            row = run.step(replace(first, **changes))
            self.assertEqual(row["error"], "")
            self.assertEqual(row["maker"]["cancels"], [1])
            self.assertEqual(row["maker"]["orders"], [])
            self.assertIsNone(row["suggestion"])
            self.assertFalse(run.report()["qualification"])

    def test_requote_waits_for_terminal_and_unknown_hedge_restores_without_reissue(self):
        factory, frame, _, _ = fixture()
        run = factory()
        def next_frame(cursor, at, orders, quotes=(), **changes):
            f = facts(cursor, at_ns=T+at, market=market(at, 1100, bid_a=999), orders=orders, **changes)
            return replace(frame, facts=replace(frame.facts, cursor=cursor, at_ns=T+at), cycle_facts=f,
                observations=tuple(replace(o, book=f.market.books[i]) for i, o in enumerate(frame.observations)),
                quotes=quotes, windows=(replace(frame.windows[0], sequence=cursor, cutoff_ns=T+at),))
        repricing = next_frame(7, 3, (done(1, 0, 0, status="sent", possible_lots=10),),
                               (quote(ticks=999, at=3, bid=999, economic_ref="economic:0"),))
        row = run.step(repricing)
        self.assertEqual((row["maker"]["cancels"], row["maker"]["orders"]), ([1], []))
        terminal = next_frame(8, 5, (done(1, 0, 0),),
                             (quote(ticks=999, at=5, bid=999, economic_ref="economic:0"),))
        row = run.step(replace(terminal, restart=True))
        self.assertEqual(row["error"], "")
        self.assertEqual((row["maker"]["orders"][0]["sequence"], row["maker"]["orders"][0]["limit_ticks"]), (2, 999))
        self.assertEqual(taker.replay(run.capture_json(), (repricing, replace(terminal, restart=True)), factory)["matched"], 2)
        run = factory()
        run.step(frame)
        unknown = next_frame(8, 2, (done(1, 0, 5, status="sent", possible_lots=5),
            done(2, 1, 0, status="unknown", possible_lots=3, economic_complete=False)),
            positions=(F(5), F(0)), safe_reduce_lots=(5, 0), possible_base=((F(5), F(10)), (F(0), F(3))))
        row = run.step(replace(unknown, restart=True))
        self.assertEqual(row["error"], "")
        self.assertEqual(row["maker"]["orders"], [])
        self.assertEqual(row["maker"]["queries"], [2])
        self.assertEqual(row["maker"]["exposure"], ["2", "10"])

    def test_invalid_monitor_latches_controlled_exit_across_restart(self):
        factory, frame, _, _ = fixture()
        run = factory()
        invalid = replace(frame, windows=(replace(frame.windows[0], value=F(3)),))
        row = run.step(invalid)
        self.assertEqual(row["maker"]["phase"], "exiting")
        second = replace(frame, facts=replace(frame.facts, cursor=8, at_ns=T+1), restart=True,
            cycle_facts=replace(frame.cycle_facts, cursor=8, at_ns=T+1, market=market(1, 1100),
                                orders=(done(1, 0, 3),)),
            observations=tuple(replace(o, book=market(1, 1100).books[i]) for i, o in enumerate(frame.observations)),
            windows=(replace(frame.windows[0], sequence=2, cutoff_ns=T+1),))
        row = run.step(second)
        self.assertEqual(row["error"], "")
        self.assertEqual(row["maker"]["reason"], "exit")
        self.assertTrue(all(o["reducing"] for o in row["maker"]["orders"]))
        self.assertEqual(taker.replay(run.capture_json(), (invalid, second), factory)["matched"], 2)

    def test_mode_and_frame_identity_cannot_mix_with_taker(self):
        from test_arbitrage_shadow import fixture as taker_fixture
        factory, frame, _, _ = fixture()
        tf, tframe, _ = taker_fixture()
        with self.assertRaisesRegex(ValueError, "shadow_frame"):
            factory().step(tframe)
        with self.assertRaisesRegex(ValueError, "shadow_frame"):
            tf().step(frame)
        run = factory()
        run.step(frame)
        with self.assertRaisesRegex(ValueError, "shadow_mode"):
            taker.replay(run.capture_json(), (frame,), tf)
        changed = json.loads(run.capture_json())
        changed["records"][0]["decision"]["maker"]["orders"][0]["lots"] = 4
        with self.assertRaisesRegex(ValueError, "decision:0"):
            taker.replay(json.dumps(changed), (frame,), factory)
        with self.assertRaisesRegex(ValueError, "maker_shadow_cursor"):
            replace(frame, cycle_facts=replace(frame.cycle_facts, cursor=8))

    def test_cycle_market_scope_and_core_permission_cannot_bypass_scan(self):
        factory, frame, _, _ = fixture()
        row = factory().step(replace(frame, facts=replace(frame.facts, opening_allowed=False)))
        self.assertEqual(row["maker"]["orders"], [])
        self.assertEqual(row["maker"]["cancels"], [1])
        mismatch = replace(frame, cycle_facts=replace(frame.cycle_facts, market=market(0, 1110)))
        row = factory().step(mismatch)
        self.assertEqual(row["error"], "maker_shadow_market")
        self.assertIsNone(row["suggestion"])
        self.assertNotIn("maker", row)

    def test_maker_budget_capacity_gap_and_missing_real_evidence(self):
        factory, frame, _, _ = fixture()
        run = factory(max_compute_ns=1)
        run.step(replace(frame, observations=(replace(frame.observations[0], continuous=False), frame.observations[1])))
        report = run.report()
        self.assertIn("compute", report["reasons"])
        self.assertIn("gaps", report["reasons"])
        self.assertEqual(report["calibration_ref"], "pending-13")
        self.assertEqual(report["actual_fills"], "not_observed")
        self.assertEqual(report["queue_evidence"], "not_observed")
        full = factory(max_capture_bytes=10)
        with self.assertRaisesRegex(ValueError, "shadow_capture_capacity"):
            full.step(frame)
        self.assertEqual(full.report()["frames"], 0)
        self.assertFalse(full.report()["qualification"])


if __name__ == "__main__":
    unittest.main()
