"""Exact, read-only cross-venue economics. Amounts are in one quote Asset's atoms.

Inputs are admitted canonical facts, not venue messages. These functions neither
own balances nor grant trading authority. No floats or implicit decimal contexts.
"""
from dataclasses import dataclass
from fractions import Fraction
from typing import Optional, Tuple

MAX_INTEGER = (1 << 127) - 1
MAX_ITEMS = 256


def exact(value):
    """Bound rational inputs and every public result to the signed i128 domain."""
    if type(value) not in (int, Fraction):
        raise ValueError("expected integer atoms or Fraction")
    value = Fraction(value)
    if abs(value.numerator) > MAX_INTEGER or value.denominator > MAX_INTEGER:
        raise ValueError("economic capacity exceeded")
    return value


def integer(value, minimum=0):
    if type(value) is not int or not minimum <= value <= MAX_INTEGER:
        raise ValueError("invalid integer unit")
    return value


def floor_atoms(value):
    value = exact(value)
    return integer(value.numerator // value.denominator, -MAX_INTEGER)


def ceil_atoms(value):
    value = exact(value)
    return integer(-(-value.numerator // value.denominator), -MAX_INTEGER)


def positive(value):
    value = exact(value)
    if value <= 0:
        raise ValueError("expected positive economic unit")
    return value


def bounded(items):
    # Require materialized finite input: never silently truncate a candidate set.
    if type(items) not in (tuple, list) or len(items) > MAX_ITEMS:
        raise ValueError("economic item capacity exceeded")
    return items


@dataclass(frozen=True)
class Cost:
    name: str
    atoms: Fraction
    treatment: str

    def __post_init__(self):
        if not isinstance(self.name, str) or not self.name or len(self.name) > 128:
            raise ValueError("missing cost identity")
        if exact(self.atoms) < 0 or self.treatment not in (
                "expense", "embedded", "model_buffer", "execution_buffer"):
            raise ValueError("invalid cost treatment")


@dataclass(frozen=True)
class CycleValue:
    gross_atoms: Fraction
    fee_atoms: int
    funding_atoms: Fraction
    rebate_atoms: Fraction
    net_atoms: int
    plan_atoms: int
    costs: Tuple[Cost, ...]


def evaluate_cycle(gross_atoms, costs, funding_atoms=(), rebate_atoms=()):
    """Gross is before expense items, but already includes embedded price effects.

    Each loss/risk identity has exactly one treatment. Funding is signed actual
    receipts; future admission funding must use funding_budget instead.
    """
    gross = exact(gross_atoms)
    bounded(costs)
    if any(not isinstance(c, Cost) for c in costs):
        raise ValueError("invalid cost")
    if len({c.name for c in costs}) != len(costs):
        raise ValueError("duplicate cost coverage")
    funding = exact(sum((exact(x) for x in bounded(funding_atoms)), Fraction(0)))
    rebates = tuple(exact(x) for x in bounded(rebate_atoms))
    if any(x < 0 for x in rebates):
        raise ValueError("negative TradingRebate")
    rebate = exact(sum(rebates, Fraction(0)))
    expense = sum(ceil_atoms(c.atoms) for c in costs if c.treatment == "expense")
    buffer = sum(ceil_atoms(c.atoms) for c in costs if c.treatment.endswith("buffer"))
    net = floor_atoms(gross + funding + rebate - expense)
    return CycleValue(gross, integer(expense), funding, rebate, net,
                      floor_atoms(net-buffer), tuple(costs))


def edge_bp(profit_atoms, reference_notional_atoms):
    return exact(exact(profit_atoms)*10_000/positive(reference_notional_atoms))


@dataclass(frozen=True)
class InstrumentRules:
    instrument: int
    version: int
    base_asset: int
    quote_asset: int
    tick_quote_atoms_per_base_atom: Fraction
    base_atoms_per_lot: Fraction
    min_lots: int
    min_notional_atoms: int
    valid_from_ns: int
    valid_until_ns: int
    # Same atomic unit only; approval belongs to the immutable configuration.
    approved_base_pair: Optional[Tuple[int, str]] = None

    def __post_init__(self):
        for value in (self.instrument, self.version, self.base_asset, self.quote_asset,
                      self.min_lots):
            integer(value, 1)
        if self.base_asset == self.quote_asset:
            raise ValueError("identical base/quote Asset")
        positive(self.tick_quote_atoms_per_base_atom)
        positive(self.base_atoms_per_lot)
        integer(self.min_notional_atoms)
        integer(self.valid_from_ns)
        integer(self.valid_until_ns, self.valid_from_ns+1)
        if self.approved_base_pair is not None:
            pair = self.approved_base_pair
            if (type(pair) is not tuple or len(pair) != 2 or type(pair[0]) is not int
                    or pair[0] <= 0 or pair[0] in (self.base_asset, self.quote_asset)
                    or type(pair[1]) is not str or not 0 < len(pair[1]) <= 128
                    or not pair[1].isascii() or any(ord(x) < 33 for x in pair[1])):
                raise ValueError("invalid economic pairing approval")

    @property
    def exposure_asset(self):
        return self.base_asset if self.approved_base_pair is None else self.approved_base_pair[0]

    def notional(self, ticks, lots):
        return exact(integer(ticks, 1)*integer(lots)*self.base_atoms_per_lot
                     * self.tick_quote_atoms_per_base_atom)


@dataclass(frozen=True)
class Sweep:
    filled_lots: int
    remaining_lots: int
    base_atoms: Fraction
    quote_atoms: Fraction
    vwap_ticks: Fraction
    fills: Tuple[Tuple[int, int], ...]


def sweep(book, rules, side, lots, limit_ticks, *, now_ns, max_age_ns):
    """Consume only proven depth, in the shape returned by decode_depth_snapshot.

    A partial IOC fill may be below order minima. None quantity stops the sweep;
    no interpolation beyond an absent or truncated level is permitted.
    """
    if not isinstance(rules, InstrumentRules) or side not in ("buy", "sell"):
        raise ValueError("missing rules or invalid side")
    integer(lots, 1)
    if lots < rules.min_lots:
        raise ValueError("order below minimum lots")
    integer(limit_ticks, 1)
    integer(now_ns)
    integer(max_age_ns)
    if not rules.valid_from_ns <= now_ns < rules.valid_until_ns:
        raise ValueError("expired InstrumentRules")
    if not isinstance(book, dict) or set(book) - {"sequence_kind", "capture_epoch"} != {
            "instrument", "rules_version", "sequence", "visible_at_ns",
            "bids", "asks", "bids_truncated", "asks_truncated"}:
        raise ValueError("invalid canonical depth")
    if book.get("sequence_kind", "venue") == "capture":
        integer(book.get("capture_epoch"), 1)
    elif book.get("sequence_kind", "venue") != "venue" or book.get("capture_epoch", 0) != 0:
        raise ValueError("invalid canonical sequence")
    for key in ("instrument", "rules_version", "sequence"):
        integer(book[key], 1)
    integer(book["visible_at_ns"])
    if (book["instrument"] != rules.instrument or book["rules_version"] != rules.version
            or not 0 <= now_ns-book["visible_at_ns"] <= max_age_ns):
        raise ValueError("stale or mismatched canonical depth")
    for name in ("bids", "asks"):
        levels = bounded(book[name])
        if not 1 <= len(levels) <= 8 or type(book[name+"_truncated"]) is not bool:
            raise ValueError("invalid depth capacity")
        previous = None
        for level in levels:
            if type(level) not in (tuple, list) or len(level) != 2:
                raise ValueError("invalid depth level")
            price, size = level
            integer(price, 1)
            if size is not None:
                integer(size)
            if previous is not None and (price >= previous if name == "bids" else price <= previous):
                raise ValueError("unordered canonical depth")
            previous = price
    if book["bids"][0][0] >= book["asks"][0][0]:
        raise ValueError("crossed canonical depth")
    if rules.notional(limit_ticks, lots) < rules.min_notional_atoms:
        raise ValueError("order below minimum notional")
    fills = []
    remaining = lots
    quote = Fraction(0)
    weighted_ticks = 0
    for ticks, size in book["asks" if side == "buy" else "bids"]:
        if remaining == 0 or size is None or (ticks > limit_ticks if side == "buy" else ticks < limit_ticks):
            break
        take = min(remaining, size)
        if take:
            fills.append((ticks, take))
            quote = exact(quote+rules.notional(ticks, take))
            weighted_ticks = integer(weighted_ticks+ticks*take)
            remaining -= take
    filled = lots-remaining
    return Sweep(filled, remaining, exact(filled*rules.base_atoms_per_lot), quote,
                 exact(Fraction(weighted_ticks, filled)) if filled else Fraction(0), tuple(fills))


@dataclass(frozen=True)
class FeeRule:
    instrument: int
    rules_version: int
    fee_asset: int
    taker_ppm: Fraction
    maker_ppm: Fraction
    valid_from_ns: int
    valid_until_ns: int

    def __post_init__(self):
        for x in (self.instrument, self.rules_version, self.fee_asset):
            integer(x, 1)
        for rate in (self.taker_ppm, self.maker_ppm):
            if not 0 <= exact(rate) <= 1_000_000:
                raise ValueError("unsupported fee rate")
        integer(self.valid_from_ns)
        integer(self.valid_until_ns, self.valid_from_ns+1)


@dataclass(frozen=True)
class Fee:
    asset: int
    asset_atoms: int
    quote_atoms: Fraction
    base_atoms: int

    def __post_init__(self):
        integer(self.asset, 1)
        integer(self.asset_atoms)
        integer(self.base_atoms)
        if (exact(self.quote_atoms) < 0 or (self.asset_atoms > 0 and self.quote_atoms <= 0)
                or self.base_atoms not in (0, self.asset_atoms)):
            raise ValueError("invalid fee valuation")


def estimate_fee(rules, fee_rule, *, ticks, lots, role, now_ns,
                 quote_atoms_per_fee_atom, available_fee_atoms=None):
    """One fill's native-asset fee. Call per fill, not once on an average price.

    Valuation must be admitted at now_ns by the caller. Unconfirmed rebates never
    improve admission. Third-asset payment capacity is mandatory.
    """
    if not isinstance(rules, InstrumentRules) or not isinstance(fee_rule, FeeRule):
        raise ValueError("missing fee or InstrumentRules")
    integer(now_ns)
    integer(lots, 1)
    integer(ticks, 1)
    if (fee_rule.instrument != rules.instrument or fee_rule.rules_version != rules.version
            or not fee_rule.valid_from_ns <= now_ns < fee_rule.valid_until_ns
            or not rules.valid_from_ns <= now_ns < rules.valid_until_ns
            or role not in ("maker", "taker", "unknown")):
        raise ValueError("invalid fee scope, role or expiry")
    valuation = positive(quote_atoms_per_fee_atom)
    rate = Fraction(fee_rule.maker_ppm if role == "maker" else fee_rule.taker_ppm, 1_000_000)
    if fee_rule.fee_asset == rules.base_asset:
        amount = ceil_atoms(exact(lots*rules.base_atoms_per_lot*rate))
    else:
        if fee_rule.fee_asset == rules.quote_asset and valuation != 1:
            raise ValueError("quote fee must use quote atom units")
        amount = ceil_atoms(exact(rules.notional(ticks, lots)*rate/valuation))
    if fee_rule.fee_asset not in (rules.base_asset, rules.quote_asset):
        if available_fee_atoms is None or integer(available_fee_atoms) < amount:
            raise ValueError("third Asset fee is not payable")
    return Fee(fee_rule.fee_asset, amount, exact(amount*valuation),
               amount if fee_rule.fee_asset == rules.base_asset else 0)


@dataclass(frozen=True)
class MatchedQuantity:
    net_base_atoms: Fraction
    hedge_lots: int
    matched_base_atoms: Fraction
    residual_base_atoms: Fraction


def match_quantity(gross_base_atoms, base_fee_atoms, hedge_base_atoms_per_lot):
    gross = positive(gross_base_atoms)
    fee = exact(base_fee_atoms)
    lot = positive(hedge_base_atoms_per_lot)
    if not 0 <= fee <= gross:
        raise ValueError("base fee exceeds gross Fill")
    net = exact(gross-fee)
    lots = floor_atoms(exact(net/lot))
    matched = exact(lots*lot)
    return MatchedQuantity(net, lots, matched, exact(net-matched))


def spot_liquidation(entry_quote_atoms, exit_quote_atoms, residual_quote_atoms, fees):
    """Value spot cash plus NET remaining inventory once, with base fees embedded.

    No second position valuation is added. Base-fee attribution is added back to
    gross solely so evaluate_cycle can show all fees without charging them twice.
    Actual rebates, funding and repair PnL can be composed at evaluate_cycle.
    """
    entry = positive(entry_quote_atoms)
    exit_value, residual = exact(exit_quote_atoms), exact(residual_quote_atoms)
    if min(exit_value, residual) < 0:
        raise ValueError("negative spot liquidation value")
    if any(not isinstance(f, Fee) for f in bounded(fees)):
        raise ValueError("invalid fee facts")
    base_fees = sum(ceil_atoms(f.quote_atoms) for f in fees if f.base_atoms)
    return evaluate_cycle(exact(exit_value+residual-entry+base_fees),
                          tuple(Cost("fee:"+str(i), f.quote_atoms, "expense")
                                for i, f in enumerate(fees)))


def linear_pnl(rules, entry_ticks, exit_ticks, lots, direction):
    """Price-only PnL for an already matched linear-USDT perpetual leg."""
    if not isinstance(rules, InstrumentRules) or direction not in ("long", "short"):
        raise ValueError("missing linear rules or direction")
    integer(lots, 1)
    delta = rules.notional(exit_ticks, lots)-rules.notional(entry_ticks, lots)
    return exact(delta if direction == "long" else -delta)


@dataclass(frozen=True)
class Scenario:
    weight: Fraction
    net_atoms: Fraction
    closed: bool

    def __post_init__(self):
        if not 0 <= exact(self.weight) <= 1 or type(self.closed) is not bool:
            raise ValueError("invalid scenario weight or closure")
        exact(self.net_atoms)


def expected_profit(scenarios):
    scenarios = bounded(scenarios)
    if (not scenarios or any(not isinstance(s, Scenario) for s in scenarios)
            or sum(s.weight for s in scenarios) != 1):
        raise ValueError("scenario weights must sum to one")
    if any(not s.closed for s in scenarios):
        raise ValueError("unresolved scenario risk; cannot qualify expected profit")
    return floor_atoms(exact(sum((s.weight*s.net_atoms for s in scenarios), Fraction(0))))


def funding_budget(payments, adverse_buffer_atoms):
    """(scenario notional atoms, signed PAYMENT rate) per leg/settlement point.

    Negative payment rates represent receipts and never subsidize another leg.
    The caller supplies every possible settlement through the risk deadline.
    """
    buffer = exact(adverse_buffer_atoms)
    if buffer < 0:
        raise ValueError("negative funding buffer")
    total = ceil_atoms(buffer)
    for notional, payment_rate in bounded(payments):
        cost = exact(positive(notional)*max(Fraction(0), exact(payment_rate)))
        total = integer(total+ceil_atoms(cost))
    return total


def entry_target(reference_profit_atoms, alpha, absolute_minimum_atoms):
    alpha = positive(alpha)
    if alpha > 1:
        raise ValueError("alpha exceeds one")
    return ceil_atoms(max(positive(absolute_minimum_atoms), positive(reference_profit_atoms)*alpha))


def holding_target(entry_target_atoms, matched_ratio, absolute_minimum_atoms):
    """Arithmetic only; the cycle state machine must freeze this value once."""
    ratio = positive(matched_ratio)
    if ratio > 1:
        raise ValueError("matched quantity exceeds original target")
    return ceil_atoms(max(positive(absolute_minimum_atoms), positive(entry_target_atoms)*ratio))


def remaining_target(target_atoms, realized_net_atoms):
    return ceil_atoms(positive(target_atoms)-exact(realized_net_atoms))


def strategy_pnl(nav_before_atoms, nav_after_atoms, net_external_allocation_atoms):
    return floor_atoms(exact(nav_after_atoms)-exact(nav_before_atoms)-exact(net_external_allocation_atoms))


def spendable_budget(allocated_atoms, settled_pnl_atoms, cap_atoms, occupied_atoms):
    """A projection of core facts, not a balance; floating gains cannot enter it.

    occupied_atoms is the core's already deduplicated total. Venue balances and
    floating losses still require their own current risk gates.
    """
    allocated, cap, occupied = integer(allocated_atoms), integer(cap_atoms), integer(occupied_atoms)
    settled = integer(settled_pnl_atoms, -MAX_INTEGER)
    return max(0, integer(min(cap, integer(allocated+settled, -MAX_INTEGER))-occupied, -MAX_INTEGER))


def capital_required(components):
    """Distinct spot principal, venue margins and fee/risk reserves; never PnL."""
    seen = set()
    total = 0
    for identity, atoms in bounded(components):
        if not isinstance(identity, str) or not identity or identity in seen:
            raise ValueError("duplicate or missing capital component")
        if exact(atoms) < 0:
            raise ValueError("negative capital component")
        seen.add(identity)
        total = integer(total+ceil_atoms(atoms))
    return total


def funds_fit(requirements, available):
    """Compare each ExchangeAccount separately, in the SAME quote Asset atoms."""
    def accounts(items):
        result = {}
        for account, atoms in bounded(items):
            integer(account, 1)
            if account in result:
                raise ValueError("duplicate ExchangeAccount")
            result[account] = integer(atoms)
        return result
    needed, balances = accounts(requirements), accounts(available)
    if not needed or not needed.keys() <= balances.keys():
        raise ValueError("missing ExchangeAccount funds")
    return all(needed[a] <= balances[a] for a in needed)


@dataclass(frozen=True)
class Candidate:
    lots: int
    plan_atoms: int
    reference_notional_atoms: int
    capital_atoms: int
    hard_gates_passed: bool

    def __post_init__(self):
        integer(self.lots, 1)
        integer(self.plan_atoms, -MAX_INTEGER)
        integer(self.reference_notional_atoms, 1)
        integer(self.capital_atoms, 1)
        if type(self.hard_gates_passed) is not bool:
            raise ValueError("missing hard gate evidence")


@dataclass(frozen=True)
class Selection:
    chosen: Optional[Candidate]
    rejections: Tuple[Tuple[int, str], ...]


def choose_quantity(candidates, *, min_profit_atoms, min_edge_bp):
    """Choose within ONE pair/mode's pre-normalized finite quantity grid."""
    integer(min_profit_atoms)
    if exact(min_edge_bp) < 0:
        raise ValueError("negative Edge threshold")
    qualified, rejected, seen = [], [], set()
    for c in bounded(candidates):
        if not isinstance(c, Candidate) or c.lots in seen:
            raise ValueError("invalid or duplicate quantity candidate")
        seen.add(c.lots)
        reason = ("hard_gate" if not c.hard_gates_passed else
                  "profit" if c.plan_atoms <= min_profit_atoms else
                  "edge" if edge_bp(c.plan_atoms, c.reference_notional_atoms) <= min_edge_bp else None)
        if reason:
            rejected.append((c.lots, reason))
        else:
            qualified.append(c)
    chosen = min(qualified, key=lambda c: (-c.plan_atoms, c.capital_atoms, c.lots)) if qualified else None
    return Selection(chosen, tuple(sorted(rejected)))


def quantity_grid(max_lots, min_lots, budget_fractions, depth_lots, max_candidates):
    """Project frozen budget fractions and depth exhaustion points to legal lots.

    max_lots is supplied after budget/depth/risk upper bounds; every result still
    needs full fee, minimum-notional, margin and economic evaluation.
    """
    integer(min_lots, 1)
    integer(max_lots, min_lots)
    integer(max_candidates, 1)
    candidates = {min_lots, max_lots}
    for ratio in bounded(budget_fractions):
        if not 0 < exact(ratio) <= 1:
            raise ValueError("invalid budget fraction")
        lots = floor_atoms(exact(max_lots*ratio))
        if lots >= min_lots:
            candidates.add(lots)
    for lots in bounded(depth_lots):
        if min_lots <= integer(lots) <= max_lots:
            candidates.add(lots)
    if len(candidates) > min(max_candidates, MAX_ITEMS):
        raise ValueError("quantity candidate capacity exceeded")
    return tuple(sorted(candidates))
