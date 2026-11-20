"""Read-only scanner lifecycle and derived projections for the existing Web app.

The node supplies the registered canonical observations, frozen research plans
and optional core authority bridge. HTTP cannot inject market data or receipts.
"""
from dataclasses import dataclass
import hashlib
import json
import secrets
from threading import RLock
from threading import Thread, Event
from queue import Queue, Empty, Full
import time

from strategies.cross_venue import arbitrage_checkpoint as checkpoint
from opportunity_scanner import arbitrage_scanner as scanner
from opportunity_scanner.scanner_archive import freeze, load, MAX_BYTES
from opportunity_scanner.scanner_history import History, encoded
from opportunity_scanner.scanner_config import ConfigStore, uint_text


@dataclass(frozen=True)
class CatalogueEntry:
    venue: int
    account: int  # Trusted observation namespace; never an ExchangeAccount authorization.
    kind: str
    rules: object
    environment: str
    specification: object = None

    @property
    def identity(self):
        return self.venue, self.account, self.rules.instrument


class CanonicalSource:
    """Node-owned admitted catalogue and shared subscription ownership.

    Registered instruments are explicit. Publishing a new symbol cannot expand
    an existing scope unless its new_instruments policy explicitly allows it.
    No credentials or execution adapters are held here.
    """
    def __init__(self, observations=(), *, subscribe=None, unsubscribe=None, assets=()):
        self.lock = RLock()
        self.registered, self.owners = {}, {}
        self.unavailable = set()
        self.listeners = {}
        self.subscribe, self.unsubscribe = subscribe, unsubscribe
        self.assets = json.loads(encoded(assets))
        self.runtime_status = lambda: {}
        for asset in self.assets:
            if (set(asset) != {"identity", "code", "atomic_scale"} or type(asset["code"]) is not str
                    or not 1 <= len(asset["code"]) <= 32 or type(asset["atomic_scale"]) is not int
                    or not 0 <= asset["atomic_scale"] <= 18):
                raise ValueError("trusted asset definition")
            uint_text(asset["identity"], minimum=1)
        if len({a["identity"] for a in self.assets}) != len(self.assets):
            raise ValueError("duplicate trusted asset")
        self.register(observations)

    def register(self, observations):
        with self.lock:
            for item in observations:
                if not isinstance(item, (scanner.Observation, CatalogueEntry)):
                    raise ValueError("canonical observation required")
                previous = self.registered.get(item.identity)
                if previous is not None and (previous.environment, previous.kind) != (item.environment, item.kind):
                    raise ValueError("catalogue identity conflict")
            updated = dict(self.registered)
            updated.update((x.identity, x) for x in observations)
            if len(updated) > 8192:
                raise ValueError("scanner catalogue capacity")
            self.registered = updated

    def acquire(self, owner, identities):
        with self.lock:
            for identity in identities:
                if identity not in self.registered:
                    raise ValueError("unregistered observation")
            previous = set(self.owners.get(owner, ()))
            wanted = set(identities)
            all_before = set().union(*self.owners.values()) if self.owners else set()
            acquired = []
            try:
                for identity in sorted(wanted - all_before):
                    if self.subscribe is not None:
                        self.subscribe(identity)
                    acquired.append(identity)
            except Exception:
                for identity in acquired:
                    if self.unsubscribe is not None:
                        self.unsubscribe(identity)
                raise
            self.owners[owner] = wanted
            all_after = set().union(*self.owners.values())
            for identity in sorted(previous - all_after):
                if self.unsubscribe is not None:
                    self.unsubscribe(identity)

    def release(self, owner):
        with self.lock:
            self.listeners.pop(owner, None)
            previous = self.owners.pop(owner, set())
            remaining = set().union(*self.owners.values()) if self.owners else set()
            for identity in sorted(previous - remaining):
                if self.unsubscribe is not None:
                    self.unsubscribe(identity)

    def deliver(self, observations, plans=(), *, at_ns, cursor):
        """Embedding MarketFeedAdapter/Host bridge delivers admitted canonical data."""
        if type(observations) is not tuple or len(observations) > 64 or type(plans) is not tuple or len(plans) > 256:
            raise ValueError("canonical scanner input capacity")
        with self.lock:
            listeners = tuple(self.listeners.values())
        for listener in listeners:
            listener(cursor, observations, plans, at_ns)


class ScannerConsole:
    def __init__(self, source, history, *, clock=time.monotonic_ns,
                 wall_clock=lambda: time.time_ns() // 1_000_000,
                 max_age_ns=5_000_000_000, max_skew_ns=1_000_000_000,
                 authority=None, resolve_selection=None, trading_bindings=(), config_path=None):
        self.source, self.history, self.clock, self.wall_clock = source, history, clock, wall_clock
        self.max_age_ns, self.max_skew_ns = max_age_ns, max_skew_ns
        self.authority = authority
        self.trading_bindings = json.loads(encoded(trading_bindings))
        self.resolve_selection = resolve_selection or (self._resolve_selection if trading_bindings else None)
        self.lock = RLock()
        self.desired, self.phase, self.session = "stopped", "Stopped", ""
        self.config = history.latest_config() or dict(version="0", scopes=[], registered=[],
            statistics=dict(version="1", min_profit_atoms="0", min_probability_ppm=0))
        self.config_store = None
        self.exchange_settings = None
        self.fee_schedules = None
        self.settings_pending = False
        if config_path is not None:
            self.bind_config(config_path)
        self.sequence = self.committed = self.cursor = 0
        self.snapshot = self._empty()
        self.last_publication = None
        self.last_evidence = {}
        self.coverage_gaps, self.errors = [], []
        self.pending_gap = None
        self.started_ns = 0
        self.last_input_ns = 0
        self.warming = set()
        self.input_queue = Queue(64)
        self.shutdown = Event()
        self.worker = Thread(target=self._run, daemon=True, name="scanner-runtime")
        self.worker.start()

    def bind_config(self, path):
        """Bind node-owned configuration independently of ephemeral history."""
        with self.lock:
            if self.desired != "stopped":
                raise ValueError("scanner config binding requires stopped scanner")
            store = ConfigStore(path)
            loaded = store.load()
            if loaded is not None:
                if self.config["version"] != "0" and self.config != loaded:
                    raise ValueError("scanner config binding conflict")
                self.config = loaded
            elif self.config["version"] != "0":
                store.save(self.config)
            self.config_store = store

    def _enqueue(self, cursor, observations, plans, at_ns):
        with self.lock:
            if self.desired != "running":
                return
            try:
                self.input_queue.put_nowait((self.session, self.config["version"], cursor, observations, plans, at_ns))
            except Full:
                self._gap("scanner_input_queue_overflow")
                self.snapshot = self._empty()
                self.phase, self.desired = "Faulted", "stopped"
                self.source.listeners.pop(self.session, None)
                self.source.release(self.session)
                self.history.interrupt(self.session, "input_overflow")

    def _run(self):
        while not self.shutdown.is_set():
            try:
                session, version, cursor, observations, plans, at_ns = self.input_queue.get(timeout=.1)
            except Empty:
                with self.lock:
                    if self.desired == "running":
                        try:
                            self.view()
                        except (OSError, ValueError) as error:
                            self._gap(str(error))
                continue
            with self.lock:
                if session != self.session or version != self.config["version"] or self.desired != "running":
                    continue
                try:
                    self.publish(session, cursor, observations, plans, at_ns=at_ns)
                except Exception as error:
                    self.errors.append(str(error))
                    self.snapshot = self._empty()
                    self.desired, self.phase = "stopped", "Faulted"
                    self.source.listeners.pop(self.session, None)
                    self.source.release(self.session)

    def _empty(self):
        return dict(schema=scanner.SCHEMA, at_ns=str(self.clock()), cursor="0", replacement=True, candidates=[])

    def _record(self, kind, identity, payload):
        try:
            self.history.record(kind, identity, dict(payload, sources=self.sources()), session=self.session,
                                sequence=self.sequence, wall_ms=self.wall_clock())
        except (OSError, ValueError) as error:
            self._gap(str(error))
            raise

    def _gap(self, reason):
        gap = dict(session=self.session, after_sequence=str(self.committed),
                   latest_sequence=str(self.sequence), reason=reason, wall_ms=self.wall_clock())
        self.pending_gap = gap
        self.coverage_gaps.append(gap)

    def _scope(self, config=None):
        config = self.config if config is None else config
        members = []
        for row in config["scopes"]:
            members.append(scanner.Scope(int(config["version"]), (int(row["venue"]),),
                (row["product"],), tuple(map(int, row["include_assets"])), tuple(map(int, row["exclude_assets"])),
                int(row["quote_asset"]) if row["quote_asset"] else None,
                int(row["min_depth_atoms"]) if row["min_depth_atoms"] is not None else None,
                int(row["max_depth_atoms"]) if row["max_depth_atoms"] is not None else None,
                environment=row["environment"]))
        return scanner.Scope(max(1, int(config["version"])), members=tuple(members))

    def _selected(self, *, include_unavailable=False):
        if self.settings_pending:
            raise ValueError("exchange settings reconciliation pending")
        scope = self._scope()
        if not self.config["scopes"]:
            return set()
        permitted = {tuple(map(int, x)) for x in self.config["registered"]}
        result = set()
        if self.exchange_settings is not None:
            settings = self.exchange_settings.view()["exchanges"]
            for row in self.config["scopes"]:
                if not any((s["venue"], s["environment"]) == (row["venue"], row["environment"])
                           and row.get("setting_id", s["identity"]) == s["identity"] for s in settings):
                    raise ValueError("scanner scope requires saved exchange setting")
        with self.source.lock:
            for identity, observed in self.source.registered.items():
                if not include_unavailable and identity in self.source.unavailable:
                    continue
                for row, member in zip(self.config["scopes"], scope.members):
                    # Depth is evaluated per fresh publication, not on catalogue admission.
                    match = (observed.venue == int(row["venue"]) and observed.kind == row["product"]
                             and observed.environment == row["environment"])
                    if match and (identity in permitted or row["new_instruments"]) and (
                            not member.include_assets or observed.rules.exposure_asset in member.include_assets
                            ) and observed.rules.exposure_asset not in member.exclude_assets and (
                            member.quote_asset is None or observed.rules.quote_asset == member.quote_asset):
                        result.add(identity)
        return result

    def reconcile_settings(self):
        """Saved settings own source selection, including recovery after a partial write."""
        with self.lock:
            settings = self.exchange_settings.view()
            by_id = {s["identity"]: s for s in settings["exchanges"]}
            rows = []
            pending = set(self.config.get("pending_catalogues", []))
            for row in self.config["scopes"]:
                setting = by_id.get(row.get("setting_id")) if row.get("setting_id") else next((s for s in by_id.values()
                    if (s["venue"], s["environment"]) == (row["venue"], row["environment"])), None)
                if setting is None:
                    continue
                adapter = next(a for a in settings["types"] if a["type"] == setting["type"])
                if row["product"] in adapter["products"]:
                    rows.append(dict(row, setting_id=setting["identity"], venue=setting["venue"], environment=setting["environment"]))
                    if (row["venue"], row["environment"]) != (setting["venue"], setting["environment"]):
                        pending.add(setting["venue"]+":"+setting["environment"])
            if rows == self.config["scopes"] and not self.settings_pending:
                self.settings_pending = False
                return
            candidate = dict(self.config, version=str(int(self.config["version"])+1), scopes=rows)
            pending.intersection_update(r["venue"]+":"+r["environment"] for r in rows)
            if pending:
                candidate["pending_catalogues"] = sorted(pending)
            else:
                candidate.pop("pending_catalogues", None)
            # Fence queued publications before touching persistence or subscriptions.
            self.snapshot = self._empty()
            self.sequence += 1
            self.settings_pending = True
            try:
                self.config = candidate
                self.config_store.save(candidate)
                self.settings_pending = False
                if self.desired == "running":
                    before = set(self.source.owners.get(self.session, ()))
                    selected = self._selected()
                    self.source.acquire(self.session, selected)
                    self.warming.intersection_update(selected)
                    self.warming.update(selected - before)
                    self.phase = "Warming" if self.warming or not selected else "Running"
                self.history.interrupt(self.session, "settings_changed")
                self._record("operations", secrets.token_hex(16), dict(action="settings_changed"))
            except Exception:
                self.settings_pending = True
                self.desired, self.phase = "stopped", "Faulted"
                self.snapshot = self._empty()
                self.source.release(self.session)
                raise

    def sources(self):
        if self.exchange_settings is None:
            return {}
        settings = self.exchange_settings.view()["exchanges"]
        return {str(o.venue)+":"+str(o.account): dict(setting_id=s["identity"], name=s["name"], environment=s["environment"])
                for o in self.source.registered.values() for s in settings
                if (str(o.venue), o.environment) == (s["venue"], s["environment"])}

    def history_rows(self, **request):
        return self.history.display_names(self.history.query(**request), self.exchange_settings.view()["exchanges"] if self.exchange_settings else [])

    def configure(self, request):
        with self.lock:
            if self.shutdown.is_set():
                raise ValueError("scanner is closed")
            if type(request) is not dict or set(request) - {"expected_version", "scopes", "statistics"}:
                raise ValueError("scanner config fields")
            if request["expected_version"] != self.config["version"]:
                raise ValueError("scanner config version conflict")
            rows = request["scopes"]
            if type(rows) is not list or len(rows) > 64:
                raise ValueError("scanner scope capacity")
            normalized, keys = [], set()
            for row in rows:
                fields = {"venue", "product", "environment", "include_assets", "exclude_assets", "quote_asset",
                          "min_depth_atoms", "max_depth_atoms", "new_instruments"}
                if type(row) is not dict or set(row) - {"setting_id"} != fields or type(row["new_instruments"]) is not bool:
                    raise ValueError("scanner scope fields")
                venue = uint_text(row["venue"], minimum=1)
                key = venue, row["product"], row["environment"]
                if key in keys:
                    raise ValueError("duplicate scanner subscription")
                keys.add(key)
                for field in ("include_assets", "exclude_assets"):
                    if type(row[field]) is not list or len(row[field]) > 256:
                        raise ValueError("scanner asset capacity")
                    for value in row[field]:
                        uint_text(value, minimum=1)
                for field in ("quote_asset", "min_depth_atoms", "max_depth_atoms"):
                    if row[field] is not None:
                        uint_text(row[field], minimum=1 if field == "quote_asset" else 0)
                if not any((o.venue, o.kind, o.environment) == key for o in self.source.registered.values()):
                    raise ValueError("venue/product/environment not registered by node")
                saved_row = json.loads(encoded(row))
                if self.exchange_settings is not None:
                    setting = next((s for s in self.exchange_settings.view()["exchanges"]
                                    if (s["venue"], s["environment"]) == (row["venue"], row["environment"])), None)
                    if setting is None or row.get("setting_id", setting["identity"]) != setting["identity"]:
                        raise ValueError("scanner scope requires saved exchange setting")
                    saved_row["setting_id"] = setting["identity"]
                normalized.append(saved_row)
            statistics = request.get("statistics", self.config["statistics"])
            if (type(statistics) is not dict or set(statistics) != {"version", "min_profit_atoms", "min_probability_ppm"}
                    or type(statistics["min_probability_ppm"]) is not int or not 0 <= statistics["min_probability_ppm"] <= 1_000_000):
                raise ValueError("scanner statistics policy")
            uint_text(statistics["version"], minimum=1)
            uint_text(statistics["min_profit_atoms"])
            if statistics != self.config["statistics"] and int(statistics["version"]) <= int(self.config["statistics"]["version"]):
                raise ValueError("statistics policy version conflict")
            candidate = dict(version=str(int(self.config["version"]) + 1), scopes=normalized,
                             statistics=statistics, registered=[[str(n) for n in x] for x in sorted(self.source.registered)])
            pending = set(self.config.get("pending_catalogues", [])).intersection(r["venue"]+":"+r["environment"] for r in normalized)
            if pending:
                candidate["pending_catalogues"] = sorted(pending)
            previous = self.config
            before = set(self.source.owners.get(self.session, ()))
            self.config = candidate
            try:
                self._scope()  # Validate exact bounds and units before committing anything.
                selected = self._selected()
                if self.desired == "running":
                    self.source.acquire(self.session, selected)
                if self.config_store is not None:
                    self.config_store.save(candidate)
                self.history.record("config", candidate["version"], candidate,
                                    sequence=int(candidate["version"]), wall_ms=self.wall_clock(), sources=self.sources())
            except Exception:
                self.config = previous
                if self.desired == "running":
                    self.source.acquire(self.session, before)
                raise
            if self.desired == "running":
                self.warming.update(selected - before)
                self.warming.intersection_update(selected)
                # Only candidates touching changed scope combinations are invalidated.
                changed = {key for key in set((r["venue"], r["product"], r["environment"]) for r in previous["scopes"] + normalized)
                           if next((r for r in previous["scopes"] if (r["venue"], r["product"], r["environment"]) == key), None)
                           != next((r for r in normalized if (r["venue"], r["product"], r["environment"]) == key), None)}
                self.snapshot["candidates"] = [r for r in self.snapshot["candidates"] if not any(
                    (leg[0], product, self.source.registered[tuple(map(int, leg))].environment) in changed
                    for leg, product in zip(r["pair"], r["products"]))]
                self.warming.update(identity for identity in selected if (
                    str(self.source.registered[identity].venue), self.source.registered[identity].kind,
                    self.source.registered[identity].environment) in changed)
                self.snapshot["scope"] = self._scope().display()
                self.sequence += 1
                self.history.interrupt(self.session, "config_changed")
                self.phase = "Warming" if self.warming or self.config.get("pending_catalogues") else "Running"
            self._record("operations", secrets.token_hex(16), dict(action="configure", config_version=candidate["version"]))
            return self.view()

    def start(self):
        with self.lock:
            if self.desired == "running":
                return self.view()
            selected = self._selected()
            if not selected:
                raise ValueError("at least one registered instrument required")
            self.phase, self.session = "Starting", secrets.token_hex(16)
            self.sequence = self.committed = self.cursor = 0
            self.snapshot, self.last_publication = self._empty(), None
            self.started_ns = self.clock()
            self.last_input_ns = self.started_ns
            try:
                self._record("runs", self.session, dict(phase="Starting", config_version=self.config["version"],
                                                        started_ns=str(self.started_ns)))
                self.source.acquire(self.session, selected)
            except Exception:
                self.phase, self.desired = "Faulted", "stopped"
                self.source.release(self.session)
                raise
            self.desired, self.phase, self.warming = "running", "Warming", set(selected)
            self.source.listeners[self.session] = self._enqueue
            return self.view()

    def stop(self):
        return self._halt("stopped")

    def pause(self):
        with self.lock:
            if self.desired != "running":
                return self.view()
            return self._halt("paused")

    def _halt(self, reason):
        with self.lock:
            if self.desired == reason:
                return self.view()
            self.desired, self.phase = reason, "Stopping"
            self.source.listeners.pop(self.session, None)
            self.sequence += 1
            self.snapshot = self._empty()  # Revoke before releasing shared subscriptions.
            try:
                self.history.interrupt(self.session, reason)
                self._record("operations", secrets.token_hex(16), dict(action="pause" if reason == "paused" else "stop"))
            finally:
                self.source.release(self.session)
                self.phase = "Paused" if reason == "paused" else "Stopped"
            return self.view()

    def publish(self, session, cursor, observations, plans=(), *, at_ns, evidence=None,
                plan_failures=None, input_versions=None, fx_rate=None, pairs=None, fresh_ids=None):
        """Node-only full canonical input; no HTTP route accepts observations/plans."""
        with self.lock:
            if self.desired != "running" or session != self.session:
                raise ValueError("inactive scanner session")
            if type(cursor) is not int or not 1 <= cursor < 1 << 63:
                raise ValueError("scanner cursor")
            digest = checkpoint.content((observations, plans, at_ns, self.config, plan_failures or {}, input_versions, fx_rate, pairs,
                                         tuple(sorted(fresh_ids)) if fresh_ids is not None else None))
            if cursor == self.cursor:
                if self.last_publication != digest:
                    raise ValueError("scanner input identity conflict")
                return self.view()
            if cursor < self.cursor or at_ns < self.last_input_ns or at_ns > self.clock():
                raise ValueError("scanner input order/time")
            if any(x.identity not in self.source.registered or
                   (x.kind, x.environment, x.rules) != (self.source.registered[x.identity].kind,
                    self.source.registered[x.identity].environment, self.source.registered[x.identity].rules) for x in observations):
                raise ValueError("unregistered canonical input")
            selected = self._selected()
            self.source.acquire(self.session, selected)
            fresh = {x.identity for x in observations if x.book is not None and x.continuous and
                     at_ns - self.max_age_ns < scanner.decode_depth_snapshot(x.book)["visible_at_ns"] <= at_ns}
            self.warming.intersection_update(selected)
            self.warming.difference_update(fresh if fresh_ids is None else fresh_ids)
            try:
                snapshot = scanner.scan(observations, plans, at_ns=at_ns, cursor=cursor,
                    max_age_ns=self.max_age_ns, max_skew_ns=self.max_skew_ns, scope=self._scope(),
                    plan_failures=plan_failures, input_versions=input_versions, fx_rate=fx_rate, selected_pairs=pairs)
                snapshot["candidates"] = [r for r in snapshot["candidates"] if all(tuple(map(int, x)) in selected for x in r["pair"])]
            except Exception as error:
                self.phase = "Faulted"
                self.snapshot = self._empty()
                self.desired = "stopped"
                self.source.release(self.session)
                self.history.interrupt(self.session, "computation_failed")
                self.errors.append(str(error))
                raise
            if self.cursor and cursor != self.cursor + 1:
                self._gap("input_cursor_gap_full_snapshot")
                self.history.interrupt(self.session, "input_gap")
            self.cursor, self.last_publication, self.snapshot = cursor, digest, snapshot
            self.last_input_ns = at_ns
            self.sequence += 1
            envelope = self._envelope()
            material = encoded(dict(schema="scanner_inputs_v3", canonical_observations=freeze(observations),
                                    frozen_plans=freeze(plans), fx_rate=freeze(fx_rate),
                                    plan_failures=plan_failures or {}, input_versions=input_versions, config=self.config,
                                    at_ns=str(at_ns), cursor=str(cursor), max_age_ns=str(self.max_age_ns),
                                    max_skew_ns=str(self.max_skew_ns), snapshot=snapshot,
                                    selected_identities=[list(map(str, x)) for x in sorted(selected)],
                                    supplied_evidence=evidence or {},
                                    **({"pairs": freeze(pairs)} if pairs is not None else {})))
            if len(material.encode()) > MAX_BYTES:
                self._gap("scanner archive capacity")
                raise ValueError("scanner archive capacity")
            evidence_digest = hashlib.sha256(material.encode()).hexdigest()
            envelope["evidence"] = [evidence_digest]
            self.last_evidence = {evidence_digest: material}
            try:
                if self.pending_gap is not None:
                    self.history.record("gaps", secrets.token_hex(16), self.pending_gap,
                                        session=self.session, wall_ms=self.wall_clock())
                    self.pending_gap = None
                self.history.batch(envelope, wall_ms=self.wall_clock(), threshold=self.config["statistics"],
                                   evidence={evidence_digest: material})
                self.committed = self.sequence
            except (OSError, ValueError) as error:
                self._gap(str(error))
            self._health()
            return self.view()

    def _health(self):
        if self.desired != "running":
            return
        bad = any(r["reason"] in ("data_gap", "stale_data", "data_skew", "expired", "rules_expired")
                  for r in self.snapshot["candidates"])
        market = self.source.runtime_status()
        states = [market["discovery"][key]["state"] for key in {
            row["venue"]+":"+row["environment"] for row in self.config["scopes"]}
            if key in market.get("discovery", {})]
        bad = bad or bool(market.get("failures")) or "failed" in states
        warming = self.warming or self.config.get("pending_catalogues") or any(state in ("loading", "unloaded") for state in states)
        self.phase = "Degraded" if bad or self.pending_gap else "Warming" if warming else "Running"

    def request_approval(self, selection):
        """Retain identity in process memory before invoking the core bridge."""
        with self.lock:
            fields = {"identity", "candidate_id", "strategy_identity", "portfolio_identity",
                      "expected_config_version", "expected_core_version", "enabled"}
            if type(selection) is not dict or set(selection) != fields or type(selection["enabled"]) is not bool:
                raise ValueError("scanner approval fields")
            uint_text(selection["identity"], minimum=1)
            uint_text(selection["strategy_identity"], minimum=1)
            uint_text(selection["portfolio_identity"], minimum=1)
            uint_text(selection["expected_core_version"])
            try:
                previous = self.history.request(selection["identity"])
            except ValueError as error:
                if str(error) != "unknown scanner request":
                    raise
            else:
                if previous["request"]["selection"] != selection:
                    raise ValueError("scanner request identity conflict")
                return previous["response"]
            if selection["expected_config_version"] != self.config["version"]:
                raise ValueError("scanner config version conflict")
            self.view()  # Refresh TTL on the server before using a candidate.
            row = next((x for x in self.snapshot["candidates"] if x["id"] == selection["candidate_id"]), None)
            if selection["enabled"] and (row is None or row["status"] != "evaluated"):
                raise ValueError("current evaluated candidate required")
            if selection["enabled"] and self.fee_schedules is not None:
                self.fee_schedules.require_current(row.get("input_versions", {}).get("fees"))
            if self.authority is None or self.resolve_selection is None:
                raise ValueError("core pair authorization unavailable")
            # Disabling uses the trusted node binding, not an expired recommendation.
            binding = self.resolve_selection(selection, row)
            if type(binding) is not dict:
                raise ValueError("core pair binding unavailable")
            request = dict(selection=selection, core=binding, candidate=row)
            response = dict(identity=selection["identity"], status="pending", trading_qualified=False)
            self.history.request(selection["identity"], request, response)
            self._record("operations", secrets.token_hex(16), dict(action="pair_request", identity=selection["identity"]))
            return self._query_or_submit(selection["identity"], request, submit=True)

    def _resolve_selection(self, selection, row):
        binding = next((b for b in self.trading_bindings if b["strategy_identity"] == selection["strategy_identity"]
                        and b["portfolio_identity"] == selection["portfolio_identity"]), None)
        if binding is None:
            raise ValueError("unregistered strategy/portfolio binding")
        if row is None:
            # Revocation refers to the original trusted selector even after TTL/stop.
            row = self.history.request_candidate(selection)
        if row is None:
            raise ValueError("unknown pair selector")
        legs = []
        for identity in row["pair"]:
            observed = self.source.registered.get(tuple(map(int, identity)))
            if observed is None:
                raise ValueError("pair observation removed")
            legs.append(dict(venue=observed.venue, environment=observed.environment, account=str(observed.account),
                             instrument=str(observed.rules.instrument), rules_version=observed.rules.version))
        return dict(identity=selection["identity"], strategy=selection["strategy_identity"], portfolio=selection["portfolio_identity"],
                    activation=binding["activation"], config_version=int(binding["config_version"]),
                    expected_version=int(selection["expected_core_version"]), legs=legs, direction=row["direction"],
                    mode="taker_taker" if row["mode"] == "taker_taker" else "maker_first" if row["maker_leg"] == 0 else "maker_second",
                    enabled=selection["enabled"])

    def query_approval(self, identity):
        with self.lock:
            uint_text(identity, minimum=1)
            previous = self.history.request(identity)
            if previous["response"]["status"] in ("accepted", "rejected"):
                return previous["response"]
            return self._query_or_submit(identity, previous["request"], submit=False)

    def core_version(self, strategy):
        if self.authority is None or not any(x["strategy_identity"] == strategy for x in self.trading_bindings):
            raise ValueError("core strategy binding unavailable")
        return self.authority.request(dict(operation="pair_authorization_version", strategy_identity=format(int(strategy), "032x")))

    def _query_or_submit(self, identity, request, *, submit):
        try:
            result = self.authority.request(dict(operation="pair_authorize" if submit else "pair_authorization_status",
                strategy_identity=format(int(request["selection"]["strategy_identity"]), "032x"),
                pair_request=request["core"]))
            if result.get("status") not in ("accepted", "rejected", "unknown"):
                raise ValueError("invalid core pair response")
            if result["status"] == "accepted" and (result.get("identity") != identity
                    or not result.get("core_version") or not result.get("barrier")):
                raise ValueError("core pair confirmation binding")
            response = dict(result, trading_qualified=False)
        except (OSError, TimeoutError, ValueError) as error:
            response = dict(identity=identity, status="unknown", reason=str(error), trading_qualified=False)
        if submit:
            row = next((r for r in self.snapshot["candidates"] if r["id"] == request["selection"]["candidate_id"]), None)
            self._record("requests", identity, dict(selection=request["selection"], candidate=row, core=request["core"]))
        self.history.request(identity, request, response)
        return response

    def replay(self, digest):
        material = self.history.artifact(digest)
        if material is None:
            return dict(replayable=False, reason="materials_expired")
        if hashlib.sha256(material.encode()).hexdigest() != digest:
            raise ValueError("scanner replay digest")
        archive = load(material)
        if archive["schema"] not in ("scanner_inputs_v1", "scanner_inputs_v2", "scanner_inputs_v3"):
            raise ValueError("scanner replay schema")
        result = scanner.scan(archive["canonical_observations"], archive["frozen_plans"],
            at_ns=int(archive["at_ns"]), cursor=int(archive["cursor"]),
            max_age_ns=int(archive["max_age_ns"]), max_skew_ns=int(archive["max_skew_ns"]), scope=self._scope(archive["config"]),
            plan_failures=archive.get("plan_failures", {}), input_versions=archive.get("input_versions"),
            legacy=archive["schema"] == "scanner_inputs_v1", fx_rate=archive.get("fx_rate"),
            selected_pairs=archive.get("pairs"), evaluation_details=archive["schema"] == "scanner_inputs_v3")
        registered = {tuple(map(int, x)) for x in archive["selected_identities"]}
        result["candidates"] = [r for r in result["candidates"] if all(tuple(map(int, x)) in registered for x in r["pair"])]
        return dict(replayable=True, matches=result == archive["snapshot"], snapshot=result)

    def _envelope(self):
        return dict(schema="scanner_console_v1", session=self.session, config_version=self.config["version"],
                    sequence=str(self.sequence), snapshot=json.loads(encoded(self.snapshot)), sources=self.sources())

    def view(self):
        with self.lock:
            now = self.clock()
            if int(self.snapshot["at_ns"]) <= now:
                refreshed = json.loads(scanner.display_json(self.snapshot, at_ns=now))
                if refreshed["candidates"] != self.snapshot["candidates"] and self.session:
                    self.snapshot = refreshed
                    self.sequence += 1
                    try:
                        envelope = self._envelope()
                        envelope["evidence"] = list(self.last_evidence)
                        self.history.batch(envelope, wall_ms=self.wall_clock(), threshold=self.config["statistics"], evidence=self.last_evidence)
                        self.committed = self.sequence
                    except (OSError, ValueError) as error:
                        self._gap(str(error))
            self._health()
            catalogue = [dict(venue=str(x.venue), account=str(x.account), instrument=str(x.rules.instrument),
                product=x.kind, environment=x.environment, base_asset=str(x.rules.exposure_asset),
                quote_asset=str(x.rules.quote_asset), rules_version=str(x.rules.version),
                **({"specification": x.specification} if isinstance(x, CatalogueEntry) and x.specification else {})) for x in self.source.registered.values()]
            market = self.source.runtime_status()
            settings = self.exchange_settings.view() if self.exchange_settings is not None else None
            exchanges = []
            if settings is not None:
                for setting in settings["exchanges"]:
                    members = [r for r in catalogue if (r["venue"], r["environment"]) == (setting["venue"], setting["environment"])]
                    failures = [market.get("failures", {}).get(str(tuple(map(int, (r["venue"], r["account"], r["instrument"]))))) for r in members]
                    failures = [error for error in failures if error]
                    active = [r for r in market.get("observations", []) if (r["venue"], r["environment"]) == (setting["venue"], setting["environment"])]
                    state = "failed" if failures else "ready" if active else "loading" if any(
                        tuple(map(int, (r["venue"], r["account"], r["instrument"]))) in self.warming for r in members
                    ) else "registered" if members else "unloaded"
                    discovery = market.get("discovery", {}).get(setting["venue"]+":"+setting["environment"])
                    if discovery:
                        state = "failed" if failures else discovery["state"]
                        failures += [discovery["error"]] if discovery["error"] else []
                        failures += [str(r["symbol"])+": "+r["reason"] for r in discovery.get("rejected", [])]
                    exchanges.append(dict(setting, source_id=setting["venue"]+":"+setting["environment"],
                        products=next(a["products"] for a in settings["types"] if a["type"] == setting["type"]),
                        catalogue_state=state, catalogue_error="; ".join(failures)))
                    for row in members:
                        row["setting_id"] = setting["identity"]
                catalogue = [row for row in catalogue if "setting_id" in row]
                if market:
                    market = dict(market, routes=[route for route in market.get("routes", []) if any(
                        (s["venue"], s["environment"]) == (route["venue"], route["requested_environment"]) for s in exchanges)])
                    active = {(s["venue"], s["environment"]) for s in exchanges}
                    market["observations"] = [r for r in market.get("observations", []) if (r["venue"], r["environment"]) in active]
                    market["evidence"] = [r for r in market.get("evidence", []) if (r["venue"], r["requested_environment"]) in active]
                    visible = {str(tuple(map(int, (r["venue"], r["account"], r["instrument"])))) for r in catalogue}
                    market["failures"] = {i:r for i,r in market.get("failures", {}).items() if i in visible}
            history_window = self.history.status()
            cutoff = int(history_window["window_start_wall_ms"])
            self.coverage_gaps = [gap for gap in self.coverage_gaps if gap["wall_ms"] >= cutoff][-64:]
            return json.loads(encoded(dict(self._envelope(), phase=self.phase, desired=self.desired, config=self.config,
                        catalogue=catalogue, exchanges=exchanges, settings_version=settings["version"] if settings else "0",
                        wall_ms=str(self.wall_clock()), clock_domain="server_monotonic_ns", server_now_ns=str(now),
                        remaining_validity_ns={r["id"]: str(max(0, int(r["valid_until_ns"])-now)) for r in self.snapshot["candidates"]},
                        trading_bindings=self.trading_bindings,
                        assets=self.source.assets,
                        latest_sequence=str(self.sequence), committed_sequence=str(self.committed),
                        backlog=0, storage_healthy=self.history.healthy, history_window=history_window,
                        storage_error=self.history.error, coverage_gaps=list(self.coverage_gaps)+history_window["gaps"], errors=list(self.errors[-64:]),
                        warming=[list(map(str, x)) for x in sorted(self.warming)], market=market or None, trading_qualified=False)))

    def close(self):
        if not self.shutdown.is_set():
            try:
                self.stop()
            finally:
                self.shutdown.set()
                self.worker.join(timeout=6)
                if self.worker.is_alive():
                    raise OSError("scanner worker did not stop")
                self.history.close()
