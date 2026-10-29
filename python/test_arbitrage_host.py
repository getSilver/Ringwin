"""Real component replay over pipes; core facts below are offline fixtures."""
import copy
from dataclasses import replace
import io
import hashlib
import json
import struct
import subprocess
import sys
import unittest
from fractions import Fraction as F

import arbitrage_checkpoint as recovery
import arbitrage_baseline as b
import arbitrage_cycle as cycle
import arbitrage_signals as signals
import arbitrage_state_space as ss
import arbitrage_evaluation as evaluation
import strategy_host as host
from test_arbitrage_checkpoint import meta
from test_arbitrage_state_space import parameters
from test_arbitrage_admission import signal_policy
from test_arbitrage_cycle import plan, facts, done, T, entry, market, estimator_for, path, LIMITS
from test_arbitrage_evaluation import calibration, policy as evaluation_policy, EXACT


def frozen_plan(version=1):
    if version not in range(1, 11):
        raise ValueError("unknown fixture configuration")
    if version == 1:
        return plan()
    ppm = (679_999, 680_000, 680_001)[(version-2)//3]
    delta = (-1, 0, 1)[(version-2)%3]
    return plan(config_version=version, target_atoms=80_000_000+2*delta,
                policy=replace(plan().policy, min_entry_probability=F(ppm, 1_000_000)))


def components(version=1):
    spec = b.WindowSpec(1, 3, 3, 1e-15, 0.)
    trained = tuple(b.Point(i*b.SECOND, i+1, float(i)) for i in range(305))
    rolling = b.fit_rolling(trained, spec=spec, version=1, training_end_ns=305*b.SECOND,
                           deviation_edges=(0.,), volatility_edges=(2.,), min_samples=2)
    estimator = next(iter(economic_inputs(version).values()))[1]["estimator"]
    result = dict(ar1=b.AR1(1, 0, 0., .5, .1, 1e-8, 1e-9, 0.), estimator=estimator,
                rolling=rolling, window=b.RollingWindow(spec),
                filter=ss.Filter(parameters()), labels=b.LabelTracker(256),
                signal=signals.Signal("pair", signal_policy(), identity=(9, 1, 1)),
                monitor=signals.Monitor((signals.Metric("error", 1, 2, 3, 1, 1000*b.SECOND),),
                                       warn_windows=2, fail_windows=2, clear_windows=2),
                cycle=cycle.Cycle(frozen_plan(version)))
    if version != 1:
        policy = replace(evaluation_policy(), min_entry_probability=frozen_plan(version).policy.min_entry_probability)
        estimator = estimator_for((path("boundary"),), policy)
        artifact = calibration(scope=evaluation.probability_scope(policy, 8_000_000, F(1), T),
            margin=F(7, 100), model_hash=policy.model_hash,
            simulation_hash=estimator.probability_model_hash(policy))
        result.update(boundary_estimator=estimator, boundary_calibration=artifact)
    return result


def economic_inputs(version=1):
    position = entry(5)
    holding = facts(11, orders=(done(1, 0, 5), done(2, 1, 5)), positions=(F(5), F(5)),
                    safe_reduce_lots=(5, 5), economic_entry=position,
                    market=market(0, 1100), at_ns=T)
    frozen = frozen_plan(version)
    estimator = estimator_for((path("holding", position=position),), frozen.policy, frozen.target_atoms)
    result = [(holding, dict(estimator=estimator, limits=LIMITS))]
    for i, tick in enumerate((1019, 1020, 1021), 12):
        result.append((facts(i, orders=holding.orders, positions=holding.positions,
                            safe_reduce_lots=(5, 5), economic_entry=position,
                            market=market(i, tick), at_ns=T+i), {}))
    return {recovery.content(value).encode("ascii"): value for value in result}


def apply_event(objects, record):
    """Test-only input codec: samples or authenticated immutable Facts references."""
    event_type, cursor, payload = record.event_type, record.shard_sequence, record.payload
    if event_type == 1:
        if len(payload) != 16:
            raise ValueError("sample length")
        grid, value = struct.unpack("<Qd", payload)
        if (record.time_presence & 1 and record.source_time_ns != grid*b.SECOND) or (
                record.time_presence & 0x10 and record.wall_time_utc_ns != grid*b.SECOND):
            raise ValueError("fixture clock evidence")
        point = b.Point(grid*b.SECOND, cursor, value)
        objects["window"].push(point)
        try:
            objects["rolling"].predict(objects["window"].statistics(), 300, 1)
        except b.Rejected as error:
            if str(error) not in ("insufficient_samples", "near_center", "empty_bucket", "degenerate_variance"):
                raise
        state = objects["filter"].push(point)
        matured = objects["labels"].advance(point)
        # Exercise real predictions, pending labels and exact threshold decisions.
        try:
            objects["ar1"].predict(point, 300, 1)
        except b.Rejected as error:
            if str(error) != "near_center":
                raise
        if not state.reason:
            objects["labels"].add(objects["filter"].predict(300, 1))
        if matured:
            errors = [x.error for x in matured if x.status == "mature"]
            objects["monitor"].update((signals.Window("error", cursor, point.grid_ns,
                F(abs(errors[0])) if errors else None, len(errors), bool(errors)),),
                at_ns=point.grid_ns, independent_evidence=True)
        objects["signal"].observe(grid, grid, F(value), qualified=True, cursor=cursor)
    elif event_type == 4 and payload == b"start":
        objects["cycle"].start(cursor=cursor, at_ns=T)
    elif event_type == 4 and payload == b"probability":
        policy = replace(evaluation_policy(), min_entry_probability=objects["cycle"].plan.policy.min_entry_probability)
        actual = evaluation.evaluate((path("boundary"),), policy, objects["boundary_estimator"],
                                     objects["boundary_calibration"], EXACT, LIMITS)
        if actual.allowed != (policy.min_entry_probability <= F(680_000, 1_000_000)):
            raise AssertionError("probability ppm equality boundary")
    elif event_type == 4 and payload in (b"monitor-duplicate", b"monitor-missing"):
        monitor = objects["monitor"]
        previous = monitor.windows["error"]
        window = previous if payload == b"monitor-duplicate" else signals.Window(
            "error", previous.sequence+1, previous.cutoff_ns+1, None, 0, False)
        monitor.update((window,), at_ns=window.cutoff_ns, independent_evidence=True)
    elif event_type == 5:
        archived = economic_inputs(objects["cycle"].plan.config_version)
        if payload not in archived:
            raise ValueError("missing economic input")
        current, kwargs = archived[payload]
        if current.cursor != cursor:
            raise ValueError("economic cursor")
        objects["cycle"].apply(current, **kwargs)
    else:
        raise ValueError("unsupported fixture input")


def runtime_factory(container, version=1):
    return recovery.ComponentRuntime(container, components(version), apply_event,
        expected=dict(schema_registry=host.SCHEMA_REGISTRY, strategy=9, definition=2,
                      config_version=version, state_schema=host.CROSS_VENUE_STATE_SCHEMA,
                      state_schema_version=2))


def events(version=1):
    result = [(1, i, struct.pack("<Qd", grid, value)) for i, (grid, value) in enumerate(
        ((305, 0.), (306, .5), (307, 1.), (308, 3.), (309, 3.), (310, 2.), (311, 1.), (610, .5), (611, 2.)), 1)]
    result.append((4, 10, b"start"))
    result.extend((5, value[0].cursor, key) for key, value in economic_inputs(version).items())
    return result


def batch(items, session=(1, 0, 1), number=1, first=None, last=None):
    data = bytearray(128)
    for kind, cursor, payload in items:
        record = bytearray((64+len(payload)+7)//8*8)
        struct.pack_into("<IIHHIQ", record, 0, len(record), len(payload), kind, 1, 0, cursor)
        if kind == 1:
            grid = struct.unpack_from("<Q", payload)[0]*b.SECOND
            struct.pack_into("<I", record, 12, 0x1f)
            struct.pack_into("<qqqq", record, 24, grid, grid+1, grid+2, grid)
        record[64:64+len(payload)] = payload
        data.extend(record)
    data[:4] = b"QSHB"
    struct.pack_into("<HHII", data, 4, 1, 128, 0, len(data))
    data[16:32] = host.SCHEMA_REGISTRY.to_bytes(16, "little")
    struct.pack_into("<QI4xQQQQqII", data, 48, *session, number,
                     first if first is not None else items[0][1],
                     last if last is not None else items[-1][1], 0, len(items), len(data)-128)
    struct.pack_into("<I", data, 124, host.crc32c(data[:124]+data[128:]))
    return bytes(data)


def run_host(saved, batches, barrier, *, session=(1, 0, 1), expected_cursor=None):
    wire = io.BytesIO()
    plan_bytes = bytearray(176)
    struct.pack_into("<QI4xQ", plan_bytes, 48, *session)
    host.write_frame(wire, host.SESSION_PLAN, session, 1, plan_bytes)
    host.write_frame(wire, host.BEGIN_RECOVERY, session, 2, struct.pack("<Q", barrier)+saved)
    sequence = 3
    for value in batches:
        host.write_frame(wire, host.INPUT_BATCH, session, sequence, value)
        sequence += 1
    cursor = expected_cursor if expected_cursor is not None else barrier
    host.write_frame(wire, host.REQUEST_CHECKPOINT, session, sequence, struct.pack("<QQ", 1, cursor))
    host.write_frame(wire, host.SHUTDOWN, session, sequence+1)
    version = struct.unpack_from("<Q", saved, 88)[0]
    result = subprocess.run([sys.executable, __file__, "--mode", "portable", "--strategy-identity", "9",
                            "--config-version", str(version)],
                            input=wire.getvalue(), capture_output=True, timeout=30)
    return result


def returned(result):
    if result.returncode:
        raise AssertionError(result.stderr.decode()+str(result.returncode))
    frames = io.BytesIO(result.stdout)
    output = [host.read_frame(frames) for _ in range(5)]
    if [x[0] for x in output] != [host.HOST_HELLO, host.HOST_HEARTBEAT,
            host.STRATEGY_RECOVERED, host.CHECKPOINT_CONTENT, host.SHUTDOWN_ACK]:
        raise AssertionError("unexpected output, including forbidden replay intent")
    return output[3][3][8:]


class HostReplayTests(unittest.TestCase):
    def test_original_clock_evidence_survives_batch_decode_and_host_recovery(self):
        initial = recovery.checkpoint(meta(), components())
        seen = []
        def observe(objects, record):
            seen.append(record)
            apply_event(objects, record)
        runtime = recovery.ComponentRuntime(initial, components(), observe,
            expected={k: meta()[k] for k in ("schema_registry", "strategy", "definition", "config_version",
                                            "state_schema", "state_schema_version")})
        source = batch(events()[:1])
        runtime.apply_batch(source, (1, 0, 1))
        time = 305*b.SECOND
        self.assertEqual(seen[0], host.InputRecord(1, 1, 0x1f, 1, time, time+1, time+2, time,
                                                  events()[0][2]))
        self.assertEqual(returned(run_host(initial, [source], 1)), runtime.checkpoint())
        broken = bytearray(source)
        struct.pack_into("<q", broken, 128+24, time-1)
        struct.pack_into("<I", broken, 124, host.crc32c(broken[:124]+broken[128:]))
        self.assertNotEqual(run_host(initial, [bytes(broken)], 1).returncode, 0)

    def test_duplicate_and_missing_monitoring_windows_across_host_checkpoint_do_not_add_health(self):
        initial = recovery.checkpoint(meta(), components())
        saved = returned(run_host(initial, [batch(events())], 14))
        _, before = host.decode_checkpoint(saved)
        state = lambda value: next(x["state"] for x in value["components"] if x["name"] == "monitor")
        for generation in (2, 3):
            session = (1, 0, generation)
            cursor = 15+generation-2
            saved = returned(run_host(saved, [batch([(4, cursor, b"monitor-duplicate")], session)], cursor, session=session))
            self.assertEqual(state(host.decode_checkpoint(saved)[1]), state(before))
        missing = returned(run_host(saved, [batch([(4, 17, b"monitor-missing")])], 17))
        after = state(host.decode_checkpoint(missing)[1])
        self.assertFalse(after["qualified"])
        self.assertEqual(after["good_windows"], 0)
        self.assertEqual(after["state"], state(before)["state"])

    def test_ppm_tick_and_target_atom_boundary_decisions_match_across_host_recovery(self):
        for version in range(2, 11):
            with self.subTest(version=version):
                metadata = dict(meta(), config_version=version)
                initial = recovery.checkpoint(metadata, components(version))
                source = events(version)+[(4, 15, b"probability")]
                expected = returned(run_host(initial, [batch(source)], 15))
                cut = returned(run_host(initial, [batch(source[:11])], 11))
                session = (1, 0, 2)
                actual = returned(run_host(cut, [batch(source[11:], session)], 15, session=session))
                self.assertEqual(actual, expected)
                _, restored = recovery.restore(cut, components(version))
                frozen = restored["cycle"]
                self.assertEqual(frozen.target_atoms, 40_000_000+(-1, 0, 1)[(version-2)%3])
                self.assertEqual(frozen.phase, "holding")
                # At a fixed tick, only the one-atom target decides equality.
                current, kwargs = list(economic_inputs(version).values())[2]
                action = frozen.apply(current, **kwargs)
                net = evaluation.value_exit(current.economic_entry, current.market, frozen.plan.policy, normal=True).net_atoms
                self.assertEqual(bool(action.intents), net >= frozen.target_atoms)

    def test_real_models_and_intents_continue_through_host_input_and_checkpoint(self):
        saved = recovery.checkpoint(meta(), components())
        result = returned(run_host(saved, [batch(events())], 14))
        metadata, restored = recovery.restore(result, components())
        self.assertEqual((metadata["cursor"], metadata["next_intent"]), (14, 5))
        self.assertEqual(restored["cycle"].phase, "exiting")
        self.assertEqual([(i.sequence, i.leg, i.lots, i.limit_ticks, i.reducing)
                         for i in restored["cycle"].issued[:2]],
                         [(1, 0, 10, 1001, False), (2, 1, 10, 1099, False)])
        self.assertEqual(restored["cycle"].target_atoms, 40_000_000)

    def test_every_checkpoint_cut_and_batch_split_has_exact_state_digest_and_intents(self):
        initial = recovery.checkpoint(meta(), components())
        source = events()
        expected = returned(run_host(initial, [batch(source)], 14))
        for cut in range(15):
            with self.subTest(cut=cut):
                saved = initial if cut == 0 else returned(run_host(initial, [batch(source[:cut])], cut))
                session = (1, 0, cut+2)
                tail = [batch([event], session, i) for i, event in enumerate(source[cut:], 1)]
                actual = returned(run_host(saved, tail, 14, session=session))
                self.assertEqual(actual, expected)
                # Input after the recovery report uses the same callback and cursor.
                self.assertEqual(returned(run_host(saved, tail, cut, session=session, expected_cursor=14)), expected)
        metadata, state = host.decode_checkpoint(expected)
        restored = recovery.restore(expected, components())[1]
        self.assertEqual(metadata["next_intent"], 5)
        self.assertTrue(restored["labels"].pending)
        self.assertGreater(restored["monitor"].sequences["error"], 0)
        self.assertEqual(host.state_digest(metadata, state), host.state_digest(*host.decode_checkpoint(actual)))

    def test_duplicate_gap_old_session_bad_count_and_cross_barrier_are_rejected(self):
        initial = recovery.checkpoint(meta(), components())
        one = batch(events()[:1])
        invalid = [
            [one, one],
            [batch(events()[1:2])],
            [batch(events()[:1], session=(1, 0, 2))],
            [batch(events()[:2])],  # Cannot report recovery beyond the requested barrier.
        ]
        broken = bytearray(one)
        struct.pack_into("<I", broken, 104, 2)
        struct.pack_into("<I", broken, 124, host.crc32c(broken[:124]+broken[128:]))
        invalid.append([bytes(broken)])
        for batches in invalid:
            with self.subTest(batches=batches):
                result = run_host(initial, batches, 1)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(b"QSSC", result.stdout)

    def test_nonfinite_capacity_and_missing_dependency_fail_without_checkpoint(self):
        initial = recovery.checkpoint(meta(), components())
        for value in (float("inf"), float("nan")):
            result = run_host(initial, [batch([(1, 1, struct.pack("<Qd", 305, value))])], 1)
            self.assertNotEqual(result.returncode, 0)
        runtime = runtime_factory(initial)
        with self.assertRaises(ValueError):
            runtime.apply_batch(batch([(1, 1, struct.pack("<Qd", 305, float("inf")))]), (1, 0, 1))
        with self.assertRaisesRegex(ValueError, "failed runtime"):
            runtime.checkpoint()

    def test_invalid_semantics_and_capacity_are_rejected_by_child_before_publication(self):
        initial = recovery.checkpoint(meta(), components())
        runtime = runtime_factory(initial)
        runtime.apply_batch(batch(events()), (1, 0, 1))
        saved = runtime.checkpoint()
        metadata, state = host.decode_checkpoint(saved)
        by_name = lambda x, name: next(row for row in x["components"] if row["name"] == name)
        cases = [
            lambda x: x["components"][0].update(dependency="0"*64),
            lambda x: x["components"].extend(copy.deepcopy(x["components"])*64),
            lambda x: by_name(x, "labels")["state"].update(_pending=by_name(x, "labels")["state"]["_pending"]*257),
            lambda x: by_name(x, "window")["state"].update(_points=by_name(x, "window")["state"]["_points"]*3601),
            lambda x: by_name(x, "filter")["state"]["_state"]["covariance"].__setitem__(0, "bff0000000000000"),
            lambda x: by_name(x, "filter")["state"]["_state"]["mean"].__setitem__(0, "7ff0000000000000"),
            lambda x: by_name(x, "cycle")["state"].update(phase="holding"),
            lambda x: by_name(x, "cycle")["state"].update(next_sequence=4),
            lambda x: by_name(x, "signal")["state"].update(evaluations_used=4),
        ]
        for mutate in cases:
            broken = copy.deepcopy(state)
            mutate(broken)
            # Recompute transport integrity so the child must validate semantics.
            payload = json.dumps(broken, separators=(",", ":")).encode()
            container = bytearray(saved[:192]+payload)
            struct.pack_into("<I", container, 12, len(container))
            struct.pack_into("<II", container, 112, len(payload), host.crc32c(payload))
            container[120:152] = hashlib.sha256(container[:120]+payload).digest()
            struct.pack_into("<I", container, 188, host.crc32c(container[:188]))
            result = run_host(bytes(container), [], metadata["cursor"])
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn(b"QSSC", result.stdout)


if __name__ == "__main__":
    if "--mode" in sys.argv:
        version = int(sys.argv[sys.argv.index("--config-version")+1]) if "--config-version" in sys.argv else 1
        raise SystemExit(host.main(runtime_factory=lambda raw: runtime_factory(raw, version)))
    unittest.main()
