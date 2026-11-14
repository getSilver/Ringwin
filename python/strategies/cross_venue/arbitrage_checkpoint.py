"""V2 checkpoints of the actual strategy components, with frozen dependencies.

Templates supply authenticated immutable configuration, never mutable progress.
Core projections are represented by content digests; they cannot restore money,
orders or permissions. V1's illustrative schema remains a separate version.
"""
from collections import deque
from dataclasses import fields, is_dataclass
from fractions import Fraction
import copy
import hashlib
import json

from strategies.cross_venue import arbitrage_baseline as b
from strategies.cross_venue import arbitrage_state_space as ss
from strategies.cross_venue import arbitrage_signals as signals
from strategies.cross_venue import arbitrage_admission as admission
from strategies.cross_venue import arbitrage_cycle as cycle
from strategies.cross_venue import arbitrage_maker as maker
from strategies.cross_venue import arbitrage_evaluation as evaluation
from strategies.cross_venue import arbitrage_probability as probability
import strategy_state as s


def content(value):
    """Hash frozen dependencies/input caches without putting them in checkpoints."""
    def tree(v):
        if is_dataclass(v):
            return [type(v).__module__, type(v).__name__, [[f.name, tree(getattr(v, f.name))] for f in fields(v)
                if not (isinstance(v, b.InstrumentRules) and f.name == "approved_base_pair" and v.approved_base_pair is None)]]
        if type(v) is float:
            return ["binary64_bits_v1", s.encode_number(v)]
        if type(v) is Fraction:
            return ["rational", v.numerator, v.denominator]
        if type(v) is bytes:
            return ["bytes", v.hex()]
        if type(v) in (tuple, list):
            return [tree(x) for x in v]
        if type(v) is dict:
            return [[tree(k), tree(v[k])] for k in sorted(v)]
        if v is None or type(v) in (bool, int, str):
            return v
        raise ValueError("unsupported dependency")
    return hashlib.sha256(json.dumps(tree(value), separators=(",", ":"), allow_nan=False).encode()).hexdigest()


def scalar(check):
    def checked(value):
        check(value)
        return value
    return checked, checked


U = scalar(s.u64)
I = scalar(s.positive64)
H = scalar(s.digest)


def text(value):
    if type(value) is not str or len(value) > 128:
        raise ValueError("text capacity")


S = scalar(text)
def boolean(value):
    if type(value) is not bool:
        raise ValueError("boolean")
B = scalar(boolean)
N = (lambda v: s.encode_number(b.finite(v)), s.decode_number)


def exact_encode(value):
    value = Fraction(value)
    result = dict(numerator=value.numerator, denominator=value.denominator)
    s.rational(result)
    return result


def exact_decode(value):
    s.rational(value)
    return Fraction(value["numerator"], value["denominator"])


Q = exact_encode, exact_decode


def optional(codec):
    def encode(v):
        return dict(tag="none") if v is None else dict(tag="present", value=codec[0](v))
    def decode(v):
        if type(v) is not dict:
            raise ValueError("optional shape")
        if list(v) == ["tag"] and v["tag"] == "none":
            return None
        if list(v) == ["tag", "value"] and v["tag"] == "present":
            return codec[1](v["value"])
        raise ValueError("optional tag")
    return encode, decode


def sequence(codec, capacity):
    def encode(v):
        if type(v) not in (tuple, list, deque) or len(v) > capacity:
            raise ValueError("sequence capacity")
        return [codec[0](x) for x in v]
    def decode(v):
        if type(v) is not list or len(v) > capacity:
            raise ValueError("sequence capacity")
        return tuple(codec[1](x) for x in v)
    return encode, decode


def structure(spec, cls=None):
    def encode(v):
        return {name: codec[0](getattr(v, name) if cls else v[name]) for name, codec in spec.items()}
    def decode(v):
        if type(v) is not dict or list(v) != list(spec):
            raise ValueError("unknown, missing, or unordered component field")
        values = {name: codec[1](v[name]) for name, codec in spec.items()}
        return cls(**values) if cls else values
    return encode, decode


def mapping(codec, capacity=64):
    pair = structure(dict(key=S, value=codec))
    rows = sequence(pair, capacity)
    def encode(v):
        return rows[0]([dict(key=k, value=v[k]) for k in sorted(v)])
    def decode(v):
        values = rows[1](v)
        s.ordered_unique([x["key"] for x in values])
        return {x["key"]: x["value"] for x in values}
    return encode, decode


POINT = structure(dict(grid_ns=U, cursor=I, value=optional(N), reason=S,
                       break_before=B, evidence=sequence(scalar(s.integer(0, (1 << 128)-1)), 16)), b.Point)
PREDICTION = structure(dict(model_kind=S, model_version=I, model_hash=H, source=POINT,
    horizon_seconds=I, direction=scalar(s.integer(-1, 1)), mean=N, variance=N,
    half_life_seconds=optional(N)), b.Prediction)
FILTER = structure(dict(mean=sequence(N, 2), covariance=sequence(N, 4), source=optional(POINT),
    count=U, reason=S, innovation=optional(N), innovation_variance=optional(N),
    log_likelihood=optional(N)), ss.FilterState)
INTENT = structure(dict(sequence=I, leg=scalar(s.integer(0, 1)), lots=I,
    limit_ticks=I, reducing=B), cycle.Intent)
WINDOW = structure(dict(metric=S, sequence=I, cutoff_ns=U, value=optional(Q),
    effective_samples=U, mature=B), signals.Window)
# Request is a strategy recommendation and identity; it carries no reservation.
KEY = sequence(sequence(scalar(s.identity), 3), 2)
def key_encode(v):
    pair, direction, mode, maker = v
    return dict(pair=KEY[0](pair), direction=direction, mode=mode,
                maker=optional(scalar(s.integer(0, 1)))[0](maker))
def key_decode(v):
    s.record(pair=s.array(s.array(s.identity, 3), 2), direction=s.integer(-1, 1),
             mode=s.choice("taker_taker", "maker_taker"), maker=lambda x: optional(U)[1](x))(v)
    pair = KEY[1](v["pair"])
    maker = optional(U)[1](v["maker"])
    if len(pair) != 2 or any(len(x) != 3 for x in pair) or pair[0] >= pair[1] or v["direction"] == 0:
        raise ValueError("request pair")
    if not ((v["mode"] == "taker_taker" and maker is None) or
            (v["mode"] == "maker_taker" and maker in (0, 1))):
        raise ValueError("request mode")
    return pair, v["direction"], v["mode"], maker
REQUEST = structure(dict(identity=H, scope=H, key=(key_encode, key_decode), lots=sequence(I, 2),
    plan_atoms=scalar(s.atoms), target_atoms=I, config_hash=H, cursor=I, fact_ref=S,
    scenario_digest=H, estimator_digest=H, valid_until_ns=U, score=Q), admission.Request)
OPPORTUNITY_KEY = sequence(scalar(s.integer(-1, (1 << 128)-1)), 5)

SPECS = {
    "rolling": dict(_points=sequence(POINT, b.MAX_WINDOW), _last=optional(POINT)),
    "ar1": {},
    "rolling_baseline": {},
    "estimator": {},
    "calibration": {},
    "filter": dict(_state=FILTER),
    "labels": dict(_pending=sequence(PREDICTION, b.MAX_PENDING), _last=optional(POINT)),
    "signal": dict(last_grid=optional(U), last_at_ns=optional(U), previous=optional(Q),
        reset_count=U, entry_count=U, armed=B, opportunity=optional(H), deadline_ns=optional(U),
        last_evaluation_ns=optional(U), evaluations_used=U, pending=optional(S), active=optional(S),
        closed_cycle=optional(S), cooldown_until_ns=U, reasons=mapping(S, 16),
        activation_ref=optional(S), enabled_at_ns=U, trigger_ns=optional(U),
        trigger_cursor=optional(U), trigger_grid=optional(U), opportunity_key=optional(OPPORTUNITY_KEY),
        last_cursor=optional(U), last_input_hash=optional(H)),
    "monitor": dict(state=scalar(s.choice("Normal", "Warning", "InvalidLatched")), qualified=B,
        sequences=mapping(U), counts=mapping(sequence(U, 2)), good_windows=U,
        last_at_ns=optional(U), windows=mapping(WINDOW)),
    "admission": dict(pending=optional(REQUEST), pending_scope=optional(S), rounds=U,
        after_cursor=U, last_time_ns=U, started_at_ns=optional(U),
        evaluated=sequence(structure(dict(scope=S, opportunity=H, revision=U)), 256),
        reservation_revision=U),
    "cycle": dict(phase=scalar(s.choice("idle", "entering", "repairing", "holding", "exiting",
        "reconciling", "settling", "completed")), next_sequence=I, pending=sequence(I, 256),
        issued=sequence(INTENT, 256), cursor=U, last_at_ns=U, cycle_ref=optional(S),
        reservation_ref=optional(S), repair_used=U, exit_used=U, target_atoms=optional(I),
        target_cursor=optional(U), first_exit=optional(structure(dict(reason=S, cursor=U))),
        reasons=mapping(S, 16), before_reconciling=optional(S), last_economic_ref=optional(S),
        last_facts_digest=optional(H), matched_base=optional(Q), entry_cursor=optional(U),
        entry_valid_until_ns=optional(U)),
}
# A separate component tag preserves the existing IOC v2 intent encoding.
SPECS["maker_cycle"] = dict(SPECS["cycle"],
    issued=sequence(structure(dict(sequence=I, leg=scalar(s.integer(0, 1)), lots=I,
        limit_ticks=I, reducing=B, time_in_force=scalar(s.choice("ioc", "post-only"))), cycle.Intent), 256),
    maker_sequence=optional(I), quote_started_ns=optional(U), last_quote_ns=optional(U),
    requotes_used=U, quote_score=optional(scalar(s.atoms)), cancel_requested=B,
    replacing=B, tail_started_ns=optional(U), entry_finished=B)
TYPES = {b.RollingWindow: "rolling", b.AR1: "ar1", b.RollingBaseline: "rolling_baseline",
         evaluation.Estimator: "estimator", probability.Calibration: "calibration",
         ss.Filter: "filter", b.LabelTracker: "labels", signals.Signal: "signal",
         signals.Monitor: "monitor", admission.Admission: "admission", cycle.Cycle: "cycle", maker.Cycle: "maker_cycle"}
CONFIG_FIELDS = {
    "rolling": {"spec"}, "ar1": set(), "rolling_baseline": set(), "filter": {"parameters"},
    "labels": {"capacity"}, "signal": {"scope", "policy", "identity"},
    "monitor": {"metrics", "warn_windows", "fail_windows", "clear_windows"},
    "admission": {"config", "pending_signal"}, "cycle": {"plan"},
    "estimator": set(), "calibration": set(), "maker_cycle": {"plan"},
}


def dependency(obj):
    if type(obj) is b.RollingWindow:
        return obj.spec
    if type(obj) in (b.AR1, b.RollingBaseline, evaluation.Estimator, probability.Calibration):
        return obj
    if type(obj) is ss.Filter:
        return obj.parameters
    if type(obj) is b.LabelTracker:
        return obj.capacity
    if type(obj) is signals.Signal:
        return obj.scope, obj.policy, obj.identity
    if type(obj) is signals.Monitor:
        return obj.metrics, obj.warn_windows, obj.fail_windows, obj.clear_windows
    if type(obj) is admission.Admission:
        return obj.config
    if type(obj) in (cycle.Cycle, maker.Cycle):
        return obj.plan
    raise ValueError("unknown component")


def progress(obj, tag):
    if SPECS[tag]:
        stored = set(SPECS[tag]) | CONFIG_FIELDS[tag]
        if tag == "admission":
            stored.remove("pending_scope")
        if set(vars(obj))-stored:
            raise ValueError("unversioned component field")
        required = set(SPECS[tag])
        if tag == "admission":
            required.remove("pending_scope")
        if tag in ("cycle", "maker_cycle"):
            required -= {"entry_cursor", "entry_valid_until_ns"}
        if required-set(vars(obj)):
            raise ValueError("missing component field")
    values = {name: getattr(obj, name, None) for name in SPECS[tag]}
    if tag == "admission":
        values["pending_scope"] = obj.pending_signal.scope if obj.pending_signal is not None else None
        values["evaluated"] = [dict(scope=k[0], opportunity=k[1], revision=v)
                               for k, v in sorted(obj.evaluated.items())]
    if tag in ("cycle", "maker_cycle") and obj.first_exit is not None:
        values["first_exit"] = dict(reason=obj.first_exit[0], cursor=obj.first_exit[1])
    return structure(SPECS[tag])[0](values)


def validate(state, cursor, strategy=None, next_intent=None):
    s.record(numeric_codec=s.choice("binary64_bits_v1"), algorithm_version=s.choice("strategy_components_v2"),
        model_algorithms=s.record(baseline=s.choice(b.ALGORITHM), state_space=s.choice(ss.ALGORITHM)),
        components=s.array(lambda v: None, 64))(state)
    for row in state["components"]:
        s.record(name=text, tag=s.choice(*SPECS), dependency=s.digest,
                 state=lambda v: None)(row)
    s.ordered_unique([x["name"] for x in state["components"]])
    for row in state["components"]:
        tag = row["tag"]
        values = structure(SPECS[tag])[1](row["state"])
        if tag == "rolling":
            b.ordered_points(values["_points"])
            if values["_points"] and values["_points"][-1] != values["_last"]:
                raise ValueError("window last point")
        if tag == "filter":
            f = values["_state"]
            if len(f.mean) != 2 or len(f.covariance) != 4:
                raise ValueError("filter dimensions")
            ss._covariance(f.covariance, 0., strict=True)
            if (f.source is None or f.source.value is None) and f.count != 0:
                raise ValueError("filter count")
            if f.innovation_variance is not None and f.innovation_variance <= 0:
                raise ValueError("filter variance")
        if tag == "labels":
            pending = values["_pending"]
            if len({p.identity for p in pending}) != len(pending):
                raise ValueError("duplicate pending prediction")
            last = values["_last"]
            if last is not None and any(p.due_ns <= last.grid_ns for p in pending):
                raise ValueError("already mature prediction")
        if tag == "signal":
            if (values["last_grid"] is None) != (values["last_at_ns"] is None):
                raise ValueError("signal progress")
            if values["trigger_cursor"] is not None and values["trigger_cursor"] > cursor:
                raise ValueError("future trigger")
            if values["last_cursor"] is not None and values["last_cursor"] > cursor:
                raise ValueError("future signal input")
            key = values["opportunity_key"]
            if key is not None and (len(key) != 5 or not 0 < key[0] < 1 << 128 or not 0 < key[1] < 1 << 128
                    or key[2] not in (-1, 1) or not 0 < key[3] < 1 << 64 or key[4] != values["trigger_cursor"]
                    or (strategy is not None and key[0] != strategy)):
                raise ValueError("opportunity semantic tuple")
            if values["opportunity"] is not None and (values["trigger_cursor"] is None or
                    values["trigger_grid"] is None or values["deadline_ns"] is None or
                    values["trigger_ns"] is None or not values["armed"]):
                raise ValueError("missing opportunity evidence")
            if values["pending"] is not None and values["active"] is not None:
                raise ValueError("pending and active signal")
        if tag == "monitor":
            if values["sequences"].keys() != values["counts"].keys() or any(len(x) != 2 for x in values["counts"].values()):
                raise ValueError("monitor scope")
            if any(name not in values["sequences"] or w.metric != name or w.sequence != values["sequences"][name]
                   for name, w in values["windows"].items()):
                raise ValueError("monitor window identity")
        if tag == "admission":
            req = values["pending"]
            if (req is None) != (values["pending_scope"] is None):
                raise ValueError("pending request association")
            if req is not None and (req.scope != values["pending_scope"] or req.cursor > cursor or len(req.lots) != 2):
                raise ValueError("pending request progress")
            if values["after_cursor"] > cursor:
                raise ValueError("future admission cursor")
            keys = [(x["scope"], x["opportunity"] or "") for x in values["evaluated"]]
            s.ordered_unique(keys)
            if any(x["revision"] > values["reservation_revision"] for x in values["evaluated"]):
                raise ValueError("future reservation revision")
        if tag in ("cycle", "maker_cycle"):
            intents = values["issued"]
            seqs = tuple(x.sequence for x in intents)
            if seqs and (seqs != tuple(range(seqs[0], values["next_sequence"])) or
                         any(x >= 1 << 63 for i in intents for x in (i.lots, i.limit_ticks))):
                raise ValueError("intent continuity")
            if (not set(values["pending"]) <= set(seqs) or len(set(values["pending"])) != len(values["pending"])):
                raise ValueError("pending intents")
            if values["cursor"] > cursor or (next_intent is not None and values["next_sequence"] != next_intent):
                raise ValueError("cycle progress")
            if values["phase"] == "idle" and (intents or values["pending"] or values["cycle_ref"] is not None):
                raise ValueError("idle cycle progress")
            if values["cursor"] and not intents:
                raise ValueError("missing cycle intents")
            if (values["last_facts_digest"] is None) != (values["last_economic_ref"] is None):
                raise ValueError("input evidence")
            if (values["phase"] == "holding" or values["before_reconciling"] == "holding") and values["target_atoms"] is None:
                raise ValueError("holding target")
            if (values["target_atoms"] is None) != (values["target_cursor"] is None) or (values["target_atoms"] is None) != (values["matched_base"] is None):
                raise ValueError("target evidence")
            before = values["before_reconciling"]
            if (values["phase"] == "reconciling") != (before is not None) or before not in (None, "entering", "repairing", "holding", "exiting", "settling", "completed"):
                raise ValueError("reconciling phase")
            if values["first_exit"] is not None and values["phase"] in ("idle", "entering", "holding"):
                raise ValueError("exit regressed")
            if values["first_exit"] is not None and values["phase"] == "reconciling" and before not in ("exiting", "settling", "completed"):
                raise ValueError("reconciling exit regressed")
            if (values["phase"] == "exiting" or before == "exiting") and values["first_exit"] is None:
                raise ValueError("exit evidence")
            if values["target_cursor"] is not None and values["target_cursor"] > values["cursor"]:
                raise ValueError("future target cursor")
            if values["first_exit"] is not None and values["first_exit"]["cursor"] > values["cursor"]:
                raise ValueError("future exit cursor")
        def evidence(v):
            if isinstance(v, b.Point) and v.cursor > cursor:
                raise ValueError("future observation")
            if is_dataclass(v):
                for f in fields(v):
                    evidence(getattr(v, f.name))
            elif type(v) is dict:
                for x in v.values():
                    evidence(x)
            elif type(v) in (list, tuple):
                for x in v:
                    evidence(x)
        evidence(values)


def snapshot(components, cursor, strategy=None, next_intent=None):
    state = dict(numeric_codec="binary64_bits_v1", algorithm_version="strategy_components_v2",
                 model_algorithms=dict(baseline=b.ALGORITHM, state_space=ss.ALGORITHM), components=[])
    for name in sorted(components):
        obj = components[name]
        tag = TYPES.get(type(obj))
        if tag is None:
            raise ValueError("unknown component")
        state["components"].append(dict(name=name, tag=tag, dependency=content(dependency(obj)), state=progress(obj, tag)))
    validate(state, cursor, strategy, next_intent)
    return state


def validate_configured(obj, tag, values, metadata):
    """Cross-check restored progress against the exact authenticated dependency."""
    cursor = metadata["cursor"]
    if tag == "rolling":
        points, last = values["_points"], values["_last"]
        if len(points) > obj.spec.capacity or any(z.grid_ns-a.grid_ns != b.SECOND or z.break_before
                                                 for a, z in zip(points, points[1:])):
            raise ValueError("window continuity or capacity")
        if any(p.value is None for p in points) or (last is not None and last.value is None and points):
            raise ValueError("invalid window point")
    if tag == "filter":
        f, p = values["_state"], obj.parameters
        if f.source is None or f.source.value is None:
            if (f.mean, f.covariance) != (p.prior_mean, p.prior_covariance) or any(
                    x is not None for x in (f.innovation, f.innovation_variance, f.log_likelihood)):
                raise ValueError("filter reset state")
        elif f.count == 0 or any(x is None for x in (f.innovation, f.innovation_variance, f.log_likelihood)):
            raise ValueError("filter update phase")
        else:
            reason = ("warming" if f.count < p.warmup else "covariance_limit"
                      if b.sum_finite((f.covariance[0], f.covariance[3])) > p.max_covariance else "")
            if f.reason != reason:
                raise ValueError("filter qualification")
    if tag == "labels":
        if len(values["_pending"]) > obj.capacity:
            raise ValueError("label capacity")
    if tag == "signal":
        p = obj.policy
        if obj.identity is not None and obj.identity[0] != metadata["strategy"]:
            raise ValueError("signal strategy identity")
        if values["evaluations_used"] > p.max_evaluations:
            raise ValueError("evaluation budget")
        if values["reset_count"] > p.reset_points or values["entry_count"] > p.entry_points:
            raise ValueError("signal counters")
        if values["trigger_grid"] is not None and (values["trigger_cursor"] is None or values["opportunity_key"] is None):
            raise ValueError("legacy offline trigger has no semantic identity")
        if values["opportunity"] is not None:
            key = (*obj.identity, p.version, values["trigger_cursor"]) if obj.identity is not None else None
            expected = b.fingerprint("opportunity", key)
            if values["opportunity_key"] != key:
                raise ValueError("opportunity scope")
            if values["opportunity"] != expected or values["deadline_ns"] != values["trigger_ns"]+p.opportunity_ttl_ns:
                raise ValueError("opportunity identity or deadline")
        if values["last_evaluation_ns"] is not None and (values["trigger_ns"] is None or
                not values["trigger_ns"] <= values["last_evaluation_ns"] < values["deadline_ns"]):
            raise ValueError("evaluation time")
    if tag == "monitor":
        if values["sequences"].keys() != obj.metrics.keys() or any(
            (sequence > 0) != (name in values["windows"]) for name, sequence in values["sequences"].items()):
            raise ValueError("monitor metric scope")
        if any(values["last_at_ns"] is None or w.cutoff_ns > values["last_at_ns"] for w in values["windows"].values()):
            raise ValueError("future monitoring window")
        valid = len(values["windows"]) == len(obj.metrics) and all(
            w.mature and w.value is not None and w.effective_samples >= obj.metrics[name].min_samples
            and values["last_at_ns"]-w.cutoff_ns < obj.metrics[name].freshness_ns
            for name, w in values["windows"].items())
        if values["qualified"] and not valid:
            raise ValueError("monitor qualification evidence")
        if values["good_windows"] and (not values["qualified"] or any(
                w.value > obj.metrics[name].clear for name, w in values["windows"].items())):
            raise ValueError("monitor healthy evidence")
        if values["good_windows"] > min(values["sequences"].values()) or any(
                count > values["sequences"][name] for name, counts in values["counts"].items() for count in counts):
            raise ValueError("monitor count progress")
        if values["state"] != "InvalidLatched" and any(f >= obj.fail_windows for _, f in values["counts"].values()):
            raise ValueError("monitor invalid state")
    if tag == "admission":
        if obj.config.version != metadata["config_version"]:
            raise ValueError("admission config identity")
        if values["rounds"] > obj.config.max_recalculations:
            raise ValueError("admission budget")
        req = values["pending"]
        if req is not None and req.config_hash != obj.config.content_hash:
            raise ValueError("request config")
    if tag in ("cycle", "maker_cycle"):
        p = obj.plan
        if p.strategy != metadata["strategy"] or p.config_version != metadata["config_version"]:
            raise ValueError("cycle identity")
        if values["repair_used"] > p.repair_attempts or values["exit_used"] > p.exit_attempts:
            raise ValueError("cycle budget")
        intents = values["issued"]
        if values["next_sequence"] != p.first_sequence+len(intents):
            raise ValueError("intent origin")
        if tag == "cycle" and intents and (len(intents) < 2 or tuple((i.leg, i.lots, i.limit_ticks, i.reducing) for i in intents[:2]) !=
                        tuple((j, leg.target_lots, p.entry_limits[j], False) for j, leg in enumerate(p.legs))):
            raise ValueError("original entry group")
        if tag == "maker_cycle":
            maker_intents = tuple(i for i in intents if not i.reducing and i.leg == p.maker_leg)
            hedge_intents = tuple(i for i in intents if not i.reducing and i.leg != p.maker_leg)
            if (values["requotes_used"] > p.max_requotes or len(maker_intents) !=
                    (1+values["requotes_used"] if intents else 0)
                    or len(hedge_intents) > values["repair_used"]
                    or len(intents) > 1+p.max_requotes+p.repair_attempts+2*p.exit_attempts):
                raise ValueError("maker budget")
            if any(i.time_in_force != ("post-only" if i in maker_intents else "ioc") for i in intents):
                raise ValueError("maker native order type")
            if (bool(intents) != (values["maker_sequence"] is not None)
                    or maker_intents and (values["maker_sequence"] != maker_intents[-1].sequence
                    or intents[0] != maker_intents[0] or maker_intents[0].lots != p.legs[p.maker_leg].target_lots)):
                raise ValueError("maker identity")
            if intents:
                if (values["quote_started_ns"] is None or values["last_quote_ns"] is None
                        or not p.policy.at_ns <= values["quote_started_ns"] <= values["last_quote_ns"] <= values["last_at_ns"]
                        or values["quote_score"] is None):
                    raise ValueError("maker quote progress")
            elif any(values[k] is not None for k in ("quote_started_ns", "last_quote_ns", "quote_score", "tail_started_ns")):
                raise ValueError("idle maker evidence")
            if (values["replacing"] and (not values["cancel_requested"] or values["entry_finished"])
                    or values["tail_started_ns"] is not None and not p.policy.at_ns <= values["tail_started_ns"] <= values["last_at_ns"]):
                raise ValueError("maker cancel or tail progress")
            if any(i.reducing and not values["entry_finished"] for i in intents):
                raise ValueError("maker exit before entry drain")
        if values["last_at_ns"] < p.policy.at_ns:
            raise ValueError("cycle time")
        if values["target_atoms"] is not None:
            from strategies.cross_venue.arbitrage_economics import holding_target
            matched = values["matched_base"]
            if not 0 < matched <= p.policy.original_base or values["target_atoms"] != holding_target(
                    p.target_atoms, matched/p.policy.original_base, p.policy.absolute_minimum_atoms):
                raise ValueError("frozen target formula")
        if (values["entry_cursor"] is None) != (values["entry_valid_until_ns"] is None):
            raise ValueError("entry evidence")
        if values["entry_cursor"] is not None and values["entry_cursor"] > cursor:
            raise ValueError("future entry cursor")


def checkpoint(metadata, components):
    import strategy_host as host
    if metadata["state_schema_version"] != 2 or metadata["state_schema"] != s.SCHEMA:
        raise ValueError("component schema")
    state = snapshot(components, metadata["cursor"], metadata["strategy"], metadata["next_intent"])
    for row in state["components"]:
        validate_configured(components[row["name"]], row["tag"], structure(SPECS[row["tag"]])[1](row["state"]), metadata)
    container = host.encode_checkpoint(metadata, state)
    restore(container, components)
    return container


def restore(container, templates, *, expected=None):
    import strategy_host as host
    metadata, state = host.decode_checkpoint(container)
    if metadata["schema_registry"] != host.SCHEMA_REGISTRY or (expected is not None and any(
            key not in metadata or metadata[key] != value for key, value in expected.items())):
        raise ValueError("checkpoint identity mismatch")
    if metadata["state_schema_version"] != 2 or metadata["state_schema"] != s.SCHEMA:
        raise ValueError("component schema")
    rows = state["components"]
    if [r["name"] for r in rows] != sorted(templates):
        raise ValueError("component scope")
    restored = copy.deepcopy(templates)
    for row in rows:
        obj, tag = restored[row["name"]], row["tag"]
        if TYPES.get(type(obj)) != tag or content(dependency(obj)) != row["dependency"]:
            raise ValueError("frozen dependency mismatch")
        values = structure(SPECS[tag])[1](row["state"])
        validate_configured(obj, tag, values, metadata)
        if tag == "rolling":
            values["_points"] = deque(values["_points"], maxlen=obj.spec.capacity)
        if tag == "labels":
            values["_pending"] = list(values["_pending"])
        if tag == "admission":
            obj._pending_scope = values.pop("pending_scope")
            values["evaluated"] = {(x["scope"], x["opportunity"]): x["revision"] for x in values["evaluated"]}
        if tag in ("cycle", "maker_cycle"):
            first = values["first_exit"]
            values["first_exit"] = None if first is None else (first["reason"], first["cursor"])
            for name in ("entry_cursor", "entry_valid_until_ns"):
                if values[name] is None:
                    values.pop(name)
                    obj.__dict__.pop(name, None)
        for name, value in values.items():
            setattr(obj, name, value)
    for obj in restored.values():
        if type(obj) is admission.Admission:
            scope = obj.__dict__.pop("_pending_scope")
            matches = [v for v in restored.values() if type(v) is signals.Signal and v.scope == scope]
            if obj.pending is not None:
                if len(matches) != 1 or matches[0].pending != obj.pending.identity or obj.pending.scope != scope:
                    raise ValueError("pending signal association")
                obj.pending_signal = matches[0]
            else:
                if scope is not None:
                    raise ValueError("unexpected pending signal")
                obj.pending_signal = None
    # Validate save as well as restore using the same canonical boundary.
    snapshot(restored, metadata["cursor"], metadata["strategy"], metadata["next_intent"])
    return metadata, restored


class ComponentRuntime:
    """Replay private components using a package-owned deterministic input callback.

    The callback consumes one admitted record, never the transport batch. Frozen
    templates and input interpretation belong to the strategy package, not IPC.
    This runtime cannot activate or publish an OrderIntent.
    """
    def __init__(self, container, templates, apply_event, *, expected):
        required = {"schema_registry", "strategy", "definition", "config_version",
                    "state_schema", "state_schema_version"}
        if set(expected) != required or not callable(apply_event):
            raise ValueError("runtime dependency contract")
        self.metadata, self.components = restore(container, templates, expected=expected)
        self.apply_event = apply_event
        self.last_batch = 0
        self.failed = False

    def apply_batch(self, batch, session, *, barrier=None):
        import strategy_host as host
        if self.failed:
            raise ValueError("failed runtime")
        # Any callback/validation failure poisons this Host; partially applied
        # private state must never be checkpointed or retried in this session.
        self.failed = True
        records, last = host.decode_component_batch(batch, session, self.last_batch+1,
                                                    self.metadata["cursor"])
        if barrier is not None and last > barrier:
            raise ValueError("batch crosses recovery barrier")
        actions = []
        for record in records:
            cursor = record.shard_sequence
            action = self.apply_event(self.components, record)
            if action is not None and action.intents:
                actions.append(action)
            self.metadata["cursor"] = cursor
            sequences = {obj.next_sequence for obj in self.components.values()
                         if type(obj) in (cycle.Cycle, maker.Cycle)}
            if len(sequences) > 1:
                raise ValueError("conflicting intent sequence owners")
            if sequences:
                self.metadata["next_intent"] = sequences.pop()
            # The same semantic/capacity checks apply while running and saving.
            snapshot(self.components, cursor, self.metadata["strategy"], self.metadata["next_intent"])
        self.metadata["cursor"] = last
        self.last_batch += 1
        self.failed = False
        return actions

    def checkpoint(self):
        if self.failed:
            raise ValueError("failed runtime")
        return checkpoint(self.metadata, self.components)


def transition_checkpoint(container, source_templates, target_templates, *, expected, target_metadata,
                          transition, migrate=None):
    """Package-owned, explicit Keep/Migrate/Rebuild; never an IPC callback name.

    Model changes cannot rewrite a frozen cycle, outstanding label, request,
    risk latch, deadline, or intent sequence. Successors start their own state.
    """
    import strategy_host as host
    metadata, original = restore(container, source_templates, expected=expected)
    if transition not in ("keep", "migrate", "rebuild"):
        raise ValueError("unknown transition")
    for key in ("schema_registry", "strategy", "state_schema", "state_schema_version", "cursor", "next_intent"):
        if metadata[key] != target_metadata[key]:
            raise ValueError("transition identity or progress")
    if set(source_templates) != set(target_templates):
        raise ValueError("transition component scope")
    if transition == "keep":
        if metadata != target_metadata:
            raise ValueError("Keep metadata mismatch")
        restore(container, target_templates, expected=expected)
        return container
    if transition == "migrate" and not callable(migrate):
        raise ValueError("explicit model migration required")
    state = snapshot(original, metadata["cursor"], metadata["strategy"], metadata["next_intent"])
    # Closed labels, cycle plans and economic references keep their old versions.
    models = {"rolling", "rolling_baseline", "ar1", "filter", "estimator", "calibration"}
    for row in state["components"]:
        name, tag = row["name"], row["tag"]
        target = target_templates[name]
        if TYPES.get(type(target)) != tag:
            raise ValueError("transition component type")
        digest = content(dependency(target))
        if tag not in models:
            if digest != row["dependency"]:
                raise ValueError("frozen non-model dependency")
            continue
        if transition == "rebuild" and tag in ("rolling", "filter"):
            row["state"] = progress(target, tag)
        elif transition == "migrate":
            row["state"] = migrate(name, tag, copy.deepcopy(row["state"]))
        row["dependency"] = digest
    migrated = host.encode_checkpoint(target_metadata, state)
    _, result = restore(migrated, target_templates, expected=target_metadata)
    if transition == "rebuild":
        for obj in result.values():
            if type(obj) is signals.Signal:
                obj.lock("rebuild", "definition:"+str(target_metadata["definition"]))
            elif type(obj) is signals.Monitor:
                obj.qualified = False
                obj.good_windows = 0
    return checkpoint(target_metadata, result)
