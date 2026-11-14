"""Offline public economic contracts; literal answers come from V1–V13."""
from decimal import Decimal
from fractions import Fraction as F
import math
import struct
import unittest

from strategies.cross_venue import arbitrage_economics as e
import strategy_host as host


class CycleTests(unittest.TestCase):
    def test_v1_complete_cycle(self):
        result = e.evaluate_cycle(
            gross_atoms=5_000_000,
            costs=(e.Cost("four fills", 811_000, "expense"),
                   e.Cost("model", 400_000, "model_buffer"),
                   e.Cost("execution", 100_000, "execution_buffer")),
            funding_atoms=(-200_000,))
        self.assertEqual(result.net_atoms, 3_989_000)
        self.assertEqual(result.plan_atoms, 3_489_000)
        self.assertEqual(result.fee_atoms, 811_000)
        self.assertEqual(e.edge_bp(result.plan_atoms, 203_000_000), F(34890, 203))
        # Independent Decimal cash/fee calculation, not the implementation's rational arithmetic.
        gross = (Decimal(101)-100)*2 + (Decimal(103)-Decimal("101.5"))*2
        fee = sum(Decimal(p)*2*Decimal(".001") for p in ("100", "101", "103", "101.5"))
        self.assertEqual((gross-fee-Decimal(".2"))*1_000_000, result.net_atoms)

    def test_v1_from_linear_rules_and_individually_rounded_fill_fees(self):
        r = rules(tick_quote_atoms_per_base_atom=F(500_000))
        fr = e.FeeRule(1, 1, 1, 1000, 0, 0, 1000)
        gross = e.linear_pnl(r, 200, 202, 2, "long") + e.linear_pnl(r, 206, 203, 2, "short")
        fees = tuple(e.estimate_fee(r, fr, ticks=t, lots=2, role="taker", now_ns=10,
                                    quote_atoms_per_fee_atom=1) for t in (200, 202, 206, 203))
        result = e.evaluate_cycle(gross, tuple(e.Cost(str(i), f.quote_atoms, "expense")
                                               for i, f in enumerate(fees)), (-200_000,))
        self.assertEqual((gross, result.fee_atoms, result.net_atoms), (5_000_000, 811_000, 3_989_000))

    def test_price_impact_is_only_attributed_once_and_residual_is_valued_once(self):
        value = e.evaluate_cycle(100, (e.Cost("slippage", 5, "embedded"),))
        self.assertEqual((value.net_atoms, value.plan_atoms), (100, 100))
        spot = e.spot_liquidation(100, 90, 12, ())
        self.assertEqual(spot.net_atoms, 2)
        with self.assertRaisesRegex(ValueError, "duplicate"):
            e.evaluate_cycle(100, (e.Cost("slippage", 5, "embedded"),
                                   e.Cost("slippage", 5, "execution_buffer")))


def rules(**changes):
    values = dict(instrument=1, version=1, base_asset=2, quote_asset=1,
                  tick_quote_atoms_per_base_atom=F(1), base_atoms_per_lot=F(1),
                  min_lots=1, min_notional_atoms=1, valid_from_ns=0, valid_until_ns=1000)
    values.update(changes)
    return e.InstrumentRules(**values)


def book(**changes):
    values = dict(instrument=1, rules_version=1, sequence=1, visible_at_ns=10,
                  bids=((99, 1), (98, 2)), asks=((100, 1), (101, 2)),
                  bids_truncated=False, asks_truncated=False)
    values.update(changes)
    return values


class DepthTests(unittest.TestCase):
    def test_v2_buy_and_sell_use_opposite_sides_and_price_protection(self):
        buy = e.sweep(book(), rules(), "buy", 3, 101, now_ns=10, max_age_ns=5)
        self.assertEqual((buy.filled_lots, buy.remaining_lots, buy.quote_atoms), (3, 0, 302))
        self.assertEqual(buy.vwap_ticks, F(302, 3))
        limited = e.sweep(book(), rules(), "buy", 3, 100, now_ns=10, max_age_ns=5)
        self.assertEqual((limited.filled_lots, limited.remaining_lots), (1, 2))
        sell = e.sweep(book(), rules(), "sell", 3, 98, now_ns=10, max_age_ns=5)
        self.assertEqual(sell.quote_atoms, 295)

    def test_missing_or_truncated_depth_never_fills_unproven_quantity(self):
        for snapshot in (book(asks=((100, 1), (101, None))), book(asks_truncated=True)):
            result = e.sweep(snapshot, rules(), "buy", 4, 102, now_ns=10, max_age_ns=5)
            self.assertGreater(result.remaining_lots, 0)
        with self.assertRaisesRegex(ValueError, "minimum"):
            e.sweep(book(), rules(min_lots=4), "buy", 3, 101, now_ns=10, max_age_ns=5)

    def test_contract_multiplier_is_exact(self):
        result = e.sweep(book(), rules(base_atoms_per_lot=F(1, 100)),
                         "buy", 3, 101, now_ns=10, max_age_ns=5)
        self.assertEqual(result.base_atoms, F(3, 100))
        self.assertEqual(result.quote_atoms, F(151, 50))

    def test_bad_rules_book_units_and_time_fail_closed(self):
        for snapshot in (book(instrument=2), book(rules_version=2),
                         book(visible_at_ns=11), book(sequence=0),
                         book(asks=((101, 1), (100, 1))), book(bids=((100, 1),)),
                         book(asks=((100, -1),)), book(asks=())):
            with self.subTest(snapshot=snapshot), self.assertRaises(ValueError):
                e.sweep(snapshot, rules(), "buy", 3, 101, now_ns=10, max_age_ns=5)
        with self.assertRaises(ValueError):
            e.sweep(book(), rules(), "buy", 1, 101, now_ns=16, max_age_ns=5)

    def test_existing_host_depth_codec_feeds_economics_without_translation(self):
        payload = bytearray(704)
        payload[:16] = (1).to_bytes(16, "little")
        struct.pack_into("<QQQ", payload, 16, 1, 1, 10)
        payload[40:42] = bytes((2, 2))
        for i, (ticks, lots) in enumerate(((99, 1), (98, 2), (100, 1), (101, 2))):
            offset = 64 + ((0 if i < 2 else 8) + i % 2)*40
            payload[offset:offset+16] = ticks.to_bytes(16, "little", signed=True)
            payload[offset+16] = 1
            payload[offset+24:offset+40] = lots.to_bytes(16, "little", signed=True)
        value = e.sweep(host.decode_depth_snapshot(bytes(payload)), rules(), "buy", 3, 101,
                        now_ns=10, max_age_ns=5)
        self.assertEqual(value.quote_atoms, 302)


class FeeTests(unittest.TestCase):
    def test_fractional_ppm_fee_rates_stay_exact(self):
        fee = e.estimate_fee(rules(), e.FeeRule(1, 1, 1, F(1, 3), 0, 0, 100),
                             ticks=3_000_000, lots=1, role="taker", now_ns=10,
                             quote_atoms_per_fee_atom=1)
        self.assertEqual(fee.asset_atoms, 1)

    def test_v7_base_fee_matching_and_cash_pnl_do_not_double_count(self):
        spot = rules(base_atoms_per_lot=F(100), tick_quote_atoms_per_base_atom=F(1))
        fee_rule = e.FeeRule(1, 1, 2, 1000, 500, 0, 100)
        fee = e.estimate_fee(spot, fee_rule, ticks=100, lots=10,
                             role="unknown", now_ns=10, quote_atoms_per_fee_atom=100)
        self.assertEqual((fee.asset_atoms, fee.quote_atoms, fee.base_atoms), (1, 100, 1))
        match = e.match_quantity(1000, fee.base_atoms, F(1))
        self.assertEqual((match.net_base_atoms, match.hedge_lots, match.residual_base_atoms), (999, 999, 0))
        # Buy 10 @100, pay .01 base, sell net 9.99 at the unchanged price.
        value = e.spot_liquidation(100_000, 99_900, 0, (fee,))
        self.assertEqual((value.gross_atoms, value.fee_atoms, value.net_atoms), (0, 100, -100))

    def test_quote_and_third_asset_fees_round_up_and_require_payable_valuation(self):
        for asset, valuation, expected_atoms in ((1, 1, 1), (3, F(2, 9), 2)):
            fee_rule = e.FeeRule(1, 1, asset, 1000, 0, 0, 100)
            fee = e.estimate_fee(rules(), fee_rule, ticks=101, lots=3,
                                 role="taker", now_ns=10,
                                 quote_atoms_per_fee_atom=valuation, available_fee_atoms=2)
            self.assertEqual(fee.asset_atoms, expected_atoms)
        with self.assertRaises(ValueError):
            e.estimate_fee(rules(), e.FeeRule(1, 1, 3, 1000, 0, 0, 100),
                           ticks=101, lots=3, role="taker", now_ns=10,
                           quote_atoms_per_fee_atom=F(2, 9), available_fee_atoms=1)

    def test_fee_scope_expiry_and_unconfirmed_maker(self):
        fee_rule = e.FeeRule(1, 1, 1, 1000, 0, 0, 100)
        for role, expected in (("maker", 0), ("unknown", 1), ("taker", 1)):
            self.assertEqual(e.estimate_fee(rules(), fee_rule, ticks=100, lots=1,
                                           role=role, now_ns=10,
                                           quote_atoms_per_fee_atom=1).asset_atoms, expected)
        for r, at in ((rules(instrument=2), 10), (rules(), 100)):
            with self.assertRaises(ValueError):
                e.estimate_fee(r, fee_rule, ticks=100, lots=1, role="taker", now_ns=at,
                               quote_atoms_per_fee_atom=1)


class ForecastTests(unittest.TestCase):
    def test_v3_failure_paths_are_included_in_expected_profit(self):
        scenarios = (e.Scenario(F(1, 2), 10_000_000, True),
                     e.Scenario(F(1, 5), -4_000_000, True),
                     e.Scenario(F(3, 10), 0, True))
        self.assertEqual(e.expected_profit(scenarios), 4_200_000)

    def test_v4_admission_funding_never_nets_income_against_expense(self):
        self.assertGreater(math.log(103/100)-math.log(101.5/101), 0)
        self.assertEqual(e.funding_budget(((100_000_000, F(-3, 1000)),
                                          (100_000_000, F(2, 1000))), 50_000), 250_000)
        actual = e.evaluate_cycle(0, (), (300_000, -200_000))
        self.assertEqual(actual.net_atoms, 100_000)

    def test_confirmed_rebates_are_actual_facts_separate_from_admission(self):
        value = e.evaluate_cycle(100, (e.Cost("fee", 10, "expense"),), rebate_atoms=(3,))
        self.assertEqual((value.rebate_atoms, value.net_atoms), (3, 93))

    def test_v8_unknown_or_incomplete_scenarios_are_not_silently_zeroed(self):
        for values in ((e.Scenario(F(1), 0, False),),
                       (e.Scenario(F(1, 2), 10, True),), ()):
            with self.assertRaises(ValueError):
                e.expected_profit(values)


class TargetArithmeticTests(unittest.TestCase):
    def test_v6_fixed_target_arithmetic(self):
        self.assertEqual(e.entry_target(10_000_000, F(4, 5), 2_000_000), 8_000_000)

    def test_v10_to_v13_partial_target_and_whole_cycle_contribution(self):
        target = e.holding_target(8_000_000, F(1, 2), 2_000_000)
        self.assertEqual(target, 4_000_000)
        self.assertEqual(e.remaining_target(target, -1_000_000), 5_000_000)
        self.assertEqual(e.evaluate_cycle(4_500_000-1_000_000, ()).net_atoms, 3_500_000)
        self.assertEqual(e.holding_target(8_000_000, F(1, 10), 2_000_000), 2_000_000)
        self.assertEqual(e.holding_target(8_000_001, F(1, 2), 2_000_000), 4_000_001)
        with self.assertRaises(ValueError):
            e.holding_target(8, F(0), 2)


class CapitalTests(unittest.TestCase):
    def test_v9_allocation_and_reservations_are_not_profit_or_expense(self):
        self.assertEqual(e.strategy_pnl(100, 130, 20), 10)
        self.assertEqual(e.spendable_budget(100, -10, 200, 20), 70)
        self.assertEqual(e.spendable_budget(100, 50, 120, 20), 100)
        self.assertEqual(e.capital_required((("spot", F(21, 2)), ("margin", 5))), 16)
        self.assertEqual(e.evaluate_cycle(10, ()).net_atoms, 10)
        # Floating profits are absent from this API; only settled authoritative PnL enters it.
        self.assertTrue(e.funds_fit(((1, 10), (2, 20)), ((1, 10), (2, 20))))
        self.assertFalse(e.funds_fit(((1, 10), (2, 20)), ((1, 100), (2, 19))))


class QuantityTests(unittest.TestCase):
    def test_v5_selects_middle_quantity_and_records_rejections(self):
        candidates = tuple(e.Candidate(q, p, 100_000_000, q*100, True)
                           for q, p in ((1, 2_000_000), (2, 3_489_000), (3, 2_800_000)))
        result = e.choose_quantity(candidates, min_profit_atoms=1, min_edge_bp=0)
        self.assertEqual(result.chosen.lots, 2)
        rejected = e.choose_quantity(candidates, min_profit_atoms=3_489_000, min_edge_bp=0)
        self.assertIsNone(rejected.chosen)
        self.assertEqual(rejected.rejections, ((1, "profit"), (2, "profit"), (3, "profit")))

    def test_quantity_grid_is_bounded_deterministic_and_not_only_maximum(self):
        self.assertEqual(e.quantity_grid(10, 2, (F(1, 2), F(1)), (3, 7), 10), (2, 3, 5, 7, 10))
        with self.assertRaises(ValueError):
            e.quantity_grid(10, 2, (F(1, 2), F(1)), (3, 7), 4)

    def test_hard_gates_strict_edge_and_deterministic_ties(self):
        candidates = (e.Candidate(1, 10, 100, 20, True),
                      e.Candidate(2, 10, 100, 10, True),
                      e.Candidate(3, 20, 100, 10, False))
        for items in (candidates, tuple(reversed(candidates))):
            result = e.choose_quantity(items, min_profit_atoms=0, min_edge_bp=999)
            self.assertEqual(result.chosen.lots, 2)
            self.assertEqual(result.rejections, ((3, "hard_gate"),))
        result = e.choose_quantity(candidates, min_profit_atoms=0, min_edge_bp=1000)
        self.assertIsNone(result.chosen)


class BoundaryTests(unittest.TestCase):
    def test_signed_rounding_matches_independent_decimal_oracle(self):
        for text, low, high in (("1.0000011", 1_000_001, 1_000_002),
                                ("-1.0000011", -1_000_002, -1_000_001),
                                ("1", 1_000_000, 1_000_000)):
            value = F(text)*1_000_000
            self.assertEqual(e.floor_atoms(value), low)
            self.assertEqual(e.ceil_atoms(value), high)
            self.assertEqual(int((Decimal(text)*1_000_000).to_integral_value(rounding="ROUND_FLOOR")), low)

    def test_rejects_floats_nonfinite_boolean_and_capacity(self):
        for value in (1.0, math.nan, math.inf, -math.inf, True, "1", Decimal("1"), 1 << 127,
                      F(1, 1 << 127)):
            with self.subTest(value=value), self.assertRaises(ValueError):
                e.evaluate_cycle(value, ())
        with self.assertRaises(ValueError):
            e.evaluate_cycle(0, tuple(e.Cost(str(i), 1, "expense") for i in range(257)))
        with self.assertRaises(ValueError):
            e.capital_required((("a", e.MAX_INTEGER), ("b", 1)))

    def test_illegal_economic_boundaries_fail_closed(self):
        calls = (
            lambda: e.edge_bp(1, 0),
            lambda: e.match_quantity(1, 0, 0),
            lambda: e.match_quantity(1, 2, 1),
            lambda: rules(base_atoms_per_lot=0),
            lambda: rules(base_asset=1),
            lambda: e.capital_required((("same", 1), ("same", 1))),
            lambda: e.funds_fit(((1, 1),), ()),
            lambda: e.funds_fit(((1, 1), (1, 1)), ((1, 2),)),
            lambda: e.entry_target(1, F(2), 1),
            lambda: e.holding_target(1, F(2), 1),
            lambda: e.funding_budget((), F(-1, 10)),
        )
        for i, call in enumerate(calls):
            with self.subTest(case=i), self.assertRaises(ValueError):
                call()

    def test_monotonic_cost_and_funding_invariants_with_exact_oracle(self):
        for gross in range(-9, 10):
            for denominator in (1, 3, 7):
                fee = F(1, denominator)
                value = e.evaluate_cycle(F(gross, denominator), (e.Cost("fee", fee, "expense"),))
                oracle = (Decimal(gross)/Decimal(denominator)-1).to_integral_value(rounding="ROUND_FLOOR")
                self.assertEqual(value.net_atoms, int(oracle))
                buffered = e.evaluate_cycle(F(gross, denominator),
                                            (e.Cost("fee", fee, "expense"),
                                             e.Cost("risk", 1, "model_buffer")))
                self.assertLessEqual(buffered.plan_atoms, value.plan_atoms)
        self.assertEqual(e.funding_budget(((100, F(-1, 10)),), 0), 0)


if __name__ == "__main__":
    unittest.main()
