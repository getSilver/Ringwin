"""Public Python IOC contract replay; these are injected core facts, not an OMS."""
from dataclasses import replace
from fractions import Fraction as F
import struct
import unittest

from strategies.cross_venue import arbitrage_cycle as c
from strategies.cross_venue import arbitrage_admission as a
from strategies.cross_venue import arbitrage_evaluation as v
import strategy_host as host
from test_arbitrage_evaluation import entry, leg, market, policy, path, estimator_for, LIMITS, T


def plan(**changes):
    values = dict(strategy=9, portfolio=7, first_sequence=1, request_ref="admission-request",
                  config_version=1, config_hash="a"*64, execution_hash="b"*64, policy=policy(original_base=F(10)),
                  legs=(c.LegSpec(1, leg(0).rules, "linear", 1, 10),
                        c.LegSpec(2, leg(1).rules, "linear", -1, 10)),
                  entry_limits=(1001, 1099), target_atoms=80_000_000,
                  repair_deadline_ns=T+20, repair_attempts=2, repair_loss_cap_atoms=1_000_000,
                  exit_deadline_ns=T+150, exit_attempts=3, daily_loss_atoms=100_000_000,
                  drawdown_atoms=100_000_000)
    values.update(changes)
    return c.Plan(**values)


def with_price_units(action, base_scale=0):
    if action is None:
        return None
    legs = tuple(replace(leg, rules=replace(leg.rules, quote_unit=("USDT", 6),
        registered_base=(leg.rules.base_asset, base_scale))) for leg in action.plan.legs)
    return replace(action, plan=replace(action.plan, legs=legs))


def facts(cursor=2, **changes):
    values = dict(cursor=cursor, at_ns=T+cursor, cycle_ref="core-cycle", reservation_ref="core-reservation",
                  admission="accepted", orders=(), positions=(F(0), F(0)), safe_reduce_lots=(0, 0),
                  market=market(cursor, 1100), economic_entry=None, economic_ref="economic:0",
                  opening_allowed=True, reducing_allowed=True, risk_causes=(), model_warning=False,
                  nav_atoms=1_000_000_000, day_start_nav_atoms=1_000_000_000,
                  external_allocation_atoms=0, flow_adjusted_peak_atoms=1_000_000_000,
                  repair_loss_atoms=0, repair_cost_atoms=0, closed_ref=None, residual_refs=())
    values.update(changes)
    return c.Facts(**values)


def done(sequence, index, lots, **changes):
    values = dict(sequence=sequence, leg=index, status="terminal", applied_lots=lots,
                  possible_lots=0, economic_complete=True, fact_ref="order:"+str(sequence))
    values.update(changes)
    return c.OrderFact(**values)


class CycleTests(unittest.TestCase):
    def test_profit_report_uses_signed_canonical_fx_and_never_rebooks_samples(self):
        cycle = c.Cycle(plan())
        cycle.start(cursor=1, at_ns=T)
        frame = facts(orders=(done(1, 0, 0), done(2, 1, 0)))
        cycle.apply(frame)
        quote = c.e.FxRate(F(998, 1000), T, "USDC-USDT spot")
        for amount, expected in ((1000, "-2"), (-1000, "2")):
            fill = c.e.FxExposure("fill", T, F(amount), F(amount), quote)
            sample = c.e.FxExposure("sample", T+1, F(0), F(amount), quote)
            snapshot = replace(frame, fx_exposures=(fill, fill, sample))
            report = cycle.profit_report(snapshot)
            self.assertEqual(report, cycle.profit_report(snapshot))
            fx = report["actual_fx"]
            self.assertEqual(fx["deviation_usdt"], [expected, "1"])
            self.assertEqual(len(fx["records"]), 2)
            self.assertEqual(fx["records"][0]["rate"]["source"], "USDC-USDT spot")
            self.assertEqual(fx["records"][1]["holding_usdt"], ["0", "1"])
            mark = replace(sample, rate=c.e.FxRate(F(997, 1000), T+1, quote.source))
            fx = cycle.profit_report(replace(frame, fx_exposures=(fill, mark)))["actual_fx"]
            self.assertEqual(fx["records"][1]["holding_usdt"], [str(-amount//1000), "1"])
            fx = cycle.profit_report(replace(frame, fx_exposures=(replace(fill, rate=None), mark)))["actual_fx"]
            self.assertEqual(fx["status"], "pending")
            self.assertIsNone(fx["deviation_usdt"])
        action = cycle.apply(replace(frame, cursor=3, at_ns=T+3, fx_exposures=(fill, mark)))
        self.assertEqual(action.profit["actual_fx"]["deviation_usdt"], ["3", "1"])

    def test_complete_entry_is_one_group_with_independent_leg_price_and_quantity(self):
        cycle = c.Cycle(plan())
        action = cycle.start(cursor=1, at_ns=T)
        self.assertEqual([(x.sequence, x.leg, x.lots, x.limit_ticks) for x in action.intents],
                         [(1, 0, 10, 1001), (2, 1, 10, 1099)])
        batch = bytearray(96)
        struct.pack_into("<Q", batch, 72, 1)
        struct.pack_into("<Q", batch, 88, 1)
        encoded = with_price_units(action).encode(bytes(batch), (1, 0, 1), activation=5)
        self.assertEqual(len(encoded), 336)
        self.assertEqual(struct.unpack_from("<HII", encoded, 98), (2, 2, 208))
        self.assertEqual(struct.unpack_from("<qqQ", encoded, 192), (10, 1001, 1))
        self.assertEqual(struct.unpack_from("<qqQ", encoded, 296), (10, 1099, 1))
        self.assertEqual(int.from_bytes(encoded[216:232], "little", signed=True), 10**17)
        self.assertEqual(int.from_bytes(encoded[320:336], "little", signed=True), 10**17)
        self.assertEqual(encoded[130], 1)
        self.assertEqual(encoded[234], 2)
        self.assertEqual(struct.unpack_from("<I", encoded, 124)[0], host.crc32c(encoded[:124]+encoded[128:]))
        self.assertEqual(cycle.start(cursor=1, at_ns=T).queries, (1, 2))

    def test_second_leg_rejected_repairs_only_known_imbalance_not_original_remainder(self):
        cycle = c.Cycle(plan())
        cycle.start(cursor=1, at_ns=T)
        f = facts(orders=(done(1, 0, 10), done(2, 1, 6)), positions=(F(10), F(6)), safe_reduce_lots=(10, 6))
        action = cycle.apply(f)
        self.assertEqual([(x.sequence, x.leg, x.lots, x.reducing) for x in action.intents], [(3, 1, 4, False)])
        # A repeated report/archived duplicate cannot manufacture another fill or repair.
        self.assertEqual(cycle.apply(replace(f, cursor=3)).queries, (3,))
        self.assertEqual(cycle.repair_used, 1)

    def test_second_dispatch_rejection_keeps_first_leg_fill_and_original_reservation(self):
        cycle = c.Cycle(plan())
        cycle.start(cursor=1, at_ns=T)
        f = facts(orders=(done(1, 0, 10), done(2, 1, 0, status="rejected")),
                  positions=(F(10), F(0)), safe_reduce_lots=(10, 0))
        action = cycle.apply(f)
        self.assertEqual([(x.leg, x.lots, x.reducing) for x in action.intents], [(1, 10, False)])
        self.assertEqual(cycle.reservation_ref, "core-reservation")
        self.assertEqual(f.positions, (F(10), F(0)))

    def test_group_codec_preserves_fee_adjusted_unequal_lot_targets(self):
        frozen = plan(policy=policy(original_base=F(9)),
                      legs=(replace(plan().legs[0], kind="spot"), replace(plan().legs[1], target_lots=9)))
        action = c.Cycle(frozen).start(cursor=1, at_ns=T)
        batch = bytearray(96)
        struct.pack_into("<Q", batch, 88, 1)
        encoded = with_price_units(action).encode(bytes(batch), (1, 0, 1), activation=5)
        self.assertEqual(struct.unpack_from("<q", encoded, 192)[0], 10)
        self.assertEqual(struct.unpack_from("<q", encoded, 296)[0], 9)

    def test_single_limit_price_carries_rules_version_and_reports_unencodable_ticks(self):
        cycle = c.Cycle(plan())
        cycle.start(cursor=1, at_ns=T)
        frame = facts(orders=(done(1, 0, 10), done(2, 1, 6)), positions=(F(10), F(6)),
                      safe_reduce_lots=(10, 6))
        action = cycle.apply(frame)
        batch = bytearray(96)
        struct.pack_into("<Q", batch, 88, action.cursor)
        encoded = with_price_units(action).encode(bytes(batch), (1, 0, 1), activation=5)
        self.assertEqual(struct.unpack_from("<HII", encoded, 98), (1, 1, 104))
        self.assertEqual(struct.unpack_from("<H", encoded, 128), (2,))
        self.assertEqual(struct.unpack_from("<qQ", encoded, 200), (action.intents[0].limit_ticks, 1))
        with self.assertRaisesRegex(ValueError, "leg_1_limit_price_tick_unit"):
            action.encode(bytes(batch), (1, 0, 1), activation=5)
        invalid = replace(action, intents=(replace(action.intents[0], limit_ticks=1 << 63),))
        with self.assertRaisesRegex(ValueError, "leg_1_limit_price_ticks"):
            with_price_units(invalid).encode(bytes(batch), (1, 0, 1), activation=5)

    def test_unknown_preserves_original_identities_and_blocks_even_profitable_exit(self):
        cycle = c.Cycle(plan())
        cycle.start(cursor=1, at_ns=T)
        f = facts(orders=(done(1, 0, 10), done(2, 1, 0, status="unknown", possible_lots=10,
                                             economic_complete=False)), positions=(F(10), F(0)),
                  safe_reduce_lots=(10, 0), possible_base=((F(10), F(10)), (F(0), F(10))),
                  risk_causes=(("margin", "margin-fact"),))
        action = cycle.apply(f)
        self.assertEqual(action.queries, (2,))
        self.assertTrue(action.reconcile)
        self.assertFalse(action.intents)
        self.assertEqual((cycle.cycle_ref, cycle.reservation_ref), ("core-cycle", "core-reservation"))
        self.assertEqual(cycle.phase, "reconciling")
        self.assertEqual(cycle.first_exit, ("margin", 2))
        self.assertTrue(cycle.apply(replace(f, cursor=3, at_ns=T+151)).escalate)

    def test_failed_repair_reduces_excess_with_fixed_budget(self):
        cycle = c.Cycle(plan(repair_attempts=0))
        cycle.start(cursor=1, at_ns=T)
        action = cycle.apply(facts(orders=(done(1, 0, 10), done(2, 1, 6)),
                                  positions=(F(10), F(6)), safe_reduce_lots=(10, 6)))
        self.assertEqual([(x.leg, x.lots, x.reducing) for x in action.intents], [(0, 4, True)])
        self.assertEqual(cycle.phase, "repairing")
        self.assertIn("repair_failed", cycle.reasons)

    def test_partial_match_freezes_target_once_and_complete_cycle_waits_for_core_closure(self):
        cycle = c.Cycle(plan())
        cycle.start(cursor=1, at_ns=T)
        position = entry(5)
        estimator = estimator_for((path("holding", position=position),), cycle.plan.policy, 80_000_000)
        f = facts(orders=(done(1, 0, 5), done(2, 1, 5)), positions=(F(5), F(5)),
                  safe_reduce_lots=(5, 5), economic_entry=position, market=market(0, 1100), at_ns=T)
        self.assertEqual(cycle.apply(f, estimator=estimator, limits=LIMITS).reason, "holding")
        self.assertEqual((cycle.phase, cycle.target_atoms, cycle.target_cursor), ("holding", 40_000_000, 2))
        # Existing Holding does not recheck probability and the absolute target never shrinks.
        action = cycle.apply(replace(f, cursor=3, at_ns=T+1, market=market(1, 1018)))
        self.assertEqual(action.reason, "take_profit")
        self.assertEqual([(x.leg, x.lots, x.reducing) for x in action.intents], [(0, 5, True), (1, 5, True)])
        self.assertEqual(cycle.first_exit, ("take_profit", 3))
        partial = replace(f, cursor=4, at_ns=T+2, market=market(2, 1100),
                          positions=(F(2), F(2)), safe_reduce_lots=(2, 2), economic_entry=entry(2),
                          orders=f.orders+(done(3, 0, 3), done(4, 1, 3)))
        self.assertEqual(cycle.apply(partial).reason, "exit")
        self.assertEqual(cycle.target_atoms, 40_000_000)
        flat = facts(5, orders=partial.orders+(done(5, 0, 2), done(6, 1, 2)))
        self.assertEqual(cycle.apply(flat).reason, "await_closure")
        self.assertEqual(cycle.phase, "settling")
        self.assertEqual(cycle.apply(replace(flat, cursor=6, closed_ref="closure:1")).reason, "closed")
        self.assertEqual(cycle.phase, "completed")

    def test_risk_priority_and_external_allocations_do_not_count_as_loss_or_profit(self):
        cycle = c.Cycle(plan())
        cycle.start(cursor=1, at_ns=T)
        f = facts(orders=(done(1, 0, 10), done(2, 1, 10)), positions=(F(10), F(10)),
                  safe_reduce_lots=(10, 10), nav_atoms=1_500_000_000, external_allocation_atoms=600_000_000,
                  market=market(101, 1000, risk=True, invalid=True), at_ns=T+101)
        action = cycle.apply(f)
        self.assertEqual(cycle.first_exit, ("daily_loss", 2))
        self.assertIn("drawdown", cycle.reasons)
        self.assertEqual(action.reason, "exit")
        cycle.apply(replace(f, cursor=3, nav_atoms=2_000_000_000, external_allocation_atoms=0))
        self.assertIn("daily_loss", cycle.reasons)
        self.assertEqual(cycle.phase, "exiting")

    def test_public_admission_recommendation_binds_group_and_expires(self):
        from test_arbitrage_admission import inputs, ready
        obs, option, cfg, approval, core = inputs()
        request = a.Admission(cfg).propose(obs, (option,), (approval,), (ready(option.plan, cfg),), core).request
        legs = tuple(c.LegSpec(x.account, x.rules, x.kind, x.direction, lots)
                     for x, lots in zip(option.plan.scenarios[0].entry.legs, option.lots))
        bound = plan(request_ref=request.identity, config_hash=cfg.content_hash,
                     policy=option.plan.policy, legs=legs, target_atoms=request.target_atoms)
        cycle = c.Cycle.from_admission(bound, request, option)
        self.assertEqual(len(cycle.start(cursor=core.cursor, at_ns=T).intents), 2)
        with self.assertRaisesRegex(ValueError, "admission_binding"):
            c.Cycle.from_admission(replace(bound, target_atoms=bound.target_atoms+1), request, option)
        for spec in (replace(bound.legs[0], rules=replace(bound.legs[0].rules, version=999)),
                     replace(bound.legs[0], kind="spot")):
            with self.subTest(spec=spec), self.assertRaisesRegex(ValueError, "admission_binding"):
                c.Cycle.from_admission(replace(bound, legs=(spec, bound.legs[1])), request, option)
        with self.assertRaisesRegex(ValueError, "admission_binding"):
            c.Cycle.from_admission(bound, replace(request, scenario_digest="f"*64), option)
        with self.assertRaisesRegex(ValueError, "admission_binding"):
            c.Cycle.from_admission(replace(bound, execution_hash="f"*64), request, option)
        expired = c.Cycle.from_admission(bound, request, option)
        with self.assertRaisesRegex(ValueError, "admission_expired_or_cursor"):
            expired.start(cursor=core.cursor, at_ns=request.valid_until_ns)

    def test_joint_rejection_creates_no_independent_retry_and_requires_closure(self):
        cycle = c.Cycle(plan())
        cycle.start(cursor=1, at_ns=T)
        f = facts(admission="rejected", reservation_ref=None)
        self.assertEqual(cycle.apply(f).reason, "await_closure")
        self.assertEqual(cycle.pending, ())
        self.assertFalse(cycle.apply(replace(f, cursor=3, closed_ref="rejected-and-reconciled")).intents)
        self.assertEqual(cycle.phase, "completed")

    def test_report_fill_order_and_archived_duplicate_use_only_core_applied_economics(self):
        for report_first in (True, False):
            with self.subTest(report_first=report_first):
                cycle = c.Cycle(plan())
                cycle.start(cursor=1, at_ns=T)
                # Report status never supplies positions; core economic coverage is explicit.
                first = facts(orders=(done(1, 0, 10, economic_complete=False),
                                      done(2, 1, 6, economic_complete=False)),
                              positions=(F(0), F(0)) if report_first else (F(10), F(6)),
                              safe_reduce_lots=(0, 0))
                self.assertEqual(cycle.apply(first).queries, (1, 2))
                complete = facts(3, orders=(done(1, 0, 10), done(2, 1, 6)),
                                 positions=(F(10), F(6)), safe_reduce_lots=(10, 6), economic_ref="unique-applied-fill")
                self.assertEqual(cycle.apply(complete).intents[0].lots, 4)
                for cursor in (4, 5):
                    duplicate = replace(complete, cursor=cursor, economic_ref="authenticated-cold-history")
                    self.assertEqual(cycle.apply(duplicate).queries, (3,))
                    self.assertEqual(cycle.repair_used, 1)
                    self.assertEqual(cycle.next_sequence, 4)

    def test_repair_attempt_time_price_loss_permission_and_depth_limits(self):
        cases = (
            (plan(repair_attempts=0), {}),
            (plan(repair_deadline_ns=T+2), {}),
            (plan(entry_limits=(1001, 1200)), {}),
            (plan(), {"repair_loss_atoms": 1_000_001}),
            (plan(), {"repair_loss_atoms": 900_000, "repair_cost_atoms": 100_001}),
            (plan(), {"opening_allowed": False}),
            (plan(), {"model_warning": True}),
            (plan(), {"market": market(2, 1100, depth=0)}),
        )
        for frozen, changes in cases:
            with self.subTest(changes=changes, limit=frozen.entry_limits, deadline=frozen.repair_deadline_ns):
                cycle = c.Cycle(frozen)
                cycle.start(cursor=1, at_ns=T)
                result = cycle.apply(facts(orders=(done(1, 0, 10), done(2, 1, 6)),
                    positions=(F(10), F(6)), safe_reduce_lots=(10, 6), **changes))
                self.assertTrue(all(x.reducing for x in result.intents))
                self.assertEqual(cycle.repair_used, 0)

    def test_repair_attempts_do_not_reset_and_never_chase_unfilled_target(self):
        cycle = c.Cycle(plan(repair_attempts=1))
        cycle.start(cursor=1, at_ns=T)
        f = facts(orders=(done(1, 0, 8), done(2, 1, 6)), positions=(F(8), F(6)), safe_reduce_lots=(8, 6))
        self.assertEqual(cycle.apply(f).intents[0].lots, 2)
        # IOC partially fills one lot. Budget exhausted: trim one; never request target 10.
        result = cycle.apply(replace(f, cursor=3, positions=(F(8), F(7)), safe_reduce_lots=(8, 7),
                                     orders=f.orders+(done(3, 1, 1),)))
        self.assertEqual([(x.leg, x.lots, x.reducing) for x in result.intents], [(0, 1, True)])
        self.assertEqual(cycle.repair_used, 1)

    def test_unknown_after_repair_and_exit_retains_phase_and_pending_identity(self):
        cycle = c.Cycle(plan())
        cycle.start(cursor=1, at_ns=T)
        f = facts(orders=(done(1, 0, 10), done(2, 1, 6)), positions=(F(10), F(6)), safe_reduce_lots=(10, 6))
        cycle.apply(f)
        uncertain = replace(f, cursor=3, orders=f.orders+(done(3, 1, 0, status="unknown", possible_lots=4,
                            economic_complete=False),), possible_base=((F(10), F(10)), (F(6), F(10))))
        self.assertEqual(cycle.apply(uncertain).queries, (3,))
        self.assertEqual(cycle.before_reconciling, "repairing")
        known = replace(f, cursor=4, at_ns=T+4, orders=f.orders+(done(3, 1, 4),), positions=(F(10), F(10)),
                        safe_reduce_lots=(10, 10), market=market(4, 1100, risk=True))
        result = cycle.apply(known)
        self.assertEqual([x.sequence for x in result.intents], [4, 5])
        exit_unknown = replace(known, cursor=5, orders=known.orders+(
            done(4, 0, 0, status="unknown", possible_lots=10, economic_complete=False), done(5, 1, 0)),
            possible_base=((F(0), F(10)), (F(10), F(10))))
        self.assertEqual(cycle.apply(exit_unknown).queries, (4,))
        self.assertEqual(cycle.before_reconciling, "exiting")
        self.assertEqual(cycle.exit_used, 1)

    def test_missing_hold_evidence_exits_and_holding_cost_correction_does_not_lower_target(self):
        cycle = c.Cycle(plan())
        cycle.start(cursor=1, at_ns=T)
        f = facts(orders=(done(1, 0, 5), done(2, 1, 5)), positions=(F(5), F(5)), safe_reduce_lots=(5, 5),
                  economic_entry=entry(5), market=market(0, 1100), at_ns=T)
        result = cycle.apply(f)
        self.assertEqual(result.reason, "holding_evidence_missing")
        self.assertEqual(cycle.phase, "exiting")
        self.assertIsNone(cycle.target_atoms)

        cycle = c.Cycle(plan())
        cycle.start(cursor=1, at_ns=T)
        estimator = estimator_for((path("corrected", position=entry(5)),), cycle.plan.policy, 80_000_000)
        cycle.apply(f, estimator=estimator, limits=LIMITS)
        corrected = replace(entry(5), completed=(v.Settled("fee-adjustment", -2_000_000),))
        # Executable gross 41m, correction -2m: 39m < frozen 40m.
        result = cycle.apply(replace(f, cursor=3, at_ns=T+1, market=market(1, 1018), economic_entry=corrected,
                                     economic_ref="fee-adjustment-version-2"))
        self.assertEqual(result.reason, "holding")
        self.assertEqual(cycle.target_atoms, 40_000_000)
        self.assertEqual(cycle.last_economic_ref, "fee-adjustment-version-2")

    def test_risk_exit_needs_no_profit_and_is_bounded_by_permission_attempts_and_time(self):
        for changes in ({"reducing_allowed": False}, {"at_ns": T+150}, {}):
            cycle = c.Cycle(plan(exit_attempts=0 if not changes else 3))
            cycle.start(cursor=1, at_ns=T)
            f = facts(orders=(done(1, 0, 10), done(2, 1, 10)), positions=(F(10), F(10)),
                      safe_reduce_lots=(10, 10), market=market(2, 1300, risk=True), **changes)
            result = cycle.apply(f)
            self.assertTrue(result.escalate)
            self.assertFalse(result.intents)
            self.assertEqual(cycle.phase, "exiting")

    def test_closure_never_waives_unknown_or_perpetual_residue_and_spot_custody_is_explicit(self):
        cycle = c.Cycle(plan())
        cycle.start(cursor=1, at_ns=T)
        f = facts(orders=(done(1, 0, 0), done(2, 1, 1)), positions=(F(0), F(1)),
                  safe_reduce_lots=(0, 1), closed_ref="bad-closure", residual_refs=("residual",))
        with self.assertRaisesRegex(ValueError, "linear_residual"):
            cycle.apply(f)
        self.assertEqual(cycle.cursor, 1)
        spot_plan = plan(legs=(replace(plan().legs[0], kind="spot"), plan().legs[1]))
        cycle = c.Cycle(spot_plan)
        cycle.start(cursor=1, at_ns=T)
        dust = facts(orders=(done(1, 0, 1), done(2, 1, 0)), positions=(F(1, 2), F(0)),
                     safe_reduce_lots=(0, 0), closed_ref="core-custody-closure", residual_refs=("owned-residual",))
        self.assertEqual(cycle.apply(dust).reason, "closed_with_residual")
        self.assertEqual(cycle.phase, "completed")
        self.assertEqual(dust.positions, (F(1, 2), F(0)))

    def test_input_scope_boundaries_and_unsafe_reduce_are_rejected_before_progress(self):
        for invalid in (dict(safe_reduce_lots=(11, 0)), dict(orders=(done(99, 0, 0),)),
                        dict(orders=(done(1, 1, 10),)), dict(at_ns=T-1),
                        dict(economic_entry=entry(1))):
            with self.subTest(invalid=invalid):
                cycle = c.Cycle(plan())
                cycle.start(cursor=1, at_ns=T)
                with self.assertRaises(ValueError):
                    cycle.apply(facts(**invalid))
                self.assertEqual(cycle.cursor, 1)
        with self.assertRaises(ValueError):
            replace(plan(), repair_attempts=256)
        with self.assertRaises(ValueError):
            done(1, 0, 1, status="rejected")

    def test_original_cycle_ownership_and_duplicate_cursor_are_preserved(self):
        cycle = c.Cycle(plan())
        cycle.start(cursor=1, at_ns=T)
        f = facts(orders=(done(1, 0, 10), done(2, 1, 6)), positions=(F(10), F(6)), safe_reduce_lots=(10, 6))
        cycle.apply(f)
        self.assertEqual(cycle.apply(f).reason, "duplicate_cursor")
        with self.assertRaisesRegex(ValueError, "cursor_content_conflict"):
            cycle.apply(replace(f, economic_ref="conflicting-same-cursor"))
        with self.assertRaisesRegex(ValueError, "cycle_ownership"):
            cycle.apply(replace(f, cursor=3, cycle_ref="other-cycle"))
        with self.assertRaisesRegex(ValueError, "cycle_ownership"):
            cycle.apply(replace(f, cursor=3, reservation_ref="other-reservation"))
        self.assertEqual((cycle.next_sequence, cycle.repair_used), (4, 1))

    def test_omitted_older_order_evidence_cannot_disappear_after_followup(self):
        cycle = c.Cycle(plan())
        cycle.start(cursor=1, at_ns=T)
        f = facts(orders=(done(1, 0, 10), done(2, 1, 6)), positions=(F(10), F(6)), safe_reduce_lots=(10, 6))
        cycle.apply(f)
        incomplete = replace(f, cursor=3, orders=(done(3, 1, 4),), positions=(F(10), F(10)), safe_reduce_lots=(10, 10))
        self.assertEqual(cycle.apply(incomplete).queries, (1, 2))
        self.assertEqual(cycle.pending, (3,))

    def test_stale_market_cannot_establish_holding_or_trigger_profit(self):
        frozen = plan(policy=policy(original_base=F(10), max_book_age_ns=3))
        f = facts(orders=(done(1, 0, 5), done(2, 1, 5)), positions=(F(5), F(5)), safe_reduce_lots=(5, 5),
                  economic_entry=entry(5), market=market(0, 1100), at_ns=T)
        estimator = estimator_for((path("fresh", position=entry(5)),), frozen.policy, 80_000_000)
        cycle = c.Cycle(frozen)
        cycle.start(cursor=1, at_ns=T)
        stale = replace(f, at_ns=T+10)
        result = cycle.apply(stale, estimator=estimator, limits=LIMITS)
        self.assertTrue(result.escalate)
        self.assertEqual(cycle.first_exit, ("holding_qualification", 2))
        self.assertIsNone(cycle.target_atoms)
        cycle = c.Cycle(frozen)
        cycle.start(cursor=1, at_ns=T)
        cycle.apply(f, estimator=estimator, limits=LIMITS)
        result = cycle.apply(replace(f, cursor=3, at_ns=T+10, market=market(1, 1018)))
        self.assertEqual(result.reason, "stale_market")
        self.assertEqual(cycle.phase, "holding")
        self.assertFalse(result.intents)


if __name__ == "__main__":
    unittest.main()
