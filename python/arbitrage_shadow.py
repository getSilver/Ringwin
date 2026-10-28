"""Offline read-only driver, not a live Host or a ShadowSimulation qualification.

Capture JSON plus the original immutable Frame archive is required for replay.
Frozen research inputs are fingerprinted rather than given another wire codec.
There is no sender, reservation callback, intent encoder or execution cycle here.
"""
import copy
from dataclasses import dataclass, asdict
import json
from time import perf_counter_ns

import arbitrage_admission as admission
import arbitrage_baseline as b
import arbitrage_checkpoint as checkpoint
import arbitrage_economics as economics
import arbitrage_probability as probability
import arbitrage_scanner as scanner
import arbitrage_signals as signals
from strategy_host import decode_depth_snapshot

SCHEMA = "arbitrage_read_only_capture_v1"
MAX_CAPTURE_BYTES = 16 * 1024 * 1024


@dataclass(frozen=True)
class Protocol:
    version: str
    code_hash: str
    calibration_ref: str
    min_frames: int
    min_duration_ns: int
    max_compute_ns: int
    max_frames: int
    max_capture_bytes: int
    max_age_ns: int
    max_gap_frames: int
    min_options_per_frame: int

    def __post_init__(self):
        probability.reference(self.version)
        probability.validate_hash(self.code_hash)
        probability.reference(self.calibration_ref)
        for value in (self.min_frames, self.min_duration_ns, self.max_compute_ns,
                      self.max_frames, self.max_capture_bytes, self.max_age_ns, self.min_options_per_frame):
            b.uint(value, 1)
        b.uint(self.max_gap_frames)
        if (self.min_frames > self.max_frames or self.max_frames > 100_000
                or self.max_capture_bytes > MAX_CAPTURE_BYTES or self.min_options_per_frame > 256):
            raise b.Rejected("shadow_capacity")


@dataclass(frozen=True)
class Frame:
    observations: tuple
    options: tuple
    approvals: tuple
    facts: admission.Facts
    # (scope, grid, exact score, qualified); cursor/time come from Facts.
    scores: tuple
    windows: tuple
    independent_evidence: bool
    restart: bool = False

    def __post_init__(self):
        for items in (self.observations, self.options, self.approvals, self.scores, self.windows):
            if type(items) is not tuple or len(items) > 256:
                raise b.Rejected("shadow_frame_capacity")
        if (not isinstance(self.facts, admission.Facts) or type(self.independent_evidence) is not bool
                or type(self.restart) is not bool):
            raise b.Rejected("shadow_frame")
        for items, cls in ((self.observations, scanner.Observation), (self.options, admission.Option),
                           (self.approvals, admission.Approval), (self.windows, signals.Window)):
            if any(not isinstance(x, cls) for x in items):
                raise b.Rejected("shadow_frame")
        if any(x.plan.policy.mode != "taker_taker" for x in self.options):
            raise b.Rejected("shadow_mode")
        for score in self.scores:
            if type(score) is not tuple or len(score) != 4 or type(score[3]) is not bool:
                raise b.Rejected("shadow_signal_input")
            probability.reference(score[0])
            b.uint(score[1])
            economics.exact(score[2])


def _json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


class Session:
    def __init__(self, protocol, config, signal_states, monitor, metadata):
        if (not isinstance(protocol, Protocol) or not isinstance(config, admission.Config)
                or not isinstance(monitor, signals.Monitor) or type(signal_states) is not tuple
                or len(signal_states) > 63 or any(not isinstance(x, signals.Signal) for x in signal_states)):
            raise b.Rejected("shadow_configuration")
        if len({x.scope for x in signal_states}) != len(signal_states):
            raise b.Rejected("shadow_signal_scope")
        self.protocol, self.config = protocol, config
        self._components = copy.deepcopy(dict(monitor=monitor, **{
            "signal"+str(i): state for i, state in enumerate(signal_states)}))
        self._metadata = copy.deepcopy(metadata)
        checkpoint.checkpoint(metadata, self._components)
        self._initial = checkpoint.content((protocol, config, self._metadata,
            tuple((name, checkpoint.dependency(obj), checkpoint.progress(obj, checkpoint.TYPES[type(obj)]))
                  for name, obj in sorted(self._components.items()))))
        self._records = []
        self._last_cursor, self._last_time = metadata["cursor"], 0
        self._stopped = False

    def step(self, frame):
        if not isinstance(frame, Frame):
            raise b.Rejected("shadow_frame")
        if self._stopped or len(self._records) >= self.protocol.max_frames:
            self._stopped = True
            raise b.Rejected("shadow_capture_capacity")
        facts = frame.facts
        if facts.cursor <= self._last_cursor or facts.at_ns < self._last_time:
            raise b.Rejected("shadow_order")
        start = perf_counter_ns()
        components = copy.deepcopy(self._components)
        monitor = components["monitor"]
        states = tuple(v for v in components.values() if isinstance(v, signals.Signal))
        state_by_scope = {x.scope: x for x in states}
        decision = dict(cursor=facts.cursor, at_ns=facts.at_ns, trading_qualified=False,
                        candidates=[], suggestion=None, rejections=[], monitor_actions=[], error="")
        ages = []
        try:
            if frame.restart:
                metadata = dict(self._metadata, cursor=self._last_cursor)
                _, components = checkpoint.restore(checkpoint.checkpoint(metadata, components), components)
                monitor = components["monitor"]
                states = tuple(v for v in components.values() if isinstance(v, signals.Signal))
                state_by_scope = {x.scope: x for x in states}
            monitor.update(frame.windows, at_ns=facts.at_ns, independent_evidence=frame.independent_evidence)
            snapshot = scanner.scan(frame.observations, tuple(x.plan for x in frame.options),
                at_ns=facts.at_ns, cursor=facts.cursor, max_age_ns=self.config.max_book_age_ns,
                max_skew_ns=self.config.max_leg_skew_ns)
            decision["candidates"] = [row for row in snapshot["candidates"] if row["mode"] == "taker_taker"]
            ages = [facts.at_ns-decode_depth_snapshot(x.book)["visible_at_ns"] for x in frame.observations]
            healthy = (bool(ages) and all(x.continuous and x.rules.valid_from_ns <= facts.at_ns < x.rules.valid_until_ns
                       for x in frame.observations) and max(ages) < self.config.max_book_age_ns
                       and max(ages)-min(ages) <= self.config.max_leg_skew_ns
                       and monitor.state == "Normal" and monitor.qualified)
            if not healthy:
                for state in states:
                    state.invalidate()
            if len({score[0] for score in frame.scores}) != len(frame.scores):
                raise b.Rejected("shadow_duplicate_signal")
            for score in frame.scores:
                if type(score) is not tuple or len(score) != 4 or score[0] not in state_by_scope:
                    raise b.Rejected("shadow_signal_input")
                scope, grid, value, qualified = score
                state_by_scope[scope].observe(grid, facts.at_ns, value,
                    qualified=qualified and healthy, cursor=facts.cursor)
            # The batch has no reservation capability; signals belong only to this shadow.
            result = admission.Admission(self.config).propose(frame.observations, frame.options,
                frame.approvals, states, facts)
            decision["rejections"] = [list(x) for x in result.rejections]
            if result.query_identity:
                decision["rejections"].append([result.query_identity, "query_original_identity"])
            if result.request is not None:
                request = result.request
                decision["suggestion"] = dict(identity=request.identity, plan_atoms=request.plan_atoms,
                    target_atoms=request.target_atoms, valid_until_ns=request.valid_until_ns)
                # No core call happened: discard hypothetical pending, keep evaluation/TTL.
                state_by_scope[request.scope].pending = None
            decision["monitor_actions"] = list(monitor.actions(phase="Scanning"))
            if monitor.state != "Normal" or not monitor.qualified:
                decision["suggestion"] = None
                decision["rejections"].append(["monitor", "model_health"])
        except (ValueError, TypeError, KeyError) as error:
            decision.update(error=str(error), suggestion=None)
            for state in states:
                state.invalidate()
            # Input rejection blocks entry; it is not evidence of model failure.
            decision["monitor_actions"] = list(dict.fromkeys(("stop_new_cycles", *monitor.actions(phase="Scanning"))))
        decision["state"] = checkpoint.content(tuple((name, checkpoint.progress(obj, checkpoint.TYPES[type(obj)]))
                                                   for name, obj in sorted(components.items())))
        decision["monitor_state"] = monitor.state
        versions = checkpoint.content((self.config.content_hash,
            tuple((x.identity, x.rules.version) for x in frame.observations),
            tuple((x.key, x.config_hash, x.model_hash, x.policy_version, x.calibration_version,
                   x.rules_versions, x.execution_hash, x.qualification_hash, x.activation_ref, x.enabled)
                  for x in frame.approvals),
            tuple((x.plan.policy.model_hash, x.plan.policy.version, x.plan.calibration.version) for x in frame.options)))
        record = dict(input_hash=checkpoint.content(frame),
                      books=[dict(identity=list(x.identity), book=x.book.hex(), continuous=x.continuous)
                             for x in frame.observations],
                      decision=decision, ages_ns=ages, restart=frame.restart, versions=versions,
                      gap=any(not x.continuous for x in frame.observations), options=len(frame.options),
                      compute_ns=b.MAX_U64)
        # Bound the complete artifact before committing any progress; never truncate.
        # Reserve every u64 timing field so capacity is independent of machine speed.
        candidate = dict(schema=SCHEMA, initial=self._initial, protocol=asdict(self.protocol),
                         records=[dict(row, compute_ns=b.MAX_U64) for row in self._records+[record]])
        result = copy.deepcopy(decision)
        if len(_json(candidate).encode()) > self.protocol.max_capture_bytes:
            self._stopped = True
            raise b.Rejected("shadow_capture_capacity")
        record["compute_ns"] = b.uint(perf_counter_ns()-start)
        self._records.append(record)
        self._components = components
        self._last_cursor, self._last_time = facts.cursor, facts.at_ns
        return result

    def capture_json(self):
        return _json(dict(schema=SCHEMA, initial=self._initial, protocol=asdict(self.protocol), records=self._records))

    def report(self):
        records = self._records
        elapsed = records[-1]["decision"]["at_ns"]-records[0]["decision"]["at_ns"] if records else 0
        reasons = []
        if len(records) < self.protocol.min_frames: reasons.append("sample_count")
        if elapsed < self.protocol.min_duration_ns: reasons.append("duration")
        if any(r["compute_ns"] > self.protocol.max_compute_ns for r in records): reasons.append("compute")
        if any(age >= self.protocol.max_age_ns for r in records for age in r["ages_ns"]): reasons.append("freshness")
        if sum(r["gap"] for r in records) > self.protocol.max_gap_frames: reasons.append("gaps")
        if any(r["options"] < self.protocol.min_options_per_frame for r in records): reasons.append("load")
        if any(r["decision"]["error"] for r in records): reasons.append("input_or_component_error")
        if any(r["decision"]["monitor_state"] != "Normal" or
               any(x[1] == "model_health" for x in r["decision"]["rejections"]) for r in records):
            reasons.append("monitor_health")
        if self._stopped: reasons.append("capture_capacity")
        return dict(schema=SCHEMA, mode="taker_taker", qualification=False, evidence="offline_unqualified",
                    real_host="not_run", real_market="not_run", calibration_ref=self.protocol.calibration_ref,
                    frames=len(records), duration_ns=elapsed, operational_gates_met=not reasons, reasons=reasons,
                    max_options=max((r["options"] for r in records), default=0),
                    max_compute_ns=max((r["compute_ns"] for r in records), default=0),
                    max_age_ns=max((age for r in records for age in r["ages_ns"]), default=0),
                    gap_frames=sum(r["gap"] for r in records), restarts=sum(r["restart"] for r in records),
                    version_changes=sum(a["versions"] != z["versions"] for a, z in zip(records, records[1:])),
                    monitor_actions=[r["decision"]["monitor_actions"] for r in records])


def replay(capture, frames, session_factory):
    """Compare actual recomputation, identifying the first divergent frame.

    Requires the complete original Frame archive and identical frozen Session
    dependencies. Measured wall-clock compute time is deliberately not replayed.
    """
    if type(capture) is not str or len(capture.encode()) > MAX_CAPTURE_BYTES:
        raise b.Rejected("shadow_capture_capacity")
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result: raise b.Rejected("shadow_duplicate_key")
            result[key] = value
        return result
    saved = json.loads(capture, object_pairs_hook=unique)
    if (type(saved) is not dict or set(saved) != {"schema", "initial", "protocol", "records"}
            or saved["schema"] != SCHEMA or type(frames) is not tuple
            or type(saved["records"]) is not list or len(saved["records"]) != len(frames)):
        raise b.Rejected("shadow_capture_shape")
    session = session_factory()
    if saved["initial"] != session._initial or _json(saved["protocol"]) != _json(asdict(session.protocol)):
        raise b.Rejected("shadow_dependency")
    for i, (record, frame) in enumerate(zip(saved["records"], frames)):
        if type(record) is not dict or set(record) != {"input_hash", "books", "decision", "ages_ns",
                "restart", "versions", "gap", "options", "compute_ns"}:
            raise b.Rejected("shadow_capture_shape")
        b.uint(record["compute_ns"])
        if record["input_hash"] != checkpoint.content(frame):
            raise b.Rejected("input:"+str(i))
        actual = session.step(frame)
        if _json(actual) != _json(record["decision"]):
            raise b.Rejected("decision:"+str(i))
        recomputed = session._records[-1]
        if _json({k: v for k, v in record.items() if k != "compute_ns"}) != _json({k: v for k, v in recomputed.items() if k != "compute_ns"}):
            raise b.Rejected("capture:"+str(i))
    return dict(matched=len(frames), qualification=False)
