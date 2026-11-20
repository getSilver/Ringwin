"""Injected certified projections, never a real Host/core/Venue acceptance."""
from dataclasses import replace
from fractions import Fraction as F
import struct
import unittest

from strategies.cross_venue import arbitrage_maker as m
from strategies.cross_venue import arbitrage_cycle as c
from strategies.cross_venue import arbitrage_evaluation as v
from strategies.cross_venue import arbitrage_checkpoint as recovery
from test_arbitrage_checkpoint import meta
from test_arbitrage_cycle import plan, facts, done, T, entry, market, path, estimator_for, LIMITS, with_price_units
from test_arbitrage_evaluation import calibration, EXACT


def maker_plan(**changes):
    base = plan()
    values = dict(vars(base), policy=replace(base.policy, mode="maker_taker"), maker_leg=0,
                  offsets=(0, 1), min_quote_interval_ns=3, max_requotes=2,
                  quote_lifetime_ns=18, improvement_atoms=1, max_unhedged_base=F(10),
                  tail_lifetime_ns=5, native_post_only=True)
    values.update(changes)
    return m.Plan(**values)


def quote(p=None, *, ticks=1000, at=0, bid=1000, economic_ref=None, applied=((), ())):
    p = maker_plan() if p is None else p
    evaluated_policy = replace(p.policy, at_ns=T+at)
    position = entry(10)
    legs = [replace(leg, rules=p.legs[i].rules, kind=p.legs[i].kind,
                    direction=p.legs[i].direction, account=p.legs[i].account,
                    entries=tuple(replace(t, fee=replace(t.fee, asset=p.legs[i].rules.quote_asset)) for t in leg.entries),
                    exit_fee=replace(leg.exit_fee, fee_asset=p.legs[i].rules.quote_asset)) for i, leg in enumerate(position.legs)]
    spec = legs[p.maker_leg]
    legs[p.maker_leg] = replace(spec, entries=(replace(spec.entries[0], ticks=ticks),))
    for i, prefix in enumerate(applied):
        if prefix:
            future = replace(legs[i].entries[0], identity="future:"+str(i), lots=10-sum(t.lots for t in prefix))
            legs[i] = replace(legs[i], entries=prefix+((future,) if future.lots else ()))
    position = replace(position, legs=tuple(legs))
    scenarios = (replace(path("maker-full", position=position), entry=replace(position, holding_at_ns=T+at),
                         markets=(market(at, 1100, bid_a=bid), market(at+1, 1018), market(at+6, 1020),
                                  market(100, 1000), market(105, 1000))),)
    estimator = estimator_for((path("source", position=position),), p.policy, p.target_atoms)
    scope = v.Context(scenarios[0].entry, scenarios[0].markets[0], p.target_atoms, evaluated_policy).scope
    estimator = replace(estimator, rows=tuple(replace(row, scope=scope, calibration=replace(row.calibration, mode="maker_taker", scope=scope))
                                              for row in estimator.rows))
    estimator = replace(estimator, rows=tuple(replace(row, calibration=replace(row.calibration,
        simulation_hash=estimator.probability_model_hash(evaluated_policy))) for row in estimator.rows))
    artifact = replace(calibration(scope=v.probability_scope(evaluated_policy, p.target_atoms,
        p.policy.original_base, T+at), model_hash=p.policy.model_hash,
        simulation_hash=estimator.probability_model_hash(evaluated_policy)), mode="maker_taker")
    stresses = tuple(m.Stress(name, 1_000_000, F(0), F(10)) for name in m.STRESS_CASES)
    return m.Quote(ticks, market(at, 1100, bid_a=bid), scenarios, estimator, artifact, EXACT, LIMITS, stresses,
                   economic_ref=economic_ref, applied_trades=applied)


class MakerTests(unittest.TestCase):
    def running(self, p=None):
        p = maker_plan() if p is None else p
        cycle = m.Cycle(p)
        cycle.start(cursor=1, at_ns=T, market=market(0, 1100), quotes=(quote(p),))
        return cycle

    def test_entry_native_post_only_and_one_active_quote(self):
        cycle = m.Cycle(maker_plan())
        action = cycle.start(cursor=1, at_ns=T, market=market(0, 1100), quotes=(quote(),))
        self.assertEqual([(i.sequence, i.leg, i.lots, i.limit_ticks, i.time_in_force) for i in action.intents],
                         [(1, 0, 10, 1000, "post-only")])
        batch = bytearray(96)
        struct.pack_into("<Q", batch, 88, 1)
        encoded = with_price_units(action).encode(bytes(batch), (1, 0, 1), activation=5)
        self.assertEqual(tuple(encoded[131:133]), (2, 3))
        self.assertFalse(cycle.start(cursor=1, at_ns=T, market=market(0, 1100), quotes=(quote(),)).intents)
        with self.assertRaises(ValueError):
            maker_plan(native_post_only=False)

    def test_unique_applied_increment_subtracts_inflight_possible_hedge(self):
        cycle = self.running()
        f = facts(orders=(done(1, 0, 3, status="sent", possible_lots=7),),
                  positions=(F(3), F(0)), safe_reduce_lots=(3, 0))
        action = cycle.apply(f)
        self.assertEqual([(i.sequence, i.leg, i.lots) for i in action.intents], [(2, 1, 3)])
        self.assertFalse(cycle.apply(replace(f, cursor=3)).intents)
        f = replace(f, cursor=4, orders=(done(1, 0, 5, status="sent", possible_lots=5),
            done(2, 1, 1, status="sent", possible_lots=2)), positions=(F(5), F(1)), safe_reduce_lots=(5, 1))
        action = cycle.apply(f)
        self.assertEqual([(i.sequence, i.lots) for i in action.intents], [(3, 2)])
        self.assertFalse(action.cancels)

    def test_safety_cancel_ignores_reprice_interval_and_fill_during_cancel_is_hedged(self):
        cycle = self.running()
        f = facts(orders=(done(1, 0, 0, status="sent", possible_lots=10),), model_warning=True)
        action = cycle.apply(f)
        self.assertEqual(action.cancels, (1,))
        f = replace(f, cursor=3, orders=(done(1, 0, 2, economic_complete=False),),
                    positions=(F(2), F(0)), safe_reduce_lots=(2, 0))
        action = cycle.apply(f)
        self.assertEqual([(i.leg, i.lots) for i in action.intents], [(1, 2)])
        self.assertFalse(cycle.entry_finished)
        self.assertEqual(action.cancels, (1,))

    def test_unknown_hedge_keeps_original_identity_and_exposure_interval(self):
        cycle = self.running()
        cycle.apply(facts(orders=(done(1, 0, 3, status="sent", possible_lots=7),),
                          positions=(F(3), F(0)), safe_reduce_lots=(3, 0)))
        f = facts(3, orders=(done(1, 0, 5, status="sent", possible_lots=5),
                    done(2, 1, 0, status="unknown", possible_lots=3, economic_complete=False)),
                  positions=(F(5), F(0)), safe_reduce_lots=(5, 0),
                  possible_base=((F(5), F(10)), (F(0), F(3))))
        action = cycle.apply(f)
        self.assertFalse(action.intents)
        self.assertEqual(action.cancels, (1,))
        self.assertEqual(action.queries, (2,))
        self.assertEqual(cycle.exposure_bounds(f), (F(2), F(10)))

    def test_terminal_rejection_completes_without_waiting_for_nonexistent_order(self):
        cycle = self.running()
        action = cycle.apply(facts(admission="rejected", closed_ref="core-closed"))
        self.assertEqual((cycle.phase, action.intents), ("completed", ()))

    def test_requote_waits_for_terminal_economic_coverage_and_preserves_lifetime(self):
        cycle = self.running()
        f = facts(3, orders=(done(1, 0, 0, status="sent", possible_lots=10),),
                  market=market(3, 1100, bid_a=999))
        action = cycle.apply(f, quotes=(quote(ticks=999, at=3, bid=999, economic_ref=f.economic_ref),))
        self.assertEqual((action.cancels, action.intents), ((1,), ()))
        self.assertTrue(cycle.replacing)
        action = cycle.apply(replace(f, cursor=4, orders=(done(1, 0, 0, economic_complete=False),)))
        self.assertFalse(action.intents)
        f = facts(5, orders=(done(1, 0, 0),), market=market(5, 1100, bid_a=999))
        action = cycle.apply(f, quotes=(quote(ticks=999, at=5, bid=999, economic_ref=f.economic_ref),))
        self.assertEqual([(i.sequence, i.limit_ticks) for i in action.intents], [(2, 999)])
        self.assertEqual((cycle.requotes_used, cycle.quote_started_ns), (1, T))
        action = cycle.apply(facts(18, orders=(done(1, 0, 0), done(2, 0, 0, status="sent", possible_lots=10))))
        self.assertEqual(action.cancels, (2,))
        self.assertFalse(action.intents)

    def test_depth_loss_immediate_cancel_and_no_initial_quote_without_full_hedge_depth(self):
        cycle = m.Cycle(maker_plan())
        action = cycle.start(cursor=1, at_ns=T, market=market(0, 1100, depth=9), quotes=())
        self.assertFalse(action.intents)
        self.assertEqual(cycle.phase, "idle")
        cycle = self.running()
        action = cycle.apply(facts(2, orders=(done(1, 0, 0, status="sent", possible_lots=10),),
                                  market=market(2, 1100, depth=9)))
        self.assertEqual(action.cancels, (1,))

    def test_queue_baseline_does_not_spend_unknown_cancellations_or_uncertified_volume(self):
        events = (m.QueueEvent("cancel", 0, 5, None), m.QueueEvent("trade", 7, 0, "tape:7"))
        baseline = m.queue_baseline(10, 3, events)
        self.assertEqual((baseline.ahead, baseline.filled_lots), (3, 0))
        hidden = m.queue_baseline(10, 3, events, hidden_ahead=4)
        self.assertEqual((hidden.ahead, hidden.filled_lots), (7, 0))
        ahead_stress = m.queue_baseline(10, 3, events, cancel_position="ahead")
        self.assertEqual((ahead_stress.ahead, ahead_stress.filled_lots), (0, 2))
        with self.assertRaises(ValueError):
            m.QueueEvent("unverified", 20, 0, None)
        with self.assertRaises(ValueError):
            m.queue_baseline(10, 3, events+events)

    def test_unknown_hedge_recovery_does_not_sell_again_and_preserves_cancel_state(self):
        cycle = self.running()
        cycle.apply(facts(orders=(done(1, 0, 3, status="sent", possible_lots=7),),
                          positions=(F(3), F(0)), safe_reduce_lots=(3, 0)))
        f = facts(3, orders=(done(1, 0, 4, status="sent", possible_lots=6),
            done(2, 1, 0, status="unknown", possible_lots=3, economic_complete=False)),
            positions=(F(4), F(0)), safe_reduce_lots=(4, 0),
            possible_base=((F(4), F(10)), (F(0), F(3))))
        cycle.apply(f)
        saved = recovery.checkpoint(meta(3, 3), {"maker": cycle})
        restored = recovery.restore(saved, {"maker": m.Cycle(cycle.plan)})[1]["maker"]
        self.assertEqual(recovery.checkpoint(meta(3, 3), {"maker": restored}), saved)
        self.assertEqual(cycle.apply(replace(f, cursor=4)), restored.apply(replace(f, cursor=4)))
        self.assertFalse(restored.apply(replace(f, cursor=5)).intents)
        self.assertEqual((restored.repair_used, restored.quote_started_ns), (1, T))

    def test_terminal_hedge_without_economic_coverage_cannot_repeat_hedge(self):
        cycle = self.running()
        cycle.apply(facts(orders=(done(1, 0, 3, status="sent", possible_lots=7),),
                          positions=(F(3), F(0)), safe_reduce_lots=(3, 0)))
        f = facts(3, orders=(done(1, 0, 3, status="sent", possible_lots=7),
                             done(2, 1, 0, economic_complete=False)),
                  positions=(F(3), F(0)), safe_reduce_lots=(3, 0))
        self.assertFalse(cycle.apply(f).intents)
        self.assertEqual(cycle.exposure_bounds(f), (F(0), F(10)))

    def test_stress_bounds_are_separate_from_joint_probability_and_cannot_be_omitted(self):
        q, p = quote(), maker_plan()
        with self.assertRaises(ValueError):
            replace(q, stresses=q.stresses[:-1])
        self.assertIsNotNone(m.select_quote(p, q.market, (q,), at_ns=T))
        adverse = replace(q.stresses[-1], loss_atoms=1_000_001)
        self.assertIsNone(m.select_quote(p, q.market, (replace(q, stresses=q.stresses[:-1]+(adverse,)),), at_ns=T))
        # Unknown is part of the joint distribution, never silently a zero-loss no-fill.
        unknown = v.Entry("unknown", (), (), T, False, ("hedge-unknown",), ((F(0), F(10)), (F(0), F(10))))
        scenario = replace(q.scenarios[0], identity="unresolved", weight=F(1, 10), entry=unknown)
        joint = replace(q, scenarios=(replace(q.scenarios[0], weight=F(9, 10)), scenario))
        self.assertIsNone(m.select_quote(p, q.market, (joint,), at_ns=T))

    def test_joint_expectation_keeps_failed_hedge_losses_not_independent_fill_probability(self):
        q, p = quote(), maker_plan()
        failure = v.Entry("flat", (), (v.Settled("repair-and-cleanup", -20_000_000),), T, False, (), ())
        scenarios = (replace(q.scenarios[0], weight=F(9, 10)),
                     replace(q.scenarios[0], identity="failed-hedge", weight=F(1, 10), entry=failure))
        result = v.evaluate(scenarios, p.policy, q.estimator, q.calibration, EXACT, LIMITS, fixed_target=p.target_atoms)
        self.assertEqual((result.plan_atoms, result.entry_target_atoms), (70_000_000, 80_000_000))
        self.assertEqual(m.select_quote(p, q.market, (replace(q, scenarios=scenarios),), at_ns=T)[1], 70_000_000)

    def test_tail_accumulates_to_minimum_and_expiry_or_capacity_cancels_immediately(self):
        base = maker_plan()
        p = replace(base, legs=(base.legs[0], replace(base.legs[1], rules=replace(base.legs[1].rules, min_lots=2))))
        cycle = self.running(p)
        f = facts(orders=(done(1, 0, 1, status="sent", possible_lots=9),),
                  positions=(F(1), F(0)), safe_reduce_lots=(1, 0))
        self.assertFalse(cycle.apply(f).intents)
        action = cycle.apply(replace(f, cursor=3, orders=(done(1, 0, 2, status="sent", possible_lots=8),),
                                     positions=(F(2), F(0)), safe_reduce_lots=(2, 0)))
        self.assertEqual(action.intents[0].lots, 2)
        cycle = self.running(p)
        cycle.apply(f)
        action = cycle.apply(replace(f, cursor=7, at_ns=T+7, market=market(7, 1100)))
        self.assertEqual((action.intents, action.cancels), ((), (1,)))
        cycle = self.running()
        with self.assertRaises(ValueError):
            cycle.apply(replace(f, orders=(done(1, 0, 11),)))

    def test_all_cycle_phases_replay_through_actual_checkpoint_with_fixed_target(self):
        cycle = self.running()
        initial = facts(2, at_ns=T, market=market(0, 1100),
            orders=(done(1, 0, 10),), positions=(F(10), F(0)), safe_reduce_lots=(10, 0))
        position = entry(10)
        q = quote(cycle.plan)
        matched = replace(initial, cursor=3, orders=initial.orders+(done(2, 1, 10),),
                          positions=(F(10), F(10)), safe_reduce_lots=(10, 10), economic_entry=position)
        triggered = replace(matched, cursor=4, at_ns=T+1, market=market(1, 1018))
        unknown = replace(triggered, cursor=5, at_ns=T+2, market=market(2, 1100),
            orders=matched.orders+(done(3, 0, 0, status="unknown", possible_lots=10, economic_complete=False),
                                   done(4, 1, 0, status="sent", possible_lots=10)),
            possible_base=((F(0), F(10)), (F(0), F(10))))
        closed = replace(matched, cursor=6, at_ns=T+6, market=market(6, 1100), economic_entry=None,
            orders=matched.orders+(done(3, 0, 10), done(4, 1, 10)), positions=(F(0), F(0)),
            safe_reduce_lots=(0, 0), closed_ref="economic-orders-closed")
        expected_phases = ("entering", "holding", "exiting", "reconciling", "completed")
        for f, phase in zip((initial, matched, triggered, unknown, closed), expected_phases):
            saved = recovery.checkpoint(meta(cycle.cursor, cycle.next_sequence), {"maker": cycle})
            clone = recovery.restore(saved, {"maker": m.Cycle(cycle.plan)})[1]["maker"]
            action = cycle.apply(f, estimator=q.estimator, limits=LIMITS)
            self.assertEqual(action, clone.apply(f, estimator=q.estimator, limits=LIMITS))
            self.assertEqual(cycle.phase, phase)
            self.assertEqual(recovery.checkpoint(meta(f.cursor, cycle.next_sequence), {"maker": cycle}),
                             recovery.checkpoint(meta(f.cursor, clone.next_sequence), {"maker": clone}))
        self.assertEqual((cycle.target_atoms, cycle.target_cursor, cycle.first_exit), (80_000_000, 3, ("take_profit", 4)))

    def test_recovery_rejects_maker_budget_type_and_clock_corruption(self):
        cycle = self.running()
        for name, value in (("requotes_used", 99), ("quote_started_ns", T+1), ("maker_sequence", 7)):
            saved = getattr(cycle, name)
            setattr(cycle, name, value)
            with self.subTest(field=name), self.assertRaises(ValueError):
                recovery.checkpoint(meta(1, 2), {"maker": cycle})
            setattr(cycle, name, saved)

    def test_partial_fill_replacement_preserves_cost_prefix_and_only_quotes_remainder(self):
        cycle = self.running()
        f = facts(2, orders=(done(1, 0, 2, status="sent", possible_lots=8),),
                  positions=(F(2), F(0)), safe_reduce_lots=(2, 0))
        cycle.apply(f)
        f = facts(3, orders=(done(1, 0, 2, status="sent", possible_lots=8), done(2, 1, 2)),
                  positions=(F(2), F(2)), safe_reduce_lots=(2, 2), market=market(3, 1100, bid_a=999))
        prefix = tuple((replace(leg.entries[0], identity="applied:"+str(i), lots=2),)
                       for i, leg in enumerate(entry(2).legs))
        q = quote(ticks=999, at=3, bid=999, economic_ref=f.economic_ref, applied=prefix)
        self.assertEqual(cycle.apply(f, quotes=(q,)).cancels, (1,))
        f = facts(4, orders=(done(1, 0, 2), done(2, 1, 2)), positions=(F(2), F(2)),
                  safe_reduce_lots=(2, 2), market=market(4, 1100, bid_a=999))
        q = quote(ticks=999, at=4, bid=999, economic_ref=f.economic_ref, applied=prefix)
        action = cycle.apply(f, quotes=(q,))
        self.assertEqual([(i.sequence, i.lots, i.limit_ticks) for i in action.intents], [(3, 8, 999)])
        self.assertEqual(cycle.quote_started_ns, T)
        with self.assertRaises(ValueError):
            m.select_quote(cycle.plan, q.market, (replace(q, economic_ref="stale-cost"),), at_ns=T+4,
                           economic_ref=f.economic_ref, applied_lots=(2, 2))

    def test_hedge_budget_exhaustion_cancels_quote_and_restart_keeps_deadline(self):
        cycle = self.running(maker_plan(repair_attempts=0))
        action = cycle.apply(facts(orders=(done(1, 0, 2, status="sent", possible_lots=8),),
            positions=(F(2), F(0)), safe_reduce_lots=(2, 0)))
        self.assertEqual((action.intents, action.cancels), ((), (1,)))
        clone = recovery.restore(recovery.checkpoint(meta(2, 2), {"maker": cycle}),
                                 {"maker": m.Cycle(cycle.plan)})[1]["maker"]
        action = clone.apply(facts(3, at_ns=T+200, market=market(200, 1100),
            orders=(done(1, 0, 2, status="sent", possible_lots=8),), positions=(F(2), F(0)), safe_reduce_lots=(2, 0)))
        self.assertTrue(action.escalate)
        self.assertEqual((action.cancels, action.intents, clone.first_exit), ((1,), (), ("deadline", 3)))

    def test_fee_correction_overhedge_trims_hedge_without_switching_maker_to_ioc(self):
        cycle = self.running()
        cycle.apply(facts(orders=(done(1, 0, 3),), positions=(F(3), F(0)), safe_reduce_lots=(3, 0)))
        action = cycle.apply(facts(3, orders=(done(1, 0, 3), done(2, 1, 3)),
            positions=(F(2), F(3)), safe_reduce_lots=(2, 3)))
        self.assertEqual([(i.leg, i.lots, i.reducing, i.time_in_force) for i in action.intents],
                         [(1, 1, True, "ioc")])
        recovery.checkpoint(meta(3, 4), {"maker": cycle})

    def test_independent_pending_exits_and_hedge_trims_expand_exposure_interval(self):
        cycle = self.running()
        cycle.apply(facts(2, at_ns=T, market=market(0, 1100), orders=(done(1, 0, 10),),
                          positions=(F(10), F(0)), safe_reduce_lots=(10, 0)))
        base = facts(3, orders=(done(1, 0, 10), done(2, 1, 10)), positions=(F(10), F(10)),
                     safe_reduce_lots=(10, 10), market=market(3, 1100, risk=True))
        cycle.apply(base)
        pending = replace(base, cursor=4, orders=base.orders+(
            done(3, 0, 0, status="sent", possible_lots=10), done(4, 1, 0, status="sent", possible_lots=10)))
        self.assertEqual(cycle.exposure_bounds(pending), (F(-10), F(10)))
        one_filled = replace(pending, orders=base.orders+(done(3, 0, 10),
            done(4, 1, 0, status="sent", possible_lots=10)), positions=(F(0), F(10)), safe_reduce_lots=(0, 0))
        self.assertEqual(cycle.exposure_bounds(one_filled), (F(-10), F(0)))

    def test_sell_maker_role_and_reprice_interval_and_count_are_independent(self):
        p = maker_plan(maker_leg=1)
        cycle = m.Cycle(p)
        action = cycle.start(cursor=1, at_ns=T, market=market(0, 1100), quotes=(quote(p, ticks=1100),))
        self.assertEqual([(i.leg, i.limit_ticks, i.time_in_force) for i in action.intents], [(1, 1100, "post-only")])
        action = cycle.apply(facts(orders=(done(1, 1, 3, status="sent", possible_lots=7),),
                                  positions=(F(0), F(3)), safe_reduce_lots=(0, 3)))
        self.assertEqual([(i.leg, i.lots, i.limit_ticks) for i in action.intents], [(0, 3, 1001)])
        for cap in (0, 2):
            p = maker_plan(max_requotes=cap)
            cycle = self.running(p)
            f = facts(2, orders=(done(1, 0, 0, status="sent", possible_lots=10),),
                      market=market(2, 1100, bid_a=999))
            self.assertFalse(cycle.apply(f, quotes=(quote(p, ticks=999, at=2, bid=999, economic_ref=f.economic_ref),)).cancels)
            f = replace(f, cursor=3, at_ns=T+3, market=market(3, 1100, bid_a=999))
            action = cycle.apply(f, quotes=(quote(p, ticks=999, at=3, bid=999, economic_ref=f.economic_ref),))
            self.assertEqual(action.cancels, (1,) if cap else ())


if __name__ == "__main__":
    unittest.main()
