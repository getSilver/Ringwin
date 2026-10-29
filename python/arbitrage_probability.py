"""Frozen stage-specific probability calibration on distinct historical blocks.

Block independence and source authenticity are external research evidence, not
inferred from non-overlap, simulation count or a successful arithmetic check.
"""
from dataclasses import dataclass
from decimal import Decimal, localcontext, ROUND_CEILING
from fractions import Fraction
from typing import Optional, Tuple

import arbitrage_baseline as b
import arbitrage_economics as e

PPM = 1_000_000
MAX_BLOCKS = 10_000


def probability(value):
    value = e.exact(value)
    if not 0 <= value <= 1:
        raise b.Rejected("probability_unit")
    return value


def reference(value):
    if type(value) is not str or not value or len(value) > 128:
        raise b.Rejected("evidence_reference")
    return value


def validate_hash(value):
    if type(value) is not str or len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
        raise b.Rejected("content_hash")
    return value


def validate_scope(stage, mode):
    if stage not in ("entry", "hold") or mode not in ("taker_taker", "maker_taker"):
        raise b.Rejected("probability_scope")


def hoeffding_margin(blocks, error_probability):
    """One-sided independent bounded-block assumption; upward to probability ppm."""
    b.uint(blocks, 1)
    alpha = probability(error_probability)
    if not 0 < alpha < 1:
        raise b.Rejected("confidence_error")
    with localcontext() as context:
        context.prec = 60
        inverse_alpha = Decimal(alpha.denominator)/Decimal(alpha.numerator)
        bound = (inverse_alpha.ln()/(2*Decimal(blocks))).sqrt()
        ppm = int((bound*PPM).to_integral_value(rounding=ROUND_CEILING))
    return Fraction(ppm, PPM)


@dataclass(frozen=True)
class Block:
    identity: str
    start_ns: int
    end_ns: int
    raw: Fraction
    outcomes: Tuple[Optional[bool], ...]

    def __post_init__(self):
        reference(self.identity)
        b.uint(self.start_ns)
        b.uint(self.end_ns, self.start_ns+1)
        probability(self.raw)
        if type(self.outcomes) is not tuple or not 1 <= len(self.outcomes) <= 256:
            raise b.Rejected("block_labels")
        if any(x is not None and type(x) is not bool for x in self.outcomes):
            raise b.Rejected("block_labels")


@dataclass(frozen=True)
class Bin:
    lower: Fraction
    upper: Fraction
    calibrated: Optional[Fraction]
    blocks: int
    mature_labels: int
    missing_labels: int


@dataclass(frozen=True)
class Calibration:
    version: int
    stage: str
    mode: str
    scope: str
    model_hash: str
    training_end_ns: int
    calibration_start_ns: int
    calibration_end_ns: int
    valid_from_ns: int
    valid_until_ns: int
    min_blocks: int
    min_labels: int
    confidence_error: Fraction
    margin: Fraction
    independence_ref: str
    covers_mc: bool
    bins: Tuple[Bin, ...]
    source_digest: str
    simulation_hash: str

    def __post_init__(self):
        b.uint(self.version, 1)
        validate_scope(self.stage, self.mode)
        reference(self.scope)
        reference(self.independence_ref)
        validate_hash(self.model_hash)
        validate_hash(self.source_digest)
        validate_hash(self.simulation_hash)
        b.uint(self.training_end_ns)
        if not self.training_end_ns <= self.calibration_start_ns < self.calibration_end_ns <= self.valid_from_ns < self.valid_until_ns:
            raise b.Rejected("calibration_time_partition")
        for t in (self.calibration_start_ns, self.calibration_end_ns, self.valid_from_ns, self.valid_until_ns):
            b.uint(t)
        b.uint(self.min_blocks, 1)
        b.uint(self.min_labels, 1)
        if not 0 < probability(self.confidence_error) < 1:
            raise b.Rejected("confidence_error")
        probability(self.margin)
        if type(self.covers_mc) is not bool or type(self.bins) is not tuple or not 1 <= len(self.bins) <= 64:
            raise b.Rejected("calibration_bins")
        previous = Fraction(0)
        for row in self.bins:
            if not isinstance(row, Bin) or row.lower != previous or not 0 <= row.lower < row.upper <= 1:
                raise b.Rejected("calibration_bins")
            probability(row.lower)
            probability(row.upper)
            if row.calibrated is not None:
                probability(row.calibrated)
            for count in (row.blocks, row.mature_labels, row.missing_labels):
                b.uint(count)
            previous = row.upper
        if previous != 1:
            raise b.Rejected("calibration_bins")

    @property
    def content_hash(self):
        ratio = lambda x: [e.exact(x).numerator, e.exact(x).denominator]
        return b.fingerprint("probability_calibration_v1", [self.version, self.stage, self.mode,
            self.scope, self.model_hash, self.training_end_ns, self.calibration_start_ns,
            self.calibration_end_ns, self.valid_from_ns, self.valid_until_ns, self.min_blocks,
            self.min_labels, ratio(self.confidence_error), ratio(self.margin), self.independence_ref,
            self.covers_mc, self.source_digest, self.simulation_hash,
            [[ratio(r.lower), ratio(r.upper), None if r.calibrated is None else ratio(r.calibrated),
              r.blocks, r.mature_labels, r.missing_labels] for r in self.bins]])


def calibrate(blocks, *, version, stage, mode, scope, model_hash, training_end_ns,
              embargo_ns, label_span_ns, valid_from_ns, valid_until_ns, bin_edges,
              min_blocks, min_labels, confidence_error, declared_margin, independence_ref, covers_mc, simulation_hash):
    """Equal-weight complete block frequencies; raw labels never impersonate blocks.

    Each block occupies a declared dependency interval. Any missing queried-bin
    label makes that bin ineligible, rather than being filled with zero or dropped.
    """
    blocks = b.materialized(blocks, MAX_BLOCKS)
    if not blocks or any(not isinstance(x, Block) for x in blocks):
        raise b.Rejected("calibration_blocks")
    if type(bin_edges) is not tuple or not 2 <= len(bin_edges) <= 65:
        raise b.Rejected("calibration_edges")
    boundaries = tuple(probability(x) for x in bin_edges)
    if boundaries[0] != 0 or boundaries[-1] != 1 or any(a >= z for a, z in zip(boundaries, boundaries[1:])):
        raise b.Rejected("calibration_edges")
    b.uint(training_end_ns)
    b.uint(embargo_ns)
    b.uint(label_span_ns, 1)
    if embargo_ns < label_span_ns:
        raise b.Rejected("time_isolation")
    seen, previous_end = set(), training_end_ns+embargo_ns
    for block in blocks:
        if block.identity in seen or block.start_ns < previous_end or block.end_ns-block.start_ns < label_span_ns:
            raise b.Rejected("duplicate_or_overlapping_blocks")
        seen.add(block.identity)
        previous_end = block.end_ns
    rows = []
    for lower, upper in zip(boundaries, boundaries[1:]):
        selected = [x for x in blocks if lower <= x.raw < upper or x.raw == upper == 1]
        complete = [x for x in selected if all(y is not None for y in x.outcomes)]
        calibrated = (e.exact(sum((Fraction(sum(x.outcomes), len(x.outcomes)) for x in complete), Fraction(0))/len(complete))
                      if complete else None)
        rows.append(Bin(lower, upper, calibrated, len(complete),
                        sum(y is not None for x in selected for y in x.outcomes),
                        sum(y is None for x in selected for y in x.outcomes)))
    ratio = lambda x: [e.exact(x).numerator, e.exact(x).denominator]
    source_digest = b.fingerprint("calibration_blocks_v1", [
        [x.identity, x.start_ns, x.end_ns, ratio(x.raw), list(x.outcomes)] for x in blocks])
    return Calibration(version, stage, mode, scope, model_hash, training_end_ns, blocks[0].start_ns,
                       blocks[-1].end_ns, valid_from_ns, valid_until_ns, min_blocks, min_labels,
                       confidence_error, declared_margin, independence_ref, covers_mc, tuple(rows), source_digest, simulation_hash)


@dataclass(frozen=True)
class SimulationError:
    method: str
    draws: int
    confidence_error: Fraction
    margin: Fraction
    source_ref: str

    def __post_init__(self):
        reference(self.source_ref)
        b.uint(self.draws)
        probability(self.margin)
        probability(self.confidence_error)
        if self.method == "exact_enumeration":
            if self.draws != 0 or self.margin != 0 or self.confidence_error != 0:
                raise b.Rejected("exact_enumeration_error")
        elif self.method == "sampled":
            if self.margin < hoeffding_margin(self.draws, self.confidence_error):
                raise b.Rejected("simulation_error_understated")
        else:
            raise b.Rejected("simulation_error_method")


@dataclass(frozen=True)
class ProbabilityResult:
    raw: Fraction
    calibrated: Optional[Fraction]
    lower_ppm: Optional[int]
    threshold_ppm: int
    effective_blocks: int
    mature_labels: int
    passed: bool
    reason: str
    calibration_hash: str


def assess(raw, artifact, *, stage, mode, scope, model_hash, simulation_hash, at_ns, min_probability, mc):
    raw, threshold = probability(raw), probability(min_probability)
    if threshold <= 0 or not isinstance(artifact, Calibration) or not isinstance(mc, SimulationError):
        raise b.Rejected("probability_evidence")
    b.uint(at_ns)
    threshold_ppm = e.ceil_atoms(threshold*PPM)
    row = next(r for r in artifact.bins if r.lower <= raw < r.upper or raw == r.upper == 1)
    reason = ""
    if (stage, mode, scope, model_hash, simulation_hash) != (artifact.stage, artifact.mode, artifact.scope, artifact.model_hash, artifact.simulation_hash):
        reason = "calibration_scope"
    elif not artifact.valid_from_ns <= at_ns < artifact.valid_until_ns:
        reason = "calibration_expired"
    elif row.missing_labels:
        reason = "missing_labels"
    elif row.blocks < artifact.min_blocks or row.calibrated is None:
        reason = "insufficient_blocks"
    elif row.mature_labels < artifact.min_labels:
        reason = "insufficient_labels"
    elif artifact.margin < hoeffding_margin(row.blocks, e.exact(artifact.confidence_error/len(artifact.bins))):
        reason = "calibration_error_understated"
    elif (mc.margin > 0 and artifact.covers_mc) or mc.source_ref in (artifact.source_digest, artifact.independence_ref):
        reason = "duplicate_error_coverage"
    if reason:
        return ProbabilityResult(raw, row.calibrated, None, threshold_ppm, row.blocks,
                                 row.mature_labels, False, reason, artifact.content_hash)
    lower = max(Fraction(0), e.exact(row.calibrated-artifact.margin-mc.margin))
    lower_ppm = e.floor_atoms(lower*PPM)
    passed = lower_ppm >= threshold_ppm
    return ProbabilityResult(raw, row.calibrated, lower_ppm, threshold_ppm, row.blocks, row.mature_labels,
                             passed, "" if passed else "probability", artifact.content_hash)
