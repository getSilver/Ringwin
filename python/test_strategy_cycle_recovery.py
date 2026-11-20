"""09b Host activation fencing of actual, checkpointed execution cycles."""
import io
import struct
import subprocess
import sys
import unittest
import copy
import hashlib
from dataclasses import replace
from fractions import Fraction as F

import strategy_host as host
from strategies.cross_venue import arbitrage_checkpoint as recovery
import test_arbitrage_host as fixture
from strategies.cross_venue import arbitrage_cycle as cycle
from test_arbitrage_cycle import plan as cycle_plan, facts, done, T, entry, market, estimator_for, path, LIMITS, with_price_units
from test_arbitrage_evaluation import wire, MODEL, EXACT
from test_arbitrage_probability import calibration
from strategies.cross_venue import arbitrage_baseline as baseline
from strategies.cross_venue import arbitrage_economics as economics
import math
import base64
import json
from pathlib import Path
from strategies.cross_venue import arbitrage_admission as admission
from strategies.cross_venue import arbitrage_signals as signals
from opportunity_scanner import arbitrage_scanner as scanner
from strategies.cross_venue import arbitrage_maker as maker
from test_arbitrage_admission import config as admission_config, signal_policy
from strategies.cross_venue import arbitrage_evaluation as valuation
from strategies.cross_venue import arbitrage_state_space as ss
from test_arbitrage_state_space import parameters


CORE_UTC = 1_767_225_600_450_000_000


def target_templates():
    result = fixture.components()
    result["filter"] = ss.Filter(parameters(version=2))
    return result


def target_runtime(container):
    expected = dict(fixture.meta(), definition=3)
    return recovery.ComponentRuntime(container, target_templates(), fixture.apply_event,
        expected={k: expected[k] for k in ("schema_registry", "strategy", "definition", "config_version",
                                         "state_schema", "state_schema_version")})


def core_plan(maker_mode=False):
    frozen = cycle_plan()
    deadline = CORE_UTC+10_000_000_000
    policy = replace(frozen.policy, original_base=F(10000), at_ns=CORE_UTC,
        absolute_minimum_atoms=1, min_profit_atoms=1, normal_limits=(90,120), risk_limits=(90,120), max_book_age_ns=1000000000,
        prediction_end_ns=deadline, risk_deadline_ns=deadline, reference_exit_ns=deadline)
    legs = tuple(replace(leg, account=account, target_lots=10000,
        rules=replace(leg.rules, instrument=instrument, tick_quote_atoms_per_base_atom=F(1,10000), valid_until_ns=deadline+1000))
        for leg, account, instrument in zip(frozen.legs, (20, 30), (101, 102)))
    frozen = replace(frozen, portfolio=10, policy=policy, legs=legs, entry_limits=(100, 110), target_atoms=8,
                     repair_deadline_ns=deadline-1, exit_deadline_ns=deadline+1000)
    if maker_mode:
        frozen = maker.Plan(**dict(vars(frozen), policy=replace(frozen.policy, mode="maker_taker")),
            maker_leg=0, offsets=(0,1), min_quote_interval_ns=3, max_requotes=2, quote_lifetime_ns=1000000000,
            improvement_atoms=1, max_unhedged_base=F(10000), tail_lifetime_ns=1000000000, native_post_only=True)
    return frozen


def core_admission_prefix(maker_mode=False, books=None):
    frozen = core_plan(maker_mode)
    now = CORE_UTC
    position = core_position(frozen, (10000, 10000), now)
    frames = (core_book(now, 111 if maker_mode else 110), core_book(now+1, 102), core_book(now+6, 102),
              core_book(frozen.policy.deadline_ns, 100), core_book(frozen.policy.deadline_ns+5, 100))
    if books is not None:
        frames = (replace(frames[0], books=tuple(books)),) + frames[1:]
    scenario = valuation.Scenario("core-entry", F(1), position, frames, (0, 5), ("filled", "filled"), ("entry:a", "entry:b"))
    observations = tuple(scanner.Observation(venue, leg.account, leg.kind, leg.rules, book, True)
        for venue, leg, book in zip((1, 21), position.legs, frames[0].books))
    pair = tuple(item.identity for item in observations)
    policy = replace(frozen.policy, scope=scanner.candidate_id(pair, 1, frozen.policy.mode, 0 if maker_mode else None))
    estimator = core_estimator(position, frames[0], replace(frozen, policy=policy))
    artifact = replace(calibration(scope=valuation.probability_scope(policy, 8, F(10000), now),
        model_hash=policy.model_hash, simulation_hash=estimator.probability_model_hash(policy)), valid_until_ns=frozen.exit_deadline_ns, mode=frozen.policy.mode)
    plan = scanner.Plan(pair, 0 if maker_mode else None, (scenario,), policy, estimator, artifact, EXACT, LIMITS, frozen.policy.deadline_ns, 200)
    cfg = admission_config(valid_until_ns=frozen.exit_deadline_ns,
        signal=signal_policy(reset_points=1, entry_points=1, opportunity_ttl_ns=1000000000), recommendation_ttl_ns=1000000000, max_book_age_ns=1000000000)
    option = admission.Option(plan, (10000, 10000), ((20, 100), (30, 100)), 20, "b"*64)
    approval = admission.Approval(plan.key, cfg.content_hash, 0, frozen.policy.deadline_ns, True, "package-activation", policy.model_hash,
                                 policy.version, artifact.version, (1, 1), "b"*64, "c"*64)
    state = signals.Signal(admission.signal_scope(pair, 1), cfg.signal, identity=(9, 10, 1))
    state.activate("package-activation", now-10)
    state.observe(1, now-1, 0, qualified=True, cursor=4)
    state.observe(2, now, 3, qualified=True, cursor=5)
    current = admission.Admission(cfg)
    facts = admission.Facts(now, 5, 1, cfg.content_hash, tuple((key,1000000) for key,_ in option.requirements), (), True, "core-proposal-5")
    request = current.propose(observations, (option,), (approval,), (state,), facts).request
    if request is None:
        raise AssertionError("core source proposal not admitted by private policy")
    quoted = None
    if maker_mode:
        quoted = maker.Quote(100, frames[0], (scenario,), estimator, artifact, EXACT, LIMITS,
            tuple(maker.Stress(name, 100, F(0), F(10000)) for name in maker.STRESS_CASES))
    return cfg, state, current, request, quoted


def core_templates(maker_mode=False, model_version=1):
    cfg, state, _, request, _ = core_admission_prefix(maker_mode)
    frozen = replace(core_plan(maker_mode), request_ref=request.identity, config_hash=cfg.content_hash,
                     policy=replace(core_plan(maker_mode).policy, scope=scanner.candidate_id(*request.key)))
    return {"cycle": (maker.Cycle if maker_mode else cycle.Cycle)(frozen),
            "signal": signals.Signal(state.scope, cfg.signal, identity=(9, 10, 1)),
            "admission": admission.Admission(cfg),
            "filter": ss.Filter(parameters(version=model_version)),
            "budget": signals.Signal("bounded-opportunity", signal_policy(), identity=(9, 10, 1)),
            "monitor": signals.Monitor((signals.Metric("error", 1, 2, 3, 1, 100000000000),),
                                       warn_windows=2, fail_windows=2, clear_windows=2)}


def core_position(frozen, quantities, now, loss=0):
    return valuation.Entry("matched", tuple(valuation.Leg(spec.account, spec.rules, spec.kind, spec.direction,
        (valuation.Trade("fill:"+str(index), frozen.entry_limits[index], quantity, economics.Fee(1, 0, F(0), 0), CORE_UTC),),
        economics.FeeRule(spec.rules.instrument, 1, 1, 0, 0, 0, frozen.exit_deadline_ns))
        for index, (spec, quantity) in enumerate(zip(frozen.legs, quantities))),
        (valuation.Settled("core-realized-loss", -loss),) if loss else (), now, True, (), (), baseline.Point(0, 1, math.log(1.1)))

def core_book(now, closing_b=110):
    return valuation.Market(now, (wire(101, now, 100, 101, 10000), wire(102, now, closing_b-1, closing_b, 10000)),
                            (F(1), F(1)), (0, 0), (), True, False, False, False)


def core_estimator(position, book, frozen):
    context = valuation.Context(position, book, economics.holding_target(frozen.target_atoms,
        position.matched_base/frozen.policy.original_base, frozen.policy.absolute_minimum_atoms), frozen.policy)
    historical = replace(position, holding_at_ns=0,
        legs=tuple(replace(leg, entries=tuple(replace(trade, at_ns=0) for trade in leg.entries)) for leg in position.legs))
    scenario = valuation.Scenario("committed-core-support", F(1), historical,
        (core_book(0), core_book(1, 102), core_book(6, 102), core_book(100, 100), core_book(105, 100)),
        (0, 5), ("filled", "filled"), ("support:a", "support:b"))
    artifact = replace(calibration(stage="hold", scope=context.scope, model_hash=frozen.policy.model_hash),
                       valid_until_ns=frozen.exit_deadline_ns+1000, mode=frozen.policy.mode)
    row = valuation.ConditionalRow(context.scope, (scenario,), artifact, EXACT,
        valuation.RebaseBounds(F(9, 10), F(11, 10), .01, F(1, 2), F(2), F(2)))
    estimator = valuation.Estimator(MODEL, 200, (row,))
    return replace(estimator, rows=(replace(row, calibration=replace(artifact,
        simulation_hash=estimator.probability_model_hash(frozen.policy))),))


def core_runtime(container, definition=2, maker_mode=False, public_books=False):
    visible_books = {}
    def apply(objects, record):
        current = objects["cycle"]
        if public_books and record.event_type == 7:
            book = host.decode_depth_snapshot(record.payload)
            if book["instrument"] not in (101, 102):
                raise ValueError("unexpected public instrument")
            visible_books[book["instrument"]] = record.payload
            return
        if record.event_type == 4 and record.payload in (b"start", b"start-risk"):
            books = tuple(visible_books[key] for key in (101, 102)) if public_books else None
            _, state, pending, request, quoted = core_admission_prefix(maker_mode, books)
            objects["filter"].push(baseline.Point(CORE_UTC//baseline.SECOND*baseline.SECOND, record.shard_sequence, .1))
            objects["signal"], objects["admission"] = state, pending
            if record.payload == b"start-risk":
                state.lock("daily_loss", "original-loss")
                state.lock("restart", "original-restart")
            budget = objects["budget"]
            budget.activate("package-activation", CORE_UTC-10)
            for grid, score in enumerate((0, 0, F(3,2), 3, 3), 1):
                budget.observe(grid, CORE_UTC-5+grid, score, qualified=True, cursor=grid)
            assert budget.evaluate(CORE_UTC)
            assert budget.evaluate(CORE_UTC+3)
            for sequence in (1, 2):
                objects["monitor"].update((signals.Window("error", sequence, CORE_UTC-3+sequence, 3 if record.payload == b"start-risk" else 0, 1, True),),
                    at_ns=CORE_UTC-3+sequence, independent_evidence=True)
            if maker_mode:
                return current.start(cursor=record.shard_sequence, at_ns=CORE_UTC, market=quoted.market, quotes=(quoted,))
            return current.start(cursor=record.shard_sequence, at_ns=CORE_UTC)
        if record.event_type != 5 or len(record.payload) != 176:
            raise ValueError("core projection codec")
        now, applied_a, possible_a, applied_b, possible_b, nav, base_a, base_b, status_a, status_b, risk = struct.unpack_from("<11Q", record.payload)
        if not record.time_presence & 0x10 or record.wall_time_utc_ns != now:
            raise ValueError("core projection clock")
        loss = struct.unpack_from("<Q", record.payload, 88)[0]
        book = core_book(now, 111 if risk & 16 else 102 if risk & 4 else 100 if risk & 8 else 110)
        book = replace(book, model_invalid=objects["monitor"].state == "InvalidLatched")
        position = None
        if base_a == base_b and base_a:
            position = core_position(current.plan, (base_a, base_b), now, loss)
        if objects["admission"].pending is not None:
            identity = objects["admission"].pending.identity
            objects["admission"].reply(identity, "reserved", cursor=record.shard_sequence, fact_ref="cycle:9:1")
        signal = objects["signal"]
        if "restart" in signal.reasons:
            signal.recover("restart", cause_ref="original-restart", recovery_ref="fresh-core-root")
        assert not signal.evaluate(now)
        assert not objects["budget"].evaluate(now)
        orders = [cycle.OrderFact(sequence, leg, ("sent", "terminal", "unknown")[status], applied, possible,
                       status != 2, "order:"+str(sequence))
                  for sequence, leg, applied, possible, status in ((1, 0, applied_a, possible_a, status_a),
                                                                  (2, 1, applied_b, possible_b, status_b))]
        for offset in (96, 136):
            sequence, leg, applied, possible, status = struct.unpack_from("<5Q", record.payload, offset)
            if sequence:
                orders.append(cycle.OrderFact(sequence, leg, ("sent", "terminal", "unknown")[status], applied, possible,
                                              status != 2, "order:"+str(sequence)))
        if maker_mode:
            orders = [order for order in orders if order.sequence in {intent.sequence for intent in current.issued}]
        if loss:
            assert position.r_done_atoms == -1 and current.target_atoms in (None, 4)
            assert 4-position.r_done_atoms == 5
        projection = cycle.Facts(cursor=record.shard_sequence, at_ns=now,
            cycle_ref="cycle:9:1", reservation_ref="reservation:9:1", admission="accepted", orders=tuple(orders),
            positions=(F(base_a), F(base_b)), safe_reduce_lots=(base_a, base_b), market=book, economic_entry=position,
            economic_ref="economic:"+str(record.shard_sequence)+":"+hashlib.sha256(record.payload).hexdigest(),
            opening_allowed=bool(risk & 16), reducing_allowed=bool(risk & 2), risk_causes=(("manual", "core-freeze"),) if risk & 1 else (), model_warning=objects["monitor"].state == "Warning",
            nav_atoms=nav, day_start_nav_atoms=nav, external_allocation_atoms=0,
            flow_adjusted_peak_atoms=nav, repair_loss_atoms=loss, repair_cost_atoms=0,
            closed_ref=None, residual_refs=(),
            possible_base=((F(base_a), F(base_a+possible_a)), (F(base_b), F(base_b+possible_b)))
                if any(order.status == "unknown" for order in orders) else ())
        estimator = core_estimator(position, book, current.plan) if position is not None else None
        return current.apply(projection, estimator=estimator, limits=LIMITS)
    def apply_with_price_units(objects, record):
        return with_price_units(apply(objects, record), base_scale=4)
    return recovery.ComponentRuntime(container, core_templates(maker_mode, 2 if definition == 3 else 1), apply_with_price_units,
        expected={k: dict(fixture.meta(), definition=definition)[k] for k in ("schema_registry", "strategy", "definition", "config_version",
                                               "state_schema", "state_schema_version")})


def phase_case(phase):
    current = cycle.Cycle(cycle_plan())
    current.start(cursor=1, at_ns=T)
    position = entry(5)
    holding = facts(2, orders=(done(1, 0, 5), done(2, 1, 5)), positions=(F(5), F(5)),
                    safe_reduce_lots=(5, 5), economic_entry=position, market=market(0, 1100), at_ns=T)
    if phase in ("holding", "exiting"):
        estimator = estimator_for((path("holding", position=position),), current.plan.policy, current.plan.target_atoms)
        current.apply(holding, estimator=estimator, limits=LIMITS)
        if phase == "exiting":
            current.apply(replace(holding, cursor=3, at_ns=T+1, risk_causes=(("manual", "manual-3"),), reducing_allowed=False))
        late = replace(holding, cursor=current.cursor+2, at_ns=T+200)
    elif phase == "repairing":
        partial = facts(2, orders=(done(1, 0, 10), done(2, 1, 6)), positions=(F(10), F(6)), safe_reduce_lots=(10, 6))
        current.apply(partial)
        late = replace(partial, cursor=4, at_ns=T+200, orders=partial.orders+(done(3, 1, 0),))
    elif phase == "reconciling":
        unknown = facts(2, orders=(done(1, 0, 10), done(2, 1, 0, status="unknown", possible_lots=10,
            economic_complete=False)), positions=(F(10), F(0)), safe_reduce_lots=(10, 0),
            possible_base=((F(10), F(10)), (F(0), F(10))), risk_causes=(("margin", "margin-2"),))
        current.apply(unknown)
        late = replace(unknown, cursor=4, at_ns=T+200)
    elif phase == "entering":
        late = facts(3, orders=(done(1, 0, 0), done(2, 1, 0)), at_ns=T+200)
    else:
        raise ValueError("unknown phase")
    if current.phase != phase:
        raise AssertionError((phase, current.phase))
    return current, late


def phase_runtime(container, phase):
    _, late = phase_case(phase)
    def apply(objects, record):
        if record.event_type != 4 or record.payload != b"late" or record.shard_sequence != late.cursor:
            raise ValueError("phase input")
        return objects["cycle"].apply(late)
    return recovery.ComponentRuntime(container, {"cycle": cycle.Cycle(cycle_plan())}, apply,
        expected={k: fixture.meta()[k] for k in ("schema_registry", "strategy", "definition", "config_version",
                                               "state_schema", "state_schema_version")})


def phase_exchange(saved, phase, late):
    metadata, state = host.decode_checkpoint(saved)
    cursor = metadata["cursor"]
    session = (1, 0, 3)
    wire = io.BytesIO()
    plan_bytes = bytearray(176)
    struct.pack_into("<QI4xQ", plan_bytes, 48, *session)
    host.write_frame(wire, host.SESSION_PLAN, session, 1, plan_bytes)
    host.write_frame(wire, host.BEGIN_RECOVERY, session, 2, struct.pack("<Q", cursor)+saved)
    payload = (9).to_bytes(16, "little")+(99).to_bytes(16, "little")+struct.pack("<Q", cursor+1)+host.state_digest(metadata, state)
    host.write_frame(wire, host.ACTIVATE_STRATEGY, session, 3, payload)
    host.write_frame(wire, host.INPUT_BATCH, session, 4, fixture.batch([], session, 1, first=cursor+1, last=cursor+1))
    host.write_frame(wire, host.INPUT_BATCH, session, 5, fixture.batch([(4, late.cursor, b"late")], session, 2))
    host.write_frame(wire, host.REQUEST_CHECKPOINT, session, 6, struct.pack("<QQ", 1, late.cursor))
    host.write_frame(wire, host.SHUTDOWN, session, 7)
    return subprocess.run([sys.executable, __file__, "--phase", phase, "--mode", "portable",
                           "--strategy-identity", "9", "--activation-identity", "99"],
                          input=wire.getvalue(), capture_output=True, timeout=30)


def exchange(saved, *, activation_digest=None, consume_activation=True, activation_identity=99):
    metadata, state = host.decode_checkpoint(saved)
    session = (1, 0, 2)
    wire = io.BytesIO()
    plan = bytearray(176)
    struct.pack_into("<QI4xQ", plan, 48, *session)
    host.write_frame(wire, host.SESSION_PLAN, session, 1, plan)
    host.write_frame(wire, host.BEGIN_RECOVERY, session, 2, struct.pack("<Q", 11)+saved)
    activation = (9).to_bytes(16, "little")+activation_identity.to_bytes(16, "little")
    activation += struct.pack("<Q", 12)+(activation_digest or host.state_digest(metadata, state))
    host.write_frame(wire, host.ACTIVATE_STRATEGY, session, 3, activation)
    number, sequence = 1, 4
    if consume_activation:
        host.write_frame(wire, host.INPUT_BATCH, session, sequence,
                         fixture.batch([], session, number, first=12, last=12))
        number, sequence = number+1, sequence+1
    host.write_frame(wire, host.INPUT_BATCH, session, sequence,
                     fixture.batch(fixture.events()[12:], session, number))
    host.write_frame(wire, host.REQUEST_CHECKPOINT, session, sequence+1, struct.pack("<QQ", 1, 14))
    host.write_frame(wire, host.SHUTDOWN, session, sequence+2)
    return subprocess.run([sys.executable, fixture.__file__, "--mode", "portable",
                           "--strategy-identity", "9", "--activation-identity", "99"],
                          input=wire.getvalue(), capture_output=True, timeout=30)


class CycleRecoveryTests(unittest.TestCase):
    def test_frozen_v2_checkpoints_restore_without_changing_dependencies_or_progress(self):
        root = Path(__file__).resolve().parents[1] / "src/testing/fixtures"
        for maker_mode, name in ((False, "strategy_cycle_recovery_v2.json"), (True, "strategy_maker_recovery_v2.json")):
            with self.subTest(maker_mode=maker_mode):
                state = json.loads((root/name).read_text(encoding="utf-8"))
                saved = host.encode_checkpoint(fixture.meta(), state)
                metadata, restored = recovery.restore(saved, core_templates(maker_mode))
                self.assertEqual(recovery.checkpoint(metadata, restored), saved)
                self.assertEqual(restored["cycle"].phase, "idle")
                wrong = core_templates(maker_mode)
                wrong["cycle"].plan = replace(wrong["cycle"].plan, exit_deadline_ns=CORE_UTC+20_000_000_000)
                with self.assertRaisesRegex(ValueError, "frozen dependency mismatch"):
                    recovery.restore(saved, wrong)

    def test_public_acceptance_contract_keeps_frozen_test_dependencies(self):
        contract = json.loads((Path(__file__).resolve().parents[1] /
            "src/testing/fixtures/cross_venue_acceptance_contract.json").read_text(encoding="utf-8"))
        for mode, maker_mode in (("taker_taker", False), ("maker_taker", True)):
            actual = {name: recovery.content(recovery.dependency(obj))
                      for name, obj in core_templates(maker_mode).items()}
            self.assertEqual(actual, contract["modes"][mode])

    def test_public_depth_is_used_by_admission_without_replacing_unknown_liquidity(self):
        books = core_book(CORE_UTC).books
        self.assertIsNotNone(core_admission_prefix(books=books)[3])
        missing = host.decode_depth_snapshot(books[0])
        missing["asks"] = tuple((price, None) for price, _ in missing["asks"])
        with self.assertRaises((AssertionError, ValueError)):
            core_admission_prefix(books=(host.encode_depth_snapshot(missing), books[1]))

    def test_declared_model_migration_and_rebuild_keep_cycle_and_unresolved_private_evidence(self):
        source = fixture.runtime_factory(recovery.checkpoint(fixture.meta(), fixture.components()))
        source.apply_batch(fixture.batch(fixture.events()), (1, 0, 1))
        source.components["signal"].lock("daily_loss", "loss-fact")
        saved = source.checkpoint()
        metadata, original = host.decode_checkpoint(saved)
        target = dict(metadata, definition=3)
        self.assertEqual(recovery.transition_checkpoint(saved, fixture.components(), fixture.components(),
            expected=metadata, target_metadata=metadata, transition="keep"), saved)
        for transition in ("migrate", "rebuild"):
            with self.subTest(transition=transition):
                changed = recovery.transition_checkpoint(saved, fixture.components(), target_templates(),
                    expected=metadata, target_metadata=target, transition=transition,
                    migrate=lambda name, tag, state: state)
                actual = fixture.returned(fixture.run_host(changed, [], metadata["cursor"],
                    script=__file__, extra_args=("--profile", "target")))
                self.assertEqual(actual, changed)
                _, restored = recovery.restore(actual, target_templates(), expected=target)
                self.assertEqual(restored["cycle"].plan, source.components["cycle"].plan)
                self.assertEqual(restored["cycle"].first_exit, source.components["cycle"].first_exit)
                self.assertEqual(restored["cycle"].next_sequence, source.components["cycle"].next_sequence)
                self.assertEqual(restored["labels"].pending, source.components["labels"].pending)
                self.assertEqual(restored["signal"].reasons["daily_loss"], "loss-fact")
                if transition == "rebuild":
                    self.assertIn("rebuild", restored["signal"].reasons)
                    self.assertFalse(restored["monitor"].qualified)
                    self.assertEqual(restored["filter"].state.count, 0)
                else:
                    self.assertEqual(restored["filter"].state, source.components["filter"].state)
                rows = lambda state: {row["name"]: row for row in state["components"]}
                self.assertEqual(rows(host.decode_checkpoint(actual)[1])["cycle"], rows(original)["cycle"])

    def test_successor_or_new_configuration_cannot_reinterpret_an_active_frozen_plan(self):
        current, _ = phase_case("holding")
        metadata = fixture.meta(current.cursor, current.next_sequence)
        saved = recovery.checkpoint(metadata, {"cycle": current})
        templates = {"cycle": cycle.Cycle(cycle_plan())}
        for changed in (dict(metadata, strategy=10), dict(metadata, config_version=2),
                        dict(metadata, next_intent=1), dict(metadata, cursor=metadata["cursor"]+1)):
            with self.assertRaises(ValueError):
                recovery.transition_checkpoint(saved, templates, templates, expected=metadata,
                    target_metadata=changed, transition="migrate", migrate=lambda name, tag, state: state)
        self.assertEqual(recovery.checkpoint(metadata, {"cycle": current}), saved)

    def test_all_five_phases_keep_original_deadlines_latches_targets_and_intent_identity(self):
        for phase in ("entering", "repairing", "holding", "exiting", "reconciling"):
            with self.subTest(phase=phase):
                current, late = phase_case(phase)
                before = copy.deepcopy(current)
                metadata = fixture.meta(current.cursor, current.next_sequence)
                saved = recovery.checkpoint(metadata, {"cycle": current})
                result = phase_exchange(saved, phase, late)
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                stream, returned = io.BytesIO(result.stdout), None
                output_sequences = []
                while stream.tell() < len(result.stdout):
                    kind, _, _, payload = host.read_frame(stream)
                    if kind == host.CHECKPOINT_CONTENT:
                        returned = payload[8:]
                    if kind == host.STRATEGY_OUTPUT:
                        output_sequences.append(struct.unpack_from("<Q", payload, 136)[0])
                expected_action = current.apply(late)
                expected_meta = fixture.meta(late.cursor, current.next_sequence)
                self.assertEqual(returned, recovery.checkpoint(expected_meta, {"cycle": current}))
                self.assertEqual(output_sequences, [expected_action.intents[0].sequence] if expected_action.intents else [])
                self.assertIsNotNone(current.first_exit)
                self.assertEqual(current.plan, before.plan)
                if before.first_exit is not None:
                    self.assertEqual(current.first_exit, before.first_exit)
                if before.target_atoms is not None:
                    self.assertEqual(current.target_atoms, before.target_atoms)
                if phase == "reconciling":
                    self.assertEqual(current.phase, "reconciling")
                    self.assertFalse(output_sequences)

    def test_holding_cycle_replays_activation_fact_before_only_new_exit_intents(self):
        initial = recovery.checkpoint(fixture.meta(), fixture.components())
        saved = fixture.returned(fixture.run_host(initial, [fixture.batch(fixture.events()[:11])], 11))
        result = exchange(saved)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        stream = io.BytesIO(result.stdout)
        frames = []
        while stream.tell() < len(result.stdout):
            frames.append(host.read_frame(stream))
        self.assertEqual([x[0] for x in frames], [101, 106, 102, 105, 108, 107])
        frame = frames[3][3]
        self.assertEqual(int.from_bytes(frame[108:124], "little"), 99)
        self.assertEqual(struct.unpack_from("<Q", frame, 136)[0], 3)
        _, restored = recovery.restore(frames[4][3][8:], fixture.components())
        self.assertEqual(struct.unpack_from("<HII", frame, 98), (2, 2, 208))
        for offset, intent in zip((200, 304), restored["cycle"].issued[-2:]):
            self.assertEqual(struct.unpack_from("<qQ", frame, offset),
                             (intent.limit_ticks, restored["cycle"].plan.legs[intent.leg].rules.version))
        self.assertEqual(restored["cycle"].first_exit, ("take_profit", 13))
        self.assertEqual(restored["cycle"].target_atoms, 40_000_000)
        self.assertEqual(restored["cycle"].next_sequence, 5)

    def test_wrong_activation_digest_identity_and_missing_barrier_never_emit(self):
        initial = recovery.checkpoint(fixture.meta(), fixture.components())
        saved = fixture.returned(fixture.run_host(initial, [fixture.batch(fixture.events()[:11])], 11))
        for changes in (dict(activation_digest=b"x"*32), dict(activation_identity=98), dict(consume_activation=False)):
            result = exchange(saved, **changes)
            self.assertNotEqual(result.returncode, 0)
            stream = io.BytesIO(result.stdout)
            kinds = []
            while stream.tell() < len(result.stdout):
                kinds.append(host.read_frame(stream)[0])
            self.assertNotIn(host.STRATEGY_OUTPUT, kinds)


if __name__ == "__main__":
    if "--convert" in sys.argv:
        mode, encoded = sys.argv[2:]
        saved = base64.b64decode(encoded, validate=True)
        metadata, _ = host.decode_checkpoint(saved)
        converted = recovery.transition_checkpoint(saved, core_templates(), core_templates(model_version=2), expected=metadata,
            target_metadata=dict(metadata, definition=3), transition=mode, migrate=lambda name, tag, state: state)
        sys.stdout.buffer.write(converted)
        raise SystemExit(0)
    if "--profile" in sys.argv:
        index = sys.argv.index("--profile")
        if sys.argv[index+1] != "target":
            raise ValueError("unknown profile")
        del sys.argv[index:index+2]
        raise SystemExit(host.main(runtime_factory=target_runtime))
    if "--core" in sys.argv:
        sys.argv.remove("--core")
        definition = 2
        maker_mode = "--core-maker" in sys.argv
        if maker_mode:
            sys.argv.remove("--core-maker")
        public_books = "--public-books" in sys.argv
        if public_books:
            sys.argv.remove("--public-books")
        if "--core-definition" in sys.argv:
            index = sys.argv.index("--core-definition")
            definition = int(sys.argv[index+1])
            del sys.argv[index:index+2]
        raise SystemExit(host.main(runtime_factory=lambda raw: core_runtime(raw, definition, maker_mode, public_books)))
    if "--phase" in sys.argv:
        index = sys.argv.index("--phase")
        phase = sys.argv[index+1]
        del sys.argv[index:index+2]
        raise SystemExit(host.main(runtime_factory=lambda raw: phase_runtime(raw, phase)))
    unittest.main()
