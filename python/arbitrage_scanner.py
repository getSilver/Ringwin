"""Read-only observation discovery and deterministic candidate display contract.

Canonical depth uses the existing Host codec. No whitelist, reservation, intent
or execution capability is accepted by this module.
"""
from dataclasses import dataclass
from fractions import Fraction
from itertools import combinations
import hashlib
import json

import arbitrage_baseline as b
import arbitrage_economics as e
import arbitrage_evaluation as v
import arbitrage_probability as p
from strategy_host import decode_depth_snapshot, RecoveryNeeded

SCHEMA = "arbitrage_candidates_v1"


@dataclass(frozen=True)
class Observation:
    venue: int
    account: int
    kind: str
    rules: e.InstrumentRules
    book: bytes
    continuous: bool

    def __post_init__(self):
        for identity in (self.venue, self.account):
            if type(identity) is not int or not 0 < identity < 1 << 128:
                raise b.Rejected("observation_identity")
        if self.kind not in ("spot", "linear") or not isinstance(self.rules, e.InstrumentRules):
            raise b.Rejected("observation_product")
        if type(self.book) is not bytes or type(self.continuous) is not bool:
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

    def __post_init__(self):
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


def scan(observations, plans, *, at_ns, cursor, max_age_ns, max_skew_ns):
    """Full replacement snapshot; omitted/expired rows cannot retain eligibility.

    Plans are frozen research scenario inputs, not scanner-generated forecasts.
    Missing research evidence still leaves a visible pending observation.
    """
    b.uint(at_ns)
    b.uint(cursor, 1)
    b.uint(max_age_ns, 1)
    b.uint(max_skew_ns)
    v._tuple(observations, 64)
    v._tuple(plans)
    if any(not isinstance(x, Observation) for x in observations) or any(not isinstance(x, Plan) for x in plans):
        raise b.Rejected("scan_input")
    indexed = {x.identity: x for x in observations}
    if len(indexed) != len(observations):
        raise b.Rejected("duplicate_observation")
    pairs = {}
    for a, z in combinations(sorted(observations, key=lambda x: x.identity), 2):
        if (a.venue == z.venue or a.account == z.account or a.rules.instrument == z.rules.instrument
                or (a.rules.exposure_asset, a.rules.quote_asset) != (z.rules.exposure_asset, z.rules.quote_asset)):
            continue
        pairs[a.identity, z.identity] = a, z
    if len(pairs) > 256:
        raise b.Rejected("scan_pair_capacity")
    grouped = {}
    for plan in plans:
        if plan.pair not in pairs:
            raise b.Rejected("plan_outside_observation")
        quantities = grouped.setdefault(plan.key, {})
        quantity = e.exact(plan.policy.original_base)
        if quantity in quantities:
            raise b.Rejected("duplicate_scan_plan")
        quantities[quantity] = plan
    rows = []
    for pair, legs in pairs.items():
        a, z = legs
        books = tuple(decode_depth_snapshot(x.book) for x in legs)
        times = tuple(x["visible_at_ns"] for x in books)
        if any(t > at_ns for t in times):
            raise b.Rejected("future_observation")
        health = ("data_gap" if not all(x.continuous for x in legs) else
                  "stale_data" if any(at_ns-t >= max_age_ns for t in times) else
                  "data_skew" if max(times)-min(times) > max_skew_ns else
                  "rules_expired" if any(not x.rules.valid_from_ns <= at_ns < x.rules.valid_until_ns for x in legs) else "")
        directions = (1, -1) if a.kind == z.kind else ((1,) if a.kind == "spot" else (-1,))
        for direction in directions:
            for mode, maker in (("taker_taker", None), ("maker_taker", 0), ("maker_taker", 1)):
                key = pair, direction, mode, maker
                options = grouped.get(key, {})
                if len(rows) >= 256:
                    raise b.Rejected("scan_candidate_capacity")
                evaluated = []
                for quantity, plan in options.items():
                    policy = plan.policy
                    reason = health or ("expired" if at_ns >= plan.valid_until_ns or at_ns >= policy.deadline_ns else
                                        "evaluation_cutoff" if policy.at_ns != at_ns else "")
                    if (policy.base_asset, policy.quote_asset) != (a.rules.exposure_asset, a.rules.quote_asset):
                        raise b.Rejected("scan_asset_scope")
                    for scenario in plan.scenarios:
                        if len(scenario.entry.legs) != 2:
                            if scenario.entry.state == "flat":
                                continue
                            raise b.Rejected("scan_entry_scope")
                        for observed, projected in zip(legs, scenario.entry.legs):
                            if (observed.account, observed.rules, observed.kind) != (projected.account, projected.rules, projected.kind):
                                raise b.Rejected("scan_entry_scope")
                        # Same-cutoff projections must bind the exact canonical input.
                        if scenario.markets[0].at_ns == at_ns and scenario.markets[0].books != tuple(x.book for x in legs):
                            raise b.Rejected("scan_depth_scope")
                    result = None
                    if not reason and a.kind == z.kind == "spot":
                        reason = "spot_spot_observation_only"
                    if not reason:
                        result = v.evaluate(plan.scenarios, policy, plan.estimator, plan.calibration,
                                            plan.simulation_error, plan.limits)
                        reason = result.reason
                    evaluated.append((plan, result, reason))
                # Qualified quantities first; then actual-plan profit, lower occupancy, lower quantity.
                evaluated.sort(key=lambda x: (not (x[1] is not None and x[1].allowed and not x[2]),
                    -(x[1].plan_atoms if x[1] is not None and x[1].plan_atoms is not None else -e.MAX_INTEGER),
                    x[0].occupied_atoms, e.exact(x[0].policy.original_base)))
                plan, result, reason = evaluated[0] if evaluated else (None, None,
                    health or ("spot_spot_observation_only" if a.kind == z.kind == "spot" else "missing_evidence"))
                age = min(max_age_ns, plan.policy.max_book_age_ns) if plan else max_age_ns
                end = min(*(min(b.MAX_U64, t+age) for t in times), *(x.rules.valid_until_ns for x in legs),
                          plan.valid_until_ns if plan else b.MAX_U64, plan.policy.deadline_ns if plan else b.MAX_U64,
                          plan.calibration.valid_until_ns if plan else b.MAX_U64)
                probability = result.entry_probability if result else None
                rows.append({"id": candidate_id(*key), "pair": [[str(n) for n in x] for x in pair],
                    "base_asset": str(a.rules.base_asset), "quote_asset": str(a.rules.quote_asset),
                    "direction": direction, "mode": mode, "maker_leg": maker,
                    "status": "evaluated" if result is not None and result.allowed and not reason else "pending",
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
                    "data_cutoff_ns": str(min(times)), "valid_until_ns": str(end), "recommended": False})
    for pair in pairs:
        for direction in (1, -1):
            eligible = [row for row in rows if row["pair"] == [[str(n) for n in x] for x in pair]
                        and row["direction"] == direction and row["status"] == "evaluated"]
            if eligible:
                best = min(eligible, key=lambda row: (-int(row["plan_atoms"]), int(row["occupied_atoms"]), row["id"]))
                best["recommended"] = True
    return {"schema": SCHEMA, "at_ns": str(at_ns), "cursor": str(cursor),
            "replacement": True, "candidates": rows}


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
