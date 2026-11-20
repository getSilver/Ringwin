"""Node-owned frozen research inputs -> current-depth Plans for the shared evaluator.

This module never fits models, calibrates probabilities, or grants trading authority.
"""
from collections import deque
from dataclasses import replace
from fractions import Fraction
import hashlib
import json
from pathlib import Path

from opportunity_scanner import arbitrage_scanner as s
from opportunity_scanner.scanner_archive import freeze, thaw, MAX_BYTES
from opportunity_scanner.scanner_config import atomic_json, _object
from strategies.cross_venue import arbitrage_baseline as b
from strategies.cross_venue import arbitrage_economics as e
from strategies.cross_venue import arbitrage_evaluation as v
from strategies.cross_venue import arbitrage_probability as p

SCHEMA = "scanner_evaluation_inputs_v1"


class LegUnavailable(b.Rejected):
    def __init__(self, leg, reason):
        super().__init__(reason)
        self.leg = leg


def publish_inputs(path, document):
    """Publish existing research artifacts atomically; creates no qualified evidence."""
    atomic_json(Path(path), freeze(document), MAX_BYTES)


class EvaluationInputs:
    def __init__(self, path, clock_id, *, synthetic=False, fees=None):
        self.path, self.clock_id, self.synthetic = Path(path), clock_id, synthetic
        self.fees = fees
        self.version, self.digest = 0, None
        self.books = {}
        self.state = dict(state="unloaded", clock_id=clock_id, missing=["evaluation_inputs"], plans=0)

    def _load(self, at_ns):
        if not self.path.is_file():
            raise b.Rejected("evaluation_inputs_missing")
        with self.path.open("rb") as stream:
            raw = stream.read(MAX_BYTES+1)
        if len(raw) > MAX_BYTES:
            raise b.Rejected("evaluation_inputs_capacity")
        tree = json.loads(raw, object_pairs_hook=_object)
        digest = hashlib.sha256(json.dumps(tree, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        doc = thaw(tree)
        if (type(doc) is not dict or set(doc) != {"schema", "version", "clock_id", "source_kind",
                "valid_from_ns", "valid_until_ns", "cases"} or doc["schema"] != SCHEMA):
            raise b.Rejected("evaluation_inputs_schema")
        b.uint(doc["version"], 1)
        b.uint(doc["valid_from_ns"])
        b.uint(doc["valid_until_ns"], doc["valid_from_ns"]+1)
        if doc["version"] < self.version or doc["version"] == self.version and self.digest != digest:
            raise b.Rejected("evaluation_inputs_version_conflict")
        if doc["clock_id"] != self.clock_id:
            raise b.Rejected("evaluation_clock_mismatch")
        if doc["source_kind"] != "historical" and not (self.synthetic and doc["source_kind"] == "synthetic"):
            raise b.Rejected("evaluation_source_kind")
        if not doc["valid_from_ns"] <= at_ns < doc["valid_until_ns"]:
            raise b.Rejected("evaluation_inputs_expired")
        if type(doc["cases"]) is not tuple or len(doc["cases"]) > 256:
            raise b.Rejected("evaluation_case_capacity")
        self.version, self.digest = doc["version"], digest
        return doc

    def _remember(self, observations):
        current = {o.identity for o in observations if o.continuous}
        self.books = {k:q for k,q in self.books.items() if k in current}
        for o in observations:
            if not o.continuous:
                continue
            q = self.books.setdefault(o.identity, deque(maxlen=16))
            if q and q[-1].rules != o.rules:
                q.clear()
            if not q or q[-1].book != o.book:
                q.append(o)

    def _point(self, legs, policy, at_ns, max_skew_ns):
        grid = at_ns // b.SECOND * b.SECOND
        chosen = []
        for leg in legs:
            available = [o for o in self.books.get(leg.identity, ())
                         if s.decode_depth_snapshot(o.book)["visible_at_ns"] <= grid]
            if not available:
                raise b.Rejected("model_warming")
            chosen.append(available[-1])
        sampler = b.GridSampler(legs[0].rules, legs[1].rules, version=policy.version,
            max_age_ns=policy.max_book_age_ns, max_skew_ns=max_skew_ns)
        for cursor, index in enumerate(sorted((0, 1), key=lambda i:
                s.decode_depth_snapshot(chosen[i].book)["visible_at_ns"]), 1):
            o = chosen[index]
            sampler.observe(index, o.book, cursor=cursor,
                admitted_at_ns=s.decode_depth_snapshot(o.book)["visible_at_ns"], healthy=True, continuous=True)
        point = sampler.sample(grid, cursor=3)
        if point.value is None or point.break_before:
            raise b.Rejected("model_warming:"+point.reason)
        return point

    def build(self, observations, *, at_ns, max_age_ns, max_skew_ns, bindings, pairs=None):
        """Return plans AND concrete per-candidate admission failures for one cutoff."""
        self._remember(observations)
        pairs = s.compatible_pairs(observations, selected_pairs=pairs)
        keys = [key for pair, legs in pairs.items() for key in s.pair_keys(pair, legs)]
        if len(keys) > 256:
            raise b.Rejected("scan_candidate_capacity")
        failures, plans, versions = {}, [], {}
        fee_version = self.fees.view()["version"] if self.fees is not None else None
        fee_rules, fee_errors = {}, {}
        if fee_version is not None:
            for pair, legs in pairs.items():
                try:
                    fee_rules[pair] = tuple(self.fees.rule(o, version=fee_version) for o in legs)
                except ValueError as error:
                    fee_errors[pair] = str(error)
        try:
            doc = self._load(at_ns)
        except (OSError, ValueError, TypeError, KeyError, OverflowError) as error:
            reason = str(error)[:256]
            failures = {s.candidate_id(*key): fee_errors.get(key[0], reason) for key in keys}
            self.state = dict(state="missing", clock_id=self.clock_id,
                              missing=sorted({reason, *failures.values()}), plans=0)
            return (), failures, {}
        indexed = {}
        for case in doc["cases"]:
            key = case.get("key") if type(case) is dict else None
            valid_key = (type(key) is tuple and len(key) == 4 and type(key[0]) is tuple and len(key[0]) == 2
                and all(type(leg) is tuple and len(leg) == 3 and all(type(n) is int and 0 < n < 1 << 128 for n in leg) for leg in key[0])
                and key[0][0] < key[0][1] and type(key[1]) is int and key[1] in (-1, 1)
                and (key[2] == "taker_taker" and key[3] is None or key[2] == "maker_taker" and type(key[3]) is int and key[3] in (0,1)))
            if not valid_key:
                self.state = dict(state="invalid", clock_id=self.clock_id, missing=["evaluation_case_key"], plans=0)
                return (), {s.candidate_id(*key): "evaluation_case_key" for key in keys}, {}
            indexed.setdefault(s.candidate_id(*case["key"]), []).append(case)
        for key in keys:
            identity = s.candidate_id(*key)
            if key[0] in fee_errors:
                failures[identity] = fee_errors[key[0]]
                continue
            cases = indexed.get(identity, ())
            if not cases:
                failures[identity] = "evaluation_case_missing"
            for case in cases:
                try:
                    plan = self._plan(case, pairs[key[0]], at_ns, max_age_ns, max_skew_ns, bindings,
                                      doc["valid_until_ns"], fee_rules.get(key[0]))
                    if fee_version is not None:
                        plan = replace(plan, fee_version=fee_version)
                    if any(old.key == plan.key and old.policy.original_base == plan.policy.original_base for old in plans):
                        plans = [old for old in plans if old.key != plan.key]
                        failures[identity] = "duplicate_evaluation_quantity"
                        break
                    plans.append(plan)
                    versions.setdefault(identity, {})[str(plan.policy.original_base)] = dict(
                        case["versions"], package=str(doc["version"]), package_digest=self.digest,
                        **({"fees": fee_version} if fee_version is not None else {}))
                except LegUnavailable as error:
                    failures[identity] = dict(leg=error.leg, reason=str(error))
                except KeyError as error:
                    failures[identity] = f"{error.args[0]}_missing"[:256]
                except (ValueError, TypeError, OverflowError, ZeroDivisionError) as error:
                    failures[identity] = str(error)[:256]
            if any(plan.key == key for plan in plans):
                failures.pop(identity, None)
        missing = sorted({failure["reason"] if type(failure) is dict else failure for failure in failures.values()})
        self.state = dict(state="ready" if plans else "missing", clock_id=self.clock_id,
            version=str(doc["version"]), digest=self.digest, missing=missing, plans=len(plans))
        return tuple(plans), failures, versions

    def _plan(self, case, legs, at, max_age, max_skew, bindings, package_end, current_fees):
        components = {"policy": v.Policy, "estimator": v.Estimator, "calibration": p.Calibration,
                      "simulation_error": p.SimulationError, "limits": v.Limits, "bounds": v.RebaseBounds}
        for name, cls in components.items():
            if not isinstance(case.get(name), cls):
                raise b.Rejected(name+"_missing")
        for name in ("scenarios", "target_lots", "entry_fees", "entry_limits", "fee_valuations",
                "fee_balances", "funds_available", "capital_factors", "capital_buffers", "entry_minimum_notionals", "versions",
                "funds_valid_until_ns", "risk_valid_until_ns", "risk_allowed"):
            if name not in case:
                raise b.Rejected(name+"_missing")
        for name in ("target_lots", "entry_fees", "entry_limits", "fee_valuations", "fee_balances",
                     "funds_available", "capital_factors", "capital_buffers", "entry_minimum_notionals"):
            if type(case[name]) is not tuple or len(case[name]) != 2:
                raise b.Rejected(name+"_scope")
        if type(case["versions"]) is not dict or not {"fees", "funds", "risk", "entry_model", "venue_rules"} <= case["versions"].keys():
            raise b.Rejected("input_versions_missing")
        for value in case["versions"].values():
            p.reference(value)
        for name in ("funds_valid_until_ns", "risk_valid_until_ns"):
            b.uint(case[name])
            if at >= case[name]:
                raise b.Rejected(name.replace("valid_until_ns", "expired"))
        if type(case["risk_allowed"]) is not bool or not case["risk_allowed"]:
            raise b.Rejected("risk_blocked")
        old, estimator = case["policy"], case["estimator"]
        pair, direction, mode, maker = case["key"]
        if (old.scope != s.candidate_id(*case["key"]) or (old.direction, old.mode) != (direction, mode)):
            raise b.Rejected("policy_scope")
        if estimator.model_hash != old.model_hash or estimator.training_end_ns > at:
            raise b.Rejected("model_scope")
        if not case["calibration"].valid_from_ns <= at < case["calibration"].valid_until_ns:
            raise b.Rejected("calibration_expired")
        if any(not o.continuous for o in legs):
            raise b.Rejected("data_gap")
        books = tuple(s.decode_depth_snapshot(o.book) for o in legs)
        if any(not 0 <= at-book["visible_at_ns"] < min(max_age, old.max_book_age_ns) for book in books):
            raise b.Rejected("stale_data")
        if abs(books[0]["visible_at_ns"]-books[1]["visible_at_ns"]) > max_skew:
            raise b.Rejected("data_skew")
        for o in legs:
            row = bindings.get(o.identity)
            if (row is not None and o.rules.settlement is None
                    and str(row.get("settlement_asset", row["quote_asset"])) != str(row["quote_asset"])):
                raise b.Rejected("settlement_conversion_required")
        if any(o.rules.settlement is not None for o in legs):
            units = tuple(o.rules.settlement or (o.rules.quote_asset, *o.rules.quote_unit) for o in legs)
            if case.get("settlement_units") != units:
                raise b.Rejected("settlement_units_missing_or_changed")
        shift = at-old.at_ns
        policy = replace(old, at_ns=at, prediction_end_ns=old.prediction_end_ns+shift,
            risk_deadline_ns=old.risk_deadline_ns+shift, reference_exit_ns=old.reference_exit_ns+shift)
        point = self._point(legs, policy, at, max_skew)
        if point.grid_ns < estimator.training_end_ns:
            raise b.Rejected("model_warming:training_grid")
        v._validate_scenarios(case["scenarios"])
        if any(not isinstance(fee, e.FeeRule) for fee in case["entry_fees"]):
            raise b.Rejected("fees_scope")
        if current_fees is not None:
            asset_ids = tuple(fee.fee_asset for fee in current_fees)
            if (tuple(fee.fee_asset for fee in case["entry_fees"]) != asset_ids
                    or any(tuple(leg.exit_fee.fee_asset for leg in scenario.entry.legs) != asset_ids
                           for scenario in case["scenarios"] if scenario.entry.legs)):
                raise b.Rejected("fees_asset_evidence_missing")
            case = dict(case, entry_fees=current_fees, scenarios=tuple(
                replace(scenario, entry=replace(scenario.entry, legs=tuple(
                    replace(leg, exit_fee=current_fees[i]) for i, leg in enumerate(scenario.entry.legs))))
                for scenario in case["scenarios"]))
        occupied, end = 0, min(package_end, case["funds_valid_until_ns"], case["risk_valid_until_ns"],
                               case["calibration"].valid_until_ns)
        target = e.strategy_units(tuple(o.rules for o in legs), policy.base_asset, policy.quote_asset)
        executions, buy_notional = [], None
        for i, o in enumerate(legs):
            rule, fee, lots = o.rules, case["entry_fees"][i], case["target_lots"][i]
            if not isinstance(fee, e.FeeRule) or (fee.instrument, fee.rules_version) != (rule.instrument, rule.version):
                raise b.Rejected("fees_scope")
            if not fee.valid_from_ns <= at < fee.valid_until_ns:
                raise b.Rejected("fees_expired")
            end = min(end, fee.valid_until_ns, rule.valid_until_ns)
            e.integer(lots, rule.min_lots)
            e.integer(case["entry_limits"][i], 1)
            factor = e.positive(case["capital_factors"][i])
            if factor > 1 or o.kind == "spot" and factor != 1:
                raise b.Rejected("capital_factor_scope")
            e.integer(case["funds_available"][i]); e.integer(case["capital_buffers"][i])
            side = "buy" if (i == 0) == (direction == 1) else "sell"
            limit = case["entry_limits"][i]
            if rule.notional(limit, lots) < rule.min_notional_atoms:
                raise b.Rejected("minimum_notional")
            if mode == "maker_taker" and maker == i:
                if (limit >= books[i]["asks"][0][0] if side == "buy" else limit <= books[i]["bids"][0][0]):
                    raise b.Rejected("maker_would_cross")
                notional = rule.notional(limit, lots)
                full_fills = ((limit, lots),)
            else:
                sweep = e.sweep(books[i], rule, side, lots, limit, now_ns=at, max_age_ns=policy.max_book_age_ns)
                if sweep.remaining_lots:
                    raise LegUnavailable(i, "insufficient_depth")
                notional = sweep.quote_atoms
                full_fills = sweep.fills
            executions.append(full_fills)
            if side == "buy":
                buy_notional = notional*e.quote_factor(rule, target)
            e.integer(case["entry_minimum_notionals"][i])
            if notional < max(rule.min_notional_atoms, case["entry_minimum_notionals"][i]):
                raise b.Rejected("minimum_notional")
            balance, entry_cost = case["fee_balances"][i], Fraction(0)
            e.integer(balance)
            for ticks, count in full_fills:
                valuation = rule.fee_valuation(fee.fee_asset, ticks, case["fee_valuations"][i])
                paid = e.estimate_fee(rule, fee, ticks=ticks, lots=count,
                    role="maker" if maker == i and mode == "maker_taker" else "taker", now_ns=at,
                    quote_atoms_per_fee_atom=valuation, available_fee_atoms=balance)
                entry_cost += paid.quote_atoms
                if fee.fee_asset not in (rule.base_asset, rule.quote_asset):
                    balance -= paid.asset_atoms
            funding_reserve = max((sum(cost.atoms for cost in scenario.markets[-1].funding_costs if cost.leg == i)
                for scenario in case["scenarios"] if scenario.markets), default=0)
            funding_reserve = e.ceil_atoms(funding_reserve*max(Fraction(1), case["bounds"].max_price_factor))
            needed = (e.ceil_atoms((notional*factor+max(Fraction(0), entry_cost))*rule.settlement_factor)
                      +case["capital_buffers"][i]+funding_reserve)
            if needed > case["funds_available"][i]:
                raise LegUnavailable(i, "insufficient_funds")
            occupied += needed*e.quote_factor(rule, target)/rule.settlement_factor
        scenarios = []
        for source in case["scenarios"]:
            entry = source.entry
            if entry.completed and not source.markets:
                raise b.Rejected("entry_cost_projection_missing")
            if (entry.completed or source.markets and source.markets[0].funding_costs) and source.markets and any(v._mid(book, o.rules) !=
                    v._mid(s.decode_depth_snapshot(payload), o.rules)
                    for book, payload, o in zip(books, source.markets[0].books, legs)):
                raise b.Rejected("entry_cost_projection_missing")
            projected, balances = [], list(case["fee_balances"])
            for i, original in enumerate(entry.legs):
                o, fee = legs[i], case["entry_fees"][i]
                if ((original.account, original.kind) != (o.account, o.kind)
                        or not e.same_valuation_rules(original.rules, o.rules)):
                    raise b.Rejected("rules_changed")
                if original.gross_lots > case["target_lots"][i]:
                    raise b.Rejected("entry_quantity_scope")
                if not original.exit_fee.valid_from_ns <= at < original.exit_fee.valid_until_ns:
                    raise b.Rejected("fees_expired")
                end = min(end, original.exit_fee.valid_until_ns)
                expected_direction = direction if i == 0 else -direction
                if original.direction != expected_direction:
                    raise b.Rejected("entry_direction_scope")
                remaining, fills = original.gross_lots, []
                # IOC partial fills may be below order minima; the submitted order above is legal.
                for ticks, available in executions[i]:
                    count = min(remaining, available)
                    if count:
                        fills.append((ticks, count))
                        remaining -= count
                trades, balance = [], case["fee_balances"][i]
                for index, (ticks, count) in enumerate(fills):
                    valuation = o.rules.fee_valuation(fee.fee_asset, ticks, case["fee_valuations"][i])
                    paid = e.estimate_fee(o.rules, fee, ticks=ticks, lots=count,
                        role="maker" if maker == i and mode == "maker_taker" else "taker", now_ns=at,
                        quote_atoms_per_fee_atom=valuation, available_fee_atoms=balance)
                    if fee.fee_asset not in (o.rules.base_asset, o.rules.quote_asset):
                        balance -= paid.asset_atoms
                    trades.append(v.Trade("scan:"+source.identity+":"+str(i)+":"+str(index), ticks, count,
                                          paid, at+entry.holding_at_ns-old.at_ns))
                projected.append(replace(original, rules=o.rules, entries=tuple(trades)))
                balances[i] = balance
            current = replace(entry, legs=tuple(projected), holding_at_ns=entry.holding_at_ns+shift,
                              model_point=point if entry.state == "matched" else None)
            funding = tuple(replace(cost, identity="scan-funding:"+cost.identity, at_ns=cost.at_ns+shift)
                            for cost in source.markets[0].funding_costs) if source.markets else ()
            market = v.Market(current.holding_at_ns, tuple(o.book for o in legs),
                case["fee_valuations"], tuple(balances), funding,
                source.markets[0].qualified if source.markets else True,
                source.markets[0].risk if source.markets else False,
                source.markets[0].model_invalid if source.markets else False,
                source.markets[0].unknown if source.markets else False,
                source.markets[0].unknown_refs if source.markets else ())
            if current.state != "matched":
                # Retain supplied zero-fill/failed/unknown outcomes, never assume both fill.
                scenarios.append(replace(source, entry=current, markets=(market,)))
            else:
                if current.matched_base > policy.original_base:
                    raise b.Rejected("quantity_step_or_fees")
                row = v.ConditionalRow(case["calibration"].scope, (source,), case["calibration"],
                                       case["simulation_error"], case["bounds"])
                scenarios.extend(v._condition(row, v.Context(current, market, policy.absolute_minimum_atoms, policy),
                                              estimator.forecast))
        entry_base = min(policy.original_base, *(o.rules.base_atoms_per_lot*lots
                         for o, lots in zip(legs, case["target_lots"])))
        return s.Plan(pair, maker, tuple(scenarios), policy, estimator, case["calibration"],
                      case["simulation_error"], case["limits"], end, max(1, e.ceil_atoms(occupied)),
                      entry_base=entry_base, buy_notional_atoms=buy_notional)
