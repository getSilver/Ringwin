"""Derived scanner history. One SQLite writer; never a trading authority store."""
from concurrent.futures import Future, TimeoutError
import hashlib
import json
from pathlib import Path
from queue import Queue, Full
import sqlite3
from threading import Thread


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


class History:
    def __init__(self, path, *, capacity=64, timeout=5):
        if type(capacity) is not int or not 1 <= capacity <= 4096 or not 0 < timeout <= 30:
            raise ValueError("history capacity/timeout")
        self.path, self.timeout = Path(path), timeout
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.queue = Queue(capacity)
        self.healthy, self.error, self.closed = True, "", False
        self.thread = Thread(target=self._writer, daemon=True, name="scanner-history")
        self.thread.start()
        self._call(self._initialize)

    @staticmethod
    def _initialize(db):
        db.executescript("""
          PRAGMA journal_mode=WAL;
          PRAGMA synchronous=FULL;
          PRAGMA foreign_keys=ON;
          CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
          INSERT OR IGNORE INTO metadata VALUES ('schema','1');
          CREATE TABLE IF NOT EXISTS records (
            kind TEXT NOT NULL, identity TEXT NOT NULL, session TEXT NOT NULL,
            sequence INTEGER NOT NULL, wall_ms INTEGER NOT NULL, payload TEXT NOT NULL,
            PRIMARY KEY(kind, identity));
          CREATE INDEX IF NOT EXISTS records_page ON records(kind,wall_ms,identity);
          CREATE TABLE IF NOT EXISTS events (
            identity TEXT PRIMARY KEY, session TEXT NOT NULL, candidate TEXT NOT NULL,
            started_ns TEXT NOT NULL, last_ns TEXT NOT NULL, ended_ns TEXT,
            wall_ms INTEGER NOT NULL, end_reason TEXT, payload TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS pins (kind TEXT NOT NULL, identity TEXT NOT NULL,
            reference TEXT NOT NULL, PRIMARY KEY(kind,identity,reference));
          CREATE TABLE IF NOT EXISTS artifacts (digest TEXT PRIMARY KEY, content TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS requests (identity TEXT PRIMARY KEY, request TEXT NOT NULL, response TEXT NOT NULL);
        """)
        if db.execute("SELECT value FROM metadata WHERE key='schema'").fetchone()[0] != "1":
            raise ValueError("unsupported scanner history schema")
        stopped = {row[0] for row in db.execute("SELECT session,payload FROM records WHERE kind='operations'")
                   if json.loads(row[1]).get("action") == "stop"}
        for run in db.execute("SELECT session FROM records WHERE kind='runs'").fetchall():
            if run[0] not in stopped:
                latest = db.execute("SELECT MAX(sequence),MAX(wall_ms) FROM records WHERE kind='batches' AND session=?", (run[0],)).fetchone()
                History._record(db, "gaps", "restart:" + run[0], run[0], latest[0] or 0, latest[1] or 0,
                                dict(reason="process_restart_unconfirmed_tail", after_sequence=str(latest[0] or 0)))
        # A crash cannot extend an event across an interval we did not observe.
        db.execute("UPDATE events SET ended_ns=last_ns,end_reason='process_interrupted' WHERE ended_ns IS NULL")
        db.commit()

    def _writer(self):
        try:
            db = sqlite3.connect(self.path, timeout=self.timeout)
            db.row_factory = sqlite3.Row
        except Exception as error:
            self.healthy, self.error = False, str(error)
            db = None
        while True:
            item = self.queue.get()
            if item is None:
                break
            fn, future = item
            try:
                if db is None:
                    raise OSError(self.error)
                result = fn(db)
                db.commit()
                self.healthy, self.error = True, ""
                future.set_result(result)
            except Exception as error:
                if db is not None:
                    db.rollback()
                self.healthy, self.error = False, str(error)
                future.set_exception(error)
        if db is not None:
            db.close()

    def _call(self, fn):
        if self.closed:
            raise OSError("history closed")
        future = Future()
        try:
            self.queue.put_nowait((fn, future))
            return future.result(timeout=self.timeout)
        except (Full, TimeoutError) as error:
            self.healthy, self.error = False, "history queue overflow or commit timeout"
            raise OSError(self.error) from error

    @staticmethod
    def _record(db, kind, identity, session, sequence, wall_ms, payload):
        content = encoded(payload)
        previous = db.execute("SELECT payload FROM records WHERE kind=? AND identity=?", (kind, identity)).fetchone()
        if previous:
            if previous[0] != content:
                raise ValueError("history identity conflict")
            return False
        db.execute("INSERT INTO records VALUES(?,?,?,?,?,?)", (kind, identity, session, sequence, wall_ms, content))
        return True

    def record(self, kind, identity, payload, *, session="", sequence=0, wall_ms=0):
        return self._call(lambda db: self._record(db, kind, identity, session, sequence, wall_ms, payload))

    def latest_config(self):
        def read(db):
            row = db.execute("SELECT payload FROM records WHERE kind='config' ORDER BY sequence DESC LIMIT 1").fetchone()
            return json.loads(row[0]) if row else None
        return self._call(read)

    def batch(self, envelope, *, wall_ms, threshold, evidence):
        # Copy before enqueueing: the producer cannot change a pending transaction.
        envelope, evidence = json.loads(encoded(envelope)), json.loads(encoded(evidence))
        def write(db):
            session, sequence = envelope["session"], int(envelope["sequence"])
            identity = session + ":" + str(sequence)
            if not self._record(db, "batches", identity, session, sequence, wall_ms, envelope):
                return
            for digest, content in evidence.items():
                if hashlib.sha256(content.encode()).hexdigest() != digest:
                    raise ValueError("history evidence digest")
                db.execute("INSERT OR IGNORE INTO artifacts VALUES(?,?)", (digest, content))
            rows = envelope["snapshot"]["candidates"]
            active = {}
            for row in rows:
                if (row["status"] != "evaluated" or not row["recommended"]
                        or int(row["plan_atoms"]) < int(threshold["min_profit_atoms"])
                        or row["probability_lower_ppm"] < threshold["min_probability_ppm"]):
                    continue
                # Quantity/evidence/config changes start a distinct statistical event.
                key = encoded([row["id"], row["quantity_base"], envelope["config_version"],
                               row["model_hash"], row["policy_version"], row["calibration_version"], threshold])
                active[key] = row
            open_rows = db.execute("SELECT * FROM events WHERE session=? AND ended_ns IS NULL", (session,)).fetchall()
            for event in open_rows:
                if event["candidate"] not in active:
                    row = next((x for x in rows if x["id"] == json.loads(event["payload"])["candidate"]["id"]), None)
                    reason = (row["reason"] or "below_threshold") if row else "removed"
                    interrupted = reason in ("expired", "stale_data", "data_gap", "data_skew", "rules_expired", "removed")
                    db.execute("UPDATE events SET ended_ns=?,end_reason=? WHERE identity=?",
                               (event["last_ns"] if interrupted else envelope["snapshot"]["at_ns"], reason, event["identity"]))
                else:
                    db.execute("UPDATE events SET last_ns=? WHERE identity=?", (envelope["snapshot"]["at_ns"], event["identity"]))
                    active.pop(event["candidate"])
            for key, row in active.items():
                event_id = hashlib.sha256((identity + key).encode()).hexdigest()
                payload = dict(candidate=row, threshold=threshold, representative="first_evaluation",
                               config_version=envelope["config_version"], evidence=list(evidence))
                db.execute("INSERT INTO events VALUES(?,?,?,?,?,?,?,NULL,?)", (event_id, session, key,
                    envelope["snapshot"]["at_ns"], envelope["snapshot"]["at_ns"], None, wall_ms, encoded(payload)))
        self._call(write)

    def interrupt(self, session, reason):
        self._call(lambda db: db.execute("UPDATE events SET ended_ns=last_ns,end_reason=? WHERE session=? AND ended_ns IS NULL",
                                         (reason, session)).rowcount)

    def request(self, identity, request=None, response=None):
        def transact(db):
            row = db.execute("SELECT request,response FROM requests WHERE identity=?", (identity,)).fetchone()
            if row is not None and request is not None and row[0] != encoded(request):
                raise ValueError("scanner request identity conflict")
            if row is None:
                if request is None:
                    raise ValueError("unknown scanner request")
                db.execute("INSERT INTO requests VALUES(?,?,?)", (identity, encoded(request), encoded(response)))
                return dict(request=request, response=response)
            if response is not None:
                db.execute("UPDATE requests SET response=? WHERE identity=?", (encoded(response), identity))
            return dict(request=json.loads(row[0]), response=response if response is not None else json.loads(row[1]))
        return self._call(transact)

    def artifact(self, digest):
        def read(db):
            row = db.execute("SELECT content FROM artifacts WHERE digest=?", (digest,)).fetchone()
            return row[0] if row else None
        return self._call(read)

    def query(self, kind, *, offset=0, limit=100, session=None, asset=None, venue=None,
              mode=None, direction=None, end_reason=None, since_wall_ms=None, until_wall_ms=None):
        if kind not in ("events", "batches", "config", "runs", "gaps", "requests", "operations", "summaries"):
            raise ValueError("history query kind")
        if type(offset) is not int or offset < 0 or type(limit) is not int or not 1 <= limit <= 500:
            raise ValueError("history pagination")
        if any(x is not None for x in (asset, venue, mode, direction, end_reason)) and kind != "events":
            raise ValueError("candidate filters require event history")
        if direction is not None and (type(direction) is not int or direction not in (-1, 1)):
            raise ValueError("history direction")
        for stamp in (since_wall_ms, until_wall_ms):
            if stamp is not None and (type(stamp) is not int or stamp < 0 or stamp >= 1 << 63):
                raise ValueError("history wall time")
        def read(db):
            clauses, params = [], []
            if session is not None:
                clauses.append("session=?")
                params.append(session)
            for field, value, comparison in (("wall_ms", since_wall_ms, ">="), ("wall_ms", until_wall_ms, "<")):
                if value is not None:
                    clauses.append(field + comparison + "?")
                    params.append(value)
            for expression, value in (("json_extract(payload,'$.candidate.base_asset')", asset),
                                      ("json_extract(payload,'$.candidate.mode')", mode),
                                      ("json_extract(payload,'$.candidate.direction')", direction), ("end_reason", end_reason)):
                if value is not None:
                    clauses.append(expression + "=?")
                    params.append(value)
            if venue is not None:
                clauses.append("(json_extract(payload,'$.candidate.pair[0][0]')=? OR json_extract(payload,'$.candidate.pair[1][0]')=?)")
                params.extend((venue, venue))
            where = " WHERE " + " AND ".join(clauses) if clauses else ""
            if kind == "events":
                rows = db.execute("SELECT * FROM events" + where + " ORDER BY wall_ms,identity LIMIT ? OFFSET ?",
                                  (*params, limit, offset)).fetchall()
                result = []
                for row in rows:
                    item = dict(row)
                    item["payload"] = json.loads(item["payload"])
                    item["right_censored"] = item["end_reason"] != "below_threshold"
                    item["duration_ns"] = str(int(item["ended_ns"] or item["last_ns"]) - int(item["started_ns"]))
                    item["replayable"] = all(db.execute("SELECT 1 FROM artifacts WHERE digest=?", (d,)).fetchone()
                                              for d in item["payload"]["evidence"]) and bool(item["payload"]["evidence"])
                    result.append(item)
                return result
            condition = " WHERE kind=?" + (" AND " + " AND ".join(clauses) if clauses else "")
            rows = db.execute("SELECT * FROM records" + condition + " ORDER BY wall_ms,identity LIMIT ? OFFSET ?",
                              (kind, *params, limit, offset)).fetchall()
            return [dict(row, payload=json.loads(row["payload"])) for row in rows]
        return self._call(read)

    def summarize(self, *, timezone="UTC"):
        if timezone != "UTC":
            raise ValueError("summary timezone must be UTC")
        def compute(db):
            groups = {}
            for row in db.execute("SELECT * FROM events ORDER BY identity"):
                payload = json.loads(row["payload"])
                candidate = payload["candidate"]
                # Every mode-specific event has exactly one half-open UTC day/profit bin.
                profit = int(candidate["plan_atoms"])
                key = encoded([row["wall_ms"] // 86_400_000, candidate["quote_asset"],
                               candidate["mode"], candidate["maker_leg"], payload["threshold"],
                               "negative" if profit < 0 else "nonnegative"])
                value = groups.setdefault(key, dict(events=0, censored=0, profit_atoms="0"))
                value["events"] += 1
                value["censored"] += row["end_reason"] != "below_threshold"
                value["profit_atoms"] = str(int(value["profit_atoms"]) + profit)
            result = dict(schema="scanner_summary_v1", timezone=timezone, weighting="event",
                          representative="first_evaluation", groups=groups,
                          coverage_complete=db.execute("SELECT 1 FROM records WHERE kind='gaps' LIMIT 1").fetchone() is None)
            self._record(db, "summaries", "current", "", 0, 0, result) if not db.execute(
                "SELECT 1 FROM records WHERE kind='summaries'").fetchone() else db.execute(
                "UPDATE records SET payload=? WHERE kind='summaries' AND identity='current'", (encoded(result),))
            return result
        return self._call(compute)

    def pin(self, kind, identity, reference):
        if kind not in ("batches", "events", "artifacts") or not reference:
            raise ValueError("history pin")
        self._call(lambda db: db.execute("INSERT OR IGNORE INTO pins VALUES(?,?,?)", (kind, identity, reference)).rowcount)

    def prune(self, *, before_wall_ms):
        if type(before_wall_ms) is not int or before_wall_ms < 0:
            raise ValueError("history retention cutoff")
        self.summarize()
        def remove(db):
            # Event evidence and pinned evaluations retain their content-addressed materials.
            db.execute("DELETE FROM records WHERE kind='batches' AND wall_ms<? AND NOT EXISTS "
                       "(SELECT 1 FROM pins WHERE kind='batches' AND identity=records.identity)", (before_wall_ms,))
            used = {digest for row in db.execute("SELECT payload FROM events") for digest in json.loads(row[0])["evidence"]}
            for row in db.execute("SELECT payload FROM records WHERE kind='batches'"):
                used.update(json.loads(row[0]).get("evidence", []))
            for row in db.execute("SELECT digest FROM artifacts").fetchall():
                if row[0] not in used:
                    db.execute("DELETE FROM artifacts WHERE digest=? AND NOT EXISTS "
                               "(SELECT 1 FROM pins WHERE kind='artifacts' AND identity=?)", (row[0], row[0]))
        self._call(remove)

    def prune_evidence(self, *, before_wall_ms):
        """Retain queryable results, protect research pins transitively."""
        if type(before_wall_ms) is not int or before_wall_ms < 0:
            raise ValueError("history retention cutoff")
        def remove(db):
            keep = {r[0] for r in db.execute("SELECT identity FROM pins WHERE kind='artifacts'")}
            for row in db.execute("SELECT payload FROM records WHERE kind='batches' AND (wall_ms>=? OR EXISTS "
                                  "(SELECT 1 FROM pins WHERE kind='batches' AND identity=records.identity))", (before_wall_ms,)):
                keep.update(json.loads(row[0]).get("evidence", []))
            for row in db.execute("SELECT payload FROM events WHERE wall_ms>=? OR EXISTS "
                                  "(SELECT 1 FROM pins WHERE kind='events' AND identity=events.identity)", (before_wall_ms,)):
                keep.update(json.loads(row[0])["evidence"])
            for row in db.execute("SELECT digest FROM artifacts").fetchall():
                if row[0] not in keep:
                    db.execute("DELETE FROM artifacts WHERE digest=?", (row[0],))
        self._call(remove)

    def backup(self, destination):
        destination = Path(destination)
        if destination.resolve() == self.path.resolve() or destination.exists():
            raise ValueError("backup destination must be a new file")
        def copy(db):
            with sqlite3.connect(destination) as target:
                db.backup(target)
        self._call(copy)

    def close(self):
        if not self.closed:
            self.closed = True
            self.queue.put(None, timeout=self.timeout)
            self.thread.join(timeout=self.timeout)
            if self.thread.is_alive():
                raise OSError("history writer did not stop")
