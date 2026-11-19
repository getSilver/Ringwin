from fractions import Fraction
import tempfile
import unittest
from pathlib import Path
from opportunity_scanner.fee_schedules import FeeSchedules, percent_ppm
from test_scanner_evaluation import inputs, NOW
from opportunity_scanner.scanner_evaluation import EvaluationInputs, publish_inputs

class ManualFeeTests(unittest.TestCase):
    def test_exact_persistent_versions_and_replay(self):
        self.assertEqual(percent_ppm("0.012345"), Fraction(2469, 20))
        observations, _ = inputs()
        with tempfile.TemporaryDirectory() as d:
            path = Path(d)/"fees.json"
            store = FeeSchedules(path)
            rows = [dict(venue=str(o.venue), account=str(o.account), product=o.kind,
                         fee_asset=str(o.rules.quote_asset), maker_percent="-0.01", taker_percent="0.01") for o in observations]
            store.save(dict(expected_version="0", rows=rows))
            before = store.rule(observations[0])
            self.assertEqual(before.maker_ppm, 0)
            self.assertEqual(FeeSchedules(path).rule(observations[0]), before)
            equivalent = [dict(row, taker_percent="0.010") for row in reversed(rows)]
            self.assertEqual(store.save(dict(expected_version="1", rows=equivalent))["version"], "1")
            rows[0]["taker_percent"] = "1"
            store.save(dict(expected_version="1", rows=rows))
            with self.assertRaisesRegex(ValueError, "fees_version_changed"):
                store.require_current("1")
            self.assertEqual(store.rule(observations[0], version="1"), before)
            self.assertEqual(store.rule(observations[0]).taker_ppm, 10000)

    def test_opening_admission_rejects_old_fee_version(self):
        from test_arbitrage_admission import inputs, ready
        from strategies.cross_venue import arbitrage_admission as admission
        from dataclasses import replace
        obs, option, config, approval, facts = inputs()
        with tempfile.TemporaryDirectory() as d:
            fees = FeeSchedules(Path(d)/"fees.json")
            rows = [dict(venue=str(o.venue), account=str(o.account), product=o.kind,
                         fee_asset=str(o.rules.quote_asset), maker_percent="0", taker_percent="0") for o in obs]
            fees.save(dict(expected_version="0", rows=rows))
            option = replace(option, plan=replace(option.plan, fee_version="1"))
            request = admission.Admission(config, fees=fees).propose(obs, (option,),
                (approval,), (ready(option.plan, config),), facts).request
            self.assertIsNotNone(request)
            from test_arbitrage_cycle import plan as cycle_plan
            from strategies.cross_venue import arbitrage_cycle as cycle
            legs = tuple(cycle.LegSpec(x.account, x.rules, x.kind, x.direction, lots)
                         for x, lots in zip(option.plan.scenarios[0].entry.legs, option.lots))
            bound = cycle_plan(request_ref=request.identity, config_hash=config.content_hash,
                policy=option.plan.policy, legs=legs, target_atoms=request.target_atoms)
            opening = cycle.Cycle.from_admission(bound, request, option, fees=fees)
            from test_arbitrage_checkpoint import roundtrip
            opening = roundtrip({"opening": opening}, facts.cursor)["opening"]
            rows[0]["maker_percent"] = "0.1"
            fees.save(dict(expected_version="1", rows=rows))
            decision = admission.Admission(config, fees=fees).propose(obs, (option,),
                (approval,), (ready(option.plan, config),), facts)
            self.assertIsNone(decision.request)
            self.assertTrue(any(reason == "fees_version_changed" for _, reason in decision.rejections))
            with self.assertRaisesRegex(ValueError, "fees_version_changed"):
                cycle.Cycle.from_admission(bound, request, option, fees=fees)
            with self.assertRaisesRegex(ValueError, "fees_version_missing"):
                cycle.Cycle.from_admission(bound, request, option)
            with self.assertRaisesRegex(ValueError, "fees_version_changed"):
                opening.start(cursor=facts.cursor, at_ns=facts.at_ns, fees=fees)
            self.assertEqual(opening.phase, "idle")

    def test_scanner_uses_saved_fees_and_reports_missing_leg(self):
        observations, doc = inputs()
        with tempfile.TemporaryDirectory() as d:
            store = FeeSchedules(Path(d)/"fees.json")
            path = Path(d)/"inputs.json"
            publish_inputs(path, doc)
            builder = EvaluationInputs(path, "test-clock", synthetic=True, fees=store)
            def build():
                return builder.build(observations, at_ns=NOW, max_age_ns=1000,
                                     max_skew_ns=10, bindings={})
            self.assertTrue(any("fees_missing_leg" in reason for reason in build()[1].values()))
            rows = [dict(venue=str(o.venue), account=str(o.account), product=o.kind,
                         fee_asset=str(o.rules.quote_asset), maker_percent="0", taker_percent="0") for o in observations]
            store.save(dict(expected_version="0", rows=rows))
            plans, failures, versions = build()
            self.assertTrue(plans, failures)
            from opportunity_scanner.scanner_archive import freeze, thaw
            archive = freeze(plans)
            self.assertEqual(plans[0].fee_version, "1")
            rows = [dict(r, taker_percent="10") for r in rows]
            store.save(dict(expected_version="1", rows=rows))
            changed, _, _ = build()
            old = thaw(archive)
            self.assertEqual(old, plans)
            self.assertEqual(changed[0].fee_version, "2")
            from strategies.cross_venue import arbitrage_evaluation as evaluation
            def result(plan):
                return evaluation.evaluate(plan.scenarios, plan.policy, plan.estimator,
                    plan.calibration, plan.simulation_error, plan.limits)
            self.assertTrue(result(old[0]).allowed, [(x.reason) for x in result(old[0]).plan_paths])
            self.assertEqual(result(changed[0]).reason, "reference_profit")

if __name__ == "__main__": unittest.main()


