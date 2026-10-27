"""Versioned offline baselines on admitted one-second samples; no order output.

Statistical values are binary64 diagnostics, never cash PnL. All policy values
are explicit research inputs. Canonical codecs and economic units stay shared.
"""
from dataclasses import dataclass
from bisect import bisect_right
from collections import deque
from fractions import Fraction
import hashlib
import json
import math
from typing import Optional, Tuple

from arbitrage_economics import InstrumentRules, exact
from strategy_host import decode_depth_snapshot, RecoveryNeeded
from strategy_state import encode_number

SECOND = 1_000_000_000
HORIZONS = (300, 900, 3600)
MAX_POINTS = 100_000
MAX_WINDOW = 3600
MAX_PENDING = 256
MAX_U64 = (1 << 64) - 1
ALGORITHM = "baseline_binary64_v1"


class Rejected(ValueError):
    """Stable reason for ineligible input/model; callers must retain the evidence."""


def uint(value, minimum=0):
    if type(value) is not int or not minimum <= value <= MAX_U64:
        raise Rejected("integer_unit")
    return value


def finite(value):
    if type(value) not in (int, float) or (type(value) is int and abs(value) > MAX_U64):
        raise Rejected("numeric_unit")
    value = float(value)
    if not math.isfinite(value):
        raise Rejected("non_finite")
    return value


def positive(value):
    value = finite(value)
    if value <= 0:
        raise Rejected("non_positive")
    return value


def sum_finite(values):
    try:
        return finite(math.fsum(values))
    except (OverflowError, ValueError) as error:
        raise Rejected("non_finite") from error


def square(value):
    value = finite(value)
    return finite(value*value)


def materialized(items, capacity):
    if type(items) not in (tuple, list) or len(items) > capacity:
        raise Rejected("capacity")
    return items


def fingerprint(kind, values):
    payload = json.dumps([ALGORITHM, kind, values], separators=(",", ":"), allow_nan=False)
    return hashlib.sha256(payload.encode("ascii")).hexdigest()


@dataclass(frozen=True)
class Point:
    grid_ns: int
    cursor: int
    value: Optional[float]
    reason: str = ""
    break_before: bool = False
    evidence: Tuple[int, ...] = ()

    def __post_init__(self):
        uint(self.grid_ns)
        uint(self.cursor, 1)
        if self.grid_ns % SECOND or type(self.break_before) is not bool:
            raise Rejected("grid_unit")
        if not isinstance(self.reason, str) or len(self.reason) > 128:
            raise Rejected("reason")
        if self.value is None:
            if not self.reason:
                raise Rejected("missing_reason")
        elif self.reason:
            raise Rejected("contradictory_point")
        else:
            finite(self.value)
        if type(self.evidence) is not tuple:
            raise Rejected("mutable_evidence")
        for value in materialized(self.evidence, 16):
            if type(value) is not int or not 0 <= value < (1 << 128):
                raise Rejected("evidence_identity")


@dataclass(frozen=True)
class Prediction:
    model_kind: str
    model_version: int
    model_hash: str
    source: Point
    horizon_seconds: int
    direction: int
    mean: float
    variance: float
    half_life_seconds: Optional[float]

    def __post_init__(self):
        uint(self.model_version, 1)
        if (self.model_kind not in ("ar1", "rolling", "state_space") or type(self.model_hash) is not str
                or len(self.model_hash) != 64 or any(x not in "0123456789abcdef" for x in self.model_hash)):
            raise Rejected("model_identity")
        if not isinstance(self.source, Point) or self.source.value is None:
            raise Rejected("invalid_observation")
        if type(self.horizon_seconds) is not int or self.horizon_seconds not in HORIZONS:
            raise Rejected("horizon_seconds")
        if type(self.direction) is not int or self.direction not in (-1, 1):
            raise Rejected("direction")
        uint(self.due_ns)
        finite(self.mean)
        if finite(self.variance) < 0:
            raise Rejected("negative_variance")
        if self.half_life_seconds is not None:
            positive(self.half_life_seconds)
        finite(self.directional_change)

    @property
    def due_ns(self):
        return self.source.grid_ns+self.horizon_seconds*SECOND

    @property
    def directional_change(self):
        return finite(self.direction*(self.source.value-self.mean))

    @property
    def identity(self):
        return (self.model_hash, self.source.grid_ns, self.source.cursor,
                self.horizon_seconds, self.direction)


@dataclass(frozen=True)
class AR1:
    version: int
    trained_until_ns: int
    center: float
    phi: float
    innovation_variance: float
    min_reversion: float
    min_variance: float
    min_abs_deviation: float

    def __post_init__(self):
        uint(self.version, 1)
        uint(self.trained_until_ns)
        finite(self.center)
        if not 0 < finite(self.phi) < 1:
            raise Rejected("non_stationary_phi")
        if not 0 < positive(self.min_reversion) < 1:
            raise Rejected("reversion_policy")
        if 1-self.phi < self.min_reversion:
            raise Rejected("near_unit_root")
        if finite(self.innovation_variance) <= positive(self.min_variance):
            raise Rejected("degenerate_variance")
        if finite(self.min_abs_deviation) < 0:
            raise Rejected("deviation_policy")

    @property
    def content_hash(self):
        return fingerprint("ar1", [self.version, self.trained_until_ns] + [
            encode_number(float(x)) for x in (self.center, self.phi, self.innovation_variance,
                                              self.min_reversion, self.min_variance, self.min_abs_deviation)])

    def predict(self, point, horizon_seconds, direction):
        if not isinstance(point, Point) or point.value is None:
            raise Rejected("invalid_observation")
        if point.grid_ns < self.trained_until_ns:
            raise Rejected("training_leakage")
        if abs(point.value-self.center) <= self.min_abs_deviation:
            raise Rejected("near_center")
        if type(horizon_seconds) is not int or horizon_seconds not in HORIZONS:
            raise Rejected("horizon_seconds")
        log_phi = math.log1p(self.phi-1) if self.phi > .5 else math.log(self.phi)
        mean = sum_finite((point.value*math.exp(horizon_seconds*log_phi),
                           self.center*(-math.expm1(horizon_seconds*log_phi))))
        variance_multiplier = (-math.expm1(2*horizon_seconds*log_phi))/(-math.expm1(2*log_phi))
        variance = self.innovation_variance*variance_multiplier
        return Prediction("ar1", self.version, self.content_hash, point, horizon_seconds, direction,
                          finite(mean), finite(variance), math.log(.5)/log_phi)


def ordered_points(points):
    materialized(points, MAX_POINTS)
    previous = None
    for point in points:
        if not isinstance(point, Point):
            raise Rejected("invalid_observation")
        if previous is not None and (point.grid_ns <= previous.grid_ns or point.cursor <= previous.cursor):
            raise Rejected("observation_order")
        previous = point
    return points


def fit_ar1(points, *, version, training_end_ns, min_pairs,
            min_reversion, min_variance, min_abs_deviation):
    """OLS intercept and slope on adjacent valid seconds, training cutoff exclusive.

    The residual variance uses n-2 regression degrees of freedom. No online
    fitting, phi clipping, gap bridging or time-unit rescaling is performed.
    """
    uint(training_end_ns, 1)
    uint(min_pairs, 3)
    pairs = [(a.value, z.value) for a, z in zip(ordered_points(points), points[1:])
             if z.grid_ns < training_end_ns and z.grid_ns-a.grid_ns == SECOND
             and a.value is not None and z.value is not None and not z.break_before]
    if len(pairs) < min_pairs:
        raise Rejected("insufficient_pairs")
    n = len(pairs)
    x_mean = sum_finite(x/n for x, _ in pairs)
    y_mean = sum_finite(y/n for _, y in pairs)
    xx = sum_finite(square(x-x_mean) for x, _ in pairs)
    if xx/n <= positive(min_variance):
        raise Rejected("degenerate_variance")
    phi = finite(sum_finite(finite((x-x_mean)*(y-y_mean)) for x, y in pairs)/xx)
    if not 0 < phi < 1:
        raise Rejected("non_stationary_phi")
    intercept = finite(y_mean-phi*x_mean)
    variance = finite(sum_finite(square(y-intercept-phi*x) for x, y in pairs)/(n-2))
    return AR1(version, training_end_ns, finite(intercept/(1-phi)), phi, variance,
               min_reversion, min_variance, min_abs_deviation)


class GridSampler:
    """Replay canonical depth bytes and explicit core health/continuity facts.

    Calls follow ShardSequence, including grid timers. Source sequence arithmetic
    cannot infer continuity: valid Venue sequences need not increase by one.
    """
    def __init__(self, first_rules, second_rules, *, version, max_age_ns, max_skew_ns):
        if any(not isinstance(r, InstrumentRules) for r in (first_rules, second_rules)):
            raise Rejected("missing_rules")
        if (first_rules.instrument == second_rules.instrument
                or first_rules.base_asset != second_rules.base_asset
                or first_rules.quote_asset != second_rules.quote_asset):
            raise Rejected("pair_asset_scope")
        self.rules = (first_rules, second_rules)
        self.version = uint(version, 1)
        self.max_age_ns = uint(max_age_ns, 1)
        self.max_skew_ns = uint(max_skew_ns)
        self._books = [None, None]
        self._cursor = 0
        self._time_ns = 0
        self._last_grid = None
        self._broken = False

    def _check_event(self, at_ns, cursor):
        uint(at_ns)
        uint(cursor, 1)
        if at_ns < self._time_ns or cursor <= self._cursor:
            raise Rejected("event_order")

    def observe(self, leg, payload, *, cursor, admitted_at_ns, healthy, continuous):
        self._check_event(admitted_at_ns, cursor)
        if type(leg) is not int or leg not in (0, 1):
            raise Rejected("leg")
        if type(healthy) is not bool or type(continuous) is not bool or type(payload) is not bytes:
            raise Rejected("canonical_input")
        try:
            book = decode_depth_snapshot(payload)
        except RecoveryNeeded as error:
            raise Rejected("invalid_depth") from error
        rule = self.rules[leg]
        if book["instrument"] != rule.instrument or book["rules_version"] != rule.version:
            raise Rejected("rules_scope")
        if book["visible_at_ns"] > admitted_at_ns:
            raise Rejected("future_book")
        self._books[leg] = (book, healthy)
        self._broken |= not healthy or not continuous
        self._cursor, self._time_ns = cursor, admitted_at_ns

    def invalidate(self, leg, *, cursor, at_ns):
        """Consume a canonical gap/health failure even when no new book exists."""
        self._check_event(at_ns, cursor)
        if type(leg) is not int or leg not in (0, 1):
            raise Rejected("leg")
        self._books[leg] = None
        self._broken = True
        self._cursor, self._time_ns = cursor, at_ns

    def sample(self, grid_ns, *, cursor):
        self._check_event(grid_ns, cursor)
        if grid_ns % SECOND:
            raise Rejected("grid_unit")
        if self._last_grid is not None and grid_ns <= self._last_grid:
            raise Rejected("grid_order")
        broken = self._broken or (self._last_grid is not None and grid_ns-self._last_grid != SECOND)
        evidence = [self.version]
        for entry in self._books:
            if entry is not None:
                book = entry[0]
                evidence.extend((book["instrument"], book["rules_version"], book["sequence"], book["visible_at_ns"]))
        reason = ""
        if any(entry is None for entry in self._books):
            reason = "missing_book"
        elif any(not entry[1] for entry in self._books):
            reason = "unhealthy_book"
        elif any(not r.valid_from_ns <= grid_ns < r.valid_until_ns for r in self.rules):
            reason = "expired_rules"
        elif any(grid_ns-entry[0]["visible_at_ns"] > self.max_age_ns for entry in self._books):
            reason = "stale_book"
        elif abs(self._books[0][0]["visible_at_ns"]-self._books[1][0]["visible_at_ns"]) > self.max_skew_ns:
            reason = "leg_skew"
        value = None
        if not reason:
            mids = [exact(Fraction(entry[0]["bids"][0][0]+entry[0]["asks"][0][0], 2)
                          * r.tick_quote_atoms_per_base_atom)
                    for entry, r in zip(self._books, self.rules)]
            value = finite(math.log(float(exact(mids[1]/mids[0]))))
        point = Point(grid_ns, cursor, value, reason, broken, tuple(evidence))
        self._cursor, self._time_ns, self._last_grid, self._broken = cursor, grid_ns, grid_ns, False
        return point


@dataclass(frozen=True)
class WindowSpec:
    version: int
    capacity: int
    warmup: int
    min_variance: float
    min_abs_z: float

    def __post_init__(self):
        uint(self.version, 1)
        if not 2 <= uint(self.warmup, 2) <= uint(self.capacity, 2) <= MAX_WINDOW:
            raise Rejected("window_capacity")
        positive(self.min_variance)
        if finite(self.min_abs_z) < 0:
            raise Rejected("deviation_policy")

    @property
    def content_hash(self):
        return fingerprint("window", [self.version, self.capacity, self.warmup,
                                      encode_number(float(self.min_variance)), encode_number(float(self.min_abs_z))])


@dataclass(frozen=True)
class Statistics:
    spec_hash: str
    source: Point
    count: int
    mean: float
    variance: float
    z_score: float

    def __post_init__(self):
        if not isinstance(self.source, Point) or self.source.value is None:
            raise Rejected("invalid_observation")
        uint(self.count, 2)
        finite(self.mean)
        positive(self.variance)
        finite(self.z_score)


class RollingWindow:
    """Recompute two-pass statistics in fixed order over a bounded valid window."""
    def __init__(self, spec):
        if not isinstance(spec, WindowSpec):
            raise Rejected("window_spec")
        self.spec = spec
        self._points = deque(maxlen=spec.capacity)
        self._last = None

    def push(self, point):
        if not isinstance(point, Point):
            raise Rejected("invalid_observation")
        if self._last is not None:
            if point.grid_ns <= self._last.grid_ns or point.cursor <= self._last.cursor:
                raise Rejected("observation_order")
            if point.grid_ns-self._last.grid_ns != SECOND or point.break_before:
                self._points.clear()
        if point.value is None:
            self._points.clear()
        else:
            self._points.append(point)
        self._last = point

    def statistics(self):
        if self._last is not None and self._last.value is None:
            raise Rejected(self._last.reason)
        n = len(self._points)
        if n < self.spec.warmup:
            raise Rejected("insufficient_samples")
        mean = sum_finite(p.value/n for p in self._points)
        variance = finite(sum_finite(square(p.value-mean) for p in self._points)/(n-1))
        if variance <= self.spec.min_variance:
            raise Rejected("degenerate_variance")
        z = finite((self._last.value-mean)/math.sqrt(variance))
        if abs(z) <= self.spec.min_abs_z:
            raise Rejected("near_center")
        return Statistics(self.spec.content_hash, self._last, n, mean, variance, z)


@dataclass(frozen=True)
class Bucket:
    key: Tuple[int, int, int, int]
    count: int
    mean_change: float
    variance: float


def edges(values):
    if type(values) is not tuple or len(values) > 16:
        raise Rejected("bucket_edges")
    previous = None
    for value in values:
        finite(value)
        if previous is not None and value <= previous:
            raise Rejected("bucket_edges")
        previous = value
    return values


def bucket_key(stats, deviation_edges, volatility_edges, horizon, direction):
    return (bisect_right(deviation_edges, direction*stats.z_score),
            bisect_right(volatility_edges, math.sqrt(stats.variance)), direction, horizon)


@dataclass(frozen=True)
class RollingBaseline:
    version: int
    trained_until_ns: int
    spec: WindowSpec
    deviation_edges: Tuple[float, ...]
    volatility_edges: Tuple[float, ...]
    min_samples: int
    buckets: Tuple[Bucket, ...]
    missing_labels: int
    excluded_labels: int

    def __post_init__(self):
        uint(self.version, 1)
        uint(self.trained_until_ns)
        if not isinstance(self.spec, WindowSpec):
            raise Rejected("window_spec")
        edges(self.deviation_edges)
        if any(x < 0 for x in edges(self.volatility_edges)):
            raise Rejected("volatility_edges")
        uint(self.min_samples, 2)
        uint(self.missing_labels)
        uint(self.excluded_labels)
        if type(self.buckets) is not tuple:
            raise Rejected("bucket_rows")
        previous = None
        for row in materialized(self.buckets, MAX_PENDING):
            if not isinstance(row, Bucket) or type(row.key) is not tuple or len(row.key) != 4:
                raise Rejected("bucket_rows")
            z, v, d, h = row.key
            if (type(z) is not int or not 0 <= z <= len(self.deviation_edges)
                    or type(v) is not int or not 0 <= v <= len(self.volatility_edges)
                    or type(d) is not int or d not in (-1, 1)
                    or type(h) is not int or h not in HORIZONS):
                raise Rejected("bucket_key")
            if previous is not None and row.key <= previous:
                raise Rejected("bucket_order")
            uint(row.count, 2)
            finite(row.mean_change)
            if finite(row.variance) < 0:
                raise Rejected("negative_variance")
            previous = row.key

    @property
    def content_hash(self):
        return fingerprint("rolling", [self.version, self.trained_until_ns, self.spec.content_hash,
            [encode_number(float(x)) for x in self.deviation_edges],
            [encode_number(float(x)) for x in self.volatility_edges], self.min_samples,
            [[list(r.key), r.count, encode_number(float(r.mean_change)), encode_number(float(r.variance))]
             for r in self.buckets], self.missing_labels, self.excluded_labels])

    def predict(self, stats, horizon_seconds, direction):
        if not isinstance(stats, Statistics) or stats.spec_hash != self.spec.content_hash:
            raise Rejected("window_scope")
        if stats.source.grid_ns < self.trained_until_ns:
            raise Rejected("training_leakage")
        if type(horizon_seconds) is not int or horizon_seconds not in HORIZONS:
            raise Rejected("horizon_seconds")
        if type(direction) is not int or direction not in (-1, 1):
            raise Rejected("direction")
        key = bucket_key(stats, self.deviation_edges, self.volatility_edges, horizon_seconds, direction)
        row = next((r for r in self.buckets if r.key == key), None)
        if row is None:
            raise Rejected("empty_bucket")
        if row.count < self.min_samples:
            raise Rejected("insufficient_bucket_samples")
        return Prediction("rolling", self.version, self.content_hash, stats.source, horizon_seconds,
                          direction, finite(stats.source.value+row.mean_change), row.variance, None)


def fit_rolling(points, *, spec, version, training_end_ns,
                deviation_edges, volatility_edges, min_samples):
    """Fit frozen endpoint-change buckets; exclude labels crossing training end.

    Count missing labels separately. Counts are raw, dependent observations,
    never effective independent samples or market calibration evidence.
    """
    uint(training_end_ns, 1)
    edges(deviation_edges)
    edges(volatility_edges)
    uint(min_samples, 2)
    points = ordered_points(points)
    visible = {p.grid_ns: p for p in points if p.grid_ns < training_end_ns}
    window = RollingWindow(spec)
    changes = {}
    missing = excluded = 0
    for point in visible.values():
        window.push(point)
        try:
            stats = window.statistics()
        except Rejected as error:
            if str(error) not in ("insufficient_samples", "degenerate_variance", "near_center") and point.value is not None:
                raise
            continue
        for horizon in HORIZONS:
            due = uint(point.grid_ns+horizon*SECOND)
            if due >= training_end_ns:
                excluded += 1
                continue
            target = visible.get(due)
            if target is None or target.value is None:
                missing += 1
                continue
            change = finite(target.value-point.value)
            for direction in (-1, 1):
                key = bucket_key(stats, deviation_edges, volatility_edges, horizon, direction)
                changes.setdefault(key, []).append(change)
                if len(changes) > MAX_PENDING:
                    raise Rejected("capacity")
    rows = []
    for key, values in sorted(changes.items()):
        n = len(values)
        if n < 2:
            continue
        mean = sum_finite(x/n for x in values)
        variance = finite(sum_finite(square(x-mean) for x in values)/(n-1))
        rows.append(Bucket(key, n, mean, variance))
    return RollingBaseline(version, training_end_ns, spec, deviation_edges, volatility_edges,
                           min_samples, tuple(rows), missing, excluded)


@dataclass(frozen=True)
class Label:
    prediction: Prediction
    status: str
    change: Optional[float]
    error: Optional[float]
    reason: str
    observed_at_ns: int
    observed_cursor: int


class LabelTracker:
    """Bound pending endpoint labels; return closed records for caller retention.

    A missing due grid is never backfilled by the next available observation.
    Capacity failure retains every pending record and grants no new eligibility.
    """
    def __init__(self, capacity):
        if uint(capacity, 1) > MAX_PENDING:
            raise Rejected("capacity")
        self.capacity = capacity
        self._pending = []
        self._last = None

    @property
    def pending(self):
        return tuple(self._pending)

    def add(self, forecast):
        if not isinstance(forecast, Prediction):
            raise Rejected("prediction")
        if self._last is not None:
            if (forecast.source.grid_ns < self._last.grid_ns
                    or forecast.source.cursor < self._last.cursor
                    or (forecast.source.grid_ns > self._last.grid_ns and forecast.source.cursor <= self._last.cursor)):
                raise Rejected("prediction_order")
        if any(p.identity == forecast.identity for p in self._pending):
            raise Rejected("duplicate_prediction")
        if len(self._pending) >= self.capacity:
            raise Rejected("capacity")
        self._pending.append(forecast)

    def advance(self, point):
        if not isinstance(point, Point):
            raise Rejected("invalid_observation")
        if self._last is not None and (point.grid_ns <= self._last.grid_ns or point.cursor <= self._last.cursor):
            raise Rejected("observation_order")
        if any(point.grid_ns < p.source.grid_ns or point.cursor < p.source.cursor
               or (point.grid_ns > p.source.grid_ns and point.cursor <= p.source.cursor)
               for p in self._pending):
            raise Rejected("label_causality")
        labels = []
        pending = []
        for forecast in self._pending:
            if forecast.due_ns > point.grid_ns:
                pending.append(forecast)
                continue
            reason = "missed_grid" if forecast.due_ns < point.grid_ns else point.reason
            if reason:
                labels.append(Label(forecast, "missing", None, None, reason, point.grid_ns, point.cursor))
            else:
                labels.append(Label(forecast, "mature", finite(point.value-forecast.source.value),
                                    finite(point.value-forecast.mean), "", point.grid_ns, point.cursor))
        self._pending, self._last = pending, point
        return tuple(labels)
