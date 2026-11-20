"""Read-only observation discovery and deterministic candidate display contract.

Canonical depth uses the existing Host codec. No whitelist, reservation, intent
or execution capability is accepted by this module.
"""
from dataclasses import dataclass
from fractions import Fraction
from itertools import combinations
from typing import Optional
import hashlib
import json

from strategies.cross_venue import arbitrage_baseline as b
from strategies.cross_venue import arbitrage_economics as e
from strategies.cross_venue import arbitrage_evaluation as v
from strategies.cross_venue import arbitrage_probability as p
from strategy_host import decode_depth_snapshot, RecoveryNeeded

SCHEMA = "arbitrage_candidates_v1"


@dataclass(frozen=True)
class Scope:
    version: int
    venues: tuple = ()
    products: tuple = ()
    include_assets: tuple = ()
    exclude_assets: tuple = ()
    quote_asset: object = None
    min_depth_atoms: object = None
    max_depth_atoms: object = None
    environment: object = None
    members: tuple = ()

    def __post_init__(self):
        b.uint(self.version, 1)
        v._tuple(self.members, 64)
        if any(not isinstance(x, Scope) or x.members for x in self.members):
            raise b.Rejected("scan_scope_members")
        if self.environment is not None and self.environment not in ("simulation", "demo", "testnet", "production"):
            raise b.Rejected("scan_environment")
        for name in ("venues", "products", "include_assets", "exclude_assets"):
            values = getattr(self, name)
            v._tuple(values)
            if len(set(values)) != len(values):
                raise b.Rejected("duplicate_scan_scope")
            for value in values:
                if name == "products":
                    if value not in ("spot", "linear"):
                        raise b.Rejected("scan_product_scope")
                else:
                    e.integer(value, 1)
        if self.quote_asset is not None:
            e.integer(self.quote_asset, 1)
        for value in (self.min_depth_atoms, self.max_depth_atoms):
            if value is not None:
                e.integer(value)
                if self.quote_asset is None:
                    raise b.Rejected("scan_depth_unit")
        if (self.min_depth_atoms is not None and self.max_depth_atoms is not None
                and self.min_depth_atoms > self.max_depth_atoms):
            raise b.Rejected("scan_depth_range")

    def contains(self, observation):
        asset = observation.rules.exposure_asset
        if ((self.venues and observation.venue not in self.venues)
                or (self.environment is not None and observation.environment != self.environment)
                or (self.products and observation.kind not in self.products)
                or (self.include_assets and asset not in self.include_assets)
                or asset in self.exclude_assets):
            return False
        if self.members and not any(x.contains(observation) for x in self.members):
            return False
        if self.min_depth_atoms is None and self.max_depth_atoms is None:
            return True
        if observation.rules.quote_asset != self.quote_asset:
            return False
        if observation.book is None:
            return True  # Keep pending routes visible until depth can be checked.
        book = decode_depth_snapshot(observation.book)
        if any(lots is None for side in ("bids", "asks") for _, lots in book[side]):
            return False
        depth = min(e.exact(sum(observation.rules.notional(ticks, lots)
                    for ticks, lots in book[side])) for side in ("bids", "asks"))
        return ((self.min_depth_atoms is None or depth >= self.min_depth_atoms)
                and (self.max_depth_atoms is None or depth <= self.max_depth_atoms))

    def display(self):
        return {"schema": "arbitrage_scope_v1", "version": str(self.version),
                "environment": self.environment, "members": [x.display() for x in self.members],
                "venues": [str(x) for x in self.venues], "products": list(self.products),
                "include_assets": [str(x) for x in self.include_assets],
                "exclude_assets": [str(x) for x in self.exclude_assets],
                **{name: None if getattr(self, name) is None else str(getattr(self, name))
                   for name in ("quote_asset", "min_depth_atoms", "max_depth_atoms")}}


@dataclass(frozen=True)
class Observation:
    venue: int
    account: int
    kind: str
    rules: e.InstrumentRules
    book: Optional[bytes]
    continuous: bool
    environment: str = "simulation"
    market_source: Optional[tuple] = None  # Actual environment, endpoint, input kind.
    market_error: Optional[str] = None
    registered_assets: Optional[tuple] = None  # Core (identity, scale) for exposure and quote.

    def __post_init__(self):
        for identity in (self.venue, self.account):
            if type(identity) is not int or not 0 < identity < 1 << 128:
                raise b.Rejected("observation_identity")
        if self.kind not in ("spot", "linear") or not isinstance(self.rules, e.InstrumentRules):
            raise b.Rejected("observation_product")
        if type(self.continuous) is not bool or (self.book is None and self.continuous):
            raise b.Rejected("observation_depth")
        if self.environment not in ("simulation", "demo", "testnet", "production"):
            raise b.Rejected("observation_environment")
        if self.market_source is not None and (type(self.market_source) is not tuple
                or len(self.market_source) != 3 or any(type(x) is not str or not x for x in self.market_source)):
            raise b.Rejected("observation_market_source")
        if self.market_error is not None and (type(self.market_error) is not str or len(self.market_error) > 2048):
            raise b.Rejected("observation_market_error")
        if self.registered_assets is not None and (type(self.registered_assets) is not tuple
                or len(self.registered_assets) != 2 or any(type(x) is not tuple or len(x) != 2
                    or any(type(n) is not int for n in x) or x[0] <= 0 or not 0 <= x[1] <= 18
                    for x in self.registered_assets)):
            raise b.Rejected("observation_registered_assets")
        if self.book is None:
            return
        if type(self.book) is not bytes:
            raise b.Rejected("observation_depth")
        try:
            book = decode_depth_snapshot(self.book)
        except RecoveryNeeded as error:
            raise b.Rejected("observation_depth") from error
        if (book["instrument"], book["rules_version"]) != (self.rules.instrument, self.rules.version):
            raise b.Rejected("observation_rules")

    @property
    def identity(self):
        return self.venue, self.account, self.rules.instrument


@dataclass(frozen=True)
class Plan:
    pair: tuple
    maker_leg: object
    scenarios: tuple
    policy: v.Policy
    estimator: v.Estimator
    calibration: p.Calibration
    simulation_error: p.SimulationError
    limits: v.Limits
    valid_until_ns: int
    occupied_atoms: int
    fee_version: Optional[str] = None

    def require_current_fees(self, fees):
        if self.fee_version is None and fees is None:
            return
        if self.fee_version is None or fees is None:
            raise b.Rejected("fees_version_missing")
        fees.require_current(self.fee_version)

    def __post_init__(self):
        if self.fee_version is not None and (type(self.fee_version) is not str
                or not self.fee_version.isascii() or not self.fee_version.isdecimal()
                or self.fee_version.startswith("0")):
            raise b.Rejected("fees_version_invalid")
        if (type(self.pair) is not tuple or len(self.pair) != 2
                or any(type(x) is not tuple or len(x) != 3 for x in self.pair)):
            raise b.Rejected("scan_pair")
        for leg in self.pair:
            for identity in leg:
                if type(identity) is not int or not 0 < identity < 1 << 128:
                    raise b.Rejected("scan_pair")
        if self.pair[0] >= self.pair[1] or not isinstance(self.policy, v.Policy):
            raise b.Rejected("scan_pair_order")
        if ((self.policy.mode == "taker_taker" and self.maker_leg is not None)
                or (self.policy.mode == "maker_taker" and
                    (type(self.maker_leg) is not int or self.maker_leg not in (0, 1)))):
            raise b.Rejected("scan_maker_leg")
        if self.policy.scope != candidate_id(*self.key):
            raise b.Rejected("scan_policy_scope")
        v._tuple(self.scenarios)
        if not self.scenarios or any(not isinstance(x, v.Scenario) for x in self.scenarios):
            raise b.Rejected("scan_scenarios")
        if (not isinstance(self.estimator, v.Estimator) or not isinstance(self.calibration, p.Calibration)
                or not isinstance(self.simulation_error, p.SimulationError) or not isinstance(self.limits, v.Limits)):
            raise b.Rejected("scan_evidence")
        b.uint(self.valid_until_ns, self.policy.at_ns+1)
        e.integer(self.occupied_atoms, 1)

    @property
    def key(self):
        return self.pair, self.policy.direction, self.policy.mode, self.maker_leg


def _ratio(value):
    return None if value is None else [str(e.exact(value).numerator), str(e.exact(value).denominator)]


def candidate_id(pair, direction, mode, maker_leg):
    """Stable scope for policies/calibration, including the particular maker leg."""
    key = pair, direction, mode, maker_leg
    return hashlib.sha256(json.dumps([SCHEMA, key], separators=(",", ":")).encode("ascii")).hexdigest()


def compatible_pairs(observations, *, legacy=False, selected_pairs=None):
    indexed = {x.identity: x for x in observations}
    if selected_pairs is None:
        # Every compatibility rule requires the same exposure or a shared
        # registered base. Keep unrelated catalogue entries out of the join.
        groups = {}
        for item in indexed.values():
            groups.setdefault(("exposure", item.rules.exposure_asset), []).append(item.identity)
            if not legacy:
                bases = {item.rules.registered_base, item.registered_assets[0] if item.registered_assets else None}
                for base in bases - {None}:
                    groups.setdefault(("registered", base), []).append(item.identity)
        selected_pairs = {pair for group in groups.values() for pair in combinations(sorted(group), 2)
                          if pair[0][0] != pair[1][0]}
    pairs = {}
    for key in sorted(selected_pairs):
        if any(identity not in indexed for identity in key):
            continue
        a, z = (indexed[identity] for identity in key)
        if (a.venue == z.venue or (legacy and a.environment != z.environment)
                or a.account == z.account or a.rules.instrument == z.rules.instrument):
            continue
        shared_units = (a.rules.exposure_asset, a.rules.quote_asset) == (z.rules.exposure_asset, z.rules.quote_asset)
        shared_registration = not legacy and a.registered_assets is not None and a.registered_assets == z.registered_assets
        shared_exposure = (e.compatible_exposure(a.rules, z.rules)
                           or a.registered_assets is not None and z.registered_assets is not None
                           and a.registered_assets[0] == z.registered_assets[0])
        mixed_parity = (not legacy and shared_exposure
                        and a.rules.quote_asset != z.rules.quote_asset and e.compatible_quotes(a.rules, z.rules))
        if not (shared_units or shared_registration or mixed_parity):
            continue
        pairs[a.identity, z.identity] = a, z
    return pairs


def pair_keys(pair, legs, *, legacy=False):
    a, z = legs
    directions = (1, -1) if not legacy or a.kind == z.kind else ((1,) if a.kind == "spot" else (-1,))
    return tuple((pair, direction, mode, maker) for direction in directions
                 for mode, maker in (("taker_taker", None), ("maker_taker", 0), ("maker_taker", 1)))


def _valid_failure(failure):
    if type(failure) is str:
        return len(failure) <= 256
    return (type(failure) is dict and set(failure) == {"leg", "reason"}
            and type(failure["leg"]) is int and failure["leg"] in (0, 1)
            and type(failure["reason"]) is str and len(failure["reason"]) <= 256)


def scan(observations, plans, *, at_ns, cursor, max_age_ns, max_skew_ns, scope=None,
         plan_failures=None, input_versions=None, legacy=False, fx_rate=None, selected_pairs=None):
    """Full replacement snapshot; omitted/expired rows cannot retain eligibility.

    Plans are frozen research scenario inputs, not scanner-generated forecasts.
    Missing research evidence still leaves a visible pending observation.
    """
    b.uint(at_ns)
    b.uint(cursor, 1)
    b.uint(max_age_ns, 1)
    b.uint(max_skew_ns)
    if fx_rate is not None and (not isinstance(fx_rate, e.FxRate) or
            not 0 <= at_ns-fx_rate.at_ns < max_age_ns):
        fx_rate = None
    v._tuple(observations, 64)
    v._tuple(plans)
    if any(not isinstance(x, Observation) for x in observations) or any(not isinstance(x, Plan) for x in plans):
        raise b.Rejected("scan_input")
    indexed = {x.identity: x for x in observations}
    if len(indexed) != len(observations):
        raise b.Rejected("duplicate_observation")
    if scope is not None and not isinstance(scope, Scope):
        raise b.Rejected("scan_scope")
    pairs = compatible_pairs(observations, legacy=legacy, selected_pairs=selected_pairs)
    plan_failures = {} if plan_failures is None else plan_failures
    if type(plan_failures) is not dict or len(plan_failures) > 256 or any(
            type(key) is not str or not _valid_failure(failure) for key, failure in plan_failures.items()):
        raise b.Rejected("scan_plan_failures")
    selected_identities = {x.identity for x in observations if scope is None or scope.contains(x)}
    active_pairs = {pair: legs for pair, legs in pairs.items() if all(x.identity in selected_identities for x in legs)}
    if len(active_pairs) > 256:
        raise b.Rejected("scan_pair_capacity")
    grouped = {}
    for plan in plans:
        if plan.pair not in pairs:
            raise b.Rejected("plan_outside_observation")
        # Validate the original binding even when a new observation filter hides it.
        legs = pairs[plan.pair]
        try:
            e.strategy_units(tuple(x.rules for x in legs), plan.policy.base_asset, plan.policy.quote_asset)
        except ValueError as error:
            raise b.Rejected("scan_asset_scope") from error
        for scenario in plan.scenarios:
            if len(scenario.entry.legs) != 2:
                if scenario.entry.state == "flat":
                    continue
                raise b.Rejected("scan_entry_scope")
            for observed, projected in zip(legs, scenario.entry.legs):
                if (observed.account, observed.rules, observed.kind) != (projected.account, projected.rules, projected.kind):
                    raise b.Rejected("scan_entry_scope")
            if scenario.markets[0].at_ns == at_ns and scenario.markets[0].books != tuple(x.book for x in legs):
                raise b.Rejected("scan_depth_scope")
        quantities = grouped.setdefault(plan.key, {})
        quantity = e.exact(plan.policy.original_base)
        if quantity in quantities:
            raise b.Rejected("duplicate_scan_plan")
        quantities[quantity] = plan
    rows = []
    books_by_identity = {x.identity: decode_depth_snapshot(x.book) for x in observations
                         if x.identity in selected_identities and x.book is not None}
    for pair, legs in active_pairs.items():
        a, z = legs
        books = tuple(books_by_identity.get(x.identity) for x in legs)
        times = tuple(book["visible_at_ns"] for book in books if book is not None)
        if any(t > at_ns for t in times):
            raise b.Rejected("future_observation")
        book_issues = tuple(("book_missing" if book is None else
                            "data_gap" if not leg.continuous else
                            "stale_data" if at_ns-book["visible_at_ns"] >= max_age_ns else
                            "rules_expired" if not leg.rules.valid_from_ns <= at_ns < leg.rules.valid_until_ns else "")
                            for leg, book in zip(legs, books))
        skewed = len(times) == 2 and abs(times[0] - times[1]) > max_skew_ns
        health = next((issue for issue in ("book_missing", "data_gap", "stale_data", "data_skew", "rules_expired")
                       if issue in book_issues or (issue == "data_skew" and skewed)), "")
        for key in pair_keys(pair, legs, legacy=legacy):
            _, direction, mode, maker = key
            buy, sell = (0, 1) if direction == 1 else (1, 0)
            observed_edge = None
            quote_compatible = e.compatible_quotes(a.rules, z.rules)
            if not health and quote_compatible:
                buy_price = books[buy]["asks"][0][0] * legs[buy].rules.tick_quote_atoms_per_base_atom
                sell_price = books[sell]["bids"][0][0] * legs[sell].rules.tick_quote_atoms_per_base_atom
                sell_price *= e.quote_factor(legs[sell].rules, legs[buy].rules)
                observed_edge = (sell_price - buy_price) * 10_000 / buy_price
            elif not health and a.registered_assets is not None and a.registered_assets == z.registered_assets:
                buy_price = books[buy]["asks"][0][0] * legs[buy].rules.tick_quote_atoms_per_base_atom
                sell_price = books[sell]["bids"][0][0] * legs[sell].rules.tick_quote_atoms_per_base_atom
                observed_edge = (sell_price - buy_price) * 10_000 / buy_price
            unsupported = ("spot_spot_observation_only" if a.kind == z.kind == "spot" else "") if legacy else (
                "spot_sell_unsupported" if legs[sell].kind == "spot" else "")
            if not unsupported and (not e.compatible_exposure(a.rules, z.rules) or not quote_compatible):
                unsupported = "evaluation_asset_scope"
            options = grouped.get(key, {})
            if len(rows) >= 256:
                raise b.Rejected("scan_candidate_capacity")
            evaluated = []
            for plan in options.values():
                policy = plan.policy
                reason = health or (unsupported if not legacy else "") or ("expired" if at_ns >= plan.valid_until_ns or at_ns >= policy.deadline_ns else
                                    "evaluation_cutoff" if policy.at_ns != at_ns else "")
                result = None
                if not reason:
                    reason = unsupported
                if not reason:
                    try:
                        result = v.evaluate(plan.scenarios, policy, plan.estimator, plan.calibration,
                                            plan.simulation_error, plan.limits)
                        reason = result.reason
                    except (ValueError, OverflowError, ZeroDivisionError) as error:
                        reason = str(error)[:256]
                evaluated.append((plan, result, reason))
            # Qualified quantities first; then actual-plan profit, lower occupancy, lower quantity.
            evaluated.sort(key=lambda x: (not (x[1] is not None and x[1].allowed and not x[2]),
                -(x[1].plan_atoms if x[1] is not None and x[1].plan_atoms is not None else -e.MAX_INTEGER),
                x[0].occupied_atoms, e.exact(x[0].policy.original_base)))
            candidate = candidate_id(*key)
            failure = plan_failures.get(candidate, "missing_evidence")
            failure_leg = None
            if type(failure) is dict:
                failure_leg, failure = failure["leg"], failure["reason"]
            plan, result, reason = evaluated[0] if evaluated else (None, None, health or unsupported or failure)
            age = min(max_age_ns, plan.policy.max_book_age_ns) if plan else max_age_ns
            end = min(*(min(b.MAX_U64, t+age) for t in times), *(x.rules.valid_until_ns for x in legs),
                      plan.valid_until_ns if plan else b.MAX_U64, plan.policy.deadline_ns if plan else b.MAX_U64,
                      plan.calibration.valid_until_ns if plan else b.MAX_U64)
            probability = result.entry_probability if result else None
            route_legs = []
            for i, leg in enumerate(legs):
                issues = [book_issues[i]] if book_issues[i] else []
                if book_issues[i] and leg.market_error:
                    issues.append(leg.market_error)
                if health == "data_skew" and times[i] == min(times):
                    issues.append("data_skew")
                if i == sell and unsupported == "spot_sell_unsupported":
                    issues.extend(("spot_inventory_unverified", unsupported))
                if i == failure_leg and reason == failure:
                    issues.append(failure)
                issues.append("execution_capability_unverified")
                actual, endpoint, input_kind = leg.market_source or (None, None, None)
                route_legs.append(dict(venue=str(leg.venue), account=str(leg.account),
                    instrument=str(leg.rules.instrument), product=leg.kind, side="buy" if i == buy else "sell",
                    requested_environment=leg.environment, actual_environment=actual,
                    market_endpoint=endpoint, market_input_kind=input_kind, issues=issues))
            estimated_fx = {}
            if not legacy and any(x.rules.settlement_unit and x.rules.settlement_unit[0] == "USDC" for x in legs):
                paths = result.plan_paths if result else ()
                units = (e.exact(sum(x.weight*x.usdc_units for x in paths))
                         if paths and all(x.usdc_units is not None for x in paths) else None)
                deviation = e.parity_deviation(units, fx_rate) if units is not None and fx_rate else None
                estimated_fx["estimated_fx"] = dict(status="pending" if deviation is None else "available",
                    net_usdc=_ratio(units), deviation_usdt=_ratio(deviation),
                    rate=fx_rate.display() if fx_rate else None,
                    settlement_assets=[str(x.rules.settlement[0] if x.rules.settlement else x.rules.quote_asset)
                                       for x in legs])
            rows.append({"id": candidate, "pair": [[str(n) for n in x] for x in pair],
                "base_asset": str(a.rules.base_asset),
                "quote_asset": str(plan.policy.quote_asset if plan else a.rules.quote_asset),
                "direction": direction, "mode": mode, "maker_leg": maker,
                "products": [x.kind for x in legs],
                **({"legs": route_legs} if not legacy else {}),
                "observed_edge_bp": _ratio(observed_edge),
                **estimated_fx,
                "status": "evaluated" if result is not None and result.allowed and not reason else
                          "rejected" if result is not None and reason in ("reference_profit", "profit", "edge", "probability", "hard_gate") else "pending",
                "reason": reason, "trading_qualified": False,
                "quantity_base": _ratio(plan.policy.original_base) if plan else None,
                "reference_atoms": str(result.reference_atoms) if result and result.reference_atoms is not None else None,
                "plan_atoms": str(result.plan_atoms) if result and result.plan_atoms is not None else None,
                "target_atoms": str(result.entry_target_atoms) if result and result.entry_target_atoms is not None else None,
                "probability_lower_ppm": probability.lower_ppm if probability else None,
                "worst_net_atoms": str(min(x.net_atoms for x in result.plan_paths))
                    if result and result.plan_paths and all(x.net_atoms is not None for x in result.plan_paths) else None,
                "unresolved_weight": _ratio(result.unresolved_weight) if result else None,
                "occupied_atoms": str(plan.occupied_atoms) if plan else None,
                "model_hash": plan.policy.model_hash if plan else None,
                "policy_version": str(plan.policy.version) if plan else None,
                "calibration_version": str(plan.calibration.version) if plan else None,
                "scenario_digest": result.scenario_digest if result else None,
                "estimator_digest": result.estimator_digest if result else None,
                "data_cutoff_ns": str(min(times, default=at_ns)), "valid_until_ns": str(end), "recommended": False,
                **({"input_versions": input_versions.get(candidate_id(*key), {}).get(str(plan.policy.original_base), {})
                   if plan else {}} if input_versions is not None else {})})
    for pair in active_pairs:
        for direction in (1, -1):
            eligible = [row for row in rows if row["pair"] == [[str(n) for n in x] for x in pair]
                        and row["direction"] == direction and row["status"] == "evaluated"]
            if eligible:
                best = min(eligible, key=lambda row: (-int(row["plan_atoms"]), int(row["occupied_atoms"]), row["id"]))
                best["recommended"] = True
    return {"schema": SCHEMA, "at_ns": str(at_ns), "cursor": str(cursor),
            "replacement": True, "candidates": rows,
            **({"scope": scope.display()} if scope is not None else {})}


def display_json(snapshot, *, at_ns):
    """Strategy-side display adapter; refresh expiry even without market events."""
    b.uint(at_ns)
    if type(snapshot) is not dict or snapshot.get("schema") != SCHEMA or at_ns < int(snapshot["at_ns"]):
        raise b.Rejected("display_snapshot")
    rows = []
    for row in snapshot["candidates"]:
        row = dict(row)
        if at_ns >= int(row["valid_until_ns"]):
            row.update(status="pending", reason="expired", trading_qualified=False, recommended=False)
        rows.append(row)
    return json.dumps(dict(snapshot, at_ns=str(at_ns), candidates=rows),
                      sort_keys=True, separators=(",", ":"), allow_nan=False)
