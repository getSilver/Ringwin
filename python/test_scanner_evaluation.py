"""Published research inputs reach the production plan builder and shared evaluator."""
from dataclasses import replace
from fractions import Fraction as F
import tempfile
from pathlib import Path
import math
import unittest

from opportunity_scanner import arbitrage_scanner as s
from opportunity_scanner.scanner_evaluation import EvaluationInputs, publish_inputs, SCHEMA
from strategies.cross_venue import arbitrage_evaluation as v
from strategies.cross_venue import arbitrage_economics as e
from strategies.cross_venue import arbitrage_probability as p
from test_arbitrage_scanner import fixture
from test_arbitrage_evaluation import estimator_for, EXACT, LIMITS
from test_arbitrage_probability import calibration
from strategies.cross_venue import arbitrage_baseline as b

NOW = 1_000_000_000
END = 10_000_000_000


def inputs(mode="taker_taker", maker=None):
    observations, plan = fixture(mode=mode,maker=maker)
    scenario = plan.scenarios[0]
    legs = tuple(replace(leg, rules=replace(leg.rules, valid_until_ns=END),
        exit_fee=replace(leg.exit_fee, valid_until_ns=END), entries=tuple(replace(t,
            ticks=(1000 if maker == 0 else 1001) if i == 0 else (1100 if maker == 1 else 1099))
            for t in leg.entries)) for i, leg in enumerate(scenario.entry.legs))
    scenario = replace(scenario, entry=replace(scenario.entry, legs=legs))
    observations = tuple(replace(o, rules=legs[i].rules,
        book=v._scaled_book(o.book, F(1), NOW-plan.policy.at_ns, dict(bids=F(1), asks=F(1))))
        for i,o in enumerate(observations))
    policy = plan.policy
    target = 7_840_000 if maker is None else 7_920_000
    estimator = estimator_for((scenario,), policy, original_target=target)
    estimator = replace(estimator, rows=tuple(replace(row,
        calibration=replace(row.calibration, mode=mode, valid_until_ns=END)) for row in estimator.rows))
    artifact = calibration(scope=v.probability_scope(policy, target, F(1), policy.at_ns),
        margin=F(7,100), model_hash=policy.model_hash, simulation_hash=estimator.probability_model_hash(policy))
    artifact = replace(artifact, mode=mode, valid_until_ns=END)
    case = dict(key=plan.key, policy=policy, estimator=estimator, calibration=artifact,
        simulation_error=EXACT, limits=LIMITS, scenarios=(scenario,),
        bounds=v.RebaseBounds(F(9,10), F(11,10), .01, F(1,2), F(2), F(2)),
        target_lots=(1,1), entry_fees=tuple(x.exit_fee for x in legs),
        entry_limits=(1000 if maker == 0 else 2000,1100 if maker == 1 else 1),
        fee_valuations=(F(1),F(1)), fee_balances=(0,0), funds_available=(1_000_000_000,1_000_000_000),
        capital_factors=(F(1),F(1)), capital_buffers=(0,0),
        entry_minimum_notionals=(0,0),
        funds_valid_until_ns=END, risk_valid_until_ns=END, risk_allowed=True,
        versions=dict(fees="fees-v1", funds="funds-v1", risk="risk-v1", entry_model="joint-entry-v1",venue_rules="rules-v1"))
    document = dict(schema=SCHEMA, version=1, clock_id="test-clock", source_kind="synthetic",
        valid_from_ns=0, valid_until_ns=END, cases=(case,))
    return observations, document


def native_inputs(observations, at, clock_id):
    """Synthetic research evidence bound to actual native-decoded rules and books."""
    legs = []
    books = tuple(s.decode_depth_snapshot(o.book) for o in observations)
    quantity = 10*observations[0].rules.base_atoms_per_lot
    lots = tuple(int(quantity/o.rules.base_atoms_per_lot) for o in observations)
    for i, o in enumerate(observations):
        fee = e.FeeRule(o.rules.instrument, o.rules.version, o.rules.quote_asset, 0, 0, 0, END)
        ticks = books[i]["asks" if i == 0 else "bids"][0][0]
        legs.append(v.Leg(o.account, o.rules, o.kind, 1 if i == 0 else -1,
            (v.Trade("native-entry:"+str(i), ticks, lots[i], e.Fee(o.rules.quote_asset, 0, F(0), 0), at),), fee))
    point = b.Point(at//b.SECOND*b.SECOND, 1,
        math.log(float(v._mid(books[1], legs[1].rules)/v._mid(books[0], legs[0].rules))))
    entry = v.Entry("matched", tuple(legs), (), at, True, (), (), point)
    frames = []
    for delay in (0,1,100,105):
        payloads = []
        for i, o in enumerate(observations):
            book = dict(books[i], visible_at_ns=at+delay)
            if i == 1 and delay:
                price = F(3000)/o.rules.tick_quote_atoms_per_base_atom
                book.update(bids=((int(price),100000),), asks=((int(price)+1,100000),))
            payloads.append(v.encode_depth_snapshot(book))
        frames.append(v.Market(at+delay, tuple(payloads), (F(1),F(1)), (0,0), (), True, False, False, False))
    scenario = v.Scenario("native-joint", F(1), entry, tuple(frames), (0,0),
                          ("filled","filled"), ("native-exit:0","native-exit:1"))
    pair = tuple(o.identity for o in observations)
    from test_arbitrage_evaluation import policy
    plan_policy = policy(scope=s.candidate_id(pair,1,"taker_taker",None), at_ns=at,
        prediction_end_ns=at+100, risk_deadline_ns=at+100, reference_exit_ns=at+100,
        base_asset=legs[0].rules.exposure_asset, quote_asset=legs[0].rules.quote_asset,
        original_base=quantity, reference_notional_atoms=int(legs[0].entry_notional),
        min_profit_atoms=1, absolute_minimum_atoms=1, max_book_age_ns=b.SECOND,
        normal_limits=(1,10**15), risk_limits=(1,10**15))
    closing = v.value_exit(entry,frames[2],plan_policy,normal=True)
    assert closing.net_atoms is not None, closing
    target = e.entry_target(closing.net_atoms,
                            plan_policy.alpha, plan_policy.absolute_minimum_atoms)
    historical_entry = replace(entry, holding_at_ns=0, model_point=replace(point,grid_ns=0),
        legs=tuple(replace(leg,entries=tuple(replace(t,at_ns=0) for t in leg.entries)) for leg in legs))
    historical = replace(scenario,entry=historical_entry,markets=tuple(replace(m,at_ns=m.at_ns-at,
        books=tuple(v._scaled_book(payload,F(1),-at,dict(bids=F(1),asks=F(1))) for payload in m.books)) for m in frames))
    scope = v.probability_scope(plan_policy,target,quantity,at)
    bounds = v.RebaseBounds(F(9,10),F(11,10),.01,F(1,100),F(100),F(2))
    artifact = replace(calibration(stage="hold",scope=scope,margin=F(7,100),model_hash=plan_policy.model_hash),valid_until_ns=END)
    estimator = v.Estimator(b.AR1(1,200,0.,.8,.01,1e-12,1e-15,0.),200,
                            (v.ConditionalRow(scope,(historical,),artifact,EXACT,bounds),))
    simulation_hash = estimator.probability_model_hash(plan_policy)
    estimator = replace(estimator,rows=tuple(replace(row,calibration=replace(row.calibration,
        simulation_hash=simulation_hash)) for row in estimator.rows))
    entry_calibration = replace(calibration(scope=scope,margin=F(7,100),model_hash=plan_policy.model_hash,
        simulation_hash=simulation_hash),valid_until_ns=END)
    case = dict(key=(pair,1,"taker_taker",None),policy=plan_policy,estimator=estimator,
        calibration=entry_calibration,simulation_error=EXACT,limits=LIMITS,bounds=bounds,scenarios=(scenario,),
        target_lots=lots,entry_fees=tuple(leg.exit_fee for leg in legs),entry_limits=(10**15,1),
        fee_valuations=(F(1),F(1)),fee_balances=(0,0),funds_available=(10**20,10**20),
        capital_factors=(F(1),F(1)),capital_buffers=(0,0),funds_valid_until_ns=END,
        entry_minimum_notionals=(10**19,10**19),
        risk_valid_until_ns=END,risk_allowed=True,
        versions=dict(fees="native-fees-v1",funds="native-funds-v1",risk="native-risk-v1",entry_model="native-joint-v1",venue_rules="native-rules-v1"))
    return dict(schema=SCHEMA,version=1,clock_id=clock_id,source_kind="synthetic",valid_from_ns=0,
                valid_until_ns=END,cases=(case,))


class EvaluationInputTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)/"scanner-evaluation.json"
        self.source = EvaluationInputs(self.path, "test-clock", synthetic=True)

    def build(self, observations, at=NOW):
        return self.source.build(observations, at_ns=at, max_age_ns=1000, max_skew_ns=10, bindings={})

    def test_published_complete_inputs_generate_real_plan_and_direct_result_matches(self):
        observations, doc = inputs()
        publish_inputs(self.path, doc)
        plans, failures, versions = self.build(observations)
        self.assertEqual(len(plans), 1, self.source.state)
        self.assertNotIn(s.candidate_id(*plans[0].key), failures)
        plan = plans[0]
        expected = v.evaluate(plan.scenarios, plan.policy, plan.estimator, plan.calibration,
                              plan.simulation_error, plan.limits)
        result = s.scan(observations, plans, at_ns=NOW, cursor=1, max_age_ns=1000,
                        max_skew_ns=10, plan_failures=failures)
        row = next(r for r in result["candidates"] if r["id"] == s.candidate_id(*plan.key))
        self.assertTrue(expected.allowed, expected.reason)
        self.assertEqual(row["status"], "evaluated", row)
        self.assertEqual(row["plan_atoms"], str(expected.plan_atoms))
        self.assertEqual(row["scenario_digest"], expected.scenario_digest)
        self.assertTrue(versions[row["id"]][str(plan.policy.original_base)]["package_digest"])

    def test_missing_file_model_and_expired_fees_report_actual_admission_reason(self):
        observations, doc = inputs()
        self.assertEqual(set(self.build(observations)[1].values()), {"evaluation_inputs_missing"})
        del doc["cases"][0]["estimator"]
        publish_inputs(self.path, doc)
        self.assertIn("estimator_missing", self.build(observations)[1].values())
        observations, doc = inputs()
        doc["version"] = 2
        case = doc["cases"][0]
        case["entry_fees"] = tuple(replace(f, valid_until_ns=NOW) for f in case["entry_fees"])
        publish_inputs(self.path, doc)
        self.assertIn("fees_expired", self.build(observations)[1].values())

    def test_restart_clock_and_same_version_replacement_never_reuse_old_plans(self):
        observations, doc = inputs()
        publish_inputs(self.path, doc)
        self.assertTrue(self.build(observations)[0])
        doc["cases"][0]["risk_allowed"] = False
        publish_inputs(self.path, doc)
        self.assertFalse(self.build(observations)[0])
        self.assertEqual(set(self.build(observations)[1].values()), {"evaluation_inputs_version_conflict"})
        fresh = EvaluationInputs(self.path, "other-clock", synthetic=True)
        self.assertEqual(set(fresh.build(observations, at_ns=NOW, max_age_ns=1000,
            max_skew_ns=10, bindings={})[1].values()), {"evaluation_clock_mismatch"})

    def test_no_backdating_current_book_to_an_earlier_model_grid(self):
        observations, doc = inputs()
        observations = tuple(replace(o, book=v._scaled_book(o.book, F(1), 1, dict(bids=F(1), asks=F(1))))
                             for o in observations)
        publish_inputs(self.path, doc)
        self.assertIn("model_warming", self.build(observations, at=NOW+1)[1].values())

    def test_model_training_cannot_use_evidence_after_the_admitted_grid(self):
        observations,doc = inputs()
        case = doc["cases"][0]
        estimator = replace(case["estimator"],training_end_ns=NOW+1,
                            forecast=replace(case["estimator"].forecast,trained_until_ns=NOW+1))
        case["estimator"] = estimator
        case["policy"] = replace(case["policy"],model_hash=estimator.model_hash)
        publish_inputs(self.path,doc)
        self.assertIn("model_warming:training_grid",self.build(observations,at=NOW+1)[1].values())

    def test_all_three_modes_use_existing_evaluator(self):
        for version,(mode,maker) in enumerate((("taker_taker",None),("maker_taker",0),("maker_taker",1)),1):
            with self.subTest(mode=mode,maker=maker):
                observations,doc = inputs(mode,maker)
                doc["version"] = version
                publish_inputs(self.path,doc)
                plans,_,_ = self.build(observations)
                self.assertEqual(len(plans),1,self.source.state)
                plan, = plans
                result = v.evaluate(plan.scenarios,plan.policy,plan.estimator,plan.calibration,
                                    plan.simulation_error,plan.limits)
                self.assertTrue(result.allowed,result.reason)

    def test_positive_spread_after_complete_costs_is_rejected(self):
        observations,doc = inputs()
        case = doc["cases"][0]
        case["entry_fees"] = tuple(replace(f,taker_ppm=100000) for f in case["entry_fees"])
        publish_inputs(self.path,doc)
        plans,failures,_ = self.build(observations)
        self.assertEqual(len(plans),1,self.source.state)
        result = s.scan(observations,plans,at_ns=NOW,cursor=1,max_age_ns=1000,max_skew_ns=10,
                        plan_failures=failures)
        row = next(r for r in result["candidates"] if r["mode"] == "taker_taker" and r["direction"] == 1)
        self.assertGreater(int(row["observed_edge_bp"][0]),0)
        self.assertEqual((row["status"],row["reason"]),("rejected","reference_profit"))
        self.assertFalse(row["recommended"])

    def test_depth_funds_risk_and_rules_invalidate_plans(self):
        for version,reason in enumerate(("insufficient_depth","insufficient_funds","risk_blocked","rules_changed","minimum_notional"),1):
            observations,doc = inputs()
            doc["version"] = version
            case = doc["cases"][0]
            if reason == "insufficient_depth":
                case["target_lots"] = (101,101)
            elif reason == "insufficient_funds":
                case["funds_available"] = (1,1)
            elif reason == "risk_blocked":
                case["risk_allowed"] = False
            elif reason == "minimum_notional":
                case["entry_minimum_notionals"] = (10**12,10**12)
            else:
                observations = tuple(replace(o,rules=replace(o.rules,version=2),book=
                    v.encode_depth_snapshot(dict(s.decode_depth_snapshot(o.book),rules_version=2))) for o in observations)
                case["entry_fees"] = tuple(replace(f,rules_version=2) for f in case["entry_fees"])
            publish_inputs(self.path,doc)
            plans,failures,_ = self.build(observations)
            self.assertFalse(plans,(reason,self.source.state))
            if reason in ("insufficient_depth", "insufficient_funds"):
                candidate = s.candidate_id(*case["key"])
                self.assertEqual(failures[candidate], {"leg": 0, "reason": reason})
                snapshot = s.scan(observations, (), at_ns=NOW, cursor=1, max_age_ns=10**10,
                    max_skew_ns=10**10, plan_failures=failures)
                row = next(r for r in snapshot["candidates"] if r["id"] == candidate)
                self.assertIn(reason, row["legs"][0]["issues"])
                self.assertNotIn(reason, row["legs"][1]["issues"])
            else:
                self.assertIn(reason, failures.values())

    def test_public_transport_rejects_synthetic_research_artifacts(self):
        observations,doc = inputs()
        publish_inputs(self.path,doc)
        source = EvaluationInputs(self.path,"test-clock")
        plans,failures,_ = source.build(observations,at_ns=NOW,max_age_ns=1000,max_skew_ns=10,bindings={})
        self.assertFalse(plans)
        self.assertEqual(set(failures.values()),{"evaluation_source_kind"})

    def test_evaluator_work_budget_failure_is_visible_without_stopping_scanner(self):
        observations,doc = inputs()
        doc["cases"][0]["limits"] = v.Limits(1,1,1)
        publish_inputs(self.path,doc)
        plans,failures,_ = self.build(observations)
        result = s.scan(observations,plans,at_ns=NOW,cursor=1,max_age_ns=1000,max_skew_ns=10,
                        plan_failures=failures)
        row = next(r for r in result["candidates"] if r["mode"] == "taker_taker" and r["direction"] == 1)
        self.assertEqual(row["reason"],"evaluation_capacity")
        self.assertEqual(row["status"],"pending")
        self.assertFalse(row["recommended"])

    def test_joint_failure_and_unknown_weights_are_preserved(self):
        observations,doc = inputs()
        case = doc["cases"][0]
        source, = case["scenarios"]
        failed = v.Entry("flat",(),(v.Settled("cleanup",-1000000),),source.entry.holding_at_ns,True,(),())
        unknown = v.Entry("unknown",(),(),source.entry.holding_at_ns,False,("order-unknown",),
                          ((F(0),F(1)),(F(0),F(1))))
        case["scenarios"] = (replace(source,weight=F(1,2)),
            replace(source,identity="failed-entry",weight=F(1,4),entry=failed),
            replace(source,identity="unknown-entry",weight=F(1,4),entry=unknown))
        publish_inputs(self.path,doc)
        plans,_,_ = self.build(observations)
        self.assertEqual(len(plans),1,self.source.state)
        self.assertEqual([x.weight for x in plans[0].scenarios],[F(1,2),F(1,4),F(1,4)])
        self.assertEqual(plans[0].scenarios[1].entry.r_done_atoms,-1000000)
        self.assertEqual(plans[0].scenarios[2].entry.unknown_refs,("order-unknown",))
        plan, = plans
        result = v.evaluate(plan.scenarios,plan.policy,plan.estimator,plan.calibration,plan.simulation_error,plan.limits)
        self.assertFalse(result.allowed)
        self.assertEqual(result.reason,"unresolved_reference")


if __name__ == "__main__":
    unittest.main()
