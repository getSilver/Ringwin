"""Public fixed-target scenario evaluation, including delayed joint execution."""
from dataclasses import replace
from fractions import Fraction as F
from decimal import Decimal, localcontext, ROUND_CEILING
import struct
import math
import unittest

from strategies.cross_venue import arbitrage_baseline as b
from strategies.cross_venue import arbitrage_economics as e
from strategies.cross_venue import arbitrage_probability as p
from strategies.cross_venue import arbitrage_evaluation as v
from test_arbitrage_probability import calibration

T = 10_000
MODEL = b.AR1(1, 200, 0., .8, .01, 1e-12, 1e-15, 0.)


def wire(instrument, at_ns, bid, ask, lots=100):
    payload = bytearray(704)
    payload[:16] = instrument.to_bytes(16, "little")
    struct.pack_into("<QQQ", payload, 16, 1, at_ns, at_ns)
    payload[40:42] = bytes((1, 1))
    for i, ticks in enumerate((bid, ask)):
        offset = 64+i*8*40
        payload[offset:offset+16] = ticks.to_bytes(16, "little", signed=True)
        payload[offset+16] = 1
        payload[offset+24:offset+40] = lots.to_bytes(16, "little", signed=True)
    return bytes(payload)


def leg(index, lots=1, kind="linear", fee_ppm=0):
    rule = e.InstrumentRules(index+1, 1, 2, 1, F(100_000), F(1), 1, 1, 0, 1_000_000)
    trade = v.Trade("entry:"+str(index), 1000 if index == 0 else 1100, lots,
                    e.Fee(1, 0, F(0), 0), T)
    return v.Leg(index+1, rule, kind, 1 if index == 0 else -1, (trade,),
                 e.FeeRule(index+1, 1, 1, fee_ppm, fee_ppm, 0, 1_000_000))


def entry(lots=1, completed=()):
    return v.Entry("matched", (leg(0, lots), leg(1, lots)), completed, T, True, (), (), b.Point(0, 1, math.log(1.1)))


def market(offset, closing_ask_b, *, bid_a=1000, risk=False, invalid=False, depth=100):
    at = T+offset
    return v.Market(at, (wire(1, at, bid_a, bid_a+1, depth),
                         wire(2, at, closing_ask_b-1, closing_ask_b, depth)),
                    (F(1), F(1)), (0, 0), (), True, risk, invalid, False)


def policy(**changes):
    values = dict(version=1, scope="fixture", model_hash=MODEL.content_hash, mode="taker_taker", direction=1,
                  base_asset=2, quote_asset=1,
                  original_base=F(1), reference_notional_atoms=100_000_000,
                  at_ns=T, prediction_end_ns=T+100, risk_deadline_ns=T+100,
                  reference_exit_ns=T+100, alpha=F(4, 5), absolute_minimum_atoms=2_000_000,
                  min_profit_atoms=5_000_000, min_edge_bp=F(0), min_entry_probability=F(65, 100),
                  min_hold_probability=F(65, 100), normal_limits=(1, 10_000),
                  risk_limits=(1, 10_000), max_book_age_ns=1000, residual_cap_base=F(0),
                  residual_haircut=F(0), reference_buffers=(), plan_buffers=(), hard_gates_passed=True,
                  reference_policy_ref="reference-v1", plan_policy_ref="fixed-target-v1")
    values.update(changes)
    return v.Policy(**values)


class ValuationTests(unittest.TestCase):
    def test_joint_depth_value_and_delayed_execution_keep_actual_economic_result(self):
        position = entry()
        quote = v.value_exit(position, market(1, 1018), policy(), normal=True)
        actual = v.value_exit(position, market(6, 1023), policy(), normal=True)
        self.assertTrue(quote.closed)
        self.assertEqual(quote.net_atoms, 8_200_000)
        self.assertEqual(actual.net_atoms, 7_700_000)
        self.assertEqual(quote.remaining_base, (F(0), F(0)))

    def test_spot_base_fee_is_not_charged_again_as_lost_inventory(self):
        spot = leg(0, lots=10, kind="spot")
        paid = replace(spot.entries[0], fee=e.Fee(2, 1, F(100_000_000), 1))
        position = v.Entry("matched", (replace(spot, entries=(paid,)), leg(1, lots=9)), (), T, True, (), ())
        result = v.value_exit(position, market(0, 1100), policy(original_base=F(9)), normal=True)
        self.assertTrue(result.closed)
        self.assertEqual(result.net_atoms, -100_000_000)

    def test_base_fee_on_spot_exit_reduces_gross_sell_without_overspending_base(self):
        spot = leg(0, lots=10, kind="spot")
        fee = e.FeeRule(1, 1, 2, 100_000, 100_000, 0, 1_000_000)
        position = v.Entry("matched", (replace(spot, exit_fee=fee), leg(1, lots=10)), (), T, True, (), ())
        result = v.value_exit(position, market(0, 1100), policy(original_base=F(10)), normal=True)
        self.assertTrue(result.closed)
        self.assertEqual(result.remaining_base, (0, 0))
        self.assertEqual(result.net_atoms, -100_000_000)

    def test_funding_is_cumulative_leg_specific_and_never_future_income(self):
        cost = v.FundingCost("funding", 1, T+3, 200_000)
        frame = replace(market(6, 1023), funding_costs=(cost,))
        result = v.value_exit(entry(), frame, policy(), normal=True)
        self.assertEqual(result.net_atoms, 7_500_000)
        with self.assertRaises(ValueError):
            v.FundingCost("income-is-not-an-outflow", 1, T, -1)

    def test_residual_cap_cannot_close_legal_unsold_spot_inventory(self):
        position = v.Entry("matched", (leg(0, kind="spot"), leg(1)), (), T, True, (), ())
        frame = market(0, 1000)
        frame = replace(frame, books=(wire(1, T, 1000, 1001, 0), frame.books[1]))
        result = v.value_exit(position, frame, policy(residual_cap_base=F(1), residual_haircut=F(1)), normal=True)
        self.assertFalse(result.closed)
        self.assertIsNone(result.net_atoms)
        self.assertEqual(result.remaining_base[0], 1)

    def test_intrinsically_unaffordable_base_fee_makes_bounded_spot_dust(self):
        spot = leg(0, kind="spot")
        spot = replace(spot, exit_fee=e.FeeRule(1, 1, 2, 1000, 1000, 0, 1_000_000))
        position = v.Entry("matched", (spot, leg(1)), (), T, True, (), ())
        result = v.value_exit(position, market(0, 1000), policy(residual_cap_base=F(1), residual_haircut=F(1)), normal=True)
        self.assertTrue(result.closed)
        self.assertEqual(result.remaining_base, (F(1), F(0)))
        self.assertEqual(result.net_atoms, 10_000_000)


EXACT = p.SimulationError("exact_enumeration", 0, F(0), F(0), "frozen-support")
LIMITS = v.Limits(256, 100_000, 256)


def path(identity, weight=F(1), actual_ask=1020, position=None):
    position = entry() if position is None else position
    return v.Scenario(identity, weight, position,
                      (market(0, 1100), market(1, 1018), market(6, actual_ask),
                       market(100, 1000), market(105, 1000)), (0, 5), ("filled", "filled"),
                      (identity+":exit:a", identity+":exit:b"))


def estimator_for(scenarios, plan, original_target=8_000_000, margin=F(7, 100)):
    rows, seen = [], set()
    for scenario in scenarios:
        if scenario.entry.state != "matched":
            continue
        target = e.holding_target(original_target, scenario.entry.matched_base/plan.original_base,
                                   plan.absolute_minimum_atoms)
        context = v.Context(scenario.entry, scenario.markets[0], target, plan)
        if context.scope in seen:
            continue
        # Frozen conditional support uses only the prefix, not this outer path's future.
        continuation = path("conditional", position=scenario.entry)
        continuation = replace(continuation, markets=(scenario.markets[0],)+continuation.markets[1:])
        historical_entry = replace(continuation.entry, holding_at_ns=0,
            legs=tuple(replace(x, entries=tuple(replace(t, at_ns=t.at_ns-T) for t in x.entries)) for x in continuation.entry.legs))
        historical_markets = []
        for frame in continuation.markets:
            books = []
            for payload in frame.books:
                decoded = v.decode_depth_snapshot(payload)
                decoded["visible_at_ns"] -= T
                books.append(v.encode_depth_snapshot(decoded))
            historical_markets.append(replace(frame, at_ns=frame.at_ns-T, books=tuple(books)))
        continuation = replace(continuation, entry=historical_entry, markets=tuple(historical_markets))
        artifact = calibration(stage="hold", margin=margin, scope=context.scope, model_hash=plan.model_hash)
        rows.append(v.ConditionalRow(context.scope, (continuation,), artifact, EXACT,
                                    v.RebaseBounds(F(9, 10), F(11, 10), .01, F(1, 2), F(2), F(2))))
        seen.add(context.scope)
    estimator = v.Estimator(MODEL, 200, tuple(rows))
    simulation_hash = estimator.probability_model_hash(plan)
    return replace(estimator, rows=tuple(replace(row, calibration=replace(row.calibration, simulation_hash=simulation_hash)) for row in rows))


def run(scenarios, plan=None, *, original_target=8_000_000, entry_margin=F(7, 100), hold_margin=F(7, 100)):
    plan = policy() if plan is None else plan
    estimator = estimator_for(scenarios, plan, original_target, hold_margin)
    artifact = calibration(scope=v.probability_scope(plan, original_target, plan.original_base, plan.at_ns),
                           margin=entry_margin, model_hash=plan.model_hash, simulation_hash=estimator.probability_model_hash(plan))
    return v.evaluate(scenarios, plan, estimator, artifact, EXACT, LIMITS)


class EvaluationTests(unittest.TestCase):
    def test_late_reported_funding_changes_actual_y_without_changing_trigger(self):
        scenario = path("late-funding")
        cost = v.FundingCost("late-cost", 1, T+3, 500_000)
        scenario = replace(scenario, markets=scenario.markets[:3]+tuple(
            replace(frame, funding_costs=(cost,)) for frame in scenario.markets[3:]))
        result = run((scenario,), original_target=7_600_000)
        self.assertEqual(result.entry_target_atoms, 7_600_000)
        self.assertEqual(result.plan_paths[0].trigger_ns, T+1)
        self.assertEqual(result.plan_paths[0].net_atoms, 7_500_000)
        self.assertEqual(result.plan_paths[0].closed_at_ns, T+100)
        self.assertFalse(result.plan_paths[0].actual_target_met)

    def test_invalid_joint_weights_duplicate_costs_and_work_limits_reject(self):
        scenario = path("bounded")
        for scenarios in ((replace(scenario, weight=F(1, 2)),), (scenario, scenario)):
            with self.assertRaises(ValueError):
                run(scenarios)
        duplicate = e.Cost("fee:entry:0", 1, "execution_buffer")
        with self.assertRaises(ValueError):
            run((scenario,), policy(plan_buffers=(duplicate,)))
        plan = policy()
        estimator = estimator_for((scenario,), plan)
        artifact = calibration(model_hash=plan.model_hash)
        for limits in (v.Limits(1, 1, 1), v.Limits(1, 100_000, 1)):
            scenarios = (scenario,) if limits.max_steps == 1 else (replace(scenario, weight=F(1, 2)), replace(scenario, identity="second", weight=F(1, 2)))
            with self.assertRaisesRegex(ValueError, "evaluation_capacity"):
                v.evaluate(scenarios, plan, estimator, artifact, EXACT, limits)
        self.assertEqual(run((scenario,), policy(hard_gates_passed=False)).reason, "hard_gate")

    def test_delayed_exit_uses_book_visible_at_arrival_not_next_update(self):
        scenario = path("between-updates", actual_ask=1060)
        scenario = replace(scenario, exit_delays_ns=(0, 4))
        result = run((scenario,))
        self.assertEqual(result.plan_paths[0].closed_at_ns, T+5)
        self.assertEqual(result.plan_paths[0].net_atoms, 8_200_000)

    def test_deadline_timer_fires_between_market_updates(self):
        scenario = path("timer")
        scenario = replace(scenario, markets=(market(0, 1100), market(99, 1100), market(105, 1000)),
                           exit_delays_ns=(0, 0))
        result = run((scenario,))
        self.assertEqual(result.reference_paths[0].trigger_ns, T+100)
        self.assertEqual(result.reference_atoms, 0)
        self.assertEqual(result.reason, "reference_profit")

    def test_s2a_s2b_s3a_s3b_reference_target_and_plan_are_separate(self):
        scenarios = (path("first", F(1, 2), actual_ask=1020), path("second", F(1, 2), actual_ask=1060))
        result = run(scenarios)
        self.assertEqual((result.reference_atoms, result.entry_target_atoms, result.plan_atoms),
                         (10_000_000, 8_000_000, 6_000_000))
        self.assertTrue(result.allowed)
        self.assertEqual(result.entry_probability.lower_ppm, 680_000)
        rejected = run(scenarios, policy(min_profit_atoms=7_000_000))
        self.assertEqual((rejected.allowed, rejected.reason, rejected.entry_target_atoms), (False, "profit", 8_000_000))
        low_probability = run(scenarios, entry_margin=F(15, 100))
        self.assertEqual((low_probability.allowed, low_probability.reason), (False, "probability"))
        self.assertEqual(result.plan_paths[0].hold_probability, result.plan_paths[1].hold_probability)
        self.assertEqual(result.nested_evaluations, 2)

    def test_s2f_s3g_trigger_success_and_delayed_realized_result_are_distinct(self):
        result = run((path("slippage", actual_ask=1023),))
        self.assertTrue(result.plan_paths[0].triggered)
        self.assertEqual(result.plan_paths[0].net_atoms, 7_700_000)
        self.assertFalse(result.plan_paths[0].actual_target_met)
        self.assertEqual(result.entry_probability.raw, 1)
        self.assertEqual(result.actual_target_probability, 0)

    def test_v6_first_legal_profit_trigger_and_v13_absolute_partial_floor(self):
        scenario = path("fixed-plan")
        scenario = replace(scenario, markets=(scenario.markets[0], market(1, 1070), market(6, 1018))+scenario.markets[3:])
        result = run((scenario,))
        self.assertEqual((result.reference_atoms, result.entry_target_atoms), (10_000_000, 8_000_000))
        self.assertEqual(v.value_exit(scenario.entry, scenario.markets[1], policy(), normal=True).net_atoms, 3_000_000)
        self.assertEqual((result.plan_paths[0].trigger_ns, result.plan_paths[0].closed_at_ns), (T+6, T+11))
        floor = run((path("ten-percent"),), policy(original_base=F(10)))
        self.assertEqual((floor.entry_target_atoms, floor.plan_paths[0].target_atoms), (8_000_000, 2_000_000))

    def test_s2c_comparison_uses_plan_returns_even_when_reference_order_is_reversed(self):
        first = run((path("a1", F(1, 2), 1020), path("a2", F(1, 2), 1060)))
        second_paths = tuple(replace(x, markets=x.markets[:3]+(market(100, 1010), market(105, 1010)))
                             for x in (path("b1", F(1, 2), 1030), path("b2", F(1, 2), 1040)))
        second = run(second_paths, original_target=7_200_000)
        self.assertEqual((first.reference_atoms, second.reference_atoms), (10_000_000, 9_000_000))
        self.assertEqual((first.plan_atoms, second.plan_atoms), (6_000_000, 6_500_000))
        self.assertTrue(first.allowed and second.allowed)
        self.assertEqual(max((first, second), key=lambda x: x.plan_atoms), second)

    def test_s2d_nonpositive_reference_cannot_be_rescued_by_absolute_target_floor(self):
        failed = v.Entry("flat", (), (v.Settled("cleanup", -1_000_000),), T, True, (), ())
        scenario = v.Scenario("failed", F(1), failed, (), (0, 0), ("filled", "filled"), ("exit:a", "exit:b"))
        result = run((scenario,))
        self.assertEqual(result.reference_atoms, -1_000_000)
        self.assertIsNone(result.entry_target_atoms)
        self.assertFalse(result.allowed)

    def test_s3d_zero_fills_and_failures_remain_in_entry_denominator(self):
        zero = v.Entry("flat", (), (), T, True, (), ())
        scenarios = [v.Scenario("zero:"+str(i), F(1, 100), zero, (), (0, 0), ("filled", "filled"),
                                ("exit:a", "exit:b")) for i in range(50)]
        scenarios.extend(path("success:"+str(i), F(1, 100), 1020) for i in range(40))
        for i in range(10):
            failed = path("risk:"+str(i), F(1, 100), 1020)
            scenarios.append(replace(failed, markets=(replace(failed.markets[0], risk=True),)+failed.markets[1:], exit_delays_ns=(0, 0)))
        result = run(tuple(scenarios), policy(min_profit_atoms=1), original_target=3_200_000)
        self.assertEqual(result.entry_probability.raw, F(2, 5))
        self.assertEqual(sum(x.weight for x in result.plan_paths), 1)

    def test_s3f_hard_exit_wins_at_same_time_as_profit_and_never_returns_to_holding(self):
        for reason in ("risk", "model_invalid", "deadline"):
            scenario = path(reason)
            frame = replace(scenario.markets[1], risk=reason == "risk", model_invalid=reason == "model_invalid")
            modified = replace(scenario, markets=(scenario.markets[0], frame)+scenario.markets[2:])
            plan = policy(risk_deadline_ns=T+1, reference_exit_ns=T+1) if reason == "deadline" else policy()
            # The reference policy obeys the same hard exit and delayed fills: reference8=>target6.4.
            target = 6_400_000
            result = run((modified,), plan, original_target=target)
            self.assertFalse(result.plan_paths[0].triggered)
            self.assertEqual(result.plan_paths[0].reason, reason)

    def test_unclosed_exit_tail_and_censoring_are_not_counted_as_zero(self):
        scenario = path("partial")
        changed = replace(scenario, markets=scenario.markets[:2]+(market(6, 1023, depth=0),)+scenario.markets[3:])
        result = run((changed,))
        self.assertIsNone(result.plan_atoms)
        self.assertEqual(result.unresolved_weight, 1)
        self.assertTrue(result.plan_paths[0].triggered)
        self.assertIsNone(result.plan_paths[0].actual_target_met)
        self.assertFalse(result.allowed)
        censored = replace(scenario, markets=scenario.markets[:1])
        result = run((censored,))
        self.assertEqual(result.reason, "unresolved_reference")
        self.assertIsNone(result.entry_target_atoms)

    def test_s2e_v10_to_v13_freeze_once_include_repair_loss_and_keep_absolute_floor(self):
        matched = entry(completed=(v.Settled("repair", -1_000_000),))
        plan = policy(original_base=F(2))
        scenario = path("partial", position=matched)
        # Reference net is9, target7.2, matched half=>3.6; repair loss does not lower it again.
        result = run((scenario,), plan, original_target=7_200_000)
        self.assertEqual((result.entry_target_atoms, result.plan_paths[0].target_atoms), (7_200_000, 3_600_000))
        self.assertEqual(e.remaining_target(4_000_000, matched.r_done_atoms), 5_000_000)
        path_value = v.value_exit(matched, market(1, 1055), plan, normal=True)
        self.assertEqual(path_value.net_atoms, 3_500_000)
        frozen = e.holding_target(8_000_000, F(1, 2), 2_000_000)
        self.assertEqual(frozen, 4_000_000)
        self.assertEqual(e.holding_target(8_000_000, F(1, 10), 2_000_000), 2_000_000)

    def test_s3e_v12_individual_path_below_target_waits_until_original_deadline(self):
        position = entry(completed=(v.Settled("repair-loss", -1_000_000),))
        scenario = path("below-target", position=position)
        scenario = replace(scenario, markets=(scenario.markets[0], market(1, 1055), market(6, 1055))+scenario.markets[3:])
        result = run((scenario,), policy(original_base=F(2), alpha=F(8, 9)))
        trace = result.plan_paths[0]
        self.assertEqual((result.entry_target_atoms, trace.target_atoms), (8_000_000, 4_000_000))
        self.assertFalse(trace.triggered)
        self.assertEqual((trace.trigger_ns, trace.reason), (T+100, "deadline"))


class HoldingTests(unittest.TestCase):
    def test_calibration_cannot_be_reused_after_generator_or_execution_policy_changes(self):
        scenario, plan = path("binding"), policy()
        estimator = estimator_for((scenario,), plan)
        context = v.Context(scenario.entry, scenario.markets[0], 8_000_000, plan)
        self.assertEqual(v.assess_holding(context, estimator, LIMITS, phase="entering").action, "hold")
        row = estimator.rows[0]
        changed_support = replace(row.scenarios[0], exit_delays_ns=(0, 4))
        replacement = replace(estimator, rows=(replace(row, scenarios=(changed_support,)),))
        changed_bounds = replace(estimator, rows=(replace(row, bounds=replace(row.bounds, max_depth_factor=F(3))),))
        for frozen in (replacement, changed_bounds):
            decision = v.assess_holding(context, frozen, LIMITS, phase="entering")
            self.assertEqual((decision.action, decision.reason), ("exit", "calibration_scope"))
        changed_plan = replace(plan, normal_limits=(999, 10_000))
        self.assertEqual(v.assess_holding(replace(context, policy=changed_plan), estimator, LIMITS,
                                         phase="entering").reason, "calibration_scope")
        artifact = calibration(scope=v.probability_scope(plan, 8_000_000, F(1), T),
            model_hash=plan.model_hash, simulation_hash=estimator.probability_model_hash(plan))
        result = v.evaluate((scenario,), plan, replacement, artifact, EXACT, LIMITS)
        self.assertEqual(result.entry_probability.reason, "calibration_scope")
        self.assertFalse(result.allowed)

    def test_conditional_ar1_mean_uses_grid_point_and_preserves_joint_residual(self):
        second = b.SECOND
        model = replace(MODEL, trained_until_ns=200*second)
        horizon_end = 2000*second
        def extend(position, at_ns, point):
            return replace(position, holding_at_ns=at_ns, model_point=point, legs=tuple(replace(leg,
                rules=replace(leg.rules, valid_until_ns=horizon_end),
                exit_fee=replace(leg.exit_fee, valid_until_ns=horizon_end),
                entries=tuple(replace(trade, at_ns=at_ns) for trade in leg.entries)) for leg in position.legs))
        source = path("historical")
        source = replace(source, entry=extend(source.entry, 0, b.Point(0, 1, .1)), markets=tuple(
            v.Market((frame.at_ns-T)*second, tuple(wire(i+1, (frame.at_ns-T)*second,
                v.decode_depth_snapshot(payload)["bids"][0][0], v.decode_depth_snapshot(payload)["asks"][0][0])
                for i, payload in enumerate(frame.books)), frame.fee_valuations, frame.fee_balances,
                (), True, False, False, False) for frame in source.markets), exit_delays_ns=(0, 5*second))
        now = 1000*second
        plan = policy(model_hash=model.content_hash, at_ns=now, prediction_end_ns=now+100*second,
                      risk_deadline_ns=now+100*second, reference_exit_ns=now+100*second,
                      max_book_age_ns=100*second)
        current = replace(source.markets[0], at_ns=now, books=tuple(wire(i+1, now,
            v.decode_depth_snapshot(payload)["bids"][0][0], v.decode_depth_snapshot(payload)["asks"][0][0])
            for i, payload in enumerate(source.markets[0].books)))
        context = v.Context(extend(entry(), now, b.Point(now, 2, .2)), current, 8_000_000, plan)
        artifact = replace(calibration(stage="hold", scope=context.scope, model_hash=model.content_hash),
            training_end_ns=200*second, calibration_start_ns=210*second, calibration_end_ns=710*second,
            valid_from_ns=720*second, valid_until_ns=horizon_end)
        row = v.ConditionalRow(context.scope, (source,), artifact, EXACT,
                              v.RebaseBounds(F(9, 10), F(11, 10), .01, F(1, 2), F(2), F(2)))
        frozen = v.Estimator(model, 200*second, (row,))
        projected = frozen.generate(context)[0]
        with localcontext() as arithmetic:
            arithmetic.prec = 60
            for original, conditioned in zip(source.markets[1:], projected.markets[1:]):
                steps = original.at_ns//second
                # Independent decimal AR(1) closed form, then conservative tick rounding.
                correction = (Decimal.from_float(.2)-Decimal.from_float(.1))*(Decimal.from_float(.8)**steps-1)
                old_ask = v.decode_depth_snapshot(original.books[1])["asks"][0][0]
                expected = int((Decimal(old_ask)*correction.exp()).to_integral_value(rounding=ROUND_CEILING))
                self.assertEqual(v.decode_depth_snapshot(conditioned.books[1])["asks"][0][0], expected)
                self.assertEqual(v.decode_depth_snapshot(conditioned.books[0])["asks"],
                                 v.decode_depth_snapshot(original.books[0])["asks"])
        extreme = replace(context, entry=replace(context.entry, model_point=b.Point(now, 3, -1e308)))
        with self.assertRaisesRegex(b.Rejected, "conditional_numeric"):
            frozen.generate(extreme)

    def test_frozen_joint_estimator_reuses_visible_prefix_at_new_time_and_price(self):
        original, plan = path("source"), policy()
        estimator = estimator_for((original,), plan)
        digest = estimator.content_hash
        new_time = 20_000
        position = replace(original.entry, holding_at_ns=new_time, legs=tuple(replace(leg,
            entries=tuple(replace(trade, at_ns=new_time) for trade in leg.entries)) for leg in original.entry.legs))
        frame = v.Market(new_time, (wire(1, new_time, 1001, 1002), wire(2, new_time, 1100, 1101)),
                         (F(1), F(1)), (0, 0), (), True, False, False, False)
        new_plan = replace(plan, at_ns=new_time, prediction_end_ns=new_time+100,
                           risk_deadline_ns=new_time+100, reference_exit_ns=new_time+100)
        context = v.Context(position, frame, 8_000_000, new_plan)
        generated = estimator.generate(context)
        self.assertEqual(generated[0].entry, position)
        self.assertEqual(generated[0].markets[0], frame)
        self.assertEqual(generated[0].markets[-1].at_ns, new_time+105)
        self.assertNotEqual(generated[0].markets[1].books, original.markets[1].books)
        self.assertEqual(estimator.content_hash, digest)
        self.assertEqual(v.assess_holding(context, estimator, LIMITS, phase="entering").action, "hold")
        thinner = replace(frame, books=(wire(1, new_time, 1001, 1002, 50), wire(2, new_time, 1100, 1101, 50)))
        thin_paths = estimator.generate(replace(context, market=thinner))
        self.assertEqual(v.decode_depth_snapshot(thin_paths[0].markets[1].books[0])["bids"][0][1], 50)
        self.assertEqual(v.decode_depth_snapshot(thin_paths[0].markets[1].books[1])["asks"][0][1], 50)
        for unsupported in (replace(frame, books=(wire(1, new_time, 2000, 2001), wire(2, new_time, 2200, 2201))),
                            replace(frame, books=(wire(1, new_time, 1001, 1002, 1), frame.books[1]))):
            decision = v.assess_holding(replace(context, market=unsupported), estimator, LIMITS, phase="entering")
            self.assertEqual(decision.action, "exit")
            self.assertTrue(decision.reason.startswith("conditional_projection:"))

    def test_repair_consumes_original_deadline_and_missing_grid_observation_rejects(self):
        scenario, plan = path("repair"), policy()
        estimator = estimator_for((scenario,), plan)
        position = replace(scenario.entry, holding_at_ns=T+20)
        context = v.Context(position, market(20, 1100), 8_000_000, plan)
        decision = v.assess_holding(context, estimator, LIMITS, phase="repairing")
        self.assertEqual(decision.remaining_ns, 80)
        missing = replace(context, entry=replace(position, model_point=None))
        self.assertEqual(v.assess_holding(missing, estimator, LIMITS, phase="repairing").action, "exit")

    def test_s3h_s3i_existing_holding_is_not_periodically_rechecked_and_unknown_reconciles(self):
        plan, scenario = policy(), path("known")
        context = v.Context(scenario.entry, scenario.markets[0], 8_000_000, plan)
        empty = v.Estimator(MODEL, 200, ())
        self.assertEqual(v.assess_holding(context, empty, LIMITS, phase="holding").action, "keep_plan")
        self.assertEqual(v.assess_holding(context, empty, LIMITS, phase="exiting").action, "continue_exit")
        self.assertEqual(v.assess_holding(context, empty, LIMITS, phase="entering").action, "exit")
        expired = replace(context, market=market(100, 1000))
        self.assertEqual(v.assess_holding(expired, empty, LIMITS, phase="repairing").reason, "deadline")
        unknown = v.Entry("unknown", (), (), T, False, ("original-order",), ((F(0), F(1)), (F(0), F(1))))
        self.assertEqual(v.assess_holding(replace(context, entry=unknown), empty, LIMITS, phase="entering").action, "reconcile")


if __name__ == "__main__":
    unittest.main()
