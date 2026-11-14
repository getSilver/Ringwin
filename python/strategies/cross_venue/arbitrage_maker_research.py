"""Maker joint diagnostics from public Cycle/Facts snapshots, never qualification.

Supplementary realized cost/adverse-selection/queue labels require authenticated
external evidence. Stress scenarios remain bounds in arbitrage_maker.Stress;
their weights are deliberately not accepted as empirical observations here.
"""
from collections import Counter
from dataclasses import dataclass
from fractions import Fraction

from strategies.cross_venue import arbitrage_baseline as b
from strategies.cross_venue import arbitrage_cycle as c
from strategies.cross_venue import arbitrage_economics as e
from strategies.cross_venue import arbitrage_maker as m
from strategies.cross_venue import arbitrage_probability as p


def validate_scopes(scopes):
    if type(scopes) is not tuple or not 1 <= len(scopes) <= 256:
        raise b.Rejected("maker_research_scopes")
    for scope in scopes:
        if type(scope) is not tuple or len(scope) != 5:
            raise b.Rejected("maker_research_scope")
        pair, leg, lots, quotes, phase = scope
        p.reference(pair)
        if type(leg) is not int or leg not in (0, 1) or phase not in ("entry", "hold"):
            raise b.Rejected("maker_research_scope")
        e.integer(lots, 1)
        if type(quotes) is not tuple or not quotes or len(quotes) > e.MAX_ITEMS:
            raise b.Rejected("maker_research_quotes")
        for ticks in quotes:
            e.integer(ticks, 1)
        if tuple(sorted(set(quotes))) != quotes:
            raise b.Rejected("maker_research_quotes")
    if len(set(scopes)) != len(scopes):
        raise b.Rejected("maker_research_scopes")


@dataclass(frozen=True)
class Observation:
    cycle_ref: str
    scope: tuple
    started_ns: int
    observed_ns: int
    wait_ns: int
    wait_censored: bool
    unknown: bool
    filled_lots: int
    hedge_status: str
    cancel_fill_lots: int
    hedge_cost_atoms: object
    adverse_selection_atoms: object
    queue_predicted_lots: object

    def __post_init__(self):
        p.reference(self.cycle_ref)
        validate_scopes((self.scope,))
        b.uint(self.started_ns)
        b.uint(self.observed_ns, self.started_ns)
        b.uint(self.wait_ns)
        if (self.wait_ns > self.observed_ns-self.started_ns or type(self.wait_censored) is not bool
                or type(self.unknown) is not bool):
            raise b.Rejected("maker_wait")
        e.integer(self.filled_lots)
        e.integer(self.cancel_fill_lots)
        if self.cancel_fill_lots > self.filled_lots or self.filled_lots > self.scope[2]:
            raise b.Rejected("maker_fill_label")
        if self.hedge_status not in ("failed", "succeeded", "unknown", "not_applicable"):
            raise b.Rejected("maker_hedge_label")
        if (self.hedge_status == "not_applicable") != (self.filled_lots == 0):
            raise b.Rejected("maker_hedge_label")
        for value in (self.hedge_cost_atoms, self.adverse_selection_atoms):
            if value is not None:
                e.integer(value, -e.MAX_INTEGER)
        if self.queue_predicted_lots is not None:
            e.integer(self.queue_predicted_lots)
            if self.queue_predicted_lots > self.scope[2]:
                raise b.Rejected("maker_queue_label")


def observe(cycle, facts, *, pair_ref, phase, hedge_failed=None,
            hedge_cost_atoms=None, adverse_selection_atoms=None, cancel_fill_lots=0,
            queue_prediction=None):
    """Capture only already-applied public projections; never advance the cycle.

    Waiting is measured through the observation and remains censored while any
    maker quote lacks terminal economic coverage. Terminal observations give a
    conservative elapsed wait, not a fabricated exchange fill timestamp.
    """
    if (not isinstance(cycle, m.Cycle) or not isinstance(facts, c.Facts)
            or cycle.quote_started_ns is None or facts.cursor != cycle.cursor
            or facts.at_ns != cycle.last_at_ns or facts.cycle_ref != cycle.cycle_ref):
        raise b.Rejected("maker_research_projection")
    if hedge_failed is not None and type(hedge_failed) is not bool:
        raise b.Rejected("maker_hedge_label")
    if phase == "hold" and cycle.phase != "holding":
        raise b.Rejected("maker_phase")
    orders = {x.sequence: x for x in facts.orders}
    intents = tuple(x for x in cycle.issued if x.leg == cycle.plan.maker_leg and not x.reducing)
    filled = sum(orders[x.sequence].applied_lots for x in intents if x.sequence in orders)
    censored = any(x.sequence not in orders or orders[x.sequence].status not in ("terminal", "rejected")
                   or not orders[x.sequence].economic_complete for x in intents)
    unknown = (facts.admission == "unknown" or facts.market.unknown
               or any(x.status == "unknown" for x in facts.orders))
    status = ("not_applicable" if not filled else "unknown" if unknown or hedge_failed is None
              else "failed" if hedge_failed else "succeeded")
    predicted = None
    if queue_prediction is not None:
        if (not isinstance(queue_prediction, m.QueueResult)
                or queue_prediction.filled_lots+queue_prediction.remaining_lots != cycle.plan.legs[cycle.plan.maker_leg].target_lots):
            raise b.Rejected("maker_queue_label")
        predicted = queue_prediction.filled_lots
    scope = (pair_ref, cycle.plan.maker_leg, cycle.plan.legs[cycle.plan.maker_leg].target_lots,
             tuple(sorted({x.limit_ticks for x in intents})), phase)
    return Observation(facts.cycle_ref, scope, cycle.quote_started_ns, facts.at_ns,
                       facts.at_ns-cycle.quote_started_ns, censored, unknown, filled, status,
                       cancel_fill_lots, hedge_cost_atoms, adverse_selection_atoms, predicted)


@dataclass(frozen=True)
class Cell:
    scope: tuple
    count: int
    joint: tuple
    censored_waits: int
    max_observed_wait_ns: int
    hedge_failure_frequency: object
    failure_probability_upper: object
    max_adverse_selection_atoms: object
    max_hedge_cost_atoms: object
    mean_queue_overestimate_lots: object
    stage_frequency: object
    plan_overestimate_atoms: object
    reference_overestimate_atoms: object
    declared_blocks: int


@dataclass(frozen=True)
class Diagnostics:
    observations: tuple
    cells: tuple
    missing_scopes: tuple
    excluded_observations: int


def summarize_maker(protocol, stage, cycles, samples):
    from strategies.cross_venue.arbitrage_research import STAGES, Outcome
    samples = tuple(b.materialized(samples, b.MAX_POINTS))
    if any(not isinstance(x, Outcome) for x in cycles):
        raise b.Rejected("research_cycles")
    outcomes = {x.identity: x for x in cycles}
    start, end = protocol.intervals[STAGES.index(stage)]
    identities = set()
    for sample in samples:
        if not isinstance(sample, Observation) or sample.scope not in protocol.maker_scopes:
            raise b.Rejected("maker_research_scope")
        outcome = outcomes.get(sample.cycle_ref)
        key = (sample.cycle_ref, sample.scope[-1])
        if (outcome is None or sample.scope[0] != outcome.pair_ref
                or sample.started_ns < outcome.start_ns or not start <= sample.observed_ns < end
                or outcome.end_ns is not None and sample.observed_ns > outcome.end_ns
                or key in identities):
            raise b.Rejected("maker_research_identity")
        identities.add(key)
    if set(outcomes) != {x.cycle_ref for x in samples}:
        raise b.Rejected("maker_research_coverage")
    cells = []
    eligible = tuple(x for x in samples if outcomes[x.cycle_ref].end_ns is not None
                     and outcomes[x.cycle_ref].profit_atoms is not None
                     and protocol.partition(outcomes[x.cycle_ref].start_ns,
                                            outcomes[x.cycle_ref].end_ns,
                                            outcomes[x.cycle_ref].end_ns) == stage)
    for scope in protocol.maker_scopes:
        rows = tuple(x for x in eligible if x.scope == scope)
        if not rows:
            continue
        joint = Counter((x.wait_ns, x.wait_censored, x.unknown, "zero" if x.filled_lots == 0 else "full" if x.filled_lots == scope[2]
                         else "partial", x.hedge_status, bool(x.cancel_fill_lots)) for x in rows)
        hedged = tuple(x for x in rows if x.hedge_status != "not_applicable")
        frequency = (Fraction(sum(x.hedge_status == "failed" for x in hedged), len(hedged))
                     if hedged and all(x.hedge_status in ("failed", "succeeded") for x in hedged) else None)
        maximum = lambda field: (max(getattr(x, field) for x in rows)
                                if all(getattr(x, field) is not None for x in rows) else None)
        queue = (sum((Fraction(x.queue_predicted_lots-x.filled_lots) for x in rows), Fraction(0))/len(rows)
                 if all(x.queue_predicted_lots is not None for x in rows) else None)
        complete = tuple(outcomes[x.cycle_ref] for x in rows
                         if outcomes[x.cycle_ref].start_ns >= start
                         and outcomes[x.cycle_ref].end_ns is not None
                         and outcomes[x.cycle_ref].end_ns < end
                         and outcomes[x.cycle_ref].end_ns-outcomes[x.cycle_ref].start_ns <= protocol.max_span_ns
                         and outcomes[x.cycle_ref].profit_atoms is not None)
        field = "entry_hit" if scope[-1] == "entry" else "hold_hit"
        stage_frequency = (sum((Fraction(getattr(x, field)) for x in complete), Fraction(0))/len(complete)
                           if complete and all(getattr(x, field) is not None for x in complete) else None)
        error = lambda prediction, actual: (max(Fraction(0), sum((Fraction(getattr(x, prediction)-getattr(x, actual))
                         for x in complete), Fraction(0))/len(complete))
                         if complete and all(getattr(x, actual) is not None for x in complete) else None)
        cells.append(Cell(scope, len(rows), tuple((*key, count) for key, count in sorted(joint.items())),
                          sum(x.wait_censored for x in rows), max(x.wait_ns for x in rows),
                          frequency, None, maximum("adverse_selection_atoms"), maximum("hedge_cost_atoms"), queue,
                          stage_frequency, error("predicted_plan_atoms", "profit_atoms"),
                          error("predicted_reference_atoms", "reference_profit_atoms"),
                          len({x.block_ref for x in complete})))
    return Diagnostics(samples, tuple(cells),
                       tuple(x for x in protocol.maker_scopes if x not in {c.scope for c in cells}),
                       len(samples)-len(eligible))
