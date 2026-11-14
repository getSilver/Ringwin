"""Offline chronological research accounting, never economic qualification.

Inputs are admitted public component results, not an execution simulator or a
second ledger. Authenticity, block independence and statistical calibration need
external evidence. Synthetic reports cannot authorize trading.
"""
from dataclasses import dataclass, asdict
from contextlib import contextmanager
from fractions import Fraction
import json
import os
from pathlib import Path
from typing import Optional

from strategies.cross_venue import arbitrage_baseline as b
from strategies.cross_venue import arbitrage_probability as p
from strategies.cross_venue import arbitrage_economics as e

STAGES = ("train", "calibration", "validation", "holdout")


@dataclass(frozen=True)
class Protocol:
    version: str
    data_hash: str
    code_hash: str
    dependency_ref: str
    seed: int
    intervals: tuple
    max_span_ns: int
    candidates: tuple
    max_trials: int
    min_blocks: int
    min_cycles: int
    max_drawdown_atoms: int
    max_tail_loss_atoms: int
    coverage_ppm: int
    min_profit_atoms: int
    mode: str = "taker_taker"
    maker_scopes: tuple = ()

    def __post_init__(self):
        p.reference(self.version)
        if self.mode not in ("taker_taker", "maker_taker"):
            raise b.Rejected("research_mode")
        if self.mode == "maker_taker":
            from strategies.cross_venue.arbitrage_maker_research import validate_scopes
            validate_scopes(self.maker_scopes)
        elif self.maker_scopes != ():
            raise b.Rejected("research_mode_scope")
        p.reference(self.dependency_ref)
        p.validate_hash(self.data_hash)
        p.validate_hash(self.code_hash)
        b.uint(self.seed)
        b.uint(self.max_span_ns, 1)
        if type(self.intervals) is not tuple or len(self.intervals) != 4:
            raise b.Rejected("research_intervals")
        previous = None
        for interval in self.intervals:
            if type(interval) is not tuple or len(interval) != 2:
                raise b.Rejected("research_intervals")
            start, end = interval
            b.uint(start)
            b.uint(end, start+1)
            if previous is not None and start-previous < self.max_span_ns:
                raise b.Rejected("research_isolation")
            previous = end
        if (type(self.candidates) is not tuple or not 1 <= len(self.candidates) <= 256
                or len(set(self.candidates)) != len(self.candidates)):
            raise b.Rejected("research_candidates")
        for candidate in self.candidates:
            p.validate_hash(candidate)
        for value in (self.max_trials, self.min_blocks, self.min_cycles,
                      self.max_drawdown_atoms, self.max_tail_loss_atoms, self.coverage_ppm,
                      self.min_profit_atoms):
            b.uint(value, 1)
        if (self.coverage_ppm >= p.PPM or self.max_trials < len(self.candidates)
                or self.max_trials > 4096):
            raise b.Rejected("research_limits")

    @property
    def content_hash(self):
        # Keep pre-Maker taker journals addressable after this additive extension.
        values = list(self.__dict__.values())
        return b.fingerprint("taker_research_v1", values[:-2]) if self.mode == "taker_taker" else b.fingerprint("maker_research_v1", values)

    def partition(self, start_ns, end_ns, observed_at_ns):
        """Same wall-clock partition for every pair; incomplete labels never enter."""
        b.uint(start_ns)
        b.uint(end_ns, start_ns)
        b.uint(observed_at_ns)
        if observed_at_ns < end_ns or end_ns-start_ns > self.max_span_ns:
            return None
        for stage, (start, end) in zip(STAGES, self.intervals):
            if start <= start_ns <= end_ns < end and observed_at_ns < end:
                return stage
        return None

    def label_partition(self, label, *, at_ns):
        """Consume LabelTracker output, never manufacture a mature market label."""
        b.uint(at_ns)
        if not isinstance(label, b.Label):
            raise b.Rejected("research_label")
        if label.status != "mature" or label.observed_at_ns > at_ns:
            return None
        return self.partition(label.prediction.source.grid_ns, label.prediction.due_ns,
                              label.observed_at_ns)


@dataclass(frozen=True)
class Equity:
    at_ns: int
    nav_atoms: int
    cumulative_external_atoms: int

    def __post_init__(self):
        b.uint(self.at_ns)
        e.integer(self.nav_atoms, -e.MAX_INTEGER)
        e.integer(self.cumulative_external_atoms, -e.MAX_INTEGER)


@dataclass(frozen=True)
class Outcome:
    identity: str
    pair_ref: str
    start_ns: int
    end_ns: Optional[int]
    block_ref: str
    profit_atoms: Optional[int]
    predicted_plan_atoms: int
    predicted_reference_atoms: int
    entry_hit: Optional[bool]
    hold_hit: Optional[bool]
    rejected: bool
    stopped: bool
    reference_profit_atoms: Optional[int] = None

    def __post_init__(self):
        for value in (self.identity, self.pair_ref, self.block_ref):
            p.reference(value)
        b.uint(self.start_ns)
        if self.end_ns is not None:
            b.uint(self.end_ns, self.start_ns)
        for value in (self.predicted_plan_atoms, self.predicted_reference_atoms):
            e.integer(value, -e.MAX_INTEGER)
        for value in (self.profit_atoms, self.reference_profit_atoms):
            if value is not None:
                e.integer(value, -e.MAX_INTEGER)
        if self.end_ns is None and self.profit_atoms is not None:
            raise b.Rejected("unclosed_profit")
        for value in (self.entry_hit, self.hold_hit):
            if value is not None and type(value) is not bool:
                raise b.Rejected("stage_outcome")
        if type(self.rejected) is not bool or type(self.stopped) is not bool:
            raise b.Rejected("cycle_outcome")


@dataclass(frozen=True)
class Report:
    protocol_hash: str
    candidate: str
    stage: str
    source_kind: str
    equity: tuple
    cycles: tuple
    profit_atoms: int
    drawdown_atoms: int
    tail_loss_atoms: int
    complete_cycles: int
    declared_blocks: int
    unresolved_cycles: int
    rejections: int
    stops: int
    plan_overestimate_atoms: Optional[Fraction]
    reference_overestimate_atoms: Optional[Fraction]
    entry_frequency: Optional[Fraction]
    hold_frequency: Optional[Fraction]
    occupancy_upper_ns: Optional[int]
    failures: tuple
    economic_qualified: bool = False
    maker: object = None


def summarize(protocol, stage, candidate, *, equity, cycles, source_kind="synthetic", maker_samples=()):
    """Retain the whole curve and all cycles, including rejected/unclosed tails.

    Frequencies, means and occupancy quantiles are diagnostics, not calibrated
    conservative bounds. Declared historical blocks still require independence
    evidence; no caller flag turns a report into real qualification.
    """
    if not isinstance(protocol, Protocol) or stage not in STAGES or candidate not in protocol.candidates:
        raise b.Rejected("research_scope")
    if source_kind not in ("synthetic", "historical"):
        raise b.Rejected("research_source")
    equity = tuple(b.materialized(equity, b.MAX_POINTS))
    cycles = tuple(b.materialized(cycles, b.MAX_POINTS))
    if protocol.mode == "maker_taker":
        from strategies.cross_venue.arbitrage_maker_research import summarize_maker
        maker = summarize_maker(protocol, stage, cycles, maker_samples)
    else:
        if maker_samples != ():
            raise b.Rejected("research_mode_scope")
        maker = None
    start, end = protocol.intervals[STAGES.index(stage)]
    if (len(equity) < 2 or any(not isinstance(x, Equity) for x in equity)
            or equity[0].at_ns != start or equity[-1].at_ns != end-1
            or any(a.at_ns >= z.at_ns for a, z in zip(equity, equity[1:]))):
        raise b.Rejected("equity_coverage")
    if (any(not isinstance(x, Outcome) or x.start_ns >= end
            or x.end_ns is not None and x.end_ns < start for x in cycles)
            or len({x.identity for x in cycles}) != len(cycles)):
        raise b.Rejected("research_cycles")
    adjusted = tuple(x.nav_atoms-x.cumulative_external_atoms for x in equity)
    peak, drawdown = adjusted[0], 0
    for nav in adjusted:
        peak = max(peak, nav)
        drawdown = max(drawdown, peak-nav)
    complete = tuple(x for x in cycles if x.start_ns >= start and x.end_ns is not None and x.end_ns < end
                     and x.profit_atoms is not None and x.end_ns-x.start_ns <= protocol.max_span_ns)
    unresolved = len(cycles)-len(complete)
    blocks = len({x.block_ref for x in complete})
    tail = max((max(0, -x.profit_atoms) for x in complete), default=0)
    error = (max(Fraction(0), sum((Fraction(x.predicted_plan_atoms-x.profit_atoms)
                                 for x in complete), Fraction(0))/len(complete)) if complete else None)
    reference = (max(Fraction(0), sum((Fraction(x.predicted_reference_atoms-x.reference_profit_atoms)
                                     for x in complete), Fraction(0))/len(complete))
                 if complete and all(x.reference_profit_atoms is not None for x in complete) else None)
    frequency = lambda field: (sum(getattr(x, field) for x in complete)/Fraction(len(complete))
                               if complete and all(getattr(x, field) is not None for x in complete) else None)
    durations = sorted(x.end_ns-x.start_ns for x in complete)
    index = (len(durations)*protocol.coverage_ppm+p.PPM-1)//p.PPM-1
    occupancy = durations[index] if durations and not unresolved else None
    failures = ["external_qualification_required"]
    if maker is not None and maker.missing_scopes:
        failures.append("maker_scope_coverage")
    if source_kind == "synthetic":
        failures.append("synthetic_input")
    if len(complete) < protocol.min_cycles:
        failures.append("insufficient_cycles")
    if blocks < protocol.min_blocks:
        failures.append("insufficient_blocks")
    if unresolved:
        failures.append("unresolved_risk")
    if drawdown > protocol.max_drawdown_atoms:
        failures.append("drawdown_limit")
    if tail > protocol.max_tail_loss_atoms:
        failures.append("tail_loss_limit")
    if adjusted[-1]-adjusted[0] < protocol.min_profit_atoms:
        failures.append("profit_limit")
    return Report(protocol.content_hash, candidate, stage, source_kind, equity, cycles,
                  adjusted[-1]-adjusted[0], drawdown, tail, len(complete), blocks,
                  unresolved, sum(x.rejected for x in cycles), sum(x.stopped for x in cycles),
                  error, reference, frequency("entry_hit"), frequency("hold_hit"), occupancy, tuple(failures),
                  maker=maker)


def _json(value):
    def encode(x):
        if isinstance(x, Fraction):
            return {"numerator": x.numerator, "denominator": x.denominator}
        raise TypeError("unsupported research value")
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False,
                      default=encode)


def _unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise b.Rejected("duplicate_journal_key")
        result[key] = value
    return result


class Study:
    """One local journal owns all versions' trials and spent holdout intervals.

    Keep this file across research versions and restarts. Deleting, editing or
    using a different journal invalidates the unseen-data claim; this is not an
    external access-control or provenance service. Crashed locks fail closed.
    """
    @staticmethod
    def create(path):
        with open(path, "x", encoding="utf-8") as stream:
            stream.write(_json({"schema": 1, "studies": {}, "used": []}))
            stream.flush()
            os.fsync(stream.fileno())

    def __init__(self, protocol, journal):
        if not isinstance(protocol, Protocol):
            raise b.Rejected("research_protocol")
        self.protocol = protocol
        self.journal = Path(journal)
        with self._edit() as data:
            data["studies"].setdefault(protocol.content_hash,
                {"protocol": asdict(protocol), "trials": [], "selected": None})

    @contextmanager
    def _edit(self):
        lock = self.journal.with_name(self.journal.name+".lock")
        temporary = self.journal.with_name(self.journal.name+".tmp")
        with open(lock, "x", encoding="ascii"):
            pass
        owned_temporary = False
        try:
            raw = self.journal.read_text(encoding="utf-8")
            if len(raw) > 64*1024*1024:
                raise b.Rejected("research_journal_capacity")
            data = json.loads(raw, object_pairs_hook=_unique_pairs)
            if (type(data) is not dict or set(data) != {"schema", "studies", "used"}
                    or data["schema"] != 1 or type(data["studies"]) is not dict
                    or type(data["used"]) is not list or len(data["studies"]) > 1024
                    or len(data["used"]) > 1024):
                raise b.Rejected("research_journal")
            for interval in data["used"]:
                if type(interval) is not list or len(interval) != 2:
                    raise b.Rejected("research_journal")
                b.uint(interval[0])
                b.uint(interval[1], interval[0]+1)
            yield data
            encoded = _json(data)
            if (len(data["studies"]) > 1024 or len(data["used"]) > 1024
                    or len(encoded) > 64*1024*1024):
                raise b.Rejected("research_journal_capacity")
            with open(temporary, "x", encoding="utf-8") as stream:
                owned_temporary = True
                stream.write(encoded)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.journal)
            owned_temporary = False
        finally:
            if owned_temporary:
                temporary.unlink()
            lock.unlink()

    def validate(self, candidate, **inputs):
        if candidate not in self.protocol.candidates:
            raise b.Rejected("research_candidate")
        with self._edit() as data:
            study = data["studies"][self.protocol.content_hash]
            if study["selected"] is not None:
                raise b.Rejected("research_frozen")
            if len(study["trials"]) >= self.protocol.max_trials:
                raise b.Rejected("research_trial_limit")
            index = len(study["trials"])
            study["trials"].append({"candidate": candidate, "result": None})
        try:
            result = summarize(self.protocol, "validation", candidate, **inputs)
        except Exception:
            with self._edit() as data:
                data["studies"][self.protocol.content_hash]["trials"][index]["result"] = {"error": "failed"}
            raise
        with self._edit() as data:
            data["studies"][self.protocol.content_hash]["trials"][index]["result"] = asdict(result)
        return result

    def freeze(self):
        with self._edit() as data:
            study = data["studies"][self.protocol.content_hash]
            if study["selected"] is not None:
                return study["selected"]
            if any(x["result"] is None for x in study["trials"]):
                raise b.Rejected("incomplete_trial")
            # Failed or interrupted attempts remain visible and consume budget.
            eligible = [x for x in study["trials"] if "error" not in x["result"]
                        and set(x["result"]["failures"]) <= {"external_qualification_required", "synthetic_input"}]
            if not eligible:
                raise b.Rejected("no_eligible_candidate")
            chosen = min(eligible, key=lambda x: (-x["result"]["profit_atoms"], x["candidate"]))
            study["selected"] = chosen["candidate"]
            return chosen["candidate"]

    def holdout(self, **inputs):
        start, end = self.protocol.intervals[-1]
        with self._edit() as data:
            study = data["studies"][self.protocol.content_hash]
            candidate = study["selected"]
            if candidate is None:
                raise b.Rejected("research_not_frozen")
            seen = list(data["used"])
            for prior in data["studies"].values():
                seen.extend(prior["protocol"]["intervals"][:3])
            if any(start < z and a < end for a, z in seen):
                raise b.Rejected("seen_holdout")
            data["used"].append([start, end])
        # Spend before reading/evaluating test outcomes, including failed calls.
        result = summarize(self.protocol, "holdout", candidate, **inputs)
        with self._edit() as data:
            data["studies"][self.protocol.content_hash]["holdout"] = asdict(result)
        return result
