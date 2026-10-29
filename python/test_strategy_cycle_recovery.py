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
import arbitrage_checkpoint as recovery
import test_arbitrage_host as fixture
import arbitrage_cycle as cycle
from test_arbitrage_cycle import plan as cycle_plan, facts, done, T, entry, market, estimator_for, path, LIMITS
from test_arbitrage_evaluation import wire
import arbitrage_evaluation as valuation
import arbitrage_state_space as ss
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


def core_templates():
    frozen = cycle_plan()
    deadline = CORE_UTC+10_000_000_000
    policy = replace(frozen.policy, original_base=F(10000), at_ns=CORE_UTC,
        prediction_end_ns=deadline, risk_deadline_ns=deadline, reference_exit_ns=deadline)
    legs = tuple(replace(leg, account=account, target_lots=10000,
        rules=replace(leg.rules, instrument=instrument, valid_until_ns=deadline+1000))
        for leg, account, instrument in zip(frozen.legs, (20, 30), (101, 102)))
    frozen = replace(frozen, portfolio=10, policy=policy, legs=legs, entry_limits=(100, 100),
                     repair_deadline_ns=deadline-1, exit_deadline_ns=deadline+1000)
    return {"cycle": cycle.Cycle(frozen)}


def core_runtime(container):
    def apply(objects, record):
        current = objects["cycle"]
        if record.event_type == 4 and record.payload == b"start":
            return current.start(cursor=record.shard_sequence, at_ns=CORE_UTC)
        if record.event_type != 5 or len(record.payload) != 48:
            raise ValueError("core projection codec")
        now, applied_a, possible_a, applied_b, possible_b, nav = struct.unpack("<QQQQQQ", record.payload)
        if not record.time_presence & 0x10 or record.wall_time_utc_ns != now:
            raise ValueError("core projection clock")
        books = tuple(wire(instrument, now, 100, 101, 10000) for instrument in (101, 102))
        book = valuation.Market(now, books, (F(1), F(1)), (0, 0), (), True, False, False, False)
        projection = cycle.Facts(cursor=record.shard_sequence, at_ns=now,
            cycle_ref="cycle:9:1", reservation_ref="reservation:9:1", admission="accepted",
            orders=tuple(cycle.OrderFact(sequence, leg, "sent", applied, possible, True, "order:"+str(sequence))
                         for sequence, leg, applied, possible in ((1, 0, applied_a, possible_a), (2, 1, applied_b, possible_b))),
            positions=(F(0), F(0)), safe_reduce_lots=(0, 0), market=book, economic_entry=None,
            economic_ref="economic:"+str(record.shard_sequence)+":"+hashlib.sha256(record.payload).hexdigest(),
            opening_allowed=False, reducing_allowed=True, risk_causes=(), model_warning=False,
            nav_atoms=nav, day_start_nav_atoms=nav, external_allocation_atoms=0,
            flow_adjusted_peak_atoms=nav, repair_loss_atoms=0, repair_cost_atoms=0,
            closed_ref=None, residual_refs=())
        return current.apply(projection)
    return recovery.ComponentRuntime(container, core_templates(), apply,
        expected={k: fixture.meta()[k] for k in ("schema_registry", "strategy", "definition", "config_version",
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
    if "--profile" in sys.argv:
        index = sys.argv.index("--profile")
        if sys.argv[index+1] != "target":
            raise ValueError("unknown profile")
        del sys.argv[index:index+2]
        raise SystemExit(host.main(runtime_factory=target_runtime))
    if "--core" in sys.argv:
        sys.argv.remove("--core")
        raise SystemExit(host.main(runtime_factory=core_runtime))
    if "--phase" in sys.argv:
        index = sys.argv.index("--phase")
        phase = sys.argv[index+1]
        del sys.argv[index:index+2]
        raise SystemExit(host.main(runtime_factory=lambda raw: phase_runtime(raw, phase)))
    unittest.main()
