"""Offline IOC decisions over admitted core projections. No orders or money owned here.

Callers project the original cycle's complete order/economic facts, including cold
history. Output is a request, never a reservation, command or permission to send.
Persistence and live Host/Venue wiring are separate acceptance work.
"""
from dataclasses import dataclass, replace
from types import SimpleNamespace
import struct

from strategies.cross_venue import arbitrage_baseline as b
from strategies.cross_venue import arbitrage_admission as admission
from strategies.cross_venue import arbitrage_economics as e
from strategies.cross_venue import arbitrage_evaluation as v
from strategies.cross_venue import arbitrage_probability as p
import strategy_host as host


def _pair(items):
    if type(items) is not tuple or len(items) != 2:
        raise b.Rejected("joint_legs")
    return items


def _identity(value):
    if type(value) is not int or not 0 < value < 1 << 128:
        raise b.Rejected("identity")


@dataclass(frozen=True)
class LegSpec:
    account: int
    rules: e.InstrumentRules
    kind: str
    direction: int
    target_lots: int

    def __post_init__(self):
        _identity(self.account)
        if not isinstance(self.rules, e.InstrumentRules):
            raise b.Rejected("instrument_rules")
        if (self.kind not in ("spot", "linear") or type(self.direction) is not int
                or self.direction not in (-1, 1) or self.kind == "spot" and self.direction != 1):
            raise b.Rejected("leg_product")
        if self.kind != "spot" and self.rules.approved_base_pair is not None:
            raise b.Rejected("pairing_requires_spot")
        e.integer(self.target_lots, self.rules.min_lots)
        if self.target_lots >= 1 << 63:
            raise b.Rejected("wire_quantity")


@dataclass(frozen=True)
class Plan:
    strategy: int
    portfolio: int
    first_sequence: int
    request_ref: str
    config_version: int
    config_hash: str
    execution_hash: str
    policy: v.Policy
    legs: tuple
    entry_limits: tuple
    target_atoms: int
    repair_deadline_ns: int
    repair_attempts: int
    repair_loss_cap_atoms: int
    exit_deadline_ns: int
    exit_attempts: int
    daily_loss_atoms: int
    drawdown_atoms: int

    def __post_init__(self):
        _identity(self.strategy)
        _identity(self.portfolio)
        b.uint(self.first_sequence, 1)
        b.uint(self.config_version, 1)
        p.reference(self.request_ref)
        p.validate_hash(self.config_hash)
        p.validate_hash(self.execution_hash)
        if not isinstance(self.policy, v.Policy):
            raise b.Rejected("ioc_policy")
        a, z = _pair(self.legs)
        if any(not isinstance(x, LegSpec) for x in self.legs):
            raise b.Rejected("leg_spec")
        if (a.account == z.account or a.rules.instrument == z.rules.instrument
                or a.direction != -z.direction or a.direction != self.policy.direction
                or a.kind == z.kind == "spot"):
            raise b.Rejected("pair_scope")
        for leg in self.legs:
            if (e.exact(leg.target_lots*leg.rules.base_atoms_per_lot) < self.policy.original_base
                    or leg.kind == "linear" and leg.target_lots*leg.rules.base_atoms_per_lot != self.policy.original_base):
                raise b.Rejected("quantity_scope")
        e.strategy_units(tuple(leg.rules for leg in self.legs), self.policy.base_asset, self.policy.quote_asset)
        for ticks in (*_pair(self.entry_limits), *self.policy.normal_limits, *self.policy.risk_limits):
            if e.integer(ticks, 1) >= 1 << 63:
                raise b.Rejected("wire_price")
        e.integer(self.target_atoms, self.policy.absolute_minimum_atoms)
        b.uint(self.repair_deadline_ns, self.policy.at_ns+1)
        if self.repair_deadline_ns > self.policy.deadline_ns:
            raise b.Rejected("repair_deadline")
        b.uint(self.exit_deadline_ns, self.policy.deadline_ns)
        for count in (self.repair_attempts, self.exit_attempts):
            if b.uint(count) > 256:
                raise b.Rejected("attempt_capacity")
        if 2+self.repair_attempts+2*self.exit_attempts > e.MAX_ITEMS:
            raise b.Rejected("cycle_intent_capacity")
        if self.first_sequence+2+self.repair_attempts+2*self.exit_attempts >= 1 << 64:
            raise b.Rejected("intent_capacity")
        e.integer(self.repair_loss_cap_atoms)
        e.integer(self.daily_loss_atoms, 1)
        e.integer(self.drawdown_atoms, 1)


@dataclass(frozen=True)
class Intent:
    sequence: int
    leg: int
    lots: int
    limit_ticks: int
    reducing: bool
    time_in_force: str = "ioc"


@dataclass(frozen=True)
class OrderFact:
    sequence: int
    leg: int
    status: str
    applied_lots: int
    possible_lots: int
    economic_complete: bool
    fact_ref: str

    def __post_init__(self):
        b.uint(self.sequence, 1)
        if type(self.leg) is not int or self.leg not in (0, 1):
            raise b.Rejected("order_leg")
        if self.status not in ("sent", "unknown", "terminal", "rejected"):
            raise b.Rejected("order_status")
        e.integer(self.applied_lots)
        e.integer(self.possible_lots)
        p.reference(self.fact_ref)
        if type(self.economic_complete) is not bool:
            raise b.Rejected("economic_coverage")
        if self.status in ("terminal", "rejected") and self.possible_lots:
            raise b.Rejected("terminal_possible_fill")
        if self.status == "rejected" and self.applied_lots:
            raise b.Rejected("rejected_fill")


@dataclass(frozen=True)
class Facts:
    """A complete original-cycle projection at cursor, certified by the caller.

    positions are remaining economic base magnitudes, never OMS cumulatives.
    safe_reduce_lots includes base-asset fee consumption and all pending orders.
    economic_entry carries remaining cost basis plus disjoint completed PnL;
    corrections replace this read projection, never append a second fake Fill.
    """
    cursor: int
    at_ns: int
    cycle_ref: str
    reservation_ref: object
    admission: str
    orders: tuple
    positions: tuple
    safe_reduce_lots: tuple
    market: v.Market
    economic_entry: object
    economic_ref: str
    opening_allowed: bool
    reducing_allowed: bool
    risk_causes: tuple
    model_warning: bool
    nav_atoms: int
    day_start_nav_atoms: int
    external_allocation_atoms: int
    flow_adjusted_peak_atoms: int
    repair_loss_atoms: int
    repair_cost_atoms: int
    closed_ref: object
    residual_refs: tuple
    possible_base: tuple = ()
    fx_exposures: tuple = ()
    fx_complete: bool = True

    def __post_init__(self):
        b.uint(self.cursor, 1)
        b.uint(self.at_ns)
        for ref in (self.cycle_ref, self.economic_ref):
            p.reference(ref)
        if self.admission not in ("accepted", "rejected", "unknown"):
            raise b.Rejected("group_admission")
        if self.admission == "accepted" or self.reservation_ref is not None:
            p.reference(self.reservation_ref)
        for items in (self.orders, self.risk_causes, self.residual_refs, self.possible_base):
            if type(items) is not tuple:
                raise b.Rejected("immutable_projection")
            e.bounded(items)
        if any(not isinstance(x, OrderFact) for x in self.orders) or len({x.sequence for x in self.orders}) != len(self.orders):
            raise b.Rejected("order_projection")
        for value in _pair(self.positions):
            if e.exact(value) < 0:
                raise b.Rejected("position_magnitude")
        for lots in _pair(self.safe_reduce_lots):
            e.integer(lots)
        if not isinstance(self.market, v.Market) or self.market.at_ns > self.at_ns:
            raise b.Rejected("market_time")
        if self.economic_entry is not None and not isinstance(self.economic_entry, v.Entry):
            raise b.Rejected("economic_entry")
        if type(self.fx_exposures) is not tuple or any(
                not isinstance(row, e.FxExposure) or row.at_ns > self.at_ns for row in e.bounded(self.fx_exposures)):
            raise b.Rejected("fx_exposure_cutoff")
        if self.fx_exposures:
            e.actual_fx_report(self.fx_exposures)
        if type(self.fx_complete) is not bool:
            raise b.Rejected("fx_exposure_coverage")
        for flag in (self.opening_allowed, self.reducing_allowed, self.model_warning):
            if type(flag) is not bool:
                raise b.Rejected("permission_evidence")
        causes = []
        for item in self.risk_causes:
            for ref in _pair(item):
                p.reference(ref)
            causes.append(item[0])
        if len(set(causes)) != len(causes):
            raise b.Rejected("duplicate_risk_cause")
        for value in (self.nav_atoms, self.day_start_nav_atoms, self.external_allocation_atoms, self.flow_adjusted_peak_atoms):
            e.integer(value, -e.MAX_INTEGER)
        e.integer(self.repair_loss_atoms)
        e.integer(self.repair_cost_atoms)
        if self.closed_ref is not None:
            p.reference(self.closed_ref)
        for ref in self.residual_refs:
            p.reference(ref)
        unknown = any(x.status == "unknown" for x in self.orders) or self.admission == "unknown"
        if unknown:
            for i, bounds in enumerate(_pair(self.possible_base)):
                low, high = _pair(bounds)
                if not 0 <= e.exact(low) <= self.positions[i] <= e.exact(high):
                    raise b.Rejected("possible_exposure")
        elif self.possible_base:
            raise b.Rejected("unexpected_exposure_interval")


@dataclass(frozen=True)
class Action:
    plan: Plan
    cursor: int
    reason: str
    intents: tuple = ()
    queries: tuple = ()
    reconcile: bool = False
    escalate: bool = False
    cancels: tuple = ()
    profit: object = None

    def package_output(self, *, fee_version=None):
        """Translate a strategy action for the fixed StrategyPackage callback."""
        import strategy_api as api

        if self.cancels:
            raise b.Rejected("cancel_projection_requires_core_mapping")
        if not self.intents:
            raise b.Rejected("no_output")
        members = []
        for intent in self.intents:
            leg = self.plan.legs[intent.leg]
            if type(intent.limit_ticks) is not int or not 0 < intent.limit_ticks < 1 << 63:
                raise b.Rejected(f"leg_{intent.leg}_limit_price_ticks")
            if leg.rules.version >= 1 << 32:
                raise b.Rejected(f"leg_{intent.leg}_limit_price_rules_version")
            if leg.rules.quote_unit is None or leg.rules.registered_base is None:
                raise b.Rejected(f"leg_{intent.leg}_limit_price_tick_unit")
            quote_scale = leg.rules.quote_unit[1]
            base_scale = leg.rules.registered_base[1]
            # Convert the atom ratio to the venue tick coefficient at scale 18.
            tick = leg.rules.tick_quote_atoms_per_base_atom * 10**(18 + base_scale - quote_scale)
            if tick.denominator != 1 or not 0 < tick.numerator < 1 << 127:
                raise b.Rejected(f"leg_{intent.leg}_limit_price_tick_unit")
            direction = -leg.direction if intent.reducing else leg.direction
            members.append(api.OrderIntent(intent.sequence, self.plan.portfolio, leg.account, leg.rules.instrument,
                "buy" if direction == 1 else "sell", intent.time_in_force, intent.reducing, intent.lots,
                api.ExactLimitPrice(intent.limit_ticks, leg.rules.version, tick.numerator)))
        members = tuple(members)
        if fee_version is not None:
            if len(members) != 2 or any(member.portfolio_reduce_only for member in members):
                raise b.Rejected("fee_checked_opening_group")
            return api.FeeCheckedIntentGroup(members, fee_version)
        return api.IntentGroup(members) if len(members) > 1 else members[0]

    def encode(self, batch, session, *, activation):
        """Use the same exact prices in the portable Host bridge."""
        _identity(activation)
        if len(batch) < 96 or struct.unpack_from("<Q", batch, 88)[0] != self.cursor:
            raise b.Rejected("output_cursor")
        output = self.package_output()
        def args(member):
            return SimpleNamespace(strategy_identity=str(self.plan.strategy), activation_identity=str(activation),
                config_version=self.plan.config_version, side=member.side, time_in_force=member.time_in_force,
                portfolio_reduce_only=member.portfolio_reduce_only, intent_sequence=member.intent_sequence,
                portfolio_identity=member.portfolio_identity, exchange_account_identity=member.exchange_account_identity,
                instrument_identity=member.instrument_identity, quantity=member.quantity, limit_price=member.limit_price.ticks,
                limit_price_rules_version=member.limit_price.rules_version,
                limit_price_tick_coefficient=member.limit_price.tick_coefficient)
        if len(self.intents) == 2:
            first, second = map(args, output.members)
            return host.output_group_frame(batch, first, session, first.intent_sequence, second)
        return host.output_frame(batch, args(output), session)


class Cycle:
    def __init__(self, plan):
        if not isinstance(plan, Plan) or type(self) is Cycle and plan.policy.mode != "taker_taker":
            raise b.Rejected("cycle_plan")
        self.plan = plan
        self.phase = "idle"
        self.next_sequence = plan.first_sequence
        self.pending = ()
        self.issued = ()
        self.cursor = 0
        self.last_at_ns = plan.policy.at_ns
        self.cycle_ref = self.reservation_ref = None
        self.repair_used = self.exit_used = 0
        self.target_atoms = self.target_cursor = None
        self.first_exit = None
        self.reasons = {}
        self.before_reconciling = None
        self.last_economic_ref = None
        self.last_facts_digest = None
        self.matched_base = None

    @classmethod
    def from_admission(cls, plan, request, option, *, fees=None):
        """Bind 08's recommendation; execution parameters must match certified execution_hash.

        The caller resolves that versioned execution configuration. The core
        still admits the ensuing complete group and checks current permissions.
        """
        if not isinstance(plan, Plan) or not isinstance(request, admission.Request) or not isinstance(option, admission.Option):
            raise b.Rejected("admission_binding")
        option.plan.require_fees(fees.opening_snapshot() if fees is not None else None)
        if (request.identity != plan.request_ref or request.config_hash != plan.config_hash
                or plan.execution_hash != option.execution_hash
                or request.target_atoms != plan.target_atoms or request.key != option.plan.key
                or request.lots != option.lots or plan.policy != option.plan.policy
                or tuple(x.target_lots for x in plan.legs) != option.lots
                or tuple((x.account, x.rules.instrument) for x in plan.legs) != tuple((x[1], x[2]) for x in request.key[0])):
            raise b.Rejected("admission_binding")
        for scenario in option.plan.scenarios:
            for spec, leg in zip(plan.legs, scenario.entry.legs):
                if (spec.account, spec.rules, spec.kind, spec.direction) != (leg.account, leg.rules, leg.kind, leg.direction):
                    raise b.Rejected("admission_binding")
        evaluated = v.evaluate(option.plan.scenarios, option.plan.policy, option.plan.estimator,
            option.plan.calibration, option.plan.simulation_error, option.plan.limits)
        if (not evaluated.allowed or (request.scenario_digest, request.estimator_digest, request.target_atoms,
                request.plan_atoms) != (evaluated.scenario_digest, evaluated.estimator_digest,
                                       evaluated.entry_target_atoms, evaluated.plan_atoms)):
            raise b.Rejected("admission_binding")
        cycle = cls(plan)
        cycle.entry_cursor = request.cursor
        cycle.entry_valid_until_ns = request.valid_until_ns
        if option.plan.fee_version is not None:
            cycle.entry_fee_version = option.plan.fee_version
            cycle.entry_fee_venues = tuple(leg[0] for leg in option.plan.pair)
        return cycle

    def _check_entry_fees(self, fees):
        version = getattr(self, "entry_fee_version", None)
        if version is not None:
            if fees is None:
                raise b.Rejected("fees_version_missing")
            venues = getattr(self, "entry_fee_venues", None)
            if venues is None or len(venues) != len(self.plan.legs):
                raise b.Rejected("fees_scope_missing")
            fees.opening_snapshot().require_opening(version, tuple(
                ((venue, leg.account, leg.rules.instrument), leg.kind) for venue, leg in zip(venues, self.plan.legs)))

    def _emit(self, cursor, reason, specs):
        intents = tuple(Intent(self.next_sequence+i, *spec) for i, spec in enumerate(specs))
        self.next_sequence += len(intents)
        self.pending = tuple(x.sequence for x in intents)
        self.issued += intents
        return Action(self.plan, cursor, reason, intents)

    def start(self, *, cursor, at_ns, fees=None):
        b.uint(cursor, 1)
        b.uint(at_ns, self.plan.policy.at_ns)
        if self.phase != "idle":
            return Action(self.plan, self.cursor, "pending_entry", queries=self.pending)
        if at_ns >= min(self.plan.policy.deadline_ns, self.plan.repair_deadline_ns):
            raise b.Rejected("entry_expired")
        if hasattr(self, "entry_cursor") and (cursor != self.entry_cursor or at_ns >= self.entry_valid_until_ns):
            raise b.Rejected("admission_expired_or_cursor")
        self._check_entry_fees(fees)
        self.cursor, self.last_at_ns, self.phase = cursor, at_ns, "entering"
        return self._emit(cursor, "joint_entry", tuple((i, leg.target_lots, self.plan.entry_limits[i], False)
                          for i, leg in enumerate(self.plan.legs)))

    def _exit(self, reason, cursor):
        if self.first_exit is None:
            self.first_exit = (reason, cursor)
        self.phase = "exiting"
        self.before_reconciling = None

    def _observe(self, facts):
        if not isinstance(facts, Facts) or self.phase == "idle":
            raise b.Rejected("cycle_facts")
        if facts.cursor < self.cursor:
            return Action(self.plan, self.cursor, "stale_cursor")
        control_facts = replace(facts, fx_exposures=(), fx_complete=True) if facts.fx_exposures or not facts.fx_complete else facts
        if facts.cursor == self.cursor:
            from strategies.cross_venue.arbitrage_checkpoint import matches_content
            if not (matches_content(control_facts, self.last_facts_digest)
                    or matches_content(facts, self.last_facts_digest)):
                raise b.Rejected("cursor_content_conflict")
            return Action(self.plan, self.cursor, "duplicate_cursor")
        if facts.at_ns < self.last_at_ns:
            raise b.Rejected("clock_regressed")
        if self.cycle_ref is not None and (facts.cycle_ref != self.cycle_ref or
                self.reservation_ref is not None and facts.reservation_ref != self.reservation_ref):
            raise b.Rejected("cycle_ownership")
        if facts.market.at_ns < self.plan.policy.at_ns:
            raise b.Rejected("market_before_plan")
        if facts.economic_entry is not None:
            position = facts.economic_entry
            if position.holding_at_ns > facts.market.at_ns:
                raise b.Rejected("economic_projection_time")
            if position.state == "matched":
                for i, leg in enumerate(position.legs):
                    spec = self.plan.legs[i]
                    if ((leg.account, leg.rules, leg.kind, leg.direction) != (spec.account, spec.rules, spec.kind, spec.direction)
                            or leg.base_atoms != facts.positions[i]):
                        raise b.Rejected("economic_projection_scope")
        issued = {x.sequence: x for x in self.issued}
        orders = {x.sequence: x for x in facts.orders}
        for order in facts.orders:
            intent = issued.get(order.sequence)
            if (intent is None or intent.leg != order.leg
                    or order.applied_lots+order.possible_lots > intent.lots):
                raise b.Rejected("order_identity_or_quantity")
        for i, leg in enumerate(self.plan.legs):
            if facts.safe_reduce_lots[i]*leg.rules.base_atoms_per_lot > facts.positions[i]:
                raise b.Rejected("unsafe_reduce_quantity")
        if facts.admission == "rejected" and (any(facts.positions) or any(x.applied_lots for x in facts.orders)):
            raise b.Rejected("joint_rejection_with_fill")
        if facts.closed_ref and any(facts.positions):
            if any(facts.positions[i] for i, x in enumerate(self.plan.legs) if x.kind == "linear"):
                raise b.Rejected("linear_residual")
            if (not facts.residual_refs or any(facts.safe_reduce_lots)
                    or any(facts.positions[i] >= x.rules.base_atoms_per_lot for i, x in enumerate(self.plan.legs)
                           if x.kind == "spot")):
                raise b.Rejected("residual_closure_evidence")
        adjusted = e.exact(facts.nav_atoms-facts.external_allocation_atoms)
        self.cursor, self.last_at_ns = facts.cursor, facts.at_ns
        from strategies.cross_venue.arbitrage_checkpoint import content
        self.last_facts_digest = content(control_facts)
        self.cycle_ref, self.reservation_ref = facts.cycle_ref, facts.reservation_ref
        self.last_economic_ref = facts.economic_ref
        for cause, ref in facts.risk_causes:
            self.reasons[cause] = ref
        if facts.day_start_nav_atoms-adjusted >= self.plan.daily_loss_atoms:
            self.reasons.setdefault("daily_loss", facts.economic_ref)
        if facts.flow_adjusted_peak_atoms-adjusted >= self.plan.drawdown_atoms:
            self.reasons.setdefault("drawdown", facts.economic_ref)
        hard = next((x for x in sorted(self.reasons) if x != "repair_failed"), None)
        reason = (hard or ("risk" if facts.market.risk else "model_invalid" if facts.market.model_invalid else
                          "deadline" if facts.at_ns >= self.plan.policy.deadline_ns else ""))
        if reason:
            if reason != "deadline":
                self.reasons.setdefault(reason, facts.economic_ref)
            self._exit(reason, facts.cursor)
        return None

    def profit_report(self, facts):
        """Actual settled economics and FX at one authoritative cycle cutoff."""
        if not isinstance(facts, Facts) or facts.cycle_ref != self.cycle_ref:
            raise b.Rejected("cycle_fact_scope")
        entry = facts.economic_entry
        fx = e.actual_fx_report(facts.fx_exposures)
        if not facts.fx_complete:
            fx.update(status="pending", deviation_usdt=None)
        return dict(cycle_ref=facts.cycle_ref, economic_ref=facts.economic_ref, cursor=str(facts.cursor),
                    quote_asset=str(self.plan.policy.quote_asset),
                    settled_parity_atoms=None if entry is None else str(entry.r_done_atoms),
                    actual_fx=fx)

    def apply(self, facts, *, estimator=None, limits=None):
        return self._report_action(facts, self._step(facts, estimator=estimator, limits=limits))

    def _report_action(self, facts, action):
        if facts.cycle_ref == self.cycle_ref and (not facts.fx_complete or facts.fx_exposures or any(
                leg.rules.settlement_unit and leg.rules.settlement_unit[0] == "USDC" for leg in self.plan.legs)):
            return replace(action, profit=self.profit_report(facts))
        return action

    def _step(self, facts, *, estimator=None, limits=None):
        observed = self._observe(facts)
        if observed is not None:
            return observed
        return self._advance(facts, estimator, limits)

    def _advance(self, facts, estimator, limits):
        issued = {x.sequence: x for x in self.issued}
        orders = {x.sequence: x for x in facts.orders}
        unknown = tuple(x.sequence for x in facts.orders if x.status == "unknown")
        if unknown or facts.admission == "unknown" or facts.market.unknown:
            if self.phase != "reconciling":
                self.before_reconciling = self.phase
            self.phase = "reconciling"
            return Action(self.plan, facts.cursor, "unknown", queries=unknown or self.pending,
                          reconcile=True, escalate=facts.at_ns >= self.plan.repair_deadline_ns)
        if self.phase == "reconciling":
            self.phase = self.before_reconciling
            self.before_reconciling = None
        if facts.admission == "rejected":
            self.pending = ()
        required = () if facts.admission == "rejected" else issued
        waiting = tuple(sorted(set(seq for seq in required if seq not in orders) |
                               {x.sequence for x in facts.orders if x.status not in ("terminal", "rejected")
                                or not x.economic_complete}))
        if waiting:
            return Action(self.plan, facts.cursor, "orders_pending", queries=waiting,
                          reconcile=True, escalate=facts.at_ns >= self.plan.exit_deadline_ns)
        self.pending = ()
        if facts.admission == "rejected":
            self.phase = "settling"
        if not any(facts.positions):
            self.phase = "completed" if facts.closed_ref else "settling"
            return Action(self.plan, facts.cursor, "closed" if facts.closed_ref else "await_closure", reconcile=True)
        if facts.closed_ref:
            # Residual policy and custody are core-owned. Linear exposure cannot be waived.
            self.phase = "completed"
            return Action(self.plan, facts.cursor, "closed_with_residual", reconcile=True)
        if self.phase in ("settling", "completed"):
            self.reasons.setdefault("late_economic_change", facts.economic_ref)
            self._exit("late_economic_change", facts.cursor)
        if self.matched_base is not None and self.phase != "exiting" and facts.positions != (self.matched_base,)*2:
            self.reasons.setdefault("late_economic_change", facts.economic_ref)
            self._exit("late_economic_change", facts.cursor)
        if any(x > self.plan.policy.original_base for x in facts.positions):
            self.reasons.setdefault("exposure_over_target", facts.economic_ref)
            self._exit("exposure_over_target", facts.cursor)
        if self.phase == "exiting":
            return self._reduce(facts, tuple(facts.safe_reduce_lots), "exit")
        a, z = facts.positions
        if a != z:
            self.phase = "repairing"
            small = 0 if a < z else 1
            big = 1-small
            gap = e.exact(abs(a-z))
            rule = self.plan.legs[small].rules
            lots = e.floor_atoms(gap/rule.base_atoms_per_lot)
            repair = (facts.opening_allowed and not facts.model_warning and facts.market.qualified
                      and facts.at_ns < self.plan.repair_deadline_ns and self.repair_used < self.plan.repair_attempts
                      and facts.repair_loss_atoms+facts.repair_cost_atoms <= self.plan.repair_loss_cap_atoms
                      and facts.positions[small]+lots*rule.base_atoms_per_lot <= self.plan.policy.original_base)
            if repair and lots:
                spec = self._protected(facts, small, lots, False, self.plan.entry_limits[small])
                if spec is not None:
                    self.repair_used += 1
                    return self._emit(facts.cursor, "repair", (spec,))
            self.reasons.setdefault("repair_failed", facts.economic_ref)
            lots = min(facts.safe_reduce_lots[big], e.floor_atoms(gap/self.plan.legs[big].rules.base_atoms_per_lot))
            quantities = tuple(lots if i == big else 0 for i in range(2))
            return self._reduce(facts, quantities, "trim_excess")
        return self._holding(facts, estimator, limits)

    def _protected(self, facts, index, lots, reducing, limit):
        leg = self.plan.legs[index]
        side = leg.direction*(-1 if reducing else 1)
        try:
            book = host.decode_depth_snapshot(facts.market.books[index])
            swept = e.sweep(book, leg.rules, "buy" if side == 1 else "sell", lots, limit,
                            now_ns=facts.at_ns, max_age_ns=self.plan.policy.max_book_age_ns)
        except ValueError:
            return None
        # IOC may partially fill; no request expands the precomputed price or quantity.
        return (index, lots, limit, reducing) if swept.filled_lots else None

    def _reduce(self, facts, quantities, reason):
        if (not facts.reducing_allowed or not facts.market.qualified or facts.at_ns >= self.plan.exit_deadline_ns
                or self.exit_used >= self.plan.exit_attempts):
            return Action(self.plan, facts.cursor, "exit_blocked", reconcile=True, escalate=True)
        normal = self.first_exit is not None and self.first_exit[0] == "take_profit" and not (
            any(x != "repair_failed" for x in self.reasons) or facts.market.risk
            or facts.market.model_invalid or facts.at_ns >= self.plan.policy.deadline_ns)
        price_limits = self.plan.policy.normal_limits if normal else self.plan.policy.risk_limits
        specs = tuple(self._protected(facts, i, lots, True, price_limits[i])
                      for i, lots in enumerate(quantities) if lots)
        specs = tuple(x for x in specs if x is not None)
        if not specs:
            return Action(self.plan, facts.cursor, "no_legal_reduce", reconcile=True, escalate=True)
        self.exit_used += 1
        return self._emit(facts.cursor, reason, specs)

    def _holding(self, facts, estimator, limits):
        position = facts.economic_entry
        if position is None or position.state != "matched":
            return Action(self.plan, facts.cursor, "economic_projection_required", reconcile=True)
        if facts.at_ns-facts.market.at_ns > self.plan.policy.max_book_age_ns:
            if self.target_atoms is None:
                self._exit("holding_qualification", facts.cursor)
                return self._reduce(facts, facts.safe_reduce_lots, "holding_qualification")
            return Action(self.plan, facts.cursor, "stale_market")
        if self.target_atoms is None:
            target = e.holding_target(self.plan.target_atoms, position.matched_base/self.plan.policy.original_base,
                                      self.plan.policy.absolute_minimum_atoms)
            context = v.Context(position, facts.market, target, self.plan.policy)
            if estimator is None or limits is None:
                self._exit("holding_evidence_missing", facts.cursor)
                return self._reduce(facts, facts.safe_reduce_lots, "holding_evidence_missing")
            try:
                decision = v.assess_holding(context, estimator, limits, phase=self.phase)
            except ValueError:
                self._exit("holding_evidence_invalid", facts.cursor)
                return self._reduce(facts, facts.safe_reduce_lots, "holding_evidence_invalid")
            if decision.action != "hold":
                self._exit(decision.reason or "holding_qualification", facts.cursor)
                return self._reduce(facts, facts.safe_reduce_lots, decision.reason or "holding_qualification")
            self.target_atoms, self.target_cursor, self.phase = target, facts.cursor, "holding"
            self.matched_base = position.matched_base
        value = v.value_exit(position, facts.market, self.plan.policy, normal=True)
        if value.closed and value.net_atoms is not None and value.net_atoms >= self.target_atoms:
            self._exit("take_profit", facts.cursor)
            return self._reduce(facts, facts.safe_reduce_lots, "take_profit")
        return Action(self.plan, facts.cursor, "holding")
