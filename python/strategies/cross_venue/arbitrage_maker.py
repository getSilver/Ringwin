"""Maker decisions over certified core projections; no OMS, ledger or permission.

Quote scenarios are joint full-cycle outcomes, including failure losses and
conditional hedge costs, not a profit multiplied by an independent fill rate.
Cancel suggestions reference the original intent in the committed cycle.
"""
from dataclasses import dataclass, replace

from strategies.cross_venue import arbitrage_baseline as b
from strategies.cross_venue import arbitrage_cycle as c
from strategies.cross_venue import arbitrage_economics as e
from strategies.cross_venue import arbitrage_evaluation as v
import strategy_host as host
from strategies.cross_venue import arbitrage_probability as p


def _possible(intent, orders):
    order = orders.get(intent.sequence)
    if order is None:
        return intent.lots
    if order.status == "terminal" and not order.economic_complete:
        return intent.lots-order.applied_lots
    return order.possible_lots


@dataclass(frozen=True)
class QueueEvent:
    identity: str
    aggressive_lots: int
    cancelled_lots: int
    trade_ref: object

    def __post_init__(self):
        p.reference(self.identity)
        e.integer(self.aggressive_lots)
        e.integer(self.cancelled_lots)
        if self.aggressive_lots:
            p.reference(self.trade_ref)


@dataclass(frozen=True)
class QueueResult:
    ahead: int
    filled_lots: int
    remaining_lots: int


def queue_baseline(visible_ahead, own_lots, events, *, hidden_ahead=0, cancel_position="unknown"):
    """Research only: L2 never proves real queue position or Venue fills.

    The baseline puts all visible same-price quantity ahead. Unknown cancels
    remove nothing ahead; `ahead` is an explicit alternative stress assumption.
    Callers certify tape references, ordering and the original quote/price scope.
    """
    e.integer(visible_ahead)
    e.integer(hidden_ahead)
    e.integer(own_lots, 1)
    v._tuple(events)
    if cancel_position not in ("unknown", "ahead", "behind"):
        raise b.Rejected("cancel_position")
    if any(not isinstance(x, QueueEvent) for x in events) or len({x.identity for x in events}) != len(events):
        raise b.Rejected("queue_event_identity")
    trade_refs = [x.trade_ref for x in events if x.aggressive_lots]
    if len(set(trade_refs)) != len(trade_refs):
        raise b.Rejected("duplicate_tape_trade")
    ahead, remaining = e.integer(visible_ahead+hidden_ahead), own_lots
    for event in events:
        if cancel_position == "ahead":
            ahead = max(0, ahead-event.cancelled_lots)
        consumed = min(ahead, event.aggressive_lots)
        ahead -= consumed
        remaining -= min(remaining, event.aggressive_lots-consumed)
    return QueueResult(ahead, own_lots-remaining, remaining)


@dataclass(frozen=True)
class Plan(c.Plan):
    maker_leg: int
    offsets: tuple
    min_quote_interval_ns: int
    max_requotes: int
    quote_lifetime_ns: int
    improvement_atoms: int
    max_unhedged_base: object
    tail_lifetime_ns: int
    native_post_only: bool

    def __post_init__(self):
        super().__post_init__()
        if self.policy.mode != "maker_taker" or type(self.maker_leg) is not int or self.maker_leg not in (0, 1):
            raise b.Rejected("maker_mode")
        if self.native_post_only is not True:
            raise b.Rejected("native_post_only_required")
        if type(self.offsets) is not tuple or not self.offsets or len(self.offsets) > 16:
            raise b.Rejected("quote_offsets")
        for offset in self.offsets:
            b.uint(offset)
        if tuple(sorted(set(self.offsets))) != self.offsets:
            raise b.Rejected("quote_offsets")
        for value in (self.min_quote_interval_ns, self.quote_lifetime_ns, self.tail_lifetime_ns):
            b.uint(value, 1)
        b.uint(self.max_requotes)
        e.integer(self.improvement_atoms, 1)
        e.positive(self.max_unhedged_base)
        if 1+self.max_requotes+self.repair_attempts+2*self.exit_attempts > e.MAX_ITEMS:
            raise b.Rejected("maker_intent_capacity")
        if self.first_sequence+1+self.max_requotes+self.repair_attempts+2*self.exit_attempts >= 1 << 64:
            raise b.Rejected("maker_sequence_capacity")


STRESS_CASES = ("no_fill", "partial_cancel", "hedge_failure", "cancel_fill", "unknown",
                "hidden_liquidity", "cancel_position", "adverse_selection")


@dataclass(frozen=True)
class Stress:
    """Registered bound, not an empirical probability or realized PnL."""
    name: str
    loss_atoms: int
    low_base: object
    high_base: object

    def __post_init__(self):
        if self.name not in STRESS_CASES:
            raise b.Rejected("maker_stress")
        e.integer(self.loss_atoms)
        if e.exact(self.low_base) > e.exact(self.high_base):
            raise b.Rejected("stress_exposure_bounds")


@dataclass(frozen=True)
class Quote:
    ticks: int
    market: v.Market
    scenarios: tuple
    estimator: v.Estimator
    calibration: object
    simulation_error: object
    limits: v.Limits
    stresses: tuple
    economic_ref: object = None
    applied_trades: tuple = ((), ())

    def __post_init__(self):
        if e.integer(self.ticks, 1) >= 1 << 63:
            raise b.Rejected("quote_price")
        v._validate_scenarios(self.scenarios)
        if not isinstance(self.market, v.Market):
            raise b.Rejected("quote_market")
        v._tuple(self.stresses, len(STRESS_CASES))
        if (any(not isinstance(x, Stress) for x in self.stresses)
                or sorted(x.name for x in self.stresses) != sorted(STRESS_CASES)):
            raise b.Rejected("maker_stress_coverage")
        if self.economic_ref is not None:
            p.reference(self.economic_ref)
        for trades in c._pair(self.applied_trades):
            v._tuple(trades, 64)
            if any(not isinstance(t, v.Trade) for t in trades):
                raise b.Rejected("quote_economic_prefix")


def select_quote(plan, market, quotes, *, at_ns, economic_ref=None, applied_lots=(0, 0)):
    """Bounded research price set; whole original hedge capacity stays reserved.

    Callers authenticate full joint scenarios, fees, funding and failure budgets
    against the execution hash. Statistical and native Venue qualification are
    independent of these offline calculations.
    """
    v._tuple(quotes, 16)
    if any(not isinstance(q, Quote) for q in quotes) or len({q.ticks for q in quotes}) != len(quotes):
        raise b.Rejected("quote_candidates")
    if (not market.qualified or market.risk or market.unknown or market.model_invalid
            or not 0 <= at_ns-market.at_ns <= plan.policy.max_book_age_ns):
        return None
    maker, hedge = plan.maker_leg, 1-plan.maker_leg
    spec = plan.legs[maker]
    book = host.decode_depth_snapshot(market.books[maker])
    rule = spec.rules
    if ((book["instrument"], book["rules_version"]) != (rule.instrument, rule.version)
            or not rule.valid_from_ns <= at_ns < rule.valid_until_ns
            or not 0 <= at_ns-book["visible_at_ns"] <= plan.policy.max_book_age_ns):
        return None
    best = book["bids" if spec.direction == 1 else "asks"][0][0]
    candidates = {best-spec.direction*k for k in plan.offsets}
    try:
        h = plan.legs[hedge]
        depth = e.sweep(host.decode_depth_snapshot(market.books[hedge]), h.rules,
                        "buy" if h.direction == 1 else "sell", h.target_lots, plan.entry_limits[hedge],
                        now_ns=at_ns, max_age_ns=plan.policy.max_book_age_ns)
    except ValueError:
        return None
    if depth.remaining_lots:
        return None
    eligible = []
    for q in quotes:
        if q.market != market:
            raise b.Rejected("quote_visible_market")
        if q.economic_ref != economic_ref or tuple(sum(t.lots for t in ts) for ts in q.applied_trades) != applied_lots:
            raise b.Rejected("quote_economic_prefix")
        if q.ticks not in candidates or spec.direction*(q.ticks-plan.entry_limits[maker]) > 0:
            continue
        if rule.notional(q.ticks, spec.target_lots) < rule.min_notional_atoms:
            continue
        if any(x.loss_atoms > plan.repair_loss_cap_atoms or
               max(abs(x.low_base), abs(x.high_base)) > plan.max_unhedged_base for x in q.stresses):
            continue
        for scenario in q.scenarios:
            for i, leg in enumerate(scenario.entry.legs):
                target = plan.legs[i]
                prefix = q.applied_trades[i]
                if ((leg.account, leg.rules, leg.kind, leg.direction) !=
                        (target.account, target.rules, target.kind, target.direction)
                        or leg.gross_lots > target.target_lots
                        or leg.entries[:len(prefix)] != prefix
                        or i == maker and any(t.ticks != q.ticks for t in leg.entries[len(prefix):])):
                    raise b.Rejected("quote_scenario_scope")
        policy = replace(plan.policy, at_ns=at_ns)
        result = v.evaluate(q.scenarios, policy, q.estimator, q.calibration,
                            q.simulation_error, q.limits, fixed_target=plan.target_atoms)
        if result.allowed:
            eligible.append((result.plan_atoms, -spec.direction*q.ticks, q.ticks, q))
    if not eligible:
        return None
    score, _, _, q = max(eligible, key=lambda row: row[:3])
    return q, score


class Cycle(c.Cycle):
    def __init__(self, plan):
        if not isinstance(plan, Plan):
            raise b.Rejected("maker_plan")
        super().__init__(plan)
        self.maker_sequence = None
        self.quote_started_ns = self.last_quote_ns = None
        self.requotes_used = 0
        self.quote_score = None
        self.cancel_requested = False
        self.replacing = False
        self.tail_started_ns = None
        self.entry_finished = False

    @classmethod
    def from_admission(cls, plan, request, option, *, fees=None):
        cycle = super().from_admission(plan, request, option, fees=fees)
        if request.key[3] != plan.maker_leg:
            raise b.Rejected("maker_admission_role")
        return cycle

    def start(self, *, cursor, at_ns, market, quotes, fees=None):
        b.uint(cursor, 1)
        b.uint(at_ns, self.plan.policy.at_ns)
        if self.phase != "idle":
            return c.Action(self.plan, self.cursor, "pending_entry", queries=self.pending)
        if at_ns >= min(self.plan.policy.deadline_ns, self.plan.repair_deadline_ns):
            raise b.Rejected("entry_expired")
        if hasattr(self, "entry_cursor") and (cursor != self.entry_cursor or at_ns >= self.entry_valid_until_ns):
            raise b.Rejected("admission_expired_or_cursor")
        selected = select_quote(self.plan, market, quotes, at_ns=at_ns)
        if selected is None:
            return c.Action(self.plan, cursor, "quote_unqualified")
        self._check_entry_fees(fees)
        self.cursor, self.last_at_ns, self.phase = cursor, at_ns, "entering"
        self.quote_started_ns = at_ns
        return self._quote(cursor, at_ns, selected, self.plan.legs[self.plan.maker_leg].target_lots)

    def _quote(self, cursor, at_ns, selected, lots):
        q, self.quote_score = selected
        self.maker_sequence = self.next_sequence
        self.last_quote_ns = at_ns
        self.cancel_requested = self.replacing = False
        return self._emit(cursor, "maker_quote", ((self.plan.maker_leg, lots, q.ticks, False, "post-only"),))

    def _protected(self, facts, index, lots, reducing, limit):
        # Maker mode never becomes an IOC chase; overhedging trims the hedge leg.
        if not reducing and index == self.plan.maker_leg:
            return None
        return super()._protected(facts, index, lots, reducing, limit)

    def apply(self, facts, *, quotes=(), estimator=None, limits=None):
        return self._report_action(facts, self._step(facts, quotes=quotes, estimator=estimator, limits=limits))

    def _step(self, facts, *, quotes=(), estimator=None, limits=None):
        observed = self._observe(facts)
        if observed is not None:
            return observed
        if self.entry_finished:
            return self._advance(facts, estimator, limits)
        if facts.admission == "rejected":
            self.entry_finished = True
            return self._advance(facts, estimator, limits)
        plan, maker, hedge = self.plan, self.plan.maker_leg, 1-self.plan.maker_leg
        orders = {x.sequence: x for x in facts.orders}
        current = orders.get(self.maker_sequence)
        terminal = current is not None and current.status in ("terminal", "rejected") and current.economic_complete
        unknown = (facts.admission == "unknown" or facts.market.unknown
                   or any(o.status == "unknown" for o in facts.orders))
        if unknown:
            self.cancel_requested, self.replacing = True, False
            action = self._advance(facts, estimator, limits)
            return replace(action, cancels=() if terminal else (self.maker_sequence,))
        if self.phase == "reconciling":
            self.phase, self.before_reconciling = self.before_reconciling, None
        maker_intents = tuple(i for i in self.issued if i.leg == maker and not i.reducing)
        hedge_intents = tuple(i for i in self.issued if i.leg == hedge and not i.reducing)
        applied_lots = tuple(sum(orders[i.sequence].applied_lots for i in self.issued
            if i.leg == j and not i.reducing and i.sequence in orders) for j in range(2))
        filled_maker = sum(orders[i.sequence].applied_lots for i in maker_intents if i.sequence in orders)
        if filled_maker > plan.legs[maker].target_lots:
            raise b.Rejected("maker_over_target")
        possible = sum(_possible(i, orders) for i in hedge_intents)
        hedge_rule = plan.legs[hedge].rules
        gap = e.exact(facts.positions[maker]-facts.positions[hedge]-possible*hedge_rule.base_atoms_per_lot)
        if gap > 0 and self.tail_started_ns is None:
            self.tail_started_ns = facts.at_ns
        elif gap <= 0:
            self.tail_started_ns = None
        tail_expired = self.tail_started_ns is not None and facts.at_ns-self.tail_started_ns >= plan.tail_lifetime_ns
        unsafe = (self.first_exit is not None or facts.model_warning or not facts.opening_allowed
                  or not facts.market.qualified or facts.at_ns >= self.quote_started_ns+plan.quote_lifetime_ns
                  or facts.at_ns >= plan.repair_deadline_ns or tail_expired
                  or abs(facts.positions[maker]-facts.positions[hedge]) > plan.max_unhedged_base)
        if unsafe:
            self.cancel_requested, self.replacing = True, False
        specs = ()
        lots = e.floor_atoms(max(0, gap)/hedge_rule.base_atoms_per_lot)
        if lots >= hedge_rule.min_lots and not self.first_exit:
            hedge_allowed = (facts.opening_allowed and facts.market.qualified and not facts.market.risk
                and not facts.market.model_invalid and facts.at_ns < plan.repair_deadline_ns
                and self.repair_used < plan.repair_attempts
                and facts.repair_loss_atoms+facts.repair_cost_atoms <= plan.repair_loss_cap_atoms
                and sum(_possible(i, orders)+(orders[i.sequence].applied_lots if i.sequence in orders else 0)
                        for i in hedge_intents)
                    +lots <= plan.legs[hedge].target_lots)
            spec = self._protected(facts, hedge, lots, False, plan.entry_limits[hedge]) if hedge_allowed else None
            if spec is None:
                self.cancel_requested, self.replacing = True, False
            else:
                self.repair_used += 1
                specs = (spec,)
        if not self.cancel_requested and not terminal and quotes:
            selected = select_quote(plan, facts.market, quotes, at_ns=facts.at_ns,
                                    economic_ref=facts.economic_ref, applied_lots=applied_lots)
            old = next(i for i in self.issued if i.sequence == self.maker_sequence)
            if selected is None:
                self.cancel_requested = True
            elif (selected[0].ticks != old.limit_ticks and self.requotes_used < plan.max_requotes
                    and facts.at_ns-self.last_quote_ns >= plan.min_quote_interval_ns
                    and selected[1] >= self.quote_score+plan.improvement_atoms):
                self.cancel_requested = self.replacing = True
        # Recheck depth even without an optional research repricing evaluation.
        if not terminal and not self.cancel_requested:
            h = plan.legs[hedge]
            try:
                swept = e.sweep(host.decode_depth_snapshot(facts.market.books[hedge]), h.rules,
                    "buy" if h.direction == 1 else "sell", h.target_lots, plan.entry_limits[hedge],
                    now_ns=facts.at_ns, max_age_ns=plan.policy.max_book_age_ns)
                capacity = not swept.remaining_lots
            except ValueError:
                capacity = False
            if not capacity:
                self.cancel_requested, self.replacing = True, False
        cancels = (self.maker_sequence,) if self.cancel_requested and not terminal else ()
        if specs:
            return replace(self._emit(facts.cursor, "incremental_hedge", specs), cancels=cancels)
        if not terminal:
            return c.Action(plan, facts.cursor, "cancel_maker" if cancels else "maker_pending",
                            queries=(self.maker_sequence,), cancels=cancels, reconcile=bool(cancels),
                            escalate=facts.at_ns >= plan.exit_deadline_ns)
        uncovered = tuple(i.sequence for i in maker_intents if i.sequence not in orders
            or orders[i.sequence].status not in ("terminal", "rejected") or not orders[i.sequence].economic_complete)
        if uncovered:
            return c.Action(plan, facts.cursor, "maker_history_pending", queries=uncovered, reconcile=True)
        outstanding = tuple(i.sequence for i in hedge_intents if i.sequence not in orders
            or orders[i.sequence].status not in ("terminal", "rejected") or not orders[i.sequence].economic_complete)
        if outstanding:
            return c.Action(plan, facts.cursor, "hedges_pending", queries=outstanding, reconcile=True,
                            escalate=facts.at_ns >= plan.exit_deadline_ns)
        remaining = plan.legs[maker].target_lots-filled_maker
        if (self.replacing and not unsafe and self.requotes_used < plan.max_requotes
                and remaining >= plan.legs[maker].rules.min_lots):
            selected = select_quote(plan, facts.market, quotes, at_ns=facts.at_ns,
                                    economic_ref=facts.economic_ref, applied_lots=applied_lots)
            if selected is not None and plan.legs[maker].rules.notional(selected[0].ticks, remaining) >= plan.legs[maker].rules.min_notional_atoms:
                self.requotes_used += 1
                return self._quote(facts.cursor, facts.at_ns, selected, remaining)
        self.entry_finished = True
        self.replacing = False
        # Full economic coverage now allows 09's fixed-target holding / exit path.
        return self._advance(facts, estimator, limits)

    def exposure_bounds(self, facts):
        """Signed maker-minus-hedge base, including every possible pending fill."""
        maker, hedge = self.plan.maker_leg, 1-self.plan.maker_leg
        if facts.possible_base:
            return (e.exact(facts.possible_base[maker][0]-facts.possible_base[hedge][1]),
                    e.exact(facts.possible_base[maker][1]-facts.possible_base[hedge][0]))
        orders = {o.sequence: o for o in facts.orders}
        low, high = list(facts.positions), list(facts.positions)
        for i in self.issued:
            possible = _possible(i, orders)*self.plan.legs[i.leg].rules.base_atoms_per_lot
            if i.reducing:
                low[i.leg] = max(0, low[i.leg]-possible)
            else:
                high[i.leg] += possible
        return e.exact(low[maker]-high[hedge]), e.exact(high[maker]-low[hedge])
