"""Offline whitelist/admission contract. Core facts and replies stay authoritative."""
from dataclasses import dataclass, fields
from fractions import Fraction
import json

from strategies.cross_venue import arbitrage_baseline as b
from strategies.cross_venue import arbitrage_economics as e
from strategies.cross_venue import arbitrage_probability as p
from opportunity_scanner import arbitrage_scanner as scanner
from strategies.cross_venue.arbitrage_signals import Signal, SignalPolicy

REQUIRED_REFS = ("strategy_definition", "state_schema", "portfolio", "activation", "rules",
                 "assets", "capabilities", "execution_model", "safety", "occupancy_model",
                 "grid", "monitoring", "risk", "funding", "fees", "valuation")


def _tuples(*items):
    for item in items:
        if type(item) is not tuple:
            raise b.Rejected("immutable_input")
        e.bounded(item)


def signal_scope(pair, direction):
    return b.fingerprint("signal_scope", (pair, direction))


@dataclass(frozen=True)
class Config:
    schema: int
    version: int
    valid_from_ns: int
    valid_until_ns: int
    references: tuple
    signal: SignalPolicy
    max_quantity_candidates: int
    max_batch_candidates: int
    max_recalculations: int
    recommendation_ttl_ns: int
    max_book_age_ns: int
    max_leg_skew_ns: int
    time_floor_ns: int
    batch_window_ns: int

    def __post_init__(self):
        _tuples(self.references, *self.references)
        if type(self.schema) is not int or self.schema != 1:
            raise b.Rejected("config_schema")
        b.uint(self.version, 1)
        b.uint(self.valid_from_ns)
        b.uint(self.valid_until_ns, self.valid_from_ns+1)
        refs = dict(e.bounded(self.references))
        if len(refs) != len(self.references) or set(refs) != set(REQUIRED_REFS):
            raise b.Rejected("config_references")
        for value in refs.values():
            p.validate_hash(value)
        if not isinstance(self.signal, SignalPolicy):
            raise b.Rejected("config_signal")
        for count in (self.max_quantity_candidates, self.max_batch_candidates, self.max_recalculations):
            if not 1 <= b.uint(count, 1) <= 256:
                raise b.Rejected("config_capacity")
        for value in (self.recommendation_ttl_ns, self.max_book_age_ns, self.time_floor_ns, self.batch_window_ns):
            b.uint(value, 1)
        b.uint(self.max_leg_skew_ns)

    @property
    def content_hash(self):
        signal = [(f.name, [str(e.exact(getattr(self.signal, f.name)).numerator),
                           str(e.exact(getattr(self.signal, f.name)).denominator)]
                   if f.name in ("reset", "entry") else getattr(self.signal, f.name))
                  for f in fields(self.signal)]
        return b.fingerprint("admission_config_v1", [(f.name, signal if f.name == "signal" else
            sorted(self.references) if f.name == "references" else getattr(self, f.name)) for f in fields(self)])


def load_config(payload):
    """Strict JSON boundary; rational thresholds are [numerator, denominator]."""
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise b.Rejected("duplicate_config_key")
            result[key] = value
        return result
    if type(payload) is not str or len(payload) > 65_536:
        raise b.Rejected("config_capacity")
    try:
        values = json.loads(payload, object_pairs_hook=unique)
        signal = values.pop("signal")
        for name in ("reset", "entry"):
            numerator, denominator = signal[name]
            e.integer(numerator, -e.MAX_INTEGER)
            e.integer(denominator, 1)
            signal[name] = Fraction(numerator, denominator)
        values["signal"] = SignalPolicy(**signal)
        values["references"] = tuple(tuple(x) for x in values["references"])
        return Config(**values)
    except (TypeError, KeyError, ZeroDivisionError, AttributeError) as error:
        raise b.Rejected("config_shape") from error


@dataclass(frozen=True)
class Approval:
    key: tuple
    config_hash: str
    valid_from_ns: int
    valid_until_ns: int
    enabled: bool
    activation_ref: str
    model_hash: str
    policy_version: int
    calibration_version: int
    rules_versions: tuple
    execution_hash: str
    qualification_hash: str

    def __post_init__(self):
        if type(self.key) is not tuple or len(self.key) != 4:
            raise b.Rejected("approval_scope")
        pair, direction, mode, maker = self.key
        if (type(pair) is not tuple or len(pair) != 2 or any(type(x) is not tuple or len(x) != 3 for x in pair)
                or pair[0] >= pair[1] or type(direction) is not int or direction not in (-1, 1)):
            raise b.Rejected("approval_scope")
        for leg in pair:
            for identity in leg:
                if type(identity) is not int or not 0 < identity < 1 << 128:
                    raise b.Rejected("approval_identity")
        if not ((mode == "taker_taker" and maker is None) or
                (mode == "maker_taker" and type(maker) is int and maker in (0, 1))):
            raise b.Rejected("approval_mode")
        for value in (self.config_hash, self.model_hash, self.execution_hash, self.qualification_hash):
            p.validate_hash(value)
        p.reference(self.activation_ref)
        b.uint(self.valid_from_ns)
        b.uint(self.valid_until_ns, self.valid_from_ns+1)
        _tuples(self.rules_versions)
        if type(self.enabled) is not bool or len(self.rules_versions) != 2:
            raise b.Rejected("approval_evidence")
        for version in (self.policy_version, self.calibration_version, *self.rules_versions):
            b.uint(version, 1)


@dataclass(frozen=True)
class Option:
    plan: scanner.Plan
    lots: tuple
    account_atoms: tuple
    occupancy_ns: int
    execution_hash: str

    def __post_init__(self):
        _tuples(self.lots, self.account_atoms, *self.account_atoms)
        if not isinstance(self.plan, scanner.Plan) or len(e.bounded(self.lots)) != 2:
            raise b.Rejected("quantity_plan")
        for lots in self.lots:
            e.integer(lots, 1)
        b.uint(self.occupancy_ns, 1)
        p.validate_hash(self.execution_hash)
        requirements = dict(e.bounded(self.account_atoms))
        if (len(requirements) != 2 or len(self.account_atoms) != 2
                or set(requirements) != {x[1] for x in self.plan.pair}):
            raise b.Rejected("quantity_accounts")
        for atoms in requirements.values():
            e.integer(atoms, 1)
        if e.integer(sum(requirements.values())) != self.plan.occupied_atoms:
            raise b.Rejected("quantity_capital")
        for scenario in self.plan.scenarios:
            if scenario.entry.state == "flat":
                continue
            for i, leg in enumerate(scenario.entry.legs):
                target_base = e.exact(self.lots[i]*leg.rules.base_atoms_per_lot)
                if (self.lots[i] < leg.rules.min_lots or target_base < self.plan.policy.original_base
                        or (leg.kind == "linear" and target_base != self.plan.policy.original_base)
                        or sum(t.lots for t in leg.entries) > self.lots[i]):
                    raise b.Rejected("quantity_lots")
                if any(leg.rules.notional(t.ticks, self.lots[i]) < leg.rules.min_notional_atoms for t in leg.entries):
                    raise b.Rejected("quantity_min_notional")

    @property
    def requirements(self):
        pair, policy = self.plan.pair, self.plan.policy
        account = dict(self.account_atoms)
        return (("total", self.plan.occupied_atoms),
                ("pair:"+b.fingerprint("pair", pair), self.plan.occupied_atoms),
                ("base:"+str(policy.base_asset), self.plan.occupied_atoms),
                *(("venue:"+str(x[0]), account[x[1]]) for x in pair),
                *(("account:"+str(x[1]), account[x[1]]) for x in pair))


@dataclass(frozen=True)
class Facts:
    at_ns: int
    cursor: int
    quote_asset: int
    config_hash: str
    remaining: tuple
    occupied: tuple
    opening_allowed: bool
    fact_ref: str

    def __post_init__(self):
        _tuples(self.remaining, self.occupied, *self.remaining, *self.occupied)
        b.uint(self.at_ns)
        b.uint(self.cursor, 1)
        e.integer(self.quote_asset, 1)
        p.validate_hash(self.config_hash)
        p.reference(self.fact_ref)
        remaining = dict(e.bounded(self.remaining))
        if len(remaining) != len(self.remaining) or type(self.opening_allowed) is not bool:
            raise b.Rejected("funds_evidence")
        for key, atoms in remaining.items():
            p.reference(key)
            e.integer(atoms)
        e.bounded(self.occupied)
        for account, instrument in self.occupied:
            e.integer(account, 1)
            e.integer(instrument, 1)


@dataclass(frozen=True)
class Request:
    identity: str
    scope: str
    key: tuple
    lots: tuple
    plan_atoms: int
    target_atoms: int
    config_hash: str
    cursor: int
    fact_ref: str
    scenario_digest: str
    estimator_digest: str
    valid_until_ns: int
    score: Fraction


@dataclass(frozen=True)
class Decision:
    request: object = None
    query_identity: object = None
    rejections: tuple = ()


class Admission:
    """One bounded deterministic batch; a new instance starts the next batch.

    propose returns a recommendation, never an OrderIntent or core reservation.
    After each response the caller must supply a newer complete core projection.
    """
    def __init__(self, config, *, fees=None):
        if not isinstance(config, Config):
            raise b.Rejected("admission_config")
        self.config = config
        self.fees = fees
        self.pending = None
        self.pending_signal = None
        self.rounds = 0
        self.after_cursor = 0
        self.last_time_ns = 0
        self.started_at_ns = None
        self.evaluated = {}
        self.reservation_revision = 0

    def propose(self, observations, options, approvals, signals, facts):
        cfg = self.config
        if not isinstance(facts, Facts):
            raise b.Rejected("admission_facts")
        if self.pending:
            return Decision(query_identity=self.pending.identity)
        if facts.cursor <= self.after_cursor or facts.at_ns < self.last_time_ns:
            raise b.Rejected("refresh_core_facts")
        self.last_time_ns = facts.at_ns
        if self.started_at_ns is None:
            self.started_at_ns = facts.at_ns
        if facts.at_ns-self.started_at_ns >= cfg.batch_window_ns:
            return Decision(rejections=(("batch", "batch_expired"),))
        for items in (options, approvals, signals):
            e.bounded(items)
        if (any(not isinstance(x, Option) for x in options) or
                any(not isinstance(x, Approval) for x in approvals) or
                any(not isinstance(x, Signal) for x in signals)):
            raise b.Rejected("admission_input")
        if len(options) > cfg.max_batch_candidates:
            raise b.Rejected("batch_capacity")
        by_key = {x.key: x for x in approvals}
        states = {x.scope: x for x in signals}
        if len(by_key) != len(approvals) or len(states) != len(signals):
            raise b.Rejected("duplicate_admission_scope")
        unresolved = sorted(x.pending for x in signals if x.pending is not None)
        if unresolved:
            return Decision(query_identity=unresolved[0])
        if (facts.config_hash != cfg.content_hash or not cfg.valid_from_ns <= facts.at_ns < cfg.valid_until_ns
                or not facts.opening_allowed):
            for state in signals:
                state.invalidate()
            return Decision(rejections=(("batch", "config_or_permission"),))
        if self.rounds >= cfg.max_recalculations:
            return Decision(rejections=(("batch", "recalculation_capacity"),))
        self.rounds += 1
        approved, rejected, seen = [], [], set()
        for option in options:
            plan = option.plan
            quantity = plan.key, e.exact(plan.policy.original_base)
            if quantity in seen:
                raise b.Rejected("duplicate_quantity")
            seen.add(quantity)
            grant = by_key.get(plan.key)
            state = states.get(signal_scope(plan.pair, plan.policy.direction))
            reason = ""
            try:
                plan.require_current_fees(self.fees)
            except ValueError as error:
                rejected.append((scanner.candidate_id(*plan.key), str(error)))
                continue
            if (grant is None or not grant.enabled or grant.config_hash != cfg.content_hash
                    or not grant.valid_from_ns <= facts.at_ns < grant.valid_until_ns):
                reason = "not_approved"
            elif (grant.model_hash != plan.policy.model_hash or grant.policy_version != plan.policy.version
                    or grant.calibration_version != plan.calibration.version or grant.execution_hash != option.execution_hash
                    or grant.rules_versions != tuple(next((x.rules.version for x in observations
                        if x.identity == leg), None) for leg in plan.pair)):
                reason = "approval_version"
            elif state is None or state.policy != cfg.signal:
                reason = "signal_policy"
            elif (state.activation_ref != grant.activation_ref or
                    (state.trigger_ns is not None and state.trigger_ns < grant.valid_from_ns)):
                reason = "signal_activation"
            elif facts.quote_asset != plan.policy.quote_asset:
                reason = "quote_asset"
            if reason:
                rejected.append((scanner.candidate_id(*plan.key), reason))
            else:
                approved.append(option)
        allowed_scopes = {signal_scope(x.plan.pair, x.plan.policy.direction) for x in approved}
        for state in signals:
            if state.scope not in allowed_scopes:
                state.invalidate()
        # Count once per signal, shared by quantities, modes and maker legs.
        eligible = set()
        for scope in sorted(allowed_scopes):
            state = states[scope]
            progress = scope, state.opportunity
            if (state.last_at_ns is not None and facts.at_ns-state.last_at_ns < cfg.max_book_age_ns
                    and state.evaluate(facts.at_ns, within_batch=
                        self.evaluated.get(progress, self.reservation_revision) < self.reservation_revision)):
                eligible.add(scope)
                self.evaluated[progress] = self.reservation_revision
        for scope in allowed_scopes-eligible:
            rejected.append((scope, "signal_not_ready"))
        per_key = {}
        remaining = dict(facts.remaining)
        for option in approved:
            plan = option.plan
            scope = signal_scope(plan.pair, plan.policy.direction)
            if scope not in eligible:
                continue
            per_key.setdefault(plan.key, []).append(option)
        qualified = []
        for key, choices in per_key.items():
            if len(choices) > cfg.max_quantity_candidates:
                raise b.Rejected("quantity_capacity")
            evaluated = []
            for option in choices:
                plan = option.plan
                row_id = scanner.candidate_id(*key)
                if any((x[1], x[2]) in facts.occupied for x in plan.pair):
                    rejected.append((row_id, "instrument_occupied"))
                    continue
                needed = dict(option.requirements)
                if not needed.keys() <= remaining.keys() or any(needed[k] > remaining[k] for k in needed):
                    rejected.append((row_id, "funds_or_concentration"))
                    continue
                snapshot = scanner.scan(observations, (plan,), at_ns=facts.at_ns, cursor=facts.cursor,
                    max_age_ns=cfg.max_book_age_ns, max_skew_ns=cfg.max_leg_skew_ns)
                row = next(x for x in snapshot["candidates"] if x["id"] == row_id)
                if row["status"] != "evaluated":
                    rejected.append((row_id, row["reason"]))
                    continue
                evaluated.append((option, row))
            if evaluated:
                option, row = min(evaluated, key=lambda x: (-int(x[1]["plan_atoms"]),
                    x[0].plan.occupied_atoms, x[0].plan.policy.original_base, x[0].lots))
                score = e.exact(Fraction(int(row["plan_atoms"]), e.integer(option.plan.occupied_atoms*
                    max(option.occupancy_ns, cfg.time_floor_ns), 1)))
                qualified.append((option, row, score))
        if not qualified:
            return Decision(rejections=tuple(sorted(rejected)))
        option, row, score = min(qualified, key=lambda x: (-x[2], x[1]["id"]))
        plan = option.plan
        scope = signal_scope(plan.pair, plan.policy.direction)
        state = states[scope]
        identity = b.fingerprint("admission_request", (state.opportunity, state.evaluations_used,
            cfg.content_hash, facts.cursor, row["id"], option.lots))
        until = min(state.deadline_ns, b.uint(facts.at_ns+cfg.recommendation_ttl_ns),
                    int(row["valid_until_ns"]), by_key[plan.key].valid_until_ns, cfg.valid_until_ns)
        request = Request(identity, scope, plan.key, option.lots, int(row["plan_atoms"]), int(row["target_atoms"]),
            cfg.content_hash, facts.cursor, facts.fact_ref, row["scenario_digest"], row["estimator_digest"], until, score)
        self.pending, self.pending_signal = request, state
        state.pending = identity
        return Decision(request=request, rejections=tuple(sorted(rejected)))

    def reply(self, identity, status, *, cursor, fact_ref, clean=False):
        b.uint(cursor, 1)
        p.reference(fact_ref)
        if self.pending is None or identity != self.pending.identity or cursor < self.pending.cursor:
            raise b.Rejected("reservation_identity")
        if status == "unknown":
            return
        if status not in ("reserved", "rejected") or (status == "rejected" and clean is not True):
            raise b.Rejected("reservation_evidence")
        state = self.pending_signal
        if status == "reserved":
            self.reservation_revision += 1
            state.active = identity
            state.invalidate()
        state.pending = None
        self.after_cursor = cursor
        self.pending = self.pending_signal = None
