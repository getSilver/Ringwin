"""Bounded rolling 24-hour scanner projections in process memory.

Restart clears these derived records. Core trading facts and approvals still
belong to DurableStore. Batch/replay caches may be shorter than event history.
"""
from collections import OrderedDict
import hashlib
import json
import secrets
from threading import RLock
import time

WINDOW_MS = 86_400_000


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


def detached(value):
    return json.loads(encoded(value))


class History:
    def __init__(self, *, clock=lambda: time.time_ns()//1_000_000, max_records=50_000,
                 max_bytes=64*1024*1024, max_batches=2048, max_evidence_bytes=16*1024*1024,
                 max_requests=1024):
        for value in (max_records, max_bytes, max_batches, max_evidence_bytes, max_requests):
            if type(value) is not int or value < 1:
                raise ValueError("history memory capacity")
        self.clock, self.lock = clock, RLock()
        self.max_records, self.max_bytes, self.max_batches = max_records, max_bytes, max_batches
        self.max_evidence_bytes, self.max_requests = max_evidence_bytes, max_requests
        self.started_ms = self.last_now = clock()
        self.instance_id = secrets.token_hex(16)
        self.last_pruned = None
        self.records, self.events, self.batches = OrderedDict(), OrderedDict(), OrderedDict()
        self.artifacts, self.requests = OrderedDict(), {}
        self.open_events, self.batch_heads = {}, {}
        self.weights, self.bytes, self.evidence_bytes = {}, 0, 0
        self.request_bytes = 0
        self.config, self.gaps = None, []
        self.healthy, self.error, self.closed = True, "", False

    def _now(self):
        if self.closed:
            raise OSError("history closed")
        now = self.clock()
        if type(now) is not int or now < 0:
            raise ValueError("history clock")
        if now < self.last_now:
            self._gap(self.last_now, "history_clock_regression")
        self.last_now = max(now, self.last_now)
        return self.last_now

    def _gap(self, now, reason):
        if not self.gaps or self.gaps[-1] != dict(wall_ms=now, reason=reason):
            self.gaps.append(dict(wall_ms=now, reason=reason))
        self.gaps = self.gaps[-64:]

    def _put(self, table, kind, identity, row):
        key = kind, identity
        size = len(encoded(row).encode())
        self.bytes += size-self.weights.get(key, 0)
        self.weights[key] = size
        table[identity] = row

    def _drop(self, table, kind, identity):
        row = table.pop(identity)
        self.bytes -= self.weights.pop((kind, identity))
        if kind == "events":
            selector = row["session"], row["candidate"]
            if self.open_events.get(selector) == identity:
                self.open_events.pop(selector)

    def _prune(self, now, *, force=False):
        if not force and self.last_pruned is not None and now-self.last_pruned < 1000:
            return
        self.last_pruned = now
        cutoff = now-WINDOW_MS
        for table, kind in ((self.records, "records"), (self.batches, "batches"), (self.events, "events")):
            for identity, row in list(table.items()):
                if row.get("last_wall_ms", row["wall_ms"]) < cutoff:
                    self._drop(table, kind, identity)
        self.batch_heads = {key: head for key, head in self.batch_heads.items() if head[2] >= cutoff}
        for digest, (_, stamp) in list(self.artifacts.items()):
            if stamp < cutoff:
                self._drop_artifact(digest)
        self.gaps = [gap for gap in self.gaps if gap["wall_ms"] >= cutoff]

    def _trim(self, now):
        # Evict batch/replay material before losing event statistics.
        while len(self.batches) > self.max_batches:
            self._drop(self.batches, "batches", next(iter(self.batches)))
        while self.bytes > self.max_bytes or len(self.records)+len(self.events)+len(self.batches) > self.max_records:
            if self.batches:
                self._drop(self.batches, "batches", next(iter(self.batches)))
            elif self.records:
                self._drop(self.records, "records", next(iter(self.records)))
                self._gap(now, "history_memory_capacity")
            elif self.events:
                self._drop(self.events, "events", next(iter(self.events)))
                self._gap(now, "history_memory_capacity")
            else:
                break
        while self.evidence_bytes > self.max_evidence_bytes:
            self._drop_artifact(next(iter(self.artifacts)))
        while len(self.batch_heads) > self.max_records:
            self.batch_heads.pop(next(iter(self.batch_heads)))
            self._gap(now, "history_memory_capacity")

    def _drop_artifact(self, digest):
        content, _ = self.artifacts.pop(digest)
        self.evidence_bytes -= len(content.encode())

    def record(self, kind, identity, payload, *, session="", sequence=0, wall_ms=None):
        payload = detached(payload)
        with self.lock:
            now = self._now()
            self._prune(now)
            key = kind, identity
            previous = self.records.get(key)
            if previous:
                if previous["payload"] != payload:
                    raise ValueError("history identity conflict")
                return False
            row = dict(kind=kind, identity=identity, session=session, sequence=sequence,
                       wall_ms=now if wall_ms is None else wall_ms, payload=payload)
            self._put(self.records, "records", key, row)
            if kind == "config":
                self.config = payload
            self._trim(now)
            return True

    def latest_config(self):
        with self.lock:
            self._now()
            return detached(self.config)

    def batch(self, envelope, *, wall_ms, threshold, evidence):
        envelope, threshold, evidence = detached(envelope), detached(threshold), detached(evidence)
        for digest, content in evidence.items():
            if hashlib.sha256(content.encode()).hexdigest() != digest:
                raise ValueError("history evidence digest")
        active = {}
        rows = envelope["snapshot"]["candidates"]
        for row in rows:
            if (row["status"] != "evaluated" or not row["recommended"]
                    or int(row["plan_atoms"]) < int(threshold["min_profit_atoms"])
                    or row["probability_lower_ppm"] < threshold["min_probability_ppm"]):
                continue
            key = encoded([row["id"], row["quantity_base"], envelope["config_version"],
                           row["model_hash"], row["policy_version"], row["calibration_version"], threshold])
            active[key] = row
        with self.lock:
            now = self._now()
            self._prune(now)
            session, sequence = envelope["session"], int(envelope["sequence"])
            identity = session+":"+str(sequence)
            fingerprint = hashlib.sha256(encoded([envelope, threshold, wall_ms]).encode()).hexdigest()
            previous = self.batches.get(identity)
            if previous:
                if previous["payload"] != envelope or previous["threshold"] != threshold or previous["wall_ms"] != wall_ms:
                    raise ValueError("history identity conflict")
                return
            head = self.batch_heads.get(session)
            if head and sequence <= head[0]:
                if sequence == head[0] and fingerprint == head[1]:
                    return
                raise ValueError("history batch sequence conflict")
            for (event_session, key), event_id in list(self.open_events.items()):
                if event_session != session:
                    continue
                event = self.events[event_id]
                if key in active:
                    event["last_ns"], event["last_wall_ms"] = envelope["snapshot"]["at_ns"], wall_ms
                    self._put(self.events, "events", event_id, event)
                    active.pop(key)
                else:
                    candidate = next((r for r in rows if r["id"] == event["payload"]["candidate"]["id"]), None)
                    reason = (candidate["reason"] or ("context_changed" if candidate["recommended"] else "below_threshold")) if candidate else "removed"
                    natural = reason == "below_threshold"
                    event.update(ended_ns=envelope["snapshot"]["at_ns"] if natural else event["last_ns"],
                        last_wall_ms=wall_ms if natural else event["last_wall_ms"], end_reason=reason)
                    self.open_events.pop((session, key))
                    self._put(self.events, "events", event_id, event)
            for key, row in active.items():
                event_id = hashlib.sha256((identity+key).encode()).hexdigest()
                event = dict(identity=event_id, session=session, candidate=key,
                    started_ns=envelope["snapshot"]["at_ns"], last_ns=envelope["snapshot"]["at_ns"],
                    ended_ns=None, wall_ms=wall_ms, last_wall_ms=wall_ms, end_reason=None,
                    payload=dict(candidate=row, threshold=threshold, representative="first_evaluation",
                                 config_version=envelope["config_version"], evidence=list(evidence)))
                self._put(self.events, "events", event_id, event)
                self.open_events[session, key] = event_id
            self._put(self.batches, "batches", identity, dict(kind="batches", identity=identity, session=session,
                sequence=sequence, wall_ms=wall_ms, payload=envelope, threshold=threshold))
            self.batch_heads[session] = sequence, fingerprint, wall_ms
            for digest, content in evidence.items():
                if digest in self.artifacts:
                    self._drop_artifact(digest)
                self.artifacts[digest] = content, wall_ms
                self.evidence_bytes += len(content.encode())
            self._trim(now)

    def interrupt(self, session, reason):
        with self.lock:
            now = self._now()
            self._prune(now)
            for (event_session, key), event_id in list(self.open_events.items()):
                if event_session == session:
                    event = self.events[event_id]
                    event.update(ended_ns=event["last_ns"], end_reason=reason)
                    self._put(self.events, "events", event_id, event)
                    self.open_events.pop((session, key))
            self._trim(now)

    def request(self, identity, request=None, response=None):
        # Keep operational idempotency state until restart; never evict pending
        # identities to make room for new requests.
        with self.lock:
            self._now()
            row = self.requests.get(identity)
            if row is not None and request is not None and row["request"] != request:
                raise ValueError("scanner request identity conflict")
            if row is None:
                if request is None:
                    raise ValueError("unknown scanner request")
                if len(self.requests) >= self.max_requests:
                    raise OSError("scanner request capacity")
                proposed = dict(request=detached(request), response=detached(response))
            else:
                proposed = dict(request=row["request"], response=row["response"] if response is None else detached(response))
            change = len(encoded(proposed).encode())-(len(encoded(row).encode()) if row else 0)
            if self.request_bytes+change > self.max_bytes:
                raise OSError("scanner request capacity")
            self.request_bytes += change
            row = self.requests[identity] = proposed
            return detached(row)

    def request_candidate(self, selection):
        """Keep revocation selectors with live request identities, beyond history expiry."""
        with self.lock:
            self._now()
            for row in reversed(list(self.requests.values())):
                request = row["request"]
                original = request.get("selection", {})
                if all(original.get(field) == selection.get(field) for field in
                       ("candidate_id", "strategy_identity", "portfolio_identity")) and request.get("candidate"):
                    return detached(request["candidate"])
            return None

    def artifact(self, digest):
        with self.lock:
            self._prune(self._now(), force=True)
            return self.artifacts[digest][0] if digest in self.artifacts else None

    def _event_view(self, row, cutoff):
        item = detached(row)
        duration = max(0, int(row["ended_ns"] or row["last_ns"])-int(row["started_ns"]))
        item.update(right_censored=row["end_reason"] != "below_threshold", duration_ns=str(duration),
            started_before_window=row["wall_ms"] < cutoff,
            window_duration_ns=str(min(duration, max(0, row["last_wall_ms"]-cutoff)*1_000_000)),
            replayable=bool(row["payload"]["evidence"]) and all(d in self.artifacts for d in row["payload"]["evidence"]))
        return item

    def query(self, kind, *, offset=0, limit=100, session=None, asset=None, venue=None,
              mode=None, direction=None, end_reason=None, since_wall_ms=None, until_wall_ms=None):
        if kind not in ("events", "batches", "config", "runs", "gaps", "requests", "operations", "summaries"):
            raise ValueError("history query kind")
        if type(offset) is not int or offset < 0 or type(limit) is not int or not 1 <= limit <= 500:
            raise ValueError("history pagination")
        if kind != "events" and any(x is not None for x in (asset, venue, mode, direction, end_reason)):
            raise ValueError("candidate filters require event history")
        if direction is not None and (type(direction) is not int or direction not in (-1, 1)):
            raise ValueError("history direction")
        for stamp in (since_wall_ms, until_wall_ms):
            if stamp is not None and (type(stamp) is not int or not 0 <= stamp < 1 << 63):
                raise ValueError("history wall time")
        with self.lock:
            now = self._now()
            self._prune(now, force=True)
            source = self.events.values() if kind == "events" else self.batches.values() if kind == "batches" else (
                row for row in self.records.values() if row["kind"] == kind)
            if kind == "summaries":
                source = [dict(kind=kind, identity="current", session="", sequence=0, wall_ms=now, payload=self.summarize())]
            elif kind == "gaps":
                source = list(source)+[dict(kind=kind, identity="memory:"+encoded(gap), session="", sequence=0,
                    wall_ms=gap["wall_ms"], payload=gap) for gap in self.gaps]
            selected = []
            for row in source:
                if session is not None and row["session"] != session:
                    continue
                if since_wall_ms is not None and row.get("last_wall_ms", row["wall_ms"]) < since_wall_ms:
                    continue
                if until_wall_ms is not None and row["wall_ms"] >= until_wall_ms:
                    continue
                if kind == "events":
                    candidate = row["payload"]["candidate"]
                    if any(value is not None and candidate[field] != value for field, value in
                           (("base_asset", asset), ("mode", mode), ("direction", direction))):
                        continue
                    if venue is not None and not any(leg[0] == venue for leg in candidate["pair"]):
                        continue
                    if end_reason is not None and row["end_reason"] != end_reason:
                        continue
                selected.append(row)
            selected.sort(key=lambda row: (row["wall_ms"], row["identity"]))
            return [self._event_view(row, now-WINDOW_MS) if kind == "events" else detached(row)
                    for row in selected[offset:offset+limit]]

    def status(self):
        with self.lock:
            now = self._now()
            self._prune(now, force=True)
            gaps = self.gaps+[row["payload"] for row in self.records.values() if row["kind"] == "gaps"]
            return detached(dict(storage="memory", instance_id=self.instance_id, window_ms=str(WINDOW_MS), window_start_wall_ms=str(max(0, now-WINDOW_MS)),
                window_end_wall_ms=str(now), coverage_from_wall_ms=str(max(self.started_ms, now-WINDOW_MS)),
                coverage_complete=self.started_ms <= now-WINDOW_MS and not gaps, gaps=gaps,
                payload_bytes=self.bytes, evidence_bytes=self.evidence_bytes, request_bytes=self.request_bytes, max_payload_bytes=self.max_bytes,
                max_evidence_bytes=self.max_evidence_bytes, retained_batches=len(self.batches),
                retained_events=len(self.events), restart_clears_history=True))

    def summarize(self, *, timezone="UTC"):
        if timezone != "UTC":
            raise ValueError("summary timezone must be UTC")
        with self.lock:
            status = self.status()
            cutoff = int(status["window_start_wall_ms"])
            groups = {}
            for event in self.events.values():
                payload = event["payload"]
                candidate, profit = payload["candidate"], int(payload["candidate"]["plan_atoms"])
                key = encoded([max(cutoff, event["wall_ms"])//WINDOW_MS, candidate["quote_asset"], candidate["mode"],
                               candidate["maker_leg"], payload["threshold"], "negative" if profit < 0 else "nonnegative"])
                value = groups.setdefault(key, dict(events=0, censored=0, carried_in=0, profit_atoms="0", window_duration_ns="0"))
                view = self._event_view(event, cutoff)
                value["events"] += 1
                value["censored"] += view["right_censored"]
                value["carried_in"] += view["started_before_window"]
                value["profit_atoms"] = str(int(value["profit_atoms"])+profit)
                value["window_duration_ns"] = str(int(value["window_duration_ns"])+int(view["window_duration_ns"]))
            return dict(schema="scanner_summary_v1", timezone=timezone, weighting="event", representative="first_evaluation",
                groups=groups, coverage_complete=status["coverage_complete"], window_start_wall_ms=status["window_start_wall_ms"],
                window_end_wall_ms=status["window_end_wall_ms"], coverage_from_wall_ms=status["coverage_from_wall_ms"],
                storage="memory", gaps=status["gaps"])

    def close(self):
        with self.lock:
            self.closed = True
            for table in (self.records, self.events, self.batches, self.artifacts, self.requests, self.open_events,
                          self.batch_heads, self.weights):
                table.clear()
            self.config, self.gaps = None, []
            self.bytes = self.evidence_bytes = self.request_bytes = 0
