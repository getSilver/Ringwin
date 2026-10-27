"""Causal two-state challenger: random-walk center plus AR(1) deviation.

Only read-only statistical projections live here. Grid/labels/numeric encoding
are shared with the baseline; fitting never runs during filtering.
"""
from dataclasses import dataclass, replace
from fractions import Fraction
import math
from typing import Optional, Tuple

import arbitrage_baseline as b
from strategy_state import encode_number

IDENTITY = (1., 0., 0., 1.)
ALGORITHM = "state_space_joseph_binary64_v1"


def _transpose(a):
    return (a[0], a[2], a[1], a[3])


def _multiply(a, z):
    return tuple(b.sum_finite(a[2*i+k]*z[2*k+j] for k in range(2))
                 for i in range(2) for j in range(2))


def _add(a, z):
    return tuple(b.sum_finite((x, y)) for x, y in zip(a, z))


def _covariance(value, tolerance, strict=False):
    if type(value) is not tuple or len(value) != 4:
        raise b.Rejected("covariance_shape")
    a, x, y, d = (b.finite(v) for v in value)
    scale = max(abs(v) for v in value)
    if a < 0 or d < 0 or abs(x-y) > tolerance*scale:
        raise b.Rejected("invalid_covariance")
    if strict:
        if x != y or Fraction(a)*Fraction(d) < Fraction(x)*Fraction(y):
            raise b.Rejected("non_psd_covariance")
    elif scale and (a/scale)*(d/scale)-(x/scale)*(y/scale) < -tolerance:
        raise b.Rejected("non_psd_covariance")
    off = b.sum_finite((x/2, y/2))
    return (a, off, off, d)


def _propagate(mean, covariance, params):
    f = (1., 0., 0., params.phi)
    projected_mean = (mean[0], b.finite(params.phi*mean[1]))
    projected_cov = _add(_multiply(_multiply(f, covariance), _transpose(f)), params.q)
    return projected_mean, _covariance(projected_cov, params.covariance_tolerance)


@dataclass(frozen=True)
class Parameters:
    version: int
    trained_until_ns: int
    phi: float
    q: Tuple[float, ...]
    r: float
    prior_mean: Tuple[float, ...]
    prior_covariance: Tuple[float, ...]
    warmup: int
    min_reversion: float
    max_covariance: float
    min_abs_deviation: float
    covariance_tolerance: float

    def __post_init__(self):
        b.uint(self.version, 1)
        b.uint(self.trained_until_ns)
        if not 0 < b.finite(self.phi) < 1:
            raise b.Rejected("non_stationary_phi")
        if not 0 < b.positive(self.min_reversion) < 1 or 1-self.phi < self.min_reversion:
            raise b.Rejected("near_unit_root")
        b.positive(self.r)
        b.positive(self.max_covariance)
        if b.finite(self.min_abs_deviation) < 0:
            raise b.Rejected("deviation_policy")
        if not 0 < b.positive(self.covariance_tolerance) < 1:
            raise b.Rejected("covariance_tolerance")
        _covariance(self.q, self.covariance_tolerance, strict=True)
        _covariance(self.prior_covariance, self.covariance_tolerance, strict=True)
        if type(self.prior_mean) is not tuple or len(self.prior_mean) != 2:
            raise b.Rejected("mean_shape")
        for value in self.prior_mean:
            b.finite(value)
        object.__setattr__(self, "prior_mean", tuple(b.finite(v) for v in self.prior_mean))
        object.__setattr__(self, "prior_covariance", tuple(b.finite(v) for v in self.prior_covariance))
        if b.uint(self.warmup, 2) > b.MAX_WINDOW:
            raise b.Rejected("warmup_capacity")

    @property
    def content_hash(self):
        numbers = (self.phi, *self.q, self.r, *self.prior_mean, *self.prior_covariance,
                   self.min_reversion, self.max_covariance, self.min_abs_deviation, self.covariance_tolerance)
        return b.fingerprint(ALGORITHM, [self.version, self.trained_until_ns, self.warmup,
                                         [encode_number(float(x)) for x in numbers]])


@dataclass(frozen=True)
class FilterState:
    mean: Tuple[float, ...]
    covariance: Tuple[float, ...]
    source: Optional[b.Point]
    count: int
    reason: str
    innovation: Optional[float]
    innovation_variance: Optional[float]
    log_likelihood: Optional[float]


class Filter:
    """Update only with the current admitted point; first valid point uses prior.

    A gap resets only these private prediction quantities. The object has no
    reference to a trading cycle, deadline, risk latch, budget or authority.
    """
    def __init__(self, parameters):
        if not isinstance(parameters, Parameters):
            raise b.Rejected("model_parameters")
        self.parameters = parameters
        self._state = FilterState(parameters.prior_mean, parameters.prior_covariance,
                                  None, 0, "warming", None, None, None)

    @property
    def state(self):
        return self._state

    def push(self, point):
        if not isinstance(point, b.Point):
            raise b.Rejected("invalid_observation")
        previous, p = self._state, self.parameters
        if previous.source is not None:
            if point.grid_ns <= previous.source.grid_ns or point.cursor <= previous.source.cursor:
                raise b.Rejected("observation_order")
        if point.value is None:
            state = FilterState(p.prior_mean, p.prior_covariance, point, 0, point.reason, None, None, None)
        else:
            continuous = (previous.count > 0 and not point.break_before
                          and point.grid_ns-previous.source.grid_ns == b.SECOND)
            mean, covariance = (_propagate(previous.mean, previous.covariance, p) if continuous
                                else (p.prior_mean, p.prior_covariance))
            innovation = b.finite(point.value-b.sum_finite(mean))
            variance = b.positive(b.sum_finite((*covariance, p.r)))
            gain = (b.finite(b.sum_finite(covariance[:2])/variance),
                    b.finite(b.sum_finite(covariance[2:])/variance))
            filtered_mean = tuple(b.sum_finite((mean[i], gain[i]*innovation)) for i in range(2))
            a = (1-gain[0], -gain[0], -gain[1], 1-gain[1])
            noise = tuple(b.finite(gain[i]*gain[j]*p.r) for i in range(2) for j in range(2))
            filtered_cov = _covariance(_add(_multiply(_multiply(a, covariance), _transpose(a)), noise),
                                       p.covariance_tolerance)
            likelihood = b.finite(-.5*b.sum_finite((math.log(2*math.pi), math.log(variance),
                                                   b.square(innovation/math.sqrt(variance)))))
            count = b.uint(previous.count+1 if continuous else 1, 1)
            reason = ("warming" if count < p.warmup else "covariance_limit"
                      if b.sum_finite((filtered_cov[0], filtered_cov[3])) > p.max_covariance else "")
            state = FilterState(filtered_mean, filtered_cov, point, count, reason,
                                innovation, variance, likelihood)
        self._state = state
        return state

    def predict(self, horizon_seconds, direction):
        state, p = self._state, self.parameters
        if state.reason or state.source is None:
            raise b.Rejected(state.reason or "warming")
        if state.source.grid_ns < p.trained_until_ns:
            raise b.Rejected("training_leakage")
        if type(horizon_seconds) is not int or horizon_seconds not in b.HORIZONS:
            raise b.Rejected("horizon_seconds")
        if abs(state.mean[1]) <= p.min_abs_deviation:
            raise b.Rejected("near_center")
        mean, covariance = state.mean, state.covariance
        for _ in range(horizon_seconds):
            mean, covariance = _propagate(mean, covariance, p)
        if b.sum_finite((covariance[0], covariance[3])) > p.max_covariance:
            raise b.Rejected("covariance_limit")
        return b.Prediction("state_space", p.version, p.content_hash, state.source, horizon_seconds,
                            direction, b.sum_finite(mean), b.positive(b.sum_finite((*covariance, p.r))),
                            math.log(.5)/math.log(p.phi))


@dataclass(frozen=True)
class FitPolicy:
    steps: Tuple[float, ...]
    contraction: float
    minimum_step: float
    iterations: int
    max_evaluations: int
    min_points: int
    profile_steps: Tuple[float, ...]
    identifiability_delta: float
    alternative_distance: float
    degeneracy_fraction: float
    improvement_tolerance: float

    def __post_init__(self):
        for vector in (self.steps, self.profile_steps):
            if type(vector) is not tuple or len(vector) != 5:
                raise b.Rejected("fit_steps")
            for value in vector:
                b.positive(value)
        if not 0 < b.positive(self.contraction) < 1 or not 0 < b.positive(self.degeneracy_fraction) < 1:
            raise b.Rejected("fit_policy")
        b.positive(self.minimum_step)
        b.positive(self.alternative_distance)
        if b.uint(self.iterations, 1) > 256 or b.uint(self.max_evaluations, 1) > 10_000:
            raise b.Rejected("fit_capacity")
        b.uint(self.min_points, 10)
        if min(b.finite(self.identifiability_delta), b.finite(self.improvement_tolerance)) < 0:
            raise b.Rejected("fit_policy")


@dataclass(frozen=True)
class FitRun:
    start_hash: str
    initial_nll: Optional[float]
    final_nll: Optional[float]
    parameters: Optional[Parameters]
    iterations: int
    converged: bool
    reason: str


@dataclass(frozen=True)
class FitReport:
    selected: Optional[Parameters]
    runs: Tuple[FitRun, ...]
    evaluations: int
    training_digest: str
    flat_coordinates: Tuple[str, ...]
    ambiguous_starts: Tuple[int, ...]
    degeneracies: Tuple[str, ...]
    identifiable: bool


def _coordinates(p):
    if p.q[0] <= 0 or p.q[3] <= 0:
        raise b.Rejected("degenerate_start")
    rho = p.q[1]/math.sqrt(p.q[0])/math.sqrt(p.q[3])
    if not -1 < rho < 1:
        raise b.Rejected("degenerate_start")
    return (math.log(p.phi)-math.log1p(-p.phi), math.log(p.q[0]), math.log(p.q[3]),
            math.atanh(rho), math.log(p.r))


def _decode(values, template):
    try:
        x, a, d, corr, noise = values
        e = math.exp(-abs(x))
        phi = 1/(1+e) if x >= 0 else e/(1+e)
        q0, q1 = b.positive(math.exp(a)), b.positive(math.exp(d))
        off = math.tanh(corr)*math.sqrt(q0)*math.sqrt(q1)
        return replace(template, phi=phi, q=(q0, off, off, q1), r=b.positive(math.exp(noise)))
    except (OverflowError, ValueError) as error:
        raise b.Rejected("fit_parameter_domain") from error


def fit(points, starts, *, training_end_ns, version, policy):
    """Deterministic bounded multistart pattern search of innovation likelihood.

    Five transformed coordinates cover phi, Q diagonals/correlation and R;
    registered priors are selected across starts using training data only.
    A report's best finite candidate never activates or qualifies a model.
    """
    b.uint(training_end_ns, 1)
    b.uint(version, 1)
    if not isinstance(policy, FitPolicy) or type(starts) is not tuple or not 2 <= len(starts) <= 16:
        raise b.Rejected("multistart_policy")
    if any(not isinstance(p, Parameters) for p in starts):
        raise b.Rejected("model_parameters")
    if len({(p.phi, *p.q, p.r, *p.prior_mean, *p.prior_covariance) for p in starts}) != len(starts):
        raise b.Rejected("distinct_starts_required")
    if len({(p.warmup, p.min_reversion, p.max_covariance, p.min_abs_deviation, p.covariance_tolerance)
            for p in starts}) != 1:
        raise b.Rejected("fit_policy_scope")
    training = tuple(p for p in b.ordered_points(points) if p.grid_ns < training_end_ns)
    if sum(p.value is not None for p in training) < policy.min_points:
        raise b.Rejected("insufficient_samples")
    digest = b.fingerprint(ALGORITHM, [[p.grid_ns, p.cursor,
        None if p.value is None else encode_number(float(p.value)), p.reason, p.break_before, list(p.evidence)]
        for p in training])
    evaluations = 0

    def score(params):
        nonlocal evaluations
        if evaluations >= policy.max_evaluations:
            raise b.Rejected("fit_capacity")
        evaluations += 1
        model, likelihoods = Filter(params), []
        for point in training:
            state = model.push(point)
            if state.reason == "covariance_limit":
                raise b.Rejected("covariance_limit")
            if state.log_likelihood is not None:
                likelihoods.append(-state.log_likelihood)
        return b.sum_finite(likelihoods)

    def proposal(values, template):
        try:
            params = _decode(values, template)
            return params, score(params)
        except b.Rejected as error:
            if str(error) == "fit_capacity":
                raise
            return None, None

    runs = []
    for start in starts:
        template = replace(start, version=version, trained_until_ns=training_end_ns)
        try:
            values = _coordinates(template)
            initial = score(template)
        except b.Rejected as error:
            if str(error) == "fit_capacity":
                raise
            runs.append(FitRun(start.content_hash, None, None, None, 0, False, str(error)))
            continue
        current, current_nll = template, initial
        steps, converged, used = policy.steps, False, 0
        for used in range(1, policy.iterations+1):
            improved = False
            for coordinate in range(5):
                for sign in (-1, 1):
                    trial = tuple(v+sign*steps[i] if i == coordinate else v for i, v in enumerate(values))
                    params, nll = proposal(trial, template)
                    if nll is not None and nll < current_nll-policy.improvement_tolerance:
                        values, current, current_nll, improved = trial, params, nll, True
            if not improved:
                steps = tuple(v*policy.contraction for v in steps)
                if max(steps) < policy.minimum_step:
                    converged = True
                    break
        runs.append(FitRun(start.content_hash, initial, current_nll, current, used, converged,
                           "" if converged else "iteration_limit"))
    valid = [(i, r) for i, r in enumerate(runs) if r.final_nll is not None]
    if not valid:
        return FitReport(None, tuple(runs), evaluations, digest, (), (), ("no_valid_start",), False)
    best_index, best = min(valid, key=lambda entry: (entry[1].final_nll, entry[0]))
    selected = best.parameters
    values = _coordinates(selected)
    flat = []
    for coordinate, name in enumerate(("phi", "q_center", "q_deviation", "q_correlation", "r")):
        differences = []
        for sign in (-1, 1):
            trial = tuple(v+sign*policy.profile_steps[i] if i == coordinate else v for i, v in enumerate(values))
            _, nll = proposal(trial, selected)
            if nll is not None:
                differences.append(abs(nll-best.final_nll))
        if not differences or min(differences) <= policy.identifiability_delta:
            flat.append(name)
    ambiguous = tuple(i for i, run in valid if i != best_index
                      and run.final_nll-best.final_nll <= policy.identifiability_delta
                      and math.sqrt(b.sum_finite(b.square(x-y) for x, y in zip(_coordinates(run.parameters), values)))
                      > policy.alternative_distance)
    total_noise = b.positive(b.sum_finite((selected.q[0], selected.q[3], selected.r)))
    degeneracies = tuple(name for name, noise in (("q_center", selected.q[0]),
                         ("q_deviation", selected.q[3]), ("r", selected.r))
                         if noise/total_noise <= policy.degeneracy_fraction)
    return FitReport(selected, tuple(runs), evaluations, digest, tuple(flat), ambiguous, degeneracies,
                     best.converged and not flat and not ambiguous and not degeneracies)
