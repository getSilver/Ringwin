"""Strategy-private S5 progress, fed by admitted one-second grid/window facts.

Grid numbers identify sampler points, not IPC batches. No balance, reservation,
order or safety permission is owned here. Persistence is ticket 10's concern.
"""
from dataclasses import dataclass

import arbitrage_baseline as b
import arbitrage_economics as e
import arbitrage_probability as p


@dataclass(frozen=True)
class SignalPolicy:
    version: int
    score_ref: str
    reset: object
    entry: object
    reset_points: int
    entry_points: int
    cooldown_ns: int
    opportunity_ttl_ns: int
    interval_ns: int
    max_evaluations: int

    def __post_init__(self):
        p.reference(self.score_ref)
        if e.exact(self.reset) >= e.exact(self.entry):
            raise b.Rejected("signal_hysteresis")
        for value in (self.version, self.reset_points, self.entry_points,
                      self.opportunity_ttl_ns, self.interval_ns, self.max_evaluations):
            b.uint(value, 1)
        b.uint(self.cooldown_ns)
        if max(self.reset_points, self.entry_points, self.max_evaluations) > 100_000:
            raise b.Rejected("signal_capacity")


class Signal:
    def __init__(self, scope, policy):
        p.reference(scope)
        if not isinstance(policy, SignalPolicy):
            raise b.Rejected("signal_policy")
        self.scope, self.policy = scope, policy
        self.last_grid = self.last_at_ns = self.previous = None
        self.reset_count = self.entry_count = 0
        self.armed = False
        self.opportunity = None
        self.deadline_ns = self.last_evaluation_ns = None
        self.evaluations_used = 0
        self.pending = self.active = None
        self.closed_cycle = None
        self.cooldown_until_ns = 0
        self.reasons = {}
        self.activation_ref = None
        self.enabled_at_ns = 0
        self.trigger_ns = None

    def activate(self, activation_ref, at_ns):
        p.reference(activation_ref)
        b.uint(at_ns)
        if activation_ref == self.activation_ref:
            return
        if self.last_at_ns is not None and at_ns < self.last_at_ns:
            raise b.Rejected("activation_time")
        self.activation_ref, self.enabled_at_ns = activation_ref, at_ns
        self.invalidate()

    def invalidate(self):
        self.reset_count = self.entry_count = 0
        self.armed = False
        self.previous = None
        self.opportunity = None

    def lock(self, reason, fact_ref):
        p.reference(reason)
        p.reference(fact_ref)
        self.reasons[reason] = fact_ref
        self.invalidate()

    def recover(self, reason, *, cause_ref, recovery_ref):
        p.reference(recovery_ref)
        if self.reasons.get(reason) != cause_ref:
            raise b.Rejected("recovery_cause")
        del self.reasons[reason]
        self.invalidate()

    def observe(self, grid, at_ns, score, *, qualified):
        b.uint(grid)
        b.uint(at_ns)
        score = e.exact(score)
        if type(qualified) is not bool:
            raise b.Rejected("signal_evidence")
        if self.last_grid is not None and grid <= self.last_grid:
            return  # Late/repeated information cannot rewrite an old grid.
        if self.last_at_ns is not None and at_ns <= self.last_at_ns:
            raise b.Rejected("signal_time")
        if self.last_grid is not None and grid != self.last_grid+1:
            self.invalidate()
        self.last_grid, self.last_at_ns = grid, at_ns
        if (not qualified or self.reasons or self.pending or self.active
                or at_ns < max(self.cooldown_until_ns, self.enabled_at_ns)):
            self.invalidate()
            return
        if self.opportunity is not None:
            if at_ns >= self.deadline_ns or score < self.policy.entry:
                self.invalidate()
            else:
                self.previous = score
                return
        if not self.armed:
            self.reset_count = self.reset_count+1 if score <= self.policy.reset else 0
            if self.reset_count >= self.policy.reset_points:
                self.armed = True
        elif score < self.policy.entry:
            self.entry_count = 0
        elif self.entry_count or (self.previous is not None and self.previous < self.policy.entry):
            self.entry_count += 1
            if self.entry_count >= self.policy.entry_points:
                self.opportunity = b.fingerprint("opportunity", (self.scope, self.policy.version,
                    self.policy.score_ref, grid))
                self.deadline_ns = b.uint(at_ns+self.policy.opportunity_ttl_ns)
                self.trigger_ns = at_ns
                self.evaluations_used, self.last_evaluation_ns = 0, None
        self.previous = score

    def evaluate(self, at_ns, *, within_batch=False):
        b.uint(at_ns)
        if type(within_batch) is not bool:
            raise b.Rejected("signal_batch")
        if (self.opportunity is None or self.pending or self.active or self.reasons
                or self.last_at_ns is None or at_ns < self.last_at_ns):
            return False
        if at_ns >= self.deadline_ns:
            self.invalidate()
            return False
        if (self.evaluations_used >= self.policy.max_evaluations or
                (not within_batch and self.last_evaluation_ns is not None
                 and at_ns-self.last_evaluation_ns < self.policy.interval_ns)):
            return False
        self.evaluations_used += 1
        self.last_evaluation_ns = at_ns
        return True

    def close(self, cycle_ref, closed_at_ns, *, reconciled, released):
        p.reference(cycle_ref)
        b.uint(closed_at_ns)
        if cycle_ref == self.closed_cycle:
            return
        if cycle_ref != self.active or reconciled is not True or released is not True:
            raise b.Rejected("cycle_not_closed")
        until = b.uint(closed_at_ns+self.policy.cooldown_ns)
        self.closed_cycle, self.active = cycle_ref, None
        self.cooldown_until_ns = until
        self.invalidate()


@dataclass(frozen=True)
class Metric:
    name: str
    clear: object
    warn: object
    fail: object
    min_samples: int
    freshness_ns: int

    def __post_init__(self):
        p.reference(self.name)
        if not e.exact(self.clear) < e.exact(self.warn) < e.exact(self.fail):
            raise b.Rejected("monitor_thresholds")
        b.uint(self.min_samples, 1)
        b.uint(self.freshness_ns, 1)


@dataclass(frozen=True)
class Window:
    metric: str
    sequence: int
    cutoff_ns: int
    value: object
    effective_samples: int
    mature: bool

    def __post_init__(self):
        p.reference(self.metric)
        b.uint(self.sequence, 1)
        b.uint(self.cutoff_ns)
        b.uint(self.effective_samples)
        if self.value is not None:
            e.exact(self.value)
        if type(self.mature) is not bool:
            raise b.Rejected("monitor_maturity")


class Monitor:
    def __init__(self, metrics, *, warn_windows, fail_windows, clear_windows):
        if not e.bounded(metrics) or any(not isinstance(x, Metric) for x in metrics):
            raise b.Rejected("monitor_metrics")
        self.metrics = {x.name: x for x in metrics}
        if len(self.metrics) != len(metrics):
            raise b.Rejected("duplicate_metric")
        for count in (warn_windows, fail_windows, clear_windows):
            b.uint(count, 1)
        self.warn_windows, self.fail_windows, self.clear_windows = warn_windows, fail_windows, clear_windows
        self.state, self.qualified = "Normal", False
        self.sequences = {name: 0 for name in self.metrics}
        self.counts = {name: (0, 0) for name in self.metrics}
        self.good_windows = 0
        self.last_at_ns = None
        self.windows = {}

    def update(self, windows, *, at_ns, independent_evidence):
        b.uint(at_ns)
        e.bounded(windows)
        if type(independent_evidence) is not bool or any(not isinstance(x, Window) for x in windows):
            raise b.Rejected("monitor_evidence")
        by_name = {x.metric: x for x in windows}
        if len(by_name) != len(windows) or by_name.keys() != self.metrics.keys():
            raise b.Rejected("monitor_scope")
        if self.last_at_ns is not None and at_ns < self.last_at_ns:
            raise b.Rejected("monitor_time")
        if any(w.cutoff_ns > at_ns for w in windows):
            raise b.Rejected("future_window")
        for w in windows:
            if w.sequence < self.sequences[w.metric]:
                raise b.Rejected("old_monitor_window")
            if w.sequence == self.sequences[w.metric] and self.windows[w.metric] != w:
                raise b.Rejected("monitor_window_rewrite")
        self.last_at_ns = at_ns
        qualified, good, all_new, consecutive = independent_evidence, independent_evidence, True, True
        for name, metric in self.metrics.items():
            w = by_name[name]
            valid = (independent_evidence and w.mature and w.value is not None and w.effective_samples >= metric.min_samples
                     and at_ns-w.cutoff_ns < metric.freshness_ns)
            qualified &= valid
            good &= valid and w.value <= metric.clear
            previous = self.sequences[name]
            consecutive &= w.sequence == previous+1
            if w.sequence <= previous:
                all_new = False
                if not valid:
                    self.counts[name] = (0, 0)
                continue
            warn, fail = self.counts[name] if w.sequence == previous+1 else (0, 0)
            self.counts[name] = (warn+1 if valid and w.value >= metric.warn else 0,
                                 fail+1 if valid and w.value >= metric.fail else 0)
            self.sequences[name] = w.sequence
            self.windows[name] = w
        self.qualified = bool(qualified)
        if not good:
            self.good_windows = 0
        elif all_new:
            self.good_windows = self.good_windows+1 if consecutive else 1
        if any(f >= self.fail_windows for _, f in self.counts.values()):
            self.state = "InvalidLatched"
        elif self.state == "Normal" and any(w >= self.warn_windows for w, _ in self.counts.values()):
            self.state = "Warning"
        elif self.state == "Warning" and self.good_windows >= self.clear_windows:
            self.state = "Normal"
        return self.state

    def invariant_failure(self):
        self.state, self.qualified = "InvalidLatched", False
        self.good_windows = 0
        self.counts = {name: (0, 0) for name in self.metrics}

    def recover(self, *, review_ref, reconciliation_ref, authorization_ref):
        for ref in (review_ref, reconciliation_ref, authorization_ref):
            p.reference(ref)
        if self.state != "InvalidLatched" or not self.qualified or self.good_windows < self.clear_windows:
            raise b.Rejected("model_recovery")
        self.state = "Normal"

    def actions(self, *, phase, unknown=False, normal_take_profit=False):
        if unknown:
            return ("query_original_identity",)
        if self.state == "InvalidLatched":
            return ("stop_new_cycles", "cancel_entry", "controlled_exit")
        if self.state == "Warning":
            return ("stop_new_cycles", "cancel_entry")
        if phase == "Holding" and normal_take_profit:
            return ("normal_exit",)
        return ()
