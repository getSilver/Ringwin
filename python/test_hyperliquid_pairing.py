"""Existing cycles retain real Asset identities for USDC and approved wrappers."""
from dataclasses import replace
import unittest

from strategies.cross_venue import arbitrage_baseline as b
from strategies.cross_venue import arbitrage_cycle as c
from strategies.cross_venue import arbitrage_evaluation as v
from test_arbitrage_cycle import plan, facts, done
from test_arbitrage_evaluation import T, policy
from test_arbitrage_maker import maker_plan, quote
from test_arbitrage_evaluation import entry, market
from strategies.cross_venue import arbitrage_checkpoint as recovery
from strategies.cross_venue import arbitrage_maker as m


class PairingTests(unittest.TestCase):
    def test_usdc_ioc_keeps_unknown_identity_and_rejects_usdt_counterpart(self):
        original = plan()
        legs = tuple(replace(x, rules=replace(x.rules, quote_asset=3)) for x in original.legs)
        configured = replace(original, policy=replace(original.policy, quote_asset=3), legs=legs)
        cycle = c.Cycle(configured)
        self.assertEqual(len(cycle.start(cursor=1, at_ns=T).intents), 2)
        unknown = facts(possible_base=((0, 10), (0, 0)), orders=(done(1, 0, 0, status="unknown", possible_lots=10, economic_complete=False),
                               done(2, 1, 0)))
        self.assertFalse(cycle.apply(unknown).intents)
        self.assertEqual(cycle.apply(replace(unknown, cursor=3)).queries, (1,))
        with self.assertRaises(ValueError):
            replace(configured, legs=(legs[0], original.legs[1]))

    def test_wrapper_requires_explicit_approval_and_keeps_fee_asset(self):
        original = plan()
        wrapped = replace(original.legs[0], kind="spot", rules=replace(original.legs[0].rules, base_asset=99))
        with self.assertRaises(ValueError):
            replace(original, legs=(wrapped, original.legs[1]))
        wrapped = replace(wrapped, rules=replace(wrapped.rules, approved_base_pair=(2, "approved-wrapper-v1")))
        configured = replace(original, legs=(wrapped, original.legs[1]))
        self.assertEqual(configured.legs[0].rules.base_asset, 99)
        self.assertEqual(configured.legs[0].rules.exposure_asset, 2)
        self.assertEqual(len(c.Cycle(configured).start(cursor=1, at_ns=T).intents), 2)
        b.GridSampler(wrapped.rules, original.legs[1].rules, version=1, max_age_ns=10, max_skew_ns=1)
        for approval in ((2, ""), (3, "approved"), (True, "approved")):
            with self.assertRaises(ValueError):
                replace(original, legs=(replace(wrapped, rules=replace(wrapped.rules, approved_base_pair=approval)), original.legs[1]))

    def test_usdc_maker_plan_uses_existing_state_machine(self):
        original = maker_plan()
        legs = tuple(replace(x, rules=replace(x.rules, quote_asset=3)) for x in original.legs)
        configured = replace(original, policy=replace(original.policy, quote_asset=3), legs=legs)
        cycle = m.Cycle(configured)
        action = cycle.start(cursor=1, at_ns=T, market=market(0, 1100), quotes=(quote(configured),))
        self.assertEqual(action.intents[0].time_in_force, "post-only")
        f = facts(3, orders=(done(1, 0, 0, status="sent", possible_lots=10),), market=market(3, 1100, bid_a=999))
        action = cycle.apply(f, quotes=(quote(configured, ticks=999, at=3, bid=999, economic_ref=f.economic_ref),))
        self.assertEqual((action.cancels, action.intents), ((1,), ()))
        action = cycle.apply(replace(f, cursor=4, orders=(done(1, 0, 0, economic_complete=False),)))
        self.assertFalse(action.intents)
        f = facts(5, orders=(done(1, 0, 0),), market=market(5, 1100, bid_a=999))
        action = cycle.apply(f, quotes=(quote(configured, ticks=999, at=5, bid=999, economic_ref=f.economic_ref),))
        self.assertEqual([(x.sequence, x.limit_ticks) for x in action.intents], [(2, 999)])

    def test_approval_version_changes_checkpoint_and_evaluation_identity(self):
        original = entry()
        first = original.legs[0]
        rules = replace(first.rules, base_asset=99, approved_base_pair=(2, "approval-v1"))
        wrapped = replace(first, kind="spot", rules=rules)
        current = replace(original, legs=(wrapped, original.legs[1]))
        newer = replace(current, legs=(replace(wrapped, rules=replace(rules, approved_base_pair=(2, "approval-v2"))), current.legs[1]))
        self.assertNotEqual(recovery.content(current), recovery.content(newer))
        self.assertNotEqual(v.Context(current, market(0, 1100), 1, policy()).identity,
                            v.Context(newer, market(0, 1100), 1, policy()).identity)


if __name__ == "__main__":
    unittest.main()
