"""Offline public admission and S5 replay; core responses remain injected facts."""
from dataclasses import replace
from fractions import Fraction as F
import json
import unittest

from strategies.cross_venue import arbitrage_admission as a
from strategies.cross_venue import arbitrage_signals as s
from test_arbitrage_scanner import fixture, T
from test_arbitrage_evaluation import estimator_for
from strategies.cross_venue import arbitrage_economics as e
from strategies.cross_venue import arbitrage_evaluation as v
from opportunity_scanner import arbitrage_scanner as scanner


def signal_policy(**changes):
    values = dict(version=1, score_ref="directional-v1", reset=F(1), entry=F(2),
                  reset_points=2, entry_points=2, cooldown_ns=2, opportunity_ttl_ns=10,
                  interval_ns=3, max_evaluations=3)
    values.update(changes)
    return s.SignalPolicy(**values)


class SignalTests(unittest.TestCase):
    def test_s5_a_hysteresis_and_d_m_bounded_opportunity(self):
        state = s.Signal("pair-direction", signal_policy())
        for i, score in enumerate((F(8, 10), F(9, 10), F(15, 10), F(21, 10), F(22, 10))):
            state.observe(i, 96+i, score, qualified=True)
        self.assertEqual(state.deadline_ns, 110)
        identity = state.opportunity
        self.assertTrue(state.evaluate(100))
        self.assertFalse(state.evaluate(102))
        self.assertTrue(state.evaluate(103))
        self.assertTrue(state.evaluate(106))
        self.assertFalse(state.evaluate(109))
        self.assertEqual(state.opportunity, identity)
        self.assertFalse(state.evaluate(110))

    def test_s5_b_c_m_no_cached_crossing_and_gap_resets(self):
        obs, option, cfg, approval, facts = inputs()
        cfg = replace(cfg, signal=signal_policy(reset_points=1, entry_points=1, cooldown_ns=5))
        approval = replace(approval, config_hash=cfg.content_hash)
        facts = replace(facts, config_hash=cfg.content_hash)
        state = ready(option.plan, cfg)
        batch = a.Admission(cfg)
        request = batch.propose(obs, (option,), (approval,), (state,), facts).request
        batch.reply(request.identity, "reserved", cursor=8, fact_ref="reserved")
        state.close(request.identity, T, reconciled=True, released=True)
        for i, score in enumerate((0, 3, 0, 3, 3, 3), 1):
            state.observe(i+2, T+i, score, qualified=True)
        self.assertIsNone(state.opportunity)
        state.observe(9, T+7, 0, qualified=True)
        state.observe(11, T+9, 3, qualified=True)
        self.assertIsNone(state.opportunity)
        state.observe(12, T+10, 0, qualified=True)
        state.observe(13, T+11, 3, qualified=True)
        self.assertIsNotNone(state.opportunity)
        state.observe(14, T+12, F(3, 2), qualified=True)
        state.observe(15, T+13, 3, qualified=True)
        self.assertIsNone(state.opportunity)

    def test_s5_j_reason_specific_recovery_and_no_duplicate_grid(self):
        state = s.Signal("pair-direction", signal_policy())
        state.observe(1, 1, 0, qualified=True)
        state.observe(1, 1, 0, qualified=True)
        self.assertFalse(state.armed)
        state.lock("daily_loss", "risk-fact")
        state.lock("restart", "restart-fact")
        state.recover("restart", cause_ref="restart-fact", recovery_ref="review")
        self.assertEqual(state.reasons, {"daily_loss": "risk-fact"})
        with self.assertRaises(ValueError):
            state.recover("daily_loss", cause_ref="other-fact", recovery_ref="review")


class MonitorTests(unittest.TestCase):
    def monitor(self):
        return s.Monitor((s.Metric("error", 1, 2, 3, 5, 10),),
                         warn_windows=2, fail_windows=2, clear_windows=2)

    def update(self, monitor, sequence, value, samples=5):
        return monitor.update((s.Window("error", sequence, sequence, value, samples, True),),
                              at_ns=sequence, independent_evidence=True)

    def test_s5_h_i_dedup_and_insufficient_evidence_breaks_clear(self):
        monitor = self.monitor()
        self.assertEqual(self.update(monitor, 1, 2), "Normal")
        self.assertEqual(self.update(monitor, 1, 2), "Normal")
        self.assertEqual(self.update(monitor, 2, 2), "Warning")
        self.update(monitor, 3, 0)
        self.update(monitor, 4, 0, samples=0)
        self.assertFalse(monitor.qualified)
        self.assertEqual(self.update(monitor, 5, 0), "Warning")
        self.assertEqual(self.update(monitor, 6, 0), "Normal")

    def test_s5_k_l_failure_priority_and_no_return_to_holding(self):
        monitor = self.monitor()
        self.update(monitor, 1, 0)
        self.assertEqual(monitor.actions(phase="Holding"), ())
        self.update(monitor, 2, 3)
        self.update(monitor, 3, 3)
        self.assertEqual(monitor.actions(phase="Holding", normal_take_profit=True),
                         ("stop_new_cycles", "cancel_entry", "controlled_exit"))
        self.assertEqual(monitor.actions(phase="Holding", unknown=True), ("query_original_identity",))
        self.update(monitor, 4, 0)
        self.update(monitor, 5, 0)
        self.assertEqual(monitor.state, "InvalidLatched")
        monitor.recover(review_ref="review", reconciliation_ref="reconciled", authorization_ref="activate")
        self.assertEqual(monitor.actions(phase="Exiting", normal_take_profit=True), ())

    def test_window_cannot_be_rewritten_and_old_health_cannot_clear_failure(self):
        monitor = self.monitor()
        self.update(monitor, 1, 0)
        self.update(monitor, 2, 0)
        with self.assertRaisesRegex(ValueError, "monitor_window_rewrite"):
            self.update(monitor, 2, 3)
        monitor.invariant_failure()
        self.update(monitor, 2, 0)
        with self.assertRaises(ValueError):
            monitor.recover(review_ref="r", reconciliation_ref="c", authorization_ref="a")
        self.update(monitor, 3, 0)
        self.update(monitor, 5, 0)
        with self.assertRaises(ValueError):
            monitor.recover(review_ref="r", reconciliation_ref="c", authorization_ref="a")


def config(**changes):
    values = dict(version=1, schema=1, valid_from_ns=0, valid_until_ns=T+1000,
                  references=tuple((name, "a"*64) for name in a.REQUIRED_REFS),
                  signal=signal_policy(reset_points=1, entry_points=1, opportunity_ttl_ns=100),
                  max_quantity_candidates=10, max_batch_candidates=32, max_recalculations=4,
                  recommendation_ttl_ns=10, max_book_age_ns=1000, max_leg_skew_ns=10,
                  time_floor_ns=1, batch_window_ns=10)
    values.update(changes)
    return a.Config(**values)


def ready(plan, cfg):
    state = s.Signal(a.signal_scope(plan.pair, plan.policy.direction), cfg.signal)
    state.activate("web-activation", 0)
    state.observe(1, T-1, 0, qualified=True)
    state.observe(2, T, 3, qualified=True)
    return state


def inputs():
    observations, plan = fixture()
    cfg = config()
    option = a.Option(plan, (1, 1), ((1, 100_000_000), (2, 100_000_000)), 20, "b"*64)
    approval = a.Approval(plan.key, cfg.content_hash, 0, T+100, True, "web-activation",
        plan.policy.model_hash, plan.policy.version, plan.calibration.version,
        (1, 1), "b"*64, "c"*64)
    remaining = tuple((key, 1_000_000_000) for key, _ in option.requirements)
    facts = a.Facts(T, 7, 1, cfg.content_hash, remaining, (), True, "core-facts-7")
    return observations, option, cfg, approval, facts


def other_account(obs, option, approval, *, occupancy_ns, first_account=1, second_account=3):
    """Same market on another ExchangeAccount, sharing the first leg's resource."""
    plan = option.plan
    first = replace(obs[0], account=first_account)
    observed = replace(obs[1], account=second_account)
    pair = (first.identity, observed.identity)
    policy = replace(plan.policy, scope=scanner.candidate_id(pair, 1, "taker_taker", None))
    scenarios = tuple(replace(x, entry=replace(x.entry,
        legs=(replace(x.entry.legs[0], account=first_account),
              replace(x.entry.legs[1], account=second_account)))) for x in plan.scenarios)
    estimator = estimator_for(scenarios, policy)
    calibration = replace(plan.calibration, scope=v.probability_scope(policy, 8_000_000, F(1), T),
                          simulation_hash=estimator.probability_model_hash(policy))
    plan = replace(plan, pair=pair, policy=policy, scenarios=scenarios, estimator=estimator, calibration=calibration)
    return (first, observed), replace(option, plan=plan,
                             account_atoms=((first_account, 100_000_000), (second_account, 100_000_000)),
                             occupancy_ns=occupancy_ns), replace(approval, key=plan.key)


class AdmissionTests(unittest.TestCase):
    def test_explicit_approval_fresh_evaluation_and_unknown_original_identity(self):
        obs, option, cfg, approval, facts = inputs()
        state = ready(option.plan, cfg)
        batch = a.Admission(cfg)
        self.assertIsNone(batch.propose(obs, (option,), (), (state,), facts).request)
        self.assertIsNone(state.opportunity)
        # Approval cannot resurrect the old scanner opportunity.
        state = ready(option.plan, cfg)
        result = batch.propose(obs, (option,), (approval,), (state,), facts)
        self.assertIsNotNone(result.request)
        self.assertEqual(result.request.plan_atoms, 8_000_000)
        batch.reply(result.request.identity, "unknown", cursor=8, fact_ref="timeout")
        retry = batch.propose(obs, (option,), (approval,), (state,), replace(facts, cursor=8))
        self.assertEqual(retry.query_identity, result.request.identity)
        self.assertIsNone(retry.request)

    def test_s5_e_f_g_rejection_refresh_success_consumes_then_close_cooldown(self):
        obs, option, cfg, approval, facts = inputs()
        state = ready(option.plan, cfg)
        batch = a.Admission(cfg)
        request = batch.propose(obs, (option,), (approval,), (state,), facts).request
        with self.assertRaises(ValueError):
            batch.reply(request.identity, "rejected", cursor=8, fact_ref="unclear")
        batch.reply(request.identity, "rejected", cursor=8, fact_ref="no-reservation", clean=True)
        with self.assertRaisesRegex(ValueError, "refresh_core_facts"):
            batch.propose(obs, (option,), (approval,), (state,), facts)
        # Same signal, a new full evaluation at a fresh cutoff (no old scenario reuse).
        result = batch.propose(obs, (option,), (approval,), (state,), replace(facts, at_ns=T+3, cursor=9))
        self.assertIsNone(result.request)
        self.assertIn("evaluation_cutoff", [reason for _, reason in result.rejections])
        state = ready(option.plan, cfg)
        batch = a.Admission(cfg)
        request = batch.propose(obs, (option,), (approval,), (state,), facts).request
        batch.reply(request.identity, "reserved", cursor=8, fact_ref="reserved")
        self.assertIsNone(state.opportunity)
        self.assertEqual(state.active, request.identity)
        # Disabling approval does not erase this active cycle.
        batch.propose(obs, (option,), (replace(approval, enabled=False),), (state,), replace(facts, cursor=9))
        self.assertEqual(state.active, request.identity)
        with self.assertRaises(ValueError):
            state.close(request.identity, T+3, reconciled=True, released=False)
        state.close(request.identity, T+3, reconciled=True, released=True)
        state.close(request.identity, T+50, reconciled=True, released=True)
        self.assertEqual(state.cooldown_until_ns, T+5)
        self.assertFalse(state.evaluate(T+5))

    def test_missing_expired_or_mismatched_evidence_never_proposes(self):
        obs, option, cfg, approval, facts = inputs()
        variants = (replace(approval, valid_until_ns=T), replace(approval, enabled=False),
                    replace(approval, model_hash="d"*64), replace(approval, policy_version=2),
                    replace(approval, calibration_version=2), replace(approval, rules_versions=(2, 1)),
                    replace(approval, execution_hash="d"*64))
        for grant in variants:
            with self.subTest(grant=grant):
                result = a.Admission(cfg).propose(obs, (option,), (grant,), (ready(option.plan, cfg),), facts)
                self.assertIsNone(result.request)
        for bad_facts in (replace(facts, config_hash="d"*64), replace(facts, at_ns=cfg.valid_until_ns),
                          replace(facts, opening_allowed=False), replace(facts, quote_asset=9)):
            self.assertIsNone(a.Admission(cfg).propose(obs, (option,), (approval,),
                (ready(option.plan, cfg),), bad_facts).request)
        self.assertIsNone(a.Admission(cfg).propose(obs, (option,), (approval,),
            (s.Signal(a.signal_scope(option.plan.pair, 1), cfg.signal),), facts).request)

    def test_per_account_caps_shared_instrument_and_configuration_limits(self):
        obs, option, cfg, approval, facts = inputs()
        for key, required in option.requirements:
            remaining = tuple((k, required-1 if k == key else n) for k, n in facts.remaining)
            result = a.Admission(cfg).propose(obs, (option,), (approval,),
                (ready(option.plan, cfg),), replace(facts, remaining=remaining))
            self.assertIsNone(result.request, key)
        self.assertIsNone(a.Admission(cfg).propose(obs, (option,), (approval,),
            (ready(option.plan, cfg),), replace(facts, occupied=((1, 1),))).request)
        with self.assertRaisesRegex(ValueError, "duplicate_quantity"):
            a.Admission(cfg).propose(obs, (option, option), (approval,), (ready(option.plan, cfg),), facts)
        with self.assertRaises(ValueError):
            config(max_batch_candidates=257)
        with self.assertRaises(ValueError):
            replace(option, lots=(0, 1))
        with self.assertRaises(ValueError):
            replace(option, account_atoms=((1, 1), (2, 1)))
        with self.assertRaises(ValueError):
            replace(option, plan=replace(option.plan, policy=replace(option.plan.policy, original_base=F(100))))

    def test_grid_selection_matches_independent_nonmonotone_exhaustion(self):
        obs, _, cfg, approval, facts = inputs()
        options, profits = [], []
        for lots, cost in ((1, 0), (2, 0), (3, 15_000_000)):
            _, plan = fixture(lots=lots)
            policy = replace(plan.policy, plan_buffers=(e.Cost("tail", cost, "model_buffer"),)) if cost else plan.policy
            estimator = estimator_for(plan.scenarios, policy, original_target=8_000_000*lots)
            calibration = replace(plan.calibration,
                scope=v.probability_scope(policy, 8_000_000*lots, F(lots), T),
                simulation_hash=estimator.probability_model_hash(policy))
            plan = replace(plan, policy=policy, estimator=estimator, calibration=calibration,
                           occupied_atoms=200_000_000*lots)
            options.append(a.Option(plan, (lots, lots), ((1, 100_000_000*lots), (2, 100_000_000*lots)), 20, "b"*64))
            result = v.evaluate(plan.scenarios, policy, estimator, calibration, plan.simulation_error, plan.limits)
            self.assertTrue(result.allowed, result.reason)
            profits.append(result.plan_atoms)
        self.assertEqual(e.quantity_grid(3, 1, (F(2, 3),), (), 3), (1, 2, 3))
        self.assertEqual(profits, [8_000_000, 16_000_000, 9_000_000])
        for ordering in (tuple(options), tuple(reversed(options))):
            result = a.Admission(cfg).propose(tuple(reversed(obs)), ordering, (approval,),
                (ready(options[0].plan, cfg),), facts)
            self.assertEqual(result.request.lots, (2, 2))
        # After capacity shrinks, re-evaluate all legal sizes; do not keep the old optimum.
        remaining = tuple((k, 200_000_000 if k == "total" else n) for k, n in facts.remaining)
        result = a.Admission(cfg).propose(obs, tuple(options), (approval,), (ready(options[0].plan, cfg),),
            replace(facts, remaining=remaining))
        self.assertEqual(result.request.lots, (1, 1))

    def test_score_exact_tie_break_and_recompute_after_core_reservation(self):
        obs, option, cfg, approval, facts = inputs()
        extra, second, grant = other_account(obs, option, approval, occupancy_ns=10)
        all_obs = obs+(extra[1],)
        remaining = dict(facts.remaining)
        remaining.update(second.requirements)
        remaining = tuple((k, 1_000_000_000) for k in remaining)
        facts = replace(facts, remaining=remaining)
        for options in ((option, second), (second, option)):
            states = (ready(option.plan, cfg), ready(second.plan, cfg))
            batch = a.Admission(cfg)
            request = batch.propose(all_obs, options, (approval, grant), states, facts).request
            self.assertEqual(request.key, second.plan.key)
            self.assertEqual(request.score, F(1, 250))
            batch.reply(request.identity, "reserved", cursor=8, fact_ref="reserved-8")
            # New batch, unchanged market cutoff but refreshed core capacities/occupancy.
            current = replace(facts, cursor=9, occupied=((1, 1), (3, 2)),
                remaining=tuple((k, max(0, n-dict(second.requirements).get(k, 0))) for k, n in remaining))
            result = a.Admission(cfg).propose(all_obs, (option,), (approval,), (states[0],), current)
            self.assertIsNone(result.request)
        tied = replace(second, occupancy_ns=20)
        keys = []
        for options in ((option, tied), (tied, option)):
            result = a.Admission(cfg).propose(all_obs, options, (approval, grant),
                (ready(option.plan, cfg), ready(tied.plan, cfg)), facts)
            keys.append(result.request.key)
        self.assertEqual(keys[0], keys[1])

    def test_disjoint_second_reservation_in_same_batch_recomputes_without_interval_delay(self):
        obs, option, cfg, approval, facts = inputs()
        extra, second, grant = other_account(obs, option, approval, occupancy_ns=10,
                                             first_account=3, second_account=4)
        remaining = dict(facts.remaining)
        remaining.update(second.requirements)
        remaining = tuple((k, 1_000_000_000) for k in remaining)
        facts = replace(facts, remaining=remaining)
        states = (ready(option.plan, cfg), ready(second.plan, cfg))
        batch = a.Admission(cfg)
        request = batch.propose(obs+extra, (option, second), (approval, grant), states, facts).request
        self.assertEqual(request.key, second.plan.key)
        batch.reply(request.identity, "reserved", cursor=8, fact_ref="reserved-8")
        current = replace(facts, cursor=9, occupied=((3, 1), (4, 2)),
            remaining=tuple((k, n-dict(second.requirements).get(k, 0)) for k, n in remaining))
        result = batch.propose(obs+extra, (option, second), (approval, grant), states, current)
        self.assertIsNotNone(result.request)
        self.assertEqual(result.request.key, option.plan.key)
        self.assertEqual(states[0].evaluations_used, 2)

    def test_internal_recompute_exception_needs_a_successful_reservation(self):
        obs, option, cfg, approval, facts = inputs()
        state = ready(option.plan, cfg)
        batch = a.Admission(cfg)
        empty = replace(facts, remaining=tuple((k, 0) for k, _ in facts.remaining))
        self.assertIsNone(batch.propose(obs, (option,), (approval,), (state,), empty).request)
        self.assertIsNone(batch.propose(obs, (option,), (approval,), (state,), facts).request)
        self.assertEqual(state.evaluations_used, 1)
        expired = replace(facts, at_ns=T+cfg.batch_window_ns, cursor=8)
        self.assertEqual(batch.propose(obs, (option,), (approval,), (state,), expired).rejections,
                         (("batch", "batch_expired"),))

    def test_capacity_fail_closed_and_stale_safety_management_stays_available(self):
        obs, option, cfg, approval, facts = inputs()
        state = ready(option.plan, cfg)
        batch = a.Admission(cfg)
        for _ in range(cfg.max_recalculations):
            batch.propose(obs, (), (), (), facts)
        self.assertEqual(batch.propose(obs, (option,), (approval,), (state,), facts).rejections,
                         (("batch", "recalculation_capacity"),))
        with self.assertRaisesRegex(ValueError, "batch_capacity"):
            a.Admission(cfg).propose(obs, (option,)*33, (approval,), (state,), facts)
        with self.assertRaises(ValueError):
            e.quantity_grid(3, 1, (F(2, 3),), (), 2)
        monitor = s.Monitor((s.Metric("error", 1, 2, 3, 1, 10),),
                            warn_windows=1, fail_windows=1, clear_windows=1)
        monitor.invariant_failure()
        self.assertEqual(monitor.actions(phase="Holding"),
                         ("stop_new_cycles", "cancel_entry", "controlled_exit"))

    def test_s5_e_funds_release_within_original_window_and_activation_history(self):
        obs, option, cfg, approval, facts = inputs()
        state = s.Signal(a.signal_scope(option.plan.pair, 1), cfg.signal)
        state.activate("web-activation", 0)
        state.observe(1, T-4, 0, qualified=True)
        state.observe(2, T-3, 3, qualified=True)
        deadline = state.deadline_ns
        batch = a.Admission(cfg)
        empty = replace(facts, at_ns=T-3, remaining=tuple((k, 0) for k, _ in facts.remaining))
        self.assertIsNone(batch.propose(obs, (option,), (approval,), (state,), empty).request)
        result = batch.propose(obs, (option,), (approval,), (state,), replace(facts, cursor=8))
        self.assertIsNotNone(result.request)
        self.assertEqual(state.deadline_ns, deadline)
        self.assertEqual(state.evaluations_used, 2)
        state = ready(option.plan, cfg)
        state.activate("new-web-activation", T)
        result = a.Admission(cfg).propose(obs, (option,),
            (replace(approval, activation_ref="new-web-activation"),), (state,), facts)
        self.assertIsNone(result.request)
        self.assertIsNone(state.opportunity)


class ConfigTests(unittest.TestCase):
    def payload(self):
        cfg = config()
        from dataclasses import asdict
        values = asdict(cfg)
        values["signal"]["reset"] = [1, 1]
        values["signal"]["entry"] = [2, 1]
        return values

    def test_strict_shape_references_units_hash_and_signal_ranges(self):
        values = self.payload()
        self.assertEqual(a.load_config(json.dumps(values)).content_hash, config().content_hash)
        self.assertNotEqual(config().content_hash, config(time_floor_ns=2).content_hash)
        for change in ({"schema": 2}, {"unexpected": 1}, {"time_floor_ns": 0},
                       {"max_book_age_ns": 1.5}, {"references": []}, {"valid_until_ns": 0}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                a.load_config(json.dumps(dict(values, **change)))
        with self.assertRaisesRegex(ValueError, "duplicate_config_key"):
            a.load_config('{"schema":1,"schema":1}')
        for change in ({"entry": F(1)}, {"max_evaluations": 0}, {"interval_ns": -1}):
            with self.assertRaises(ValueError):
                signal_policy(**change)


if __name__ == "__main__":
    unittest.main()
