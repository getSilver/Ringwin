"""Explicit cross-venue StrategyPrivateState schema; no core economic authority.

Only JSON primitives cross this boundary. There is no object reconstruction,
implicit migration, default insertion, or checkpoint-only numeric rounding.
"""
import json
import math
import re
import struct
from fractions import Fraction

SCHEMA = 0x43565354415445000000000000000001
MAX_PAYLOAD = 8 * 1024 * 1024


def integer(low, high):
    def validate(value):
        if type(value) is not int or not low <= value <= high:
            raise ValueError("integer range")
    return validate


def choice(*values):
    def validate(value):
        if type(value) is not str or value not in values:
            raise ValueError("unknown tag")
    return validate


def hexadecimal(length):
    def validate(value):
        if type(value) is not str or re.fullmatch("[0-9a-f]{%d}" % length, value) is None:
            raise ValueError("non-canonical hex")
    return validate


def record(**fields):
    def validate(value):
        if type(value) is not dict or list(value) != list(fields):
            raise ValueError("unknown, missing, or unordered field")
        for name, check in fields.items():
            check(value[name])
    return validate


def array(item, capacity):
    def validate(value):
        if type(value) is not list or len(value) > capacity:
            raise ValueError("array capacity")
        for element in value:
            item(element)
    return validate


def tagged(**variants):
    def validate(value):
        if type(value) is not dict or type(value.get("tag")) is not str or value["tag"] not in variants:
            raise ValueError("unknown tag")
        variants[value["tag"]](value)
    return validate


u32 = integer(0, (1 << 32) - 1)
u64 = integer(0, (1 << 64) - 1)
identity = integer(1, (1 << 128) - 1)
positive64 = integer(1, (1 << 64) - 1)
atoms = integer(-(1 << 127), (1 << 127) - 1)
positive_atoms = integer(1, (1 << 127) - 1)
ppm = integer(0, 1_000_000)
digest = hexadecimal(64)
reference = record(identity=identity, version=positive64, cursor=u64)
maybe_ref = tagged(none=record(tag=choice("none")),
                   present=record(tag=choice("present"), value=reference))
money = record(asset=identity, atoms=atoms)
quantity = record(instrument=identity, rules_version=positive64, lots=positive_atoms)
direction = choice("long_first", "short_first")
reason = choice("profit", "deadline", "risk", "model_invalid", "reconciliation",
                "repair_failed", "unknown", "manual", "data_gap", "fee_invalid",
                "margin", "loss_limit", "drawdown", "capacity", "clock", "disabled")
phase = choice("idle", "reserving", "entering", "repairing", "holding", "exiting",
               "reconciling", "completed")


def encode_number(value):
    if type(value) is not float or not math.isfinite(value):
        raise ValueError("non-finite binary64")
    return struct.pack(">d", value).hex()


def decode_number(value):
    hexadecimal(16)(value)
    result = struct.unpack(">d", bytes.fromhex(value))[0]
    if not math.isfinite(result):
        raise ValueError("non-finite binary64")
    return result


def number(value):
    decode_number(value)


def rational(value):
    record(numerator=atoms, denominator=identity)(value)
    if math.gcd(value["numerator"], value["denominator"]) != 1:
        raise ValueError("non-canonical rational")


observation = record(grid=u64, cursor=u64, value=number)
window = record(capacity=integer(1, 3600), warmup=integer(1, 3600),
                gap=maybe_ref, observations=array(observation, 3600))
model_common = dict(parameters=reference, warmup=choice("cold", "warming", "ready"),
                    last_input=maybe_ref, last_grid=u64, window=window)
model = tagged(
    rolling=record(tag=choice("rolling"), **model_common, sum=number, sum_squares=number),
    ar1=record(tag=choice("ar1"), **model_common, phi=number, center=number,
               last_observation=number),
    state_space=record(tag=choice("state_space"), **model_common,
                       update_phase=choice("filtered"), prior=reference,
                       mean=array(number, 2), covariance=array(number, 4)))
target = tagged(
    pending=record(tag=choice("pending")),
    frozen=record(tag=choice("frozen"), matched=rational, value=money,
                  freeze_cursor=u64, rule=reference))
plan = record(config=reference, model=reference, calibration=reference,
              original_quantity=quantity, mode=choice("taker_taker", "maker_taker"),
              reference_profit=money, entry_target=money, alpha_ppm=integer(1, 1_000_000),
              absolute_minimum=money, price_target=atoms, exit_policy=reference,
              holding_target=target)
intent_ref = record(strategy=identity, sequence=positive64,
                    role=choice("entry", "replacement", "hedge", "repair", "exit"),
                    order=maybe_ref, observed_terminal=maybe_ref,
                    observed_fill=maybe_ref, unknown=choice("yes", "no"))
deadline = tagged(none=record(tag=choice("none")),
                  present=record(tag=choice("present"), start=reference,
                                 clock=reference, utc_start_ns=u64,
                                 duration_ns=positive64, utc_deadline_ns=u64))
time_state = record(reservation=deadline, dispatch=deadline, economic_fill=deadline,
                    prediction=deadline, holding=deadline, exit=deadline, repair=deadline)
opportunity = tagged(
    none=record(tag=choice("none")),
    active=record(tag=choice("active"), strategy=identity, pair=identity,
                  direction=direction, signal_version=positive64,
                  trigger_sequence=positive64, deadline=deadline,
                  evaluations=u32, evaluation_limit=u32, last_evaluation=maybe_ref,
                  status=choice("available", "request_pending", "consumed", "expired")))
signal = record(closure=maybe_ref, cooldown=deadline, direction=direction,
                score_version=positive64, last_grid=u64, reset_count=u32,
                crossing_count=u32, phase=choice("waiting_reset", "armed", "triggered", "cooldown"),
                opportunity=opportunity)
label_state = tagged(pending=record(tag=choice("pending")),
                     missing=record(tag=choice("missing"), evidence=reference),
                     mature=record(tag=choice("mature"), evidence=reference, value=number))
prediction = record(identity=identity, generated_cursor=u64, due_grid=u64,
                    horizon_seconds=positive64, model=reference, calibration=reference,
                    value=number, lower=number, upper=number, label=label_state)
monitor = record(health=choice("normal", "warning", "invalid_latched"),
                 reasons=array(reason, 16), recovery_evidence=array(reference, 16),
                 last_window=maybe_ref, observed_windows=u64, healthy_count=u32,
                 unhealthy_count=u32, matured_count=u64, missing_count=u64)
cycle = tagged(
    none=record(tag=choice("none")),
    active=record(tag=choice("active"), group=reference, core_cycle=maybe_ref,
                  phase=phase, before_reconciling=phase, plan=plan,
                  intents=array(intent_ref, 64), repair_attempts=u32,
                  hedge_attempts=u32, exit_attempts=u32, first_exit=maybe_ref,
                  first_exit_reason=tagged(none=record(tag=choice("none")),
                                          present=record(tag=choice("present"), value=reason)),
                  additional_reasons=array(reason, 16), times=time_state,
                  economic_refs=array(reference, 64)))
pair = record(pair_ref=identity, first_account=identity, first_instrument=identity,
              second_account=identity, second_instrument=identity, direction=direction,
              cycle=cycle, signal=signal, model=model, monitor=monitor,
              predictions=array(prediction, 256))
root = record(
    dependencies=record(numeric_codec=choice("binary64_bits_v1"), algorithm_version=positive64,
                        config_hash=digest, model_hash=digest, calibration_hash=digest,
                        execution_hash=digest, rules_hash=digest, assets_hash=digest),
    progress=record(input_identity=u64, input_version=positive64),
    pairs=array(pair, 16),
    research=tagged(disabled=record(tag=choice("disabled")),
                    enabled=record(tag=choice("enabled"), algorithm_version=positive64,
                                   seed=hexadecimal(64), counter=u64,
                                   evaluation_identity=identity, used=u32, limit=u32)))


def ordered_unique(values):
    if any(a >= b for a, b in zip(values, values[1:])):
        raise ValueError("duplicate or unordered identity")


def validate(state, cursor, strategy=None, next_intent=None):
    root(state)
    ordered_unique([p["pair_ref"] for p in state["pairs"]])
    if state["progress"]["input_identity"] > cursor:
        raise ValueError("future input progress")
    for p in state["pairs"]:
        m = p["model"]
        w = m["window"]
        points = w["observations"]
        if w["warmup"] > w["capacity"] or len(points) > w["capacity"]:
            raise ValueError("window capacity")
        ordered_unique([o["grid"] for o in points])
        ordered_unique([o["cursor"] for o in points])
        if points and (points[-1]["grid"] != m["last_grid"] or points[-1]["cursor"] > cursor):
            raise ValueError("window progress mismatch")
        if m["warmup"] == "ready" and len(points) < w["warmup"]:
            raise ValueError("incomplete warmup")
        if m["tag"] == "rolling" and decode_number(m["sum_squares"]) < 0:
            raise ValueError("negative sum of squares")
        if m["tag"] == "ar1" and not 0 < decode_number(m["phi"]) < 1:
            raise ValueError("invalid AR1 coefficient")
        if m["tag"] == "state_space":
            if len(m["mean"]) != 2 or len(m["covariance"]) != 4:
                raise ValueError("matrix dimensions")
            a, b, c, d = [Fraction.from_float(decode_number(v)) for v in m["covariance"]]
            if a < 0 or d < 0 or b != c or a * d < b * c:
                raise ValueError("invalid covariance")
        predictions = p["predictions"]
        ordered_unique([(v["generated_cursor"], v["identity"]) for v in predictions])
        if len({v["identity"] for v in predictions}) != len(predictions):
            raise ValueError("duplicate prediction")
        for v in predictions:
            if v["generated_cursor"] > cursor or not (
                decode_number(v["lower"]) <= decode_number(v["value"]) <= decode_number(v["upper"])):
                raise ValueError("invalid prediction")
        s = p["signal"]
        o = s["opportunity"]
        if o["tag"] == "active" and (o["pair"] != p["pair_ref"] or
                o["direction"] != p["direction"] or o["trigger_sequence"] > cursor or
                o["evaluations"] > o["evaluation_limit"] or o["deadline"]["tag"] != "present" or
                (strategy is not None and o["strategy"] != strategy)):
            raise ValueError("invalid opportunity")
        c = p["cycle"]
        if c["tag"] == "active":
            plan_state = c["plan"]
            holding = plan_state["holding_target"]
            if (c["phase"] == "holding" or
                    (c["phase"] == "reconciling" and c["before_reconciling"] == "holding")) and holding["tag"] != "frozen":
                raise ValueError("holding target not frozen")
            if holding["tag"] == "frozen" and (holding["freeze_cursor"] > cursor or
                    holding["matched"]["numerator"] < 0 or
                    holding["matched"]["numerator"] > holding["matched"]["denominator"]):
                raise ValueError("invalid target evidence")
            assets = [plan_state[k]["asset"] for k in ("reference_profit", "entry_target", "absolute_minimum")]
            if len(set(assets)) != 1 or plan_state["entry_target"]["atoms"] <= 0 or plan_state["absolute_minimum"]["atoms"] <= 0:
                raise ValueError("target units")
            if holding["tag"] == "frozen" and (holding["value"]["asset"] != assets[0] or holding["value"]["atoms"] <= 0):
                raise ValueError("holding target units")
            minimum = plan_state["absolute_minimum"]["atoms"]
            reference_target = -(-(plan_state["reference_profit"]["atoms"] * plan_state["alpha_ppm"]) // 1_000_000)
            if plan_state["entry_target"]["atoms"] != max(minimum, reference_target):
                raise ValueError("entry target formula")
            if holding["tag"] == "frozen":
                ratio = holding["matched"]
                target_atoms = -(-(ratio["numerator"] * plan_state["entry_target"]["atoms"]) // ratio["denominator"])
                if holding["value"]["atoms"] != max(minimum, target_atoms):
                    raise ValueError("holding target formula")
            if (c["first_exit"]["tag"] == "none") != (c["first_exit_reason"]["tag"] == "none"):
                raise ValueError("exit evidence mismatch")
            if (c["phase"] == "exiting" or
                    (c["phase"] == "reconciling" and c["before_reconciling"] == "exiting")) and c["first_exit"]["tag"] == "none":
                raise ValueError("missing exit evidence")
            if c["first_exit"]["tag"] == "present" and not (
                    c["phase"] in ("exiting", "completed") or
                    (c["phase"] == "reconciling" and c["before_reconciling"] == "exiting")):
                raise ValueError("exit state regressed")
            ordered_unique([(i["strategy"], i["sequence"]) for i in c["intents"]])
            if any((strategy is not None and i["strategy"] != strategy) or
                   (next_intent is not None and i["sequence"] >= next_intent)
                   for i in c["intents"]):
                raise ValueError("intent progress mismatch")
            if c["phase"] == "completed" and any(i["unknown"] == "yes" for i in c["intents"]):
                raise ValueError("completed with unknown order")
        for reasons in (p["monitor"]["reasons"], c.get("additional_reasons", [])):
            ordered_unique(reasons)
        if (p["monitor"]["health"] == "normal") != (len(p["monitor"]["reasons"]) == 0):
            raise ValueError("monitor health reasons mismatch")
    r = state["research"]
    if r["tag"] == "enabled" and r["used"] > r["limit"]:
        raise ValueError("research budget")
    # Walk only the already schema-bounded object, checking all evidence refs
    # and clock arithmetic, including nested labels, deadlines and freeze refs.
    def evidence(value):
        if type(value) is dict:
            if list(value) == ["identity", "version", "cursor"] and value["cursor"] > cursor:
                raise ValueError("future evidence")
            if list(value) == ["tag", "start", "clock", "utc_start_ns", "duration_ns", "utc_deadline_ns"]:
                if value["utc_start_ns"] + value["duration_ns"] != value["utc_deadline_ns"]:
                    raise ValueError("deadline arithmetic")
            for nested in value.values():
                evidence(nested)
        elif type(value) is list:
            for nested in value:
                evidence(nested)
    evidence(state)


def encode(state, cursor, strategy=None, next_intent=None):
    validate(state, cursor, strategy, next_intent)
    payload = json.dumps(state, ensure_ascii=True, separators=(",", ":"), allow_nan=False).encode("ascii")
    if len(payload) > MAX_PAYLOAD:
        raise ValueError("state capacity")
    return payload


def parse_integer(token):
    # The largest declared integer is u128 (39 decimal digits). Bound parsing
    # before Python constructs a potentially enormous arbitrary-precision int.
    if len(token) > (40 if token.startswith("-") else 39):
        raise ValueError("integer token capacity")
    return int(token)


def decode(payload, cursor, strategy=None, next_intent=None):
    if len(payload) > MAX_PAYLOAD:
        raise ValueError("state capacity")
    def pairs(values):
        result = {}
        for key, value in values:
            if key in result:
                raise ValueError("duplicate field")
            result[key] = value
        return result
    def reject(_):
        raise ValueError("floating JSON forbidden")
    try:
        state = json.loads(payload, object_pairs_hook=pairs, parse_int=parse_integer,
                           parse_float=reject, parse_constant=reject)
        if encode(state, cursor, strategy, next_intent) != payload:
            raise ValueError("non-canonical state")
    except (RecursionError, UnicodeError, OverflowError, TypeError) as error:
        raise ValueError("invalid portable state") from error
    return state
