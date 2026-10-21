"""Portable state checks through the Host checkpoint boundary."""
import copy
import io
import struct
import subprocess
import sys
from pathlib import Path
import unittest

import strategy_host as host


def metadata():
    return dict(schema_registry=host.SCHEMA_REGISTRY, strategy=1, definition=2,
                state_schema=host.CROSS_VENUE_STATE_SCHEMA, state_schema_version=1,
                config_version=1, cursor=10, next_intent=3)


def state():
    # This fixture is an empty, configured instance, not an active trading cycle.
    return dict(
        dependencies=dict(numeric_codec="binary64_bits_v1", algorithm_version=1,
                          config_hash="11" * 32, model_hash="22" * 32,
                          calibration_hash="33" * 32, execution_hash="44" * 32,
                          rules_hash="55" * 32, assets_hash="66" * 32),
        progress=dict(input_identity=10, input_version=1), pairs=[],
        research=dict(tag="disabled"))


def pair(kind="rolling"):
    ref = dict(identity=1, version=1, cursor=0)
    none = dict(tag="none")
    number = lambda value: struct.pack(">d", value).hex()
    model = dict(tag=kind, parameters=ref, warmup="cold", last_input=none,
                 last_grid=0, window=dict(capacity=3, warmup=2, gap=none, observations=[]))
    if kind == "rolling":
        model.update(sum=number(0.), sum_squares=number(0.))
    elif kind == "ar1":
        model.update(phi=number(.5), center=number(0.), last_observation=number(0.))
    else:
        model.update(update_phase="filtered", prior=ref,
                     mean=[number(0.), number(0.)],
                     covariance=[number(1.), number(0.), number(0.), number(1.)])
    return dict(pair_ref=1, first_account=1, first_instrument=1,
                second_account=2, second_instrument=2, direction="long_first",
                cycle=none,
                signal=dict(closure=none, cooldown=none, direction="long_first",
                            score_version=1, last_grid=0, reset_count=0,
                            crossing_count=0, phase="waiting_reset", opportunity=none),
                model=model, monitor=dict(health="normal", reasons=[], recovery_evidence=[],
                                         last_window=none, observed_windows=0, healthy_count=0,
                                         unhealthy_count=0, matured_count=0, missing_count=0),
                predictions=[])


def occupied_pair():
    p = pair("state_space")
    ref = dict(identity=1, version=1, cursor=3)
    none = dict(tag="none")
    present = dict(tag="present", value=ref)
    clock = dict(tag="present", start=ref, clock=ref, utc_start_ns=100,
                 duration_ns=10, utc_deadline_ns=110)
    p["cycle"] = dict(tag="active", group=ref, core_cycle=none,
                      phase="reconciling", before_reconciling="holding",
                      plan=dict(config=ref, model=ref, calibration=ref,
                                original_quantity=dict(instrument=1, rules_version=1, lots=100),
                                mode="maker_taker", reference_profit=dict(asset=1, atoms=10),
                                entry_target=dict(asset=1, atoms=8), alpha_ppm=800_000,
                                absolute_minimum=dict(asset=1, atoms=2), price_target=500,
                                exit_policy=ref,
                                holding_target=dict(tag="frozen", matched=dict(numerator=1, denominator=2),
                                                    value=dict(asset=1, atoms=4), freeze_cursor=8, rule=ref)),
                      intents=[dict(strategy=1, sequence=1, role="hedge", order=present,
                                    observed_terminal=none, observed_fill=present, unknown="yes")],
                      repair_attempts=2, hedge_attempts=1, exit_attempts=0,
                      first_exit=none, first_exit_reason=none,
                      additional_reasons=["unknown"],
                      times=dict(reservation=clock, dispatch=clock, economic_fill=clock,
                                 prediction=clock, holding=clock, exit=none, repair=clock),
                      economic_refs=[ref])
    p["signal"]["opportunity"] = dict(tag="active", strategy=1, pair=1, direction="long_first",
                                        signal_version=1, trigger_sequence=3, deadline=clock,
                                        evaluations=2, evaluation_limit=3, last_evaluation=present,
                                        status="consumed")
    p["monitor"]["health"] = "invalid_latched"
    p["monitor"]["reasons"] = ["model_invalid"]
    p["predictions"] = [dict(identity=1, generated_cursor=3, due_grid=20,
                              horizon_seconds=5, model=ref, calibration=ref,
                              value="3fe0000000000000", lower="0000000000000000",
                              upper="3ff0000000000000", label=dict(tag="pending"))]
    return p


class CheckpointTests(unittest.TestCase):
    def test_host_accepts_versioned_private_state_and_binds_every_field(self):
        original = state()
        container = host.encode_checkpoint(metadata(), original)
        actual_metadata, actual = host.decode_checkpoint(container)
        self.assertEqual(actual_metadata, metadata())
        self.assertEqual(actual, original)
        changed = copy.deepcopy(original)
        changed["dependencies"]["calibration_hash"] = "77" * 32
        self.assertNotEqual(host.state_digest(metadata(), original),
                            host.state_digest(metadata(), changed))

    def test_real_host_returns_private_state_checkpoint_at_requested_cursor(self):
        original = state()
        original["pairs"] = [occupied_pair()]
        container = host.encode_checkpoint(metadata(), original)
        session = (1, 0, 1)
        plan = bytearray(176)
        struct.pack_into("<QI4xQ", plan, 48, *session)
        wire = io.BytesIO()
        host.write_frame(wire, host.SESSION_PLAN, session, 1, plan)
        host.write_frame(wire, host.BEGIN_RECOVERY, session, 2,
                         struct.pack("<Q", 10) + container)
        host.write_frame(wire, 7, session, 3, struct.pack("<QQ", 1, 10))
        host.write_frame(wire, host.SHUTDOWN, session, 4)
        result = subprocess.run([sys.executable, str(Path(host.__file__)), "--mode", "portable",
                                 "--strategy-identity", "1", "--config-version", "1"],
                                input=wire.getvalue(), capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        output = io.BytesIO(result.stdout)
        frames = [host.read_frame(output) for _ in range(5)]
        self.assertEqual([f[0] for f in frames], [101, 106, 102, 108, 107])
        self.assertEqual(frames[3][3][:8], struct.pack("<Q", 1))
        restored_metadata, restored = host.decode_checkpoint(frames[3][3][8:])
        self.assertEqual(restored_metadata, metadata())
        self.assertEqual(restored, original)

    def test_frozen_target_unknown_refs_labels_clock_and_random_material_survive(self):
        original = state()
        original["pairs"] = [occupied_pair()]
        original["research"] = dict(tag="enabled", algorithm_version=1, seed="aa" * 32,
                                     counter=123, evaluation_identity=5, used=2, limit=3)
        restored_metadata, restored = host.decode_checkpoint(host.encode_checkpoint(metadata(), original))
        self.assertEqual(restored, original)
        self.assertEqual(restored_metadata["next_intent"], 3)
        self.assertEqual(restored["pairs"][0]["cycle"]["plan"]["holding_target"]["value"]["atoms"], 4)
        for mutate in (lambda s: s["pairs"][0]["cycle"]["plan"]["holding_target"]["value"].update(atoms=3),
                       lambda s: s["pairs"][0]["cycle"]["times"]["holding"].update(utc_deadline_ns=120),
                       lambda s: s["pairs"][0]["cycle"]["intents"][0].update(sequence=3),
                       lambda s: s["pairs"][0]["cycle"]["plan"].update(holding_target=dict(tag="pending")),
                       lambda s: s["pairs"][0]["cycle"].update(before_reconciling="exiting"),
                       lambda s: s["pairs"][0]["cycle"].update(
                           phase="holding", first_exit=dict(tag="present", value=dict(identity=1, version=1, cursor=9)),
                           first_exit_reason=dict(tag="present", value="deadline"))):
            invalid = copy.deepcopy(original)
            mutate(invalid)
            with self.assertRaises(ValueError):
                host.encode_checkpoint(metadata(), invalid)

    def test_schema_capacity_and_warmup_limits_reject_without_trimming(self):
        original = state()
        original["pairs"] = [occupied_pair()]
        cases = []
        warm = copy.deepcopy(original)
        warm["pairs"][0]["model"]["warmup"] = "ready"
        cases.append(warm)
        labels = copy.deepcopy(original)
        labels["pairs"][0]["predictions"] *= 257
        cases.append(labels)
        window = copy.deepcopy(original)
        window["pairs"][0]["model"]["window"]["capacity"] = 3601
        cases.append(window)
        for invalid in cases:
            before = copy.deepcopy(invalid)
            with self.assertRaises(ValueError):
                host.encode_checkpoint(metadata(), invalid)
            self.assertEqual(invalid, before)
        with self.assertRaises(ValueError):
            host.decode_checkpoint(b"QSSC" + bytes(192 + 8 * 1024 * 1024))

    def test_noncanonical_numeric_and_contradictory_state_never_publish(self):
        cases = []
        for kind in ("rolling", "ar1", "state_space"):
            bad = state()
            bad["pairs"] = [pair(kind)]
            key = {"rolling": "sum", "ar1": "phi", "state_space": "mean"}[kind]
            for bits in ("7ff0000000000000", "7ff8000000000000", "bff000000000000A"):
                variant = copy.deepcopy(bad)
                if key == "mean":
                    variant["pairs"][0]["model"][key][0] = bits
                else:
                    variant["pairs"][0]["model"][key] = bits
                cases.append(variant)
        variant = state()
        variant["pairs"] = [pair("state_space")]
        variant["pairs"][0]["model"]["covariance"][0] = "bff0000000000000"
        cases.append(variant)
        variant = state()
        variant["progress"]["input_identity"] = 11
        cases.append(variant)
        variant = state()
        variant["pairs"] = [pair()] * 17
        cases.append(variant)
        variant = state()
        variant["dependencies"]["balance"] = 100
        cases.append(variant)
        for variant in cases:
            with self.subTest(state=variant), self.assertRaises(ValueError):
                host.encode_checkpoint(metadata(), variant)

    def test_lossless_model_bits_preserve_subnormal_signed_zero_and_integer_identity(self):
        original = state()
        original["pairs"] = [pair("state_space")]
        original["pairs"][0]["pair_ref"] = (1 << 127) + 1
        original["pairs"][0]["model"]["mean"] = ["0000000000000001", "8000000000000000"]
        container = host.encode_checkpoint(metadata(), original)
        self.assertEqual(host.decode_checkpoint(container)[1], original)

    def test_duplicate_keys_float_json_and_byte_damage_rejected(self):
        container = host.encode_checkpoint(metadata(), state())
        for offset in (0, 80, 120, 188, len(container) - 1):
            damaged = bytearray(container)
            damaged[offset] ^= 1
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                host.decode_checkpoint(damaged)
        # Re-sign malformed JSON to test schema checks beyond checksum rejection.
        payload = container[192:]
        variants = [payload.replace(b'"input_identity":10', b'"input_identity":10.0'),
                    payload.replace(b'"input_identity":10', b'"input_identity":10,"input_identity":10'),
                    b' ' + payload]
        import hashlib
        for payload in variants:
            changed = bytearray(container[:192] + payload)
            struct.pack_into("<I", changed, 12, len(changed))
            struct.pack_into("<II", changed, 112, len(payload), host.crc32c(payload))
            changed[120:152] = hashlib.sha256(changed[:120] + payload).digest()
            struct.pack_into("<I", changed, 188, host.crc32c(changed[:188]))
            with self.assertRaises(ValueError):
                host.decode_checkpoint(changed)


if __name__ == "__main__":
    unittest.main()
