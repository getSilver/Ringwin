"""Canonical input -> shared evaluation -> read-only display replay."""
from dataclasses import replace
from fractions import Fraction as F
import json
import unittest

from opportunity_scanner import arbitrage_scanner as s
from strategies.cross_venue import arbitrage_evaluation as v
from strategy_host import decode_depth_snapshot, encode_depth_snapshot
from test_arbitrage_evaluation import (T, EXACT, LIMITS, path, policy, estimator_for, wire)
from test_arbitrage_probability import calibration


def fixture(mode="taker_taker", maker=None, lots=1):
    from test_arbitrage_evaluation import entry
    scenario = path("scan", position=entry(lots))
    observations = tuple(s.Observation(i+10, leg.account, leg.kind, leg.rules,
        scenario.markets[0].books[i], True) for i, leg in enumerate(scenario.entry.legs))
    pair = tuple(x.identity for x in observations)
    plan_policy = policy(mode=mode, original_base=F(lots), scope=s.candidate_id(pair, 1, mode, maker))
    estimator = estimator_for((scenario,), plan_policy)
    artifact = calibration(scope=v.probability_scope(plan_policy, 8_000_000, F(lots), T),
        margin=F(7, 100), model_hash=plan_policy.model_hash,
        simulation_hash=estimator.probability_model_hash(plan_policy))
    # Calibration helper defaults to taker_taker; changing mode must not reuse its identity.
    artifact = replace(artifact, mode=mode)
    plan = s.Plan(pair, maker, (scenario,), plan_policy,
                  estimator, artifact, EXACT, LIMITS, T+50, 200_000_000)
    return observations, plan


def scan(observations, plans=(), now=T, **changes):
    values = dict(at_ns=now, cursor=7, max_age_ns=1000, max_skew_ns=10)
    values.update(changes)
    return s.scan(observations, plans, **values)


def selected(snapshot):
    return next(x for x in snapshot["candidates"] if x["direction"] == 1 and x["mode"] == "taker_taker")


class ScannerTests(unittest.TestCase):
    def test_scope_depth_exact_bounds_unknown_quantity_and_quote_unit(self):
        observations, _ = fixture()
        # Leg A: min(1000*100,1001*100)*100000 = 10,000,000,000 atoms.
        # Leg B is deeper, so its upper bound must cover both independently.
        scope = s.Scope(1, min_depth_atoms=10_000_000_000, max_depth_atoms=10_990_000_000, quote_asset=1)
        self.assertEqual(len(scan(observations, scope=scope)["candidates"]), 6)
        self.assertEqual(scan(observations, scope=replace(scope, min_depth_atoms=10_000_000_001))["candidates"], [])
        self.assertEqual(scan(observations, scope=replace(scope, max_depth_atoms=10_989_999_999))["candidates"], [])
        self.assertEqual(scan(observations, scope=replace(scope, quote_asset=2))["candidates"], [])
        book = decode_depth_snapshot(observations[0].book)
        book["bids"] = ((1000, None),)
        unknown = (replace(observations[0], book=encode_depth_snapshot(book)), observations[1])
        self.assertEqual(scan(unknown, scope=s.Scope(1, min_depth_atoms=0, quote_asset=1))["candidates"], [])
        self.assertEqual(len(scan(unknown, scope=s.Scope(1))["candidates"]), 6)
        for changes in (dict(min_depth_atoms=-1), dict(min_depth_atoms=1, max_depth_atoms=0),
                        dict(min_depth_atoms=0, quote_asset=None), dict(max_depth_atoms=1.0)):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                replace(scope, **changes)

    def test_versioned_scope_filters_without_invalidating_original_plans(self):
        observations, plan = fixture()
        scope = s.Scope(1, (10, 11), ("linear",), (), (), None, None, None)
        result = scan(observations, (plan,), scope=scope)
        self.assertEqual(selected(result)["status"], "evaluated")
        self.assertEqual(result["scope"]["version"], "1")
        self.assertEqual(scan(observations, (plan,), scope=replace(scope,
            exclude_assets=(observations[0].rules.exposure_asset,)))["candidates"], [])
        with self.assertRaisesRegex(ValueError, "scan_asset_scope"):
            scan(observations, (replace(plan, policy=replace(plan.policy, base_asset=3)),),
                 scope=replace(scope, venues=(99,)))

    def test_public_input_to_display_exactly_reuses_trade_evaluation(self):
        observations, plan = fixture()
        expected = v.evaluate(plan.scenarios, plan.policy, plan.estimator, plan.calibration,
                              plan.simulation_error, plan.limits)
        result = scan(observations, (plan,))
        row = selected(result)
        self.assertEqual(row["plan_atoms"], str(expected.plan_atoms))
        self.assertEqual(row["target_atoms"], str(expected.entry_target_atoms))
        self.assertEqual(row["scenario_digest"], expected.scenario_digest)
        self.assertEqual(row["probability_lower_ppm"], expected.entry_probability.lower_ppm)
        self.assertEqual(row["status"], "evaluated")
        self.assertTrue(row["recommended"])
        display = json.loads(s.display_json(result, at_ns=T))
        self.assertEqual(display, result)
        self.assertTrue(all(x["trading_qualified"] is False for x in display["candidates"]))
        self.assertEqual(set(result), {"schema", "at_ns", "cursor", "replacement", "candidates"})

    def test_discovery_has_no_whitelist_and_pending_evidence_never_qualifies(self):
        observations, _ = fixture()
        result = scan(observations)
        self.assertEqual(len(result["candidates"]), 6)
        self.assertEqual({x["reason"] for x in result["candidates"]}, {"missing_evidence"})
        self.assertFalse(any(x["recommended"] or x["trading_qualified"] for x in result["candidates"]))
        self.assertEqual(len({x["id"] for x in result["candidates"]}), 6)

    def test_frozen_replay_is_order_independent_and_does_not_mutate_inputs(self):
        observations, plan = fixture()
        result = scan(observations, (plan,))
        replay = scan(tuple(reversed(observations)), (plan,))
        self.assertEqual(s.display_json(result, at_ns=T), s.display_json(replay, at_ns=T))
        self.assertEqual(plan.policy, policy(scope=s.candidate_id(*plan.key)))
        expired = json.loads(s.display_json(result, at_ns=T+50))
        self.assertEqual(selected(expired)["reason"], "expired")
        self.assertFalse(selected(expired)["recommended"])
        self.assertEqual(selected(result)["status"], "evaluated")

    def test_refresh_invalidates_old_candidate_and_removal_replaces_snapshot(self):
        observations, plan = fixture()
        before = selected(scan(observations, (plan,)))
        after = selected(scan(observations, (plan,), now=T+50))
        self.assertEqual(before["id"], after["id"])
        self.assertEqual(after["reason"], "expired")
        self.assertEqual(scan(observations[:1])["candidates"], [])
        self.assertEqual(selected(scan(observations, (plan,), now=T+1))["reason"], "evaluation_cutoff")

    def test_gap_staleness_skew_and_rule_expiry_remove_recommendation(self):
        observations, plan = fixture()
        gap = (replace(observations[0], continuous=False), observations[1])
        self.assertEqual(selected(scan(gap, (plan,)))["reason"], "data_gap")
        self.assertEqual(selected(scan(observations, now=T+1000))["reason"], "stale_data")
        skew = (replace(observations[0], book=wire(1, T-11, 1000, 1001)), observations[1])
        self.assertEqual(selected(scan(skew))["reason"], "data_skew")
        self.assertEqual(selected(scan(observations, now=1_000_000, max_age_ns=2_000_000))["reason"], "rules_expired")

    def test_all_products_and_environment_orders_match_with_leg_diagnostics(self):
        observations, _ = fixture()
        for environments in (("demo", "testnet"), ("testnet", "demo")):
            for products in (("spot", "spot"), ("spot", "linear"), ("linear", "spot"), ("linear", "linear")):
                with self.subTest(environments=environments, products=products):
                    legs = tuple(replace(o, venue=10 if i == 0 else 987, kind=products[i], environment=environments[i])
                                 for i, o in enumerate(observations))
                    rows = scan(tuple(reversed(legs)))["candidates"]
                    self.assertEqual(len(rows), 6)
                    self.assertEqual({x["direction"] for x in rows}, {-1, 1})
                    for row in rows:
                        self.assertEqual([leg["venue"] for leg in row["legs"]], ["10", "987"])
                        self.assertEqual([leg["requested_environment"] for leg in row["legs"]], list(environments))
                        sell = 1 if row["direction"] == 1 else 0
                        self.assertEqual(row["legs"][sell]["side"], "sell")
                        self.assertEqual(row["legs"][1-sell]["side"], "buy")
                        if products[sell] == "spot":
                            self.assertIn("spot_inventory_unverified", row["legs"][sell]["issues"])
                            self.assertIn("spot_sell_unsupported", row["legs"][sell]["issues"])
                            self.assertEqual(row["status"], "pending")

    def test_old_scanner_archive_preserves_original_pairing_rules(self):
        from opportunity_scanner.scanner_archive import freeze, thaw
        observations, _ = fixture()
        observations = (replace(observations[0], kind="spot"), observations[1])
        saved = freeze(observations)
        for row in saved["tuple"]:
            for name in ("market_source", "market_error", "registered_assets"):
                del row["fields"][name]
        legacy = scan(thaw(saved), legacy=True)["candidates"]
        self.assertEqual(len(legacy), 3)
        self.assertTrue(all(row["direction"] == 1 and "legs" not in row for row in legacy))

    def test_cross_asset_or_same_venue_filtering(self):
        observations, _ = fixture()
        same = (observations[0], replace(observations[1], venue=observations[0].venue))
        self.assertEqual(scan(same)["candidates"], [])
        different = (observations[0], replace(observations[1], rules=replace(observations[1].rules, base_asset=3)))
        self.assertEqual(scan(different)["candidates"], [])

    def test_scope_mismatch_duplicate_and_future_inputs_fail_closed(self):
        observations, plan = fixture()
        invalid = [((observations[0], observations[0]), ()),
                   (observations, (plan, plan)),
                   (observations[:1], (plan,)),
                   (observations, (replace(plan, policy=replace(plan.policy, base_asset=3)),)),
                   ((replace(observations[0], book=wire(1, T, 999, 1000)), observations[1]), (plan,))]
        for inputs, plans in invalid:
            with self.subTest(inputs=inputs), self.assertRaises(ValueError):
                scan(inputs, plans)
        with self.assertRaisesRegex(ValueError, "future_observation"):
            scan(observations, now=T-1)
        with self.assertRaises(ValueError):
            replace(plan, maker_leg=0)
        with self.assertRaisesRegex(ValueError, "scan_policy_scope"):
            replace(plan, policy=replace(plan.policy, scope="another-pair-or-maker"))
        with self.assertRaises(ValueError):
            replace(observations[0], book=b"bad")

    def test_three_mode_keys_keep_maker_leg_and_never_inherit_qualification(self):
        observations, taker = fixture()
        _, maker_a = fixture("maker_taker", 0)
        _, maker_b = fixture("maker_taker", 1)
        result = scan(observations, (maker_b, taker, maker_a))
        rows = [x for x in result["candidates"] if x["direction"] == 1]
        self.assertEqual(len({x["id"] for x in rows}), 3)
        # The frozen hold artifacts remain taker-only and must reject maker evidence.
        self.assertEqual(sum(x["recommended"] for x in rows), 1)
        self.assertFalse(any(x["trading_qualified"] for x in rows))
        self.assertEqual(s.display_json(result, at_ns=T), s.display_json(
            scan(observations, (maker_a, maker_b, taker)), at_ns=T))

    def test_quantity_selection_matches_independent_exhaustion_of_shared_results(self):
        observations, original = fixture()
        policy2 = replace(original.policy, original_base=F(2))
        estimator2 = estimator_for(original.scenarios, policy2)
        artifact2 = replace(original.calibration,
            scope=v.probability_scope(policy2, 8_000_000, F(2), T),
            simulation_hash=estimator2.probability_model_hash(policy2))
        second = replace(original, policy=policy2, estimator=estimator2, calibration=artifact2,
                         occupied_atoms=100_000_000)
        options = (original, second)
        results = [(plan, v.evaluate(plan.scenarios, plan.policy, plan.estimator, plan.calibration,
                                    plan.simulation_error, plan.limits)) for plan in options]
        qualified = [(plan, result) for plan, result in results if result.allowed]
        self.assertEqual(len(qualified), 2)
        best = min(qualified, key=lambda x: (-x[1].plan_atoms, x[0].occupied_atoms, x[0].policy.original_base))[0]
        row = selected(scan(observations, options))
        self.assertEqual(row["quantity_base"], [str(best.policy.original_base.numerator),
                                               str(best.policy.original_base.denominator)])
        self.assertEqual(scan(observations, options), scan(observations, tuple(reversed(options))))

    def test_capacity_and_display_error_responses(self):
        observations, plan = fixture()
        with self.assertRaises(ValueError):
            scan(observations, (plan,)*257)
        many = tuple(replace(observations[0], venue=i+100, account=i+100,
            rules=replace(observations[0].rules, instrument=i+100),
            book=wire(i+100, T, 1000, 1001)) for i in range(10))
        with self.assertRaisesRegex(ValueError, "scan_candidate_capacity"):
            scan(many)
        snapshot = scan(observations, (plan,))
        with self.assertRaisesRegex(ValueError, "display_snapshot"):
            s.display_json(dict(snapshot, schema="unknown"), at_ns=T)
        with self.assertRaisesRegex(ValueError, "display_snapshot"):
            s.display_json(snapshot, at_ns=T-1)

    def test_display_validity_is_capped_by_calibration_and_data_policy(self):
        observations, plan = fixture()
        shorter = replace(plan, calibration=replace(plan.calibration, valid_until_ns=T+10))
        row = selected(scan(observations, (shorter,)))
        self.assertEqual(row["valid_until_ns"], str(T+10))
        self.assertEqual(selected(json.loads(s.display_json(scan(observations, (shorter,)),
            at_ns=T+10)))["reason"], "expired")


if __name__ == "__main__":
    unittest.main()
