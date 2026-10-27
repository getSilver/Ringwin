"""Read-only fixed-target evaluation on joint canonical execution scenarios.

Positions/fills below are hypothetical or injected core projections, never an
OMS or a second authoritative ledger. The module emits no trading commands.
"""
from dataclasses import dataclass, replace
from fractions import Fraction
import hashlib
import math
from typing import Optional, Tuple

import arbitrage_baseline as b
import arbitrage_economics as e
import arbitrage_probability as p
from strategy_host import decode_depth_snapshot, encode_depth_snapshot, RecoveryNeeded


def _tuple(items, capacity=256):
    if type(items) is not tuple:
        raise b.Rejected("immutable_input")
    return b.materialized(items, capacity)


def _ratio(value):
    value = e.exact(value)
    return [value.numerator, value.denominator]


@dataclass(frozen=True)
class Settled:
    identity: str
    net_atoms: int

    def __post_init__(self):
        p.reference(self.identity)
        e.integer(self.net_atoms, -e.MAX_INTEGER)


@dataclass(frozen=True)
class FundingCost:
    identity: str
    leg: int
    at_ns: int
    atoms: int

    def __post_init__(self):
        p.reference(self.identity)
        if type(self.leg) is not int or self.leg not in (0, 1):
            raise b.Rejected("funding_leg")
        b.uint(self.at_ns)
        e.integer(self.atoms)


@dataclass(frozen=True)
class Trade:
    identity: str
    ticks: int
    lots: int
    fee: e.Fee
    at_ns: int

    def __post_init__(self):
        p.reference(self.identity)
        e.integer(self.ticks, 1)
        e.integer(self.lots, 1)
        b.uint(self.at_ns)
        if not isinstance(self.fee, e.Fee):
            raise b.Rejected("fee_fact")


@dataclass(frozen=True)
class Leg:
    account: int
    rules: e.InstrumentRules
    kind: str
    direction: int
    entries: Tuple[Trade, ...]
    exit_fee: e.FeeRule

    def __post_init__(self):
        if type(self.account) is not int or not 0 < self.account < (1 << 128):
            raise b.Rejected("account_identity")
        if not isinstance(self.rules, e.InstrumentRules) or not isinstance(self.exit_fee, e.FeeRule):
            raise b.Rejected("missing_rules")
        if self.kind not in ("spot", "linear") or type(self.direction) is not int or self.direction not in (-1, 1):
            raise b.Rejected("leg_product")
        if self.kind == "spot" and self.direction != 1:
            raise b.Rejected("spot_short_not_allowed")
        if (self.exit_fee.instrument, self.exit_fee.rules_version) != (self.rules.instrument, self.rules.version):
            raise b.Rejected("fee_scope")
        for trade in _tuple(self.entries, 64):
            if not isinstance(trade, Trade):
                raise b.Rejected("entry_trade")
            fee = trade.fee
            if fee.base_atoms != (fee.asset_atoms if fee.asset == self.rules.base_asset else 0):
                raise b.Rejected("base_fee_unit")
            if self.kind == "linear" and fee.base_atoms:
                raise b.Rejected("linear_settlement_scope")
        if self.kind == "linear" and self.exit_fee.fee_asset == self.rules.base_asset:
            raise b.Rejected("linear_settlement_scope")
        if self.base_atoms < 0:
            raise b.Rejected("negative_spot_receipt")

    @property
    def gross_lots(self):
        return e.integer(sum(t.lots for t in self.entries))

    @property
    def base_atoms(self):
        base = e.exact(self.gross_lots*self.rules.base_atoms_per_lot)
        return e.exact(base-sum(t.fee.base_atoms for t in self.entries)) if self.kind == "spot" else base

    @property
    def entry_notional(self):
        return e.exact(sum((self.rules.notional(t.ticks, t.lots) for t in self.entries), Fraction(0)))


@dataclass(frozen=True)
class Entry:
    state: str
    legs: Tuple[Leg, ...]
    completed: Tuple[Settled, ...]
    holding_at_ns: int
    holding_risk_passed: bool
    unknown_refs: Tuple[str, ...]
    possible_base: Tuple[Tuple[Fraction, Fraction], ...]
    model_point: Optional[b.Point] = None

    def __post_init__(self):
        if self.state not in ("matched", "flat", "unknown") or type(self.holding_risk_passed) is not bool:
            raise b.Rejected("entry_state")
        b.uint(self.holding_at_ns)
        if self.model_point is not None and (not isinstance(self.model_point, b.Point)
                or self.model_point.value is None or self.model_point.grid_ns > self.holding_at_ns):
            raise b.Rejected("future_or_invalid_model_observation")
        _tuple(self.legs, 2)
        if len(self.legs) not in (0, 2) or any(not isinstance(x, Leg) for x in self.legs):
            raise b.Rejected("joint_legs")
        if self.state == "flat" and self.legs:
            raise b.Rejected("flat_position")
        if self.legs:
            a, z = self.legs
            if (a.rules.base_asset != z.rules.base_asset or a.rules.quote_asset != z.rules.quote_asset
                    or a.rules.instrument == z.rules.instrument or a.direction != -z.direction
                    or a.account == z.account):
                raise b.Rejected("pair_asset_or_direction")
            if any(t.at_ns > self.holding_at_ns for leg in self.legs for t in leg.entries):
                raise b.Rejected("future_entry_trade")
        if self.state == "matched" and (len(self.legs) != 2 or self.legs[0].base_atoms <= 0
                                         or self.legs[0].base_atoms != self.legs[1].base_atoms):
            raise b.Rejected("unmatched_entry_requires_repair")
        identities = [t.identity for leg in self.legs for t in leg.entries]
        for item in _tuple(self.completed):
            if not isinstance(item, Settled):
                raise b.Rejected("settled_projection")
            identities.append(item.identity)
        if len(set(identities)) != len(identities):
            raise b.Rejected("duplicate_economic_fact")
        for ref in _tuple(self.unknown_refs, 64):
            p.reference(ref)
        _tuple(self.possible_base, 2)
        if self.state == "unknown":
            if not self.unknown_refs or len(self.possible_base) != 2:
                raise b.Rejected("unknown_exposure_evidence")
            for bounds in self.possible_base:
                if type(bounds) is not tuple or len(bounds) != 2 or not 0 <= e.exact(bounds[0]) <= e.exact(bounds[1]):
                    raise b.Rejected("unknown_exposure_evidence")
        elif self.unknown_refs or self.possible_base:
            raise b.Rejected("contradictory_unknown")

    @property
    def r_done_atoms(self):
        return e.floor_atoms(sum((x.net_atoms for x in self.completed), 0))

    @property
    def matched_base(self):
        if self.state != "matched":
            raise b.Rejected("not_matched")
        return self.legs[0].base_atoms


@dataclass(frozen=True)
class Market:
    at_ns: int
    books: Tuple[bytes, bytes]
    fee_valuations: Tuple[Fraction, Fraction]
    fee_balances: Tuple[int, int]
    funding_costs: Tuple[FundingCost, ...]
    qualified: bool
    risk: bool
    model_invalid: bool
    unknown: bool
    unknown_refs: Tuple[str, ...] = ()

    def __post_init__(self):
        b.uint(self.at_ns)
        if len(_tuple(self.books, 2)) != 2 or any(type(x) is not bytes for x in self.books):
            raise b.Rejected("joint_depth")
        for payload in self.books:
            try:
                book = decode_depth_snapshot(payload)
            except RecoveryNeeded as error:
                raise b.Rejected("invalid_depth") from error
            if book["visible_at_ns"] > self.at_ns:
                raise b.Rejected("future_book")
        if len(_tuple(self.fee_valuations, 2)) != 2 or len(_tuple(self.fee_balances, 2)) != 2:
            raise b.Rejected("fee_valuation_scope")
        for value in self.fee_valuations:
            e.positive(value)
        for balance in self.fee_balances:
            e.integer(balance)
        seen = set()
        for cost in _tuple(self.funding_costs):
            if not isinstance(cost, FundingCost) or cost.at_ns > self.at_ns or cost.identity in seen:
                raise b.Rejected("funding_outflow_projection")
            seen.add(cost.identity)
        if any(type(x) is not bool for x in (self.qualified, self.risk, self.model_invalid, self.unknown)):
            raise b.Rejected("market_health")
        for ref in _tuple(self.unknown_refs, 64):
            p.reference(ref)
        if bool(self.unknown_refs) != self.unknown:
            raise b.Rejected("unknown_order_references")


@dataclass(frozen=True)
class Policy:
    version: int
    scope: str
    model_hash: str
    mode: str
    direction: int
    base_asset: int
    quote_asset: int
    original_base: Fraction
    reference_notional_atoms: int
    at_ns: int
    prediction_end_ns: int
    risk_deadline_ns: int
    reference_exit_ns: int
    alpha: Fraction
    absolute_minimum_atoms: int
    min_profit_atoms: int
    min_edge_bp: Fraction
    min_entry_probability: Fraction
    min_hold_probability: Fraction
    normal_limits: Tuple[int, int]
    risk_limits: Tuple[int, int]
    max_book_age_ns: int
    residual_cap_base: Fraction
    residual_haircut: Fraction
    reference_buffers: Tuple[e.Cost, ...]
    plan_buffers: Tuple[e.Cost, ...]
    hard_gates_passed: bool
    reference_policy_ref: str
    plan_policy_ref: str

    def __post_init__(self):
        b.uint(self.version, 1)
        p.reference(self.scope)
        p.validate_hash(self.model_hash)
        p.validate_scope("entry", self.mode)
        if type(self.direction) is not int or self.direction not in (-1, 1):
            raise b.Rejected("direction")
        e.integer(self.base_asset, 1)
        e.integer(self.quote_asset, 1)
        if self.base_asset == self.quote_asset:
            raise b.Rejected("pair_asset_scope")
        e.positive(self.original_base)
        e.integer(self.reference_notional_atoms, 1)
        b.uint(self.at_ns)
        for value in (self.prediction_end_ns, self.risk_deadline_ns):
            b.uint(value, self.at_ns+1)
        if not self.at_ns <= b.uint(self.reference_exit_ns) <= self.deadline_ns:
            raise b.Rejected("reference_deadline")
        if not 0 < p.probability(self.alpha) <= 1:
            raise b.Rejected("alpha")
        e.integer(self.absolute_minimum_atoms, 1)
        e.integer(self.min_profit_atoms, 1)
        if e.exact(self.min_edge_bp) < 0:
            raise b.Rejected("edge_threshold")
        if min(p.probability(self.min_entry_probability), p.probability(self.min_hold_probability)) <= 0:
            raise b.Rejected("probability_threshold")
        for limits in (self.normal_limits, self.risk_limits):
            if len(_tuple(limits, 2)) != 2:
                raise b.Rejected("joint_price_limits")
            for ticks in limits:
                e.integer(ticks, 1)
        b.uint(self.max_book_age_ns, 1)
        if e.exact(self.residual_cap_base) < 0:
            raise b.Rejected("residual_limit")
        p.probability(self.residual_haircut)
        for costs in (self.reference_buffers, self.plan_buffers):
            for cost in _tuple(costs):
                if not isinstance(cost, e.Cost) or cost.treatment not in ("embedded", "model_buffer", "execution_buffer"):
                    raise b.Rejected("buffer_cost_coverage")
            if len({x.name for x in costs}) != len(costs):
                raise b.Rejected("duplicate_buffer_coverage")
        if type(self.hard_gates_passed) is not bool:
            raise b.Rejected("hard_gate_evidence")
        p.reference(self.reference_policy_ref)
        p.reference(self.plan_policy_ref)
        if self.reference_policy_ref == self.plan_policy_ref:
            raise b.Rejected("distinct_exit_policies")

    @property
    def deadline_ns(self):
        return min(self.prediction_end_ns, self.risk_deadline_ns)


@dataclass(frozen=True)
class ExitValue:
    net_atoms: Optional[int]
    closed: bool
    remaining_base: Tuple[Fraction, ...]
    reason: str
    legs: Tuple[Optional[e.CycleValue], ...]


def _close_leg(leg, market, index, policy, normal):
    book = decode_depth_snapshot(market.books[index])
    side = "sell" if leg.direction == 1 else "buy"
    lots = leg.gross_lots if leg.kind == "linear" else e.floor_atoms(leg.base_atoms/leg.rules.base_atoms_per_lot)
    limit = (policy.normal_limits if normal else policy.risk_limits)[index]

    def sweep_and_fee(requested):
        swept = e.sweep(book, leg.rules, side, requested, limit,
                        now_ns=market.at_ns, max_age_ns=policy.max_book_age_ns)
        fees, available = [], market.fee_balances[index]
        for ticks, filled in swept.fills:
            valuation = (ticks*leg.rules.tick_quote_atoms_per_base_atom if leg.exit_fee.fee_asset == leg.rules.base_asset
                         else Fraction(1) if leg.exit_fee.fee_asset == leg.rules.quote_asset else market.fee_valuations[index])
            fee = e.estimate_fee(leg.rules, leg.exit_fee, ticks=ticks, lots=filled, role="taker",
                                 now_ns=market.at_ns, quote_atoms_per_fee_atom=valuation,
                                 available_fee_atoms=available)
            fees.append(fee)
            if fee.asset not in (leg.rules.base_asset, leg.rules.quote_asset):
                available -= fee.asset_atoms
        return swept, tuple(fees)

    if leg.kind == "spot" and leg.exit_fee.fee_asset == leg.rules.base_asset:
        low, high = 0, lots
        while low < high:
            candidate = (low+high+1)//2
            if candidate < leg.rules.min_lots or leg.rules.notional(limit, candidate) < leg.rules.min_notional_atoms:
                low = candidate
                continue
            swept, fees = sweep_and_fee(candidate)
            if swept.base_atoms+sum(f.base_atoms for f in fees) <= leg.base_atoms:
                low = candidate
            else:
                high = candidate-1
        lots = low
    if lots < leg.rules.min_lots or leg.rules.notional(limit, lots) < leg.rules.min_notional_atoms:
        exit_quote, used_base, exit_fees, remaining_lots = Fraction(0), Fraction(0), (), leg.gross_lots
    else:
        swept, exit_fees = sweep_and_fee(lots)
        exit_quote = swept.quote_atoms
        used_base = e.exact(swept.base_atoms+sum(f.base_atoms for f in exit_fees))
        remaining_lots = leg.gross_lots-swept.filled_lots
    fees = tuple(t.fee for t in leg.entries)+exit_fees
    remaining = e.exact(leg.base_atoms-used_base)
    if remaining < 0:
        raise b.Rejected("exit_increases_exposure")
    if leg.kind == "spot":
        closed = remaining <= policy.residual_cap_base
        if not closed:
            return None, remaining, False
        residual_value = e.exact(remaining*book["bids"][0][0]*leg.rules.tick_quote_atoms_per_base_atom*policy.residual_haircut)
        value = e.spot_liquidation(leg.entry_notional, exit_quote, residual_value, fees)
    else:
        closed = remaining_lots == 0
        if not closed:
            return None, remaining, False
        value = e.evaluate_cycle(e.exact(leg.direction*(exit_quote-leg.entry_notional)),
                                 tuple(e.Cost("fee:"+str(i), fee.quote_atoms, "expense") for i, fee in enumerate(fees)))
    return value, remaining, closed


def value_exit(entry, market, policy, *, normal):
    """Immediately executable protected two-leg liquidation, before exit delay."""
    if not isinstance(entry, Entry) or not isinstance(market, Market) or not isinstance(policy, Policy):
        raise b.Rejected("economic_projection_input")
    if type(normal) is not bool:
        raise b.Rejected("exit_policy_kind")
    if any(x.rules.base_asset != policy.base_asset or x.rules.quote_asset != policy.quote_asset for x in entry.legs):
        raise b.Rejected("candidate_asset_scope")
    if entry.state != "matched" or not market.qualified or market.unknown:
        return ExitValue(None, False, tuple(x.base_atoms for x in entry.legs), "unqualified_exit", ())
    if market.at_ns < entry.holding_at_ns:
        raise b.Rejected("future_entry")
    values, remaining, closed = [], [], True
    try:
        for index, leg in enumerate(entry.legs):
            value, rest, complete = _close_leg(leg, market, index, policy, normal)
            values.append(value)
            remaining.append(rest)
            closed &= complete
    except ValueError as error:
        return ExitValue(None, False, tuple(x.base_atoms for x in entry.legs), str(error), tuple(values))
    references = {t.identity for leg in entry.legs for t in leg.entries} | {x.identity for x in entry.completed}
    if references & {x.identity for x in market.funding_costs}:
        raise b.Rejected("duplicate_economic_fact")
    net = (e.floor_atoms(sum(x.net_atoms for x in values)+entry.r_done_atoms-sum(x.atoms for x in market.funding_costs))
           if closed else None)
    return ExitValue(net, closed, tuple(remaining), "" if closed else "unclosed_exit", tuple(values))


def _entry_payload(entry):
    return [entry.state, entry.holding_at_ns, entry.holding_risk_passed,
        [[leg.account, leg.rules.instrument, leg.rules.version, leg.rules.base_asset, leg.rules.quote_asset,
          _ratio(leg.rules.tick_quote_atoms_per_base_atom), _ratio(leg.rules.base_atoms_per_lot),
          leg.rules.min_lots, leg.rules.min_notional_atoms, leg.rules.valid_from_ns, leg.rules.valid_until_ns,
          leg.kind, leg.direction,
          [[t.identity, t.ticks, t.lots, t.at_ns, t.fee.asset, t.fee.asset_atoms,
            _ratio(t.fee.quote_atoms), t.fee.base_atoms] for t in leg.entries],
          [leg.exit_fee.instrument, leg.exit_fee.rules_version, leg.exit_fee.fee_asset,
           _ratio(leg.exit_fee.taker_ppm), _ratio(leg.exit_fee.maker_ppm),
           leg.exit_fee.valid_from_ns, leg.exit_fee.valid_until_ns]] for leg in entry.legs],
        [[x.identity, x.net_atoms] for x in entry.completed], list(entry.unknown_refs),
        [[_ratio(a), _ratio(z)] for a, z in entry.possible_base],
        None if entry.model_point is None else [entry.model_point.grid_ns, entry.model_point.cursor,
             b.encode_number(float(entry.model_point.value)), list(entry.model_point.evidence)]]


def _market_payload(market):
    return [market.at_ns, [hashlib.sha256(x).hexdigest() for x in market.books],
            [_ratio(x) for x in market.fee_valuations], list(market.fee_balances),
            [[x.identity, x.leg, x.at_ns, x.atoms] for x in market.funding_costs],
            market.qualified, market.risk, market.model_invalid, market.unknown, list(market.unknown_refs)]


def probability_scope(policy, target_atoms, matched_base, at_ns, r_done_atoms=0):
    """Exact declared feature stratum; calibrators cannot silently cross it."""
    e.integer(target_atoms, 1)
    e.positive(matched_base)
    b.uint(at_ns)
    e.integer(r_done_atoms, -e.MAX_INTEGER)
    return b.fingerprint("target_probability_scope_v1", [policy.scope, policy.mode, policy.direction,
        policy.base_asset, policy.quote_asset,
        _ratio(matched_base), target_atoms, policy.deadline_ns-at_ns, r_done_atoms])


@dataclass(frozen=True)
class Context:
    entry: Entry
    market: Market
    target_atoms: int
    policy: Policy

    def __post_init__(self):
        if not isinstance(self.entry, Entry) or not isinstance(self.market, Market) or not isinstance(self.policy, Policy):
            raise b.Rejected("holding_context")
        e.integer(self.target_atoms, 1)
        if any(x.rules.base_asset != self.policy.base_asset or x.rules.quote_asset != self.policy.quote_asset for x in self.entry.legs):
            raise b.Rejected("candidate_asset_scope")
        if self.market.at_ns < self.entry.holding_at_ns or self.market.at_ns < self.policy.at_ns:
            raise b.Rejected("holding_context_time")

    @property
    def scope(self):
        return probability_scope(self.policy, self.target_atoms, self.entry.matched_base,
                                 self.market.at_ns, self.entry.r_done_atoms)

    @property
    def identity(self):
        return b.fingerprint("holding_visible_context_v1", [_entry_payload(self.entry),
            _market_payload(self.market), self.target_atoms, self.policy.version, self.policy.model_hash,
            self.policy.scope, self.policy.mode, self.policy.direction, self.policy.deadline_ns,
            list(self.policy.normal_limits), list(self.policy.risk_limits), self.policy.max_book_age_ns,
            _ratio(self.policy.residual_cap_base), _ratio(self.policy.residual_haircut)])


@dataclass(frozen=True)
class Scenario:
    identity: str
    weight: Fraction
    entry: Entry
    markets: Tuple[Market, ...]
    exit_delays_ns: Tuple[int, int]
    exit_status: Tuple[str, str]
    exit_refs: Tuple[str, str]

    def __post_init__(self):
        p.reference(self.identity)
        if p.probability(self.weight) <= 0 or not isinstance(self.entry, Entry):
            raise b.Rejected("scenario_weight_or_entry")
        _tuple(self.markets, 8192)
        if self.entry.state == "matched" and (not self.markets or self.markets[0].at_ns != self.entry.holding_at_ns):
            raise b.Rejected("holding_observation_missing")
        previous_time, funding = None, {}
        economic_refs = {t.identity for leg in self.entry.legs for t in leg.entries} | {x.identity for x in self.entry.completed}
        for market in self.markets:
            if not isinstance(market, Market) or (previous_time is not None and market.at_ns <= previous_time):
                raise b.Rejected("scenario_market_order")
            current = {x.identity: x for x in market.funding_costs}
            if any(current.get(key) != value for key, value in funding.items()) or economic_refs & current.keys():
                raise b.Rejected("funding_fact_regression_or_duplicate")
            if any(x.at_ns < self.entry.holding_at_ns for x in market.funding_costs):
                raise b.Rejected("funding_already_in_entry_projection")
            previous_time, funding = market.at_ns, current
        if len(_tuple(self.exit_delays_ns, 2)) != 2 or len(_tuple(self.exit_status, 2)) != 2:
            raise b.Rejected("joint_execution")
        for delay in self.exit_delays_ns:
            b.uint(delay)
        if any(x not in ("filled", "rejected", "unknown") for x in self.exit_status):
            raise b.Rejected("joint_execution_status")
        if len(_tuple(self.exit_refs, 2)) != 2 or self.exit_refs[0] == self.exit_refs[1]:
            raise b.Rejected("joint_execution_references")
        for ref in self.exit_refs:
            p.reference(ref)


@dataclass(frozen=True)
class RebaseBounds:
    min_price_factor: Fraction
    max_price_factor: Fraction
    max_log_spread_shift: float
    min_depth_factor: Fraction
    max_depth_factor: Fraction
    max_top_spread_factor: Fraction

    def __post_init__(self):
        if not 0 < e.positive(self.min_price_factor) <= e.positive(self.max_price_factor):
            raise b.Rejected("rebase_price_bounds")
        if b.finite(self.max_log_spread_shift) < 0:
            raise b.Rejected("rebase_spread_bounds")
        if not 0 < e.positive(self.min_depth_factor) <= e.positive(self.max_depth_factor):
            raise b.Rejected("rebase_depth_bounds")
        e.positive(self.max_top_spread_factor)


@dataclass(frozen=True)
class ConditionalRow:
    scope: str
    scenarios: Tuple[Scenario, ...]
    calibration: p.Calibration
    simulation_error: p.SimulationError
    bounds: RebaseBounds


@dataclass(frozen=True)
class Estimator:
    forecast: b.AR1
    training_end_ns: int
    rows: Tuple[ConditionalRow, ...]

    def __post_init__(self):
        b.uint(self.training_end_ns)
        if not isinstance(self.forecast, b.AR1) or self.forecast.trained_until_ns > self.training_end_ns:
            raise b.Rejected("frozen_forecast")
        b.uint(self.training_end_ns)
        seen = set()
        for row in _tuple(self.rows):
            if not isinstance(row, ConditionalRow) or row.scope in seen:
                raise b.Rejected("conditional_estimator_rows")
            p.validate_hash(row.scope)
            _validate_scenarios(row.scenarios)
            if not isinstance(row.calibration, p.Calibration) or not isinstance(row.simulation_error, p.SimulationError):
                raise b.Rejected("conditional_probability_evidence")
            if not isinstance(row.bounds, RebaseBounds):
                raise b.Rejected("conditional_rebase_bounds")
            for scenario in row.scenarios:
                if (scenario.entry.state != "matched" or not scenario.markets
                        or scenario.markets[-1].at_ns > self.training_end_ns or not scenario.markets[0].qualified
                        or scenario.markets[0].unknown or scenario.markets[0].risk or scenario.markets[0].model_invalid
                        or scenario.entry.model_point is None):
                    raise b.Rejected("conditional_training_partition")
            seen.add(row.scope)

    @property
    def model_hash(self):
        return self.forecast.content_hash

    @property
    def content_hash(self):
        return b.fingerprint("conditional_estimator_v1", [self.model_hash, self.training_end_ns,
            [[r.scope, _scenarios_digest(r.scenarios), r.calibration.content_hash,
              r.simulation_error.method, r.simulation_error.draws, _ratio(r.simulation_error.confidence_error),
              _ratio(r.simulation_error.margin), r.simulation_error.source_ref,
              _ratio(r.bounds.min_price_factor), _ratio(r.bounds.max_price_factor),
              b.encode_number(float(r.bounds.max_log_spread_shift)), _ratio(r.bounds.min_depth_factor),
              _ratio(r.bounds.max_depth_factor), _ratio(r.bounds.max_top_spread_factor)] for r in self.rows]])

    def generate(self, context):
        if (not isinstance(context, Context) or context.entry.state != "matched"
                or self.model_hash != context.policy.model_hash or self.training_end_ns > context.market.at_ns):
            raise b.Rejected("conditional_evidence")
        row = next((r for r in self.rows if r.scope == context.scope), None)
        if row is None:
            raise b.Rejected("conditional_scope")
        return _condition(row, context, self.forecast)


def _mid(book, rule):
    return e.positive(e.exact(Fraction(book["bids"][0][0]+book["asks"][0][0], 2)*rule.tick_quote_atoms_per_base_atom))


def _scaled_book(payload, factor, time_shift):
    book = decode_depth_snapshot(payload)
    book["visible_at_ns"] = b.uint(book["visible_at_ns"]+time_shift)
    for side in ("bids", "asks"):
        levels = []
        for ticks, lots in book[side]:
            scaled = e.exact(ticks*factor)
            price = e.floor_atoms(scaled) if side == "bids" else e.ceil_atoms(scaled)
            if price <= 0:
                raise b.Rejected("conditioned_price_not_legal")
            if levels and levels[-1][0] == price:
                previous = levels[-1][1]
                levels[-1] = (price, None if previous is None or lots is None else e.integer(previous+lots))
            else:
                levels.append((price, lots))
        book[side] = tuple(levels)
    try:
        return encode_depth_snapshot(book)
    except (RecoveryNeeded, OverflowError, ValueError) as error:
        raise b.Rejected("conditioned_depth_not_legal") from error


def _condition(row, context, forecast):
    """Joint historical residual paths, rebased using only the visible prefix.

    A returns/depth/latency/failure stay in the SAME block. B receives the frozen
    AR(1) conditional-mean correction, never an independent leg draw.
    """
    output = []
    if context.entry.model_point is None:
        raise b.Rejected("missing_grid_model_observation")
    current_books = tuple(decode_depth_snapshot(x) for x in context.market.books)
    current_mids = tuple(_mid(book, leg.rules) for book, leg in zip(current_books, context.entry.legs))
    current_s = b.finite(math.log(float(e.exact(current_mids[1]/current_mids[0]))))
    for source in row.scenarios:
        if (source.entry.matched_base != context.entry.matched_base
                or any(a.rules != z.rules or a.kind != z.kind or a.direction != z.direction or a.exit_fee != z.exit_fee or a.account != z.account
                       for a, z in zip(source.entry.legs, context.entry.legs))):
            raise b.Rejected("conditional_instrument_or_quantity_scope")
        first = source.markets[0]
        shift = context.market.at_ns-first.at_ns
        first_books = tuple(decode_depth_snapshot(x) for x in first.books)
        source_mids = tuple(_mid(book, leg.rules) for book, leg in zip(first_books, source.entry.legs))
        source_s = b.finite(math.log(float(e.exact(source_mids[1]/source_mids[0]))))
        factors = tuple(e.exact(a/z) for a, z in zip(current_mids, source_mids))
        if (any(not row.bounds.min_price_factor <= x <= row.bounds.max_price_factor for x in factors)
                or abs(current_s-source_s) > row.bounds.max_log_spread_shift):
            raise b.Rejected("conditional_market_scope")
        for current, historical, leg in zip(current_books, first_books, context.entry.legs):
            side = "bids" if leg.direction == 1 else "asks"
            if any(size is None for _, size in current[side]+historical[side]):
                raise b.Rejected("conditional_liquidity_scope")
            old_depth = sum(size for _, size in historical[side])
            depth = sum(size for _, size in current[side])
            if old_depth <= 0 or not row.bounds.min_depth_factor <= Fraction(depth, old_depth) <= row.bounds.max_depth_factor:
                raise b.Rejected("conditional_liquidity_scope")
            old_spread = historical["asks"][0][0]-historical["bids"][0][0]
            spread = current["asks"][0][0]-current["bids"][0][0]
            if Fraction(spread, old_spread) > row.bounds.max_top_spread_factor:
                raise b.Rejected("conditional_liquidity_scope")
        projected = [context.market]
        original_costs = {x.identity for x in first.funding_costs}
        def mean_change(point, origin, future):
            before = (origin-point.grid_ns)//b.SECOND
            steps = (future-point.grid_ns)//b.SECOND-before
            log_phi = math.log(forecast.phi)
            return b.finite((point.value-forecast.center)*math.exp(before*log_phi)*math.expm1(steps*log_phi))
        for frame in source.markets[1:]:
            offset = frame.at_ns-first.at_ns
            # Mean changes use admitted grid observations, never an off-grid quote update.
            correction = b.finite(mean_change(context.entry.model_point, context.market.at_ns, context.market.at_ns+offset)
                                  -mean_change(source.entry.model_point, first.at_ns, frame.at_ns))
            adjusted = e.positive(Fraction.from_float(b.positive(math.exp(correction))))
            scaled_factors = (factors[0], e.exact(factors[1]*adjusted))
            books = tuple(_scaled_book(payload, factor, shift) for payload, factor in zip(frame.books, scaled_factors))
            valuations = tuple(e.exact(now*later/before) for now, later, before in
                               zip(context.market.fee_valuations, frame.fee_valuations, first.fee_valuations))
            balances = tuple(min(now, max(0, now+later-before)) for now, later, before in
                             zip(context.market.fee_balances, frame.fee_balances, first.fee_balances))
            funding = list(context.market.funding_costs)
            for item in frame.funding_costs:
                if item.identity not in original_costs:
                    funding.append(FundingCost("conditional:"+source.identity+":"+item.identity, item.leg,
                                               b.uint(item.at_ns+shift), e.ceil_atoms(item.atoms*factors[item.leg])))
            refs = tuple("conditional:"+source.identity+":"+ref for ref in frame.unknown_refs)
            projected.append(Market(b.uint(context.market.at_ns+offset), books, valuations, balances,
                                    tuple(funding), frame.qualified, frame.risk, frame.model_invalid, frame.unknown, refs))
        output.append(Scenario(source.identity, source.weight, context.entry, tuple(projected),
                               source.exit_delays_ns, source.exit_status, source.exit_refs))
    return tuple(output)


def _validate_scenarios(scenarios):
    _tuple(scenarios)
    if not scenarios or any(not isinstance(x, Scenario) for x in scenarios):
        raise b.Rejected("joint_scenarios")
    if len({x.identity for x in scenarios}) != len(scenarios) or sum(x.weight for x in scenarios) != 1:
        raise b.Rejected("scenario_identity_or_weights")
    pair = None
    for scenario in scenarios:
        if scenario.entry.legs:
            current = tuple((x.account, x.rules, x.kind, x.direction, x.exit_fee) for x in scenario.entry.legs)
            if pair is not None and current != pair:
                raise b.Rejected("joint_scenario_pair_scope")
            pair = current


def _scenarios_digest(scenarios):
    return b.fingerprint("joint_scenarios_v1", [[x.identity, _ratio(x.weight), _entry_payload(x.entry),
        [_market_payload(m) for m in x.markets], list(x.exit_delays_ns), list(x.exit_status), list(x.exit_refs)] for x in scenarios])


@dataclass(frozen=True)
class Limits:
    max_scenarios: int
    max_steps: int
    max_nested: int

    def __post_init__(self):
        if b.uint(self.max_scenarios, 1) > 256 or b.uint(self.max_steps, 1) > 1_000_000 or b.uint(self.max_nested, 1) > 256:
            raise b.Rejected("evaluation_capacity")


class _Work:
    def __init__(self, limits):
        if not isinstance(limits, Limits):
            raise b.Rejected("evaluation_limits")
        self.limits, self.steps, self.nested = limits, 0, 0

    def consume(self, count, scenarios=0, nested=0):
        if (scenarios > self.limits.max_scenarios or self.steps+count > self.limits.max_steps
                or self.nested+nested > self.limits.max_nested):
            raise b.Rejected("evaluation_capacity")
        self.steps += count
        self.nested += nested


@dataclass(frozen=True)
class PathResult:
    identity: str
    weight: Fraction
    target_atoms: Optional[int]
    triggered: Optional[bool]
    trigger_ns: Optional[int]
    closed_at_ns: Optional[int]
    net_atoms: Optional[int]
    actual_target_met: Optional[bool]
    reason: str
    remaining_base: Tuple[Fraction, ...]
    hold_probability: Optional[p.ProbabilityResult]
    unknown_refs: Tuple[str, ...]
    possible_remaining: Tuple[Tuple[Fraction, Fraction], ...] = ()


def _market_at(scenario, at_ns):
    if not scenario.markets[0].at_ns <= at_ns <= scenario.markets[-1].at_ns:
        return None
    low, high = 0, len(scenario.markets)
    while low < high:
        middle = (low+high)//2
        if scenario.markets[middle].at_ns <= at_ns:
            low = middle+1
        else:
            high = middle
    return replace(scenario.markets[low-1], at_ns=at_ns)


def _execute_exit(scenario, trigger, target, reason, policy, holding_probability):
    remaining = tuple(x.base_atoms for x in scenario.entry.legs)
    triggered = reason == "profit"
    if any(x != "filled" for x in scenario.exit_status):
        unknown = tuple(ref for ref, state in zip(scenario.exit_refs, scenario.exit_status) if state == "unknown")
        ranges = tuple((Fraction(0) if state != "rejected" else base, base)
                       for state, base in zip(scenario.exit_status, remaining))
        return PathResult(scenario.identity, scenario.weight, target, triggered, trigger.at_ns, None,
                          None, None, "exit_"+next(x for x in scenario.exit_status if x != "filled"),
                          remaining, holding_probability, scenario.entry.unknown_refs+unknown, ranges)
    arrivals = []
    for delay in scenario.exit_delays_ns:
        due = b.uint(trigger.at_ns+delay)
        arrival = _market_at(scenario, due)
        if arrival is None or not arrival.qualified or arrival.unknown:
            return PathResult(scenario.identity, scenario.weight, target, triggered, trigger.at_ns,
                              None, None, None, "unclosed_exit", remaining, holding_probability,
                              arrival.unknown_refs if arrival is not None else (),
                              tuple((Fraction(0), x) for x in remaining))
        arrivals.append(arrival)
    values, remaining, closed = [], [], True
    try:
        for leg_index, (leg, market) in enumerate(zip(scenario.entry.legs, arrivals)):
            value, rest, complete = _close_leg(leg, market, leg_index, policy, triggered)
            values.append(value)
            remaining.append(rest)
            closed &= complete
    except ValueError as error:
        return PathResult(scenario.identity, scenario.weight, target, triggered, trigger.at_ns, None,
                          None, None, str(error), tuple(x.base_atoms for x in scenario.entry.legs), holding_probability, ())
    latest = max(arrivals, key=lambda x: x.at_ns)
    # Late-reported costs affect realized Y, never the earlier decision quote.
    applicable = tuple(x for x in scenario.markets[-1].funding_costs if x.at_ns <= arrivals[x.leg].at_ns)
    funding = sum(x.atoms for x in applicable)
    closed_at = latest.at_ns
    if applicable:
        identities = {x.identity for x in applicable}
        known_at = next(x.at_ns for x in scenario.markets if identities <= {z.identity for z in x.funding_costs})
        closed_at = max(closed_at, known_at)
    net = e.floor_atoms(sum(x.net_atoms for x in values)+scenario.entry.r_done_atoms-funding) if closed else None
    return PathResult(scenario.identity, scenario.weight, target, triggered, trigger.at_ns,
                      closed_at if closed else None, net, net >= target if closed and target is not None else None,
                      reason if closed else "unclosed_exit", tuple(remaining), holding_probability, ())


def _raw_probability(paths):
    if any(x.triggered is None for x in paths):
        return None
    return e.exact(sum((x.weight for x in paths if x.triggered), Fraction(0)))


def _holding_probability(context, estimator, work):
    if (not isinstance(estimator, Estimator) or estimator.model_hash != context.policy.model_hash
            or estimator.training_end_ns > context.market.at_ns):
        return None, "conditional_evidence"
    row = next((x for x in estimator.rows if x.scope == context.scope), None)
    if row is None:
        return None, "conditional_scope"
    if estimator.training_end_ns > row.calibration.training_end_ns:
        return None, "conditional_training_partition"
    work.consume(sum(len(x.markets) for x in row.scenarios), scenarios=len(row.scenarios), nested=1)
    try:
        conditioned = estimator.generate(context)
    except ValueError as error:
        return None, "conditional_projection:"+str(error)
    paths = tuple(_simulate(x, context.policy, context.target_atoms, "continuation", None, work) for x in conditioned)
    raw = _raw_probability(paths)
    if raw is None or any(x.net_atoms is None for x in paths):
        return None, "unresolved_conditional_risk"
    _simulation_weights(conditioned, row.simulation_error)
    result = p.assess(raw, row.calibration, stage="hold", mode=context.policy.mode, scope=context.scope,
                      model_hash=context.policy.model_hash, at_ns=context.market.at_ns,
                      min_probability=context.policy.min_hold_probability, mc=row.simulation_error)
    return result, "" if result.passed else result.reason


def _simulation_weights(scenarios, simulation_error):
    if simulation_error.method == "sampled" and any(e.exact(x.weight*simulation_error.draws).denominator != 1 for x in scenarios):
        raise b.Rejected("simulation_draw_weights")


def _simulate(scenario, policy, target, mode, estimator, work):
    work.consume(len(scenario.markets)+1)
    entry = scenario.entry
    if any(x.rules.base_asset != policy.base_asset or x.rules.quote_asset != policy.quote_asset for x in entry.legs):
        raise b.Rejected("candidate_asset_scope")
    if entry.state == "flat":
        return PathResult(scenario.identity, scenario.weight, target, False, None, entry.holding_at_ns,
                          entry.r_done_atoms, entry.r_done_atoms >= target if target is not None else None, "flat", (), None, ())
    if entry.state == "unknown":
        return PathResult(scenario.identity, scenario.weight, target, None, None, None, None, None,
                          "reconciliation", tuple(z for _, z in entry.possible_base), None,
                          entry.unknown_refs, entry.possible_base)
    if entry.matched_base > policy.original_base or entry.legs[0].direction != policy.direction:
        raise b.Rejected("candidate_quantity_or_direction")
    if entry.holding_at_ns < policy.at_ns:
        raise b.Rejected("entry_before_evaluation")
    included = {"executed_price_impact"}
    for leg in entry.legs:
        included.update(t.identity for t in leg.entries)
        included.update("fee:"+t.identity for t in leg.entries)
    for market in scenario.markets:
        included.update(x.identity for x in market.funding_costs)
        included.update("funding:"+x.identity for x in market.funding_costs)
    costs = policy.reference_buffers if mode == "reference" else policy.plan_buffers
    if any(c.name in included and c.treatment != "embedded" for c in costs):
        raise b.Rejected("duplicate_actual_cost_coverage")
    frozen_target = (e.holding_target(target, entry.matched_base/policy.original_base, policy.absolute_minimum_atoms)
                     if target is not None and mode != "continuation" else target)
    first = scenario.markets[0]
    holding_probability, force = None, ("holding_risk" if not entry.holding_risk_passed else
                                        "market_unqualified" if not first.qualified else "")
    if (mode == "actual" and not force and first.at_ns < policy.deadline_ns
            and not first.unknown and not first.risk and not first.model_invalid):
        context = Context(entry, first, frozen_target, policy)
        holding_probability, force = _holding_probability(context, estimator, work)
    times = {x.at_ns for x in scenario.markets}
    timers = (policy.deadline_ns, policy.reference_exit_ns) if mode == "reference" else (policy.deadline_ns,)
    times.update(t for t in timers if first.at_ns <= t <= scenario.markets[-1].at_ns)
    work.consume(len(times)-len(scenario.markets))
    for index, at_ns in enumerate(sorted(times)):
        market = _market_at(scenario, at_ns)
        if market.unknown:
            return PathResult(scenario.identity, scenario.weight, frozen_target, None, None, None,
                              None, None, "reconciliation", tuple(x.base_atoms for x in entry.legs),
                              holding_probability, market.unknown_refs,
                              tuple((Fraction(0), x.base_atoms) for x in entry.legs))
        reason = ("risk" if market.risk else "model_invalid" if market.model_invalid else
                  "deadline" if market.at_ns >= policy.deadline_ns else force if index == 0 else "")
        if mode == "reference" and not reason and market.at_ns >= policy.reference_exit_ns:
            reason = "reference_exit"
        if mode != "reference" and not reason:
            quote = value_exit(entry, market, policy, normal=True)
            if quote.closed and quote.net_atoms >= frozen_target:
                reason = "profit"
        if reason:
            return _execute_exit(scenario, market, frozen_target, reason, policy, holding_probability)
    return PathResult(scenario.identity, scenario.weight, frozen_target, None, None, None, None, None,
                      "censored", tuple(x.base_atoms for x in entry.legs), holding_probability, ())


@dataclass(frozen=True)
class HoldingDecision:
    action: str
    target_atoms: int
    probability: Optional[p.ProbabilityResult]
    reason: str
    remaining_ns: int


def assess_holding(context, estimator, limits, *, phase):
    """One boundary check; never add periodic probability exits to Holding."""
    if not isinstance(context, Context) or phase not in ("entering", "repairing", "holding", "exiting"):
        raise b.Rejected("holding_phase")
    remaining = max(0, context.policy.deadline_ns-context.market.at_ns)
    if context.entry.state == "unknown" or context.market.unknown:
        return HoldingDecision("reconcile", context.target_atoms, None, "unknown", remaining)
    if phase == "exiting":
        return HoldingDecision("continue_exit", context.target_atoms, None, "already_exiting", remaining)
    hard = ("risk" if context.market.risk else "model_invalid" if context.market.model_invalid else
            "deadline" if remaining == 0 else "")
    if hard:
        return HoldingDecision("exit", context.target_atoms, None, hard, remaining)
    if phase == "holding":
        return HoldingDecision("keep_plan", context.target_atoms, None, "already_holding", remaining)
    if context.entry.state == "flat":
        return HoldingDecision("complete", context.target_atoms, None, "no_match", remaining)
    if not context.entry.holding_risk_passed or not context.market.qualified:
        return HoldingDecision("exit", context.target_atoms, None, "holding_qualification", remaining)
    result, reason = _holding_probability(context, estimator, _Work(limits))
    return HoldingDecision("hold" if not reason else "exit", context.target_atoms, result, reason, remaining)


@dataclass(frozen=True)
class Evaluation:
    policy: Policy
    scenario_digest: str
    estimator_digest: str
    reference_atoms: Optional[int]
    entry_target_atoms: Optional[int]
    plan_atoms: Optional[int]
    entry_probability: Optional[p.ProbabilityResult]
    reference_paths: Tuple[PathResult, ...]
    plan_paths: Tuple[PathResult, ...]
    actual_target_probability: Optional[Fraction]
    unresolved_weight: Fraction
    allowed: bool
    reason: str
    steps: int
    nested_evaluations: int


def _expected(paths, buffers):
    if any(x.net_atoms is None for x in paths):
        return None
    mean = e.expected_profit(tuple(e.Scenario(x.weight, x.net_atoms, True) for x in paths))
    return e.evaluate_cycle(mean, buffers).plan_atoms


def evaluate(scenarios, policy, estimator, entry_calibration, simulation_error, limits):
    """Reference policy -> one target -> actual plan, on independent replay state.

    Only frozen estimator rows keyed by the current visible prefix reach the
    future Holding gate. Conditional continuations cannot invoke another gate.
    """
    _validate_scenarios(scenarios)
    if not isinstance(policy, Policy) or not isinstance(estimator, Estimator):
        raise b.Rejected("evaluation_policy_or_estimator")
    if not isinstance(entry_calibration, p.Calibration) or not isinstance(simulation_error, p.SimulationError):
        raise b.Rejected("entry_probability_evidence")
    _simulation_weights(scenarios, simulation_error)
    work = _Work(limits)
    work.consume(0, scenarios=len(scenarios))
    digest, estimator_digest = _scenarios_digest(scenarios), estimator.content_hash
    reference_paths = tuple(_simulate(x, policy, None, "reference", None, work) for x in scenarios)
    reference_profit = _expected(reference_paths, policy.reference_buffers)
    if reference_profit is None or reference_profit <= 0:
        return Evaluation(policy, digest, estimator_digest, reference_profit, None, None, None,
                          reference_paths, (), None, Fraction(0), False,
                          "unresolved_reference" if reference_profit is None else "reference_profit", work.steps, work.nested)
    target = e.entry_target(reference_profit, policy.alpha, policy.absolute_minimum_atoms)
    paths = tuple(_simulate(x, policy, target, "actual", estimator, work) for x in scenarios)
    plan_profit = _expected(paths, policy.plan_buffers)
    unresolved = e.exact(sum((x.weight for x in paths if x.net_atoms is None), Fraction(0)))
    raw = _raw_probability(paths)
    entry_probability = None
    if raw is not None:
        entry_probability = p.assess(raw, entry_calibration, stage="entry", mode=policy.mode,
            scope=probability_scope(policy, target, policy.original_base, policy.at_ns), model_hash=policy.model_hash,
            at_ns=policy.at_ns, min_probability=policy.min_entry_probability, mc=simulation_error)
    # Future gate failure costs stay in Y; missing qualification cannot be repaired by p_cal.
    evidence_failures = {"conditional_evidence", "conditional_scope", "conditional_prefix_mismatch",
        "conditional_training_partition", "unresolved_conditional_risk", "calibration_scope", "calibration_expired",
        "missing_labels", "insufficient_blocks", "insufficient_labels", "calibration_error_understated", "duplicate_error_coverage"}
    reason = ("unresolved_plan" if plan_profit is None else "hard_gate" if not policy.hard_gates_passed else
              "conditional_evidence" if any(x.reason in evidence_failures or x.reason.startswith("conditional_projection:") for x in paths) else
              "profit" if plan_profit <= policy.min_profit_atoms else
              "edge" if e.edge_bp(plan_profit, policy.reference_notional_atoms) <= policy.min_edge_bp else
              "probability_evidence" if entry_probability is None else entry_probability.reason)
    if estimator.training_end_ns > entry_calibration.training_end_ns:
        reason = "entry_training_partition"
    actual_met = (None if any(x.actual_target_met is None for x in paths) else
                  e.exact(sum((x.weight for x in paths if x.actual_target_met), Fraction(0))))
    return Evaluation(policy, digest, estimator_digest, reference_profit, target, plan_profit,
                      entry_probability, reference_paths, paths, actual_met, unresolved, not reason, reason,
                      work.steps, work.nested)


