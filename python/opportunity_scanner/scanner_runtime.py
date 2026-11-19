"""Public REST polling -> native MarketFeedAdapter -> canonical depth -> scanner.

Public protocol transport is replaceable; asset bindings come from node-owned
activated-registry projection. No credentials or execution capability.
"""
from dataclasses import replace
from fractions import Fraction
import hashlib
import copy
import json
import os
from pathlib import Path
import secrets
import subprocess
import threading
import time
import urllib.request

from strategies.cross_venue import arbitrage_economics as economics
from opportunity_scanner.arbitrage_scanner import Observation, decode_depth_snapshot
from opportunity_scanner.scanner_console import CanonicalSource, CatalogueEntry, ScannerConsole
from opportunity_scanner.scanner_config import atomic_json, _object
from opportunity_scanner.scanner_history import History
from opportunity_scanner.scanner_assets import AssetBindings
from opportunity_scanner.scanner_evaluation import EvaluationInputs
from strategy_instance import NativeAuthority

ROOT = Path(__file__).resolve().parents[2]
MAX_FRAME = 120 * 1024
MAX_CATALOGUE = 8192
MAX_DISCOVERY_BYTES = 4 * 1024 * 1024
MAX_HL_METADATA_BYTES = 1024 * 1024
CATALOGUE_REFRESH_NS = 30_000_000_000
CATALOGUE_TTL_NS = 90_000_000_000
# Stable historical identities, never an admission list or a worker configuration.
OKX_LEGACY_IDENTITIES = {"BTC-USDT": 0x4f4b5800000001, "BTC-USDT-SWAP": 0x4f4b5800000002,
                         "BTC-USDC": 0x4f4b5800000003}
ROUTES = {
    (1, "production"): ("https://www.okx.com", "production"),
    (1, "demo"): ("https://www.okx.com", "production"),
    (21, "production"): ("https://api.hyperliquid.xyz", "production"),
    (21, "testnet"): ("https://api.hyperliquid-testnet.xyz", "testnet"),
}



class PublicTransport:
    def request(self, url, body=None, *, max_bytes=MAX_FRAME):
        data = None if body is None else json.dumps(body, separators=(",", ":")).encode()
        request = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
        # urllib's default client signature is rejected by the OKX public gateway.
        opener = urllib.request.build_opener()
        opener.addheaders = []
        with opener.open(request, timeout=3) as response:
            payload = response.read(max_bytes + 1)
        if len(payload) > max_bytes:
            raise ValueError("public transport capacity exceeded")
        return payload.decode("utf-8")

    def catalogue(self, setting, product):
        base, _ = ROUTES[int(setting["venue"]), setting["environment"]]
        if (setting["type"], setting["venue"], product) == ("hyperliquid", "21", "linear"):
            return self.request(base + "/info", {"type": "meta"}, max_bytes=MAX_HL_METADATA_BYTES)
        if setting["type"] != "okx" or setting["venue"] != "1" or product not in ("spot", "linear"):
            raise ValueError("unsupported discovery source")
        kind = "SPOT" if product == "spot" else "SWAP"
        return self.request(base + "/api/v5/public/instruments?instType=" + kind, max_bytes=MAX_DISCOVERY_BYTES)

    def metadata(self, binding):
        base, _ = ROUTES[binding["venue"], binding["environment"]]
        if binding["venue"] == 1:
            kind = "SPOT" if binding["product"] == "spot" else "SWAP"
            return self.request(base + "/api/v5/public/instruments?instType=" + kind + "&instId=" + binding["symbol"])
        if binding["venue"] == 21 and binding["product"] == "linear":
            return self.request(base + "/info", {"type": "meta"}, max_bytes=MAX_HL_METADATA_BYTES)
        raise ValueError("unsupported metadata source")

    def book(self, binding):
        base, _ = ROUTES[binding["venue"], binding["environment"]]
        if binding["venue"] == 1:
            return self.request(base + "/api/v5/market/books?instId=" + binding["symbol"] + "&sz=5")
        if binding["venue"] == 21 and binding["product"] == "linear":
            return self.request(base + "/info", {"type": "l2Book", "coin": binding["symbol"]})
        raise ValueError("unsupported book source")


class ScannerRuntime:
    def __init__(self, directory, *, transport=None, clock=time.monotonic_ns,
                 utc_clock=time.time_ns, automatic=True, asset_provider=None):
        configuration = dict(schema=1, assets=[], bindings=[])
        bindings = []
        self.directory = Path(directory).resolve()
        self.directory.mkdir(parents=True, exist_ok=True)
        self.clock, self.utc_clock, self.transport = clock, utc_clock, transport or PublicTransport()
        self.asset_provider = asset_provider or (lambda: dict(schema=1, bindings=[]))
        self.asset_bindings = AssetBindings(dict(schema=1, bindings=[]))
        self.asset_binding_digest = None
        self.evaluation = EvaluationInputs(self.directory/"scanner-evaluation.json", secrets.token_hex(16),
            synthetic=getattr(self.transport, "input_kind", "venue_public") == "synthetic_protocol_fixture")
        self.lock = threading.RLock()
        self.poll_lock = threading.Lock()
        self.bindings, entries = {}, []
        self.discovery_status, self.discovery_threads = {}, []
        self.discovery_lock = threading.Lock()
        self.discovery_settings, self.next_discovery, self.discovery_success = {}, {}, {}
        self.discovery_inflight, self.source_generations = {}, {}
        cache = self.directory / "scanner-discovery.json"
        if cache.is_file():
            if cache.stat().st_size > MAX_DISCOVERY_BYTES:
                raise ValueError("saved discovery capacity")
            saved = json.loads(cache.read_text(encoding="utf-8"), object_pairs_hook=_object)
            if saved.get("schema") != 1 or set(saved) != {"schema", "assets", "bindings", "sources"}:
                raise ValueError("saved discovery schema")
            configuration = saved
            bindings = saved["bindings"]
            self.discovery_status = saved["sources"]
            if len(bindings) > MAX_CATALOGUE:
                raise ValueError("saved discovery binding capacity")
        assets = {int(a["identity"]): a for a in configuration["assets"]}
        for row in bindings:
            venue, environment = row["venue"], row["environment"]
            if (venue, environment) not in ROUTES:
                raise ValueError("unsupported venue/environment; Hyperliquid uses testnet, not demo")
            if venue == 1 and "okx_binding" not in row:
                raise ValueError("missing discovered OKX binding")
            if venue == 21 and (not row.get("hl_discovered") or row["product"] != "linear" or row["symbol"] != row["binding"]["coin"]):
                raise ValueError("missing discovered Hyperliquid binding")
            base, quote = int(row["base_asset"]), int(row["quote_asset"])
            self._validate_associations(row)
            if base not in assets or quote not in assets:
                raise ValueError("missing trusted asset definition")
            if not row.get("asset_associations") and (venue == 1 and assets[quote]["code"] != row["symbol"].split("-")[1]
                    or venue == 21 and assets[quote]["code"] != row["specification"]["quote"]):
                raise ValueError("settlement/quote asset mismatch")
            if not row.get("asset_associations") and assets[base]["code"] != (row["symbol"].split("-")[0] if venue == 1 else row["symbol"]):
                raise ValueError("base asset identity mismatch")
            if venue == 1 and row["product"] == "spot" and Fraction(row["lot_base"]) != Fraction(row["lot_wire"]):
                raise ValueError("OKX spot quantity units mismatch")
            if venue == 1 and row["product"] == "linear" and Fraction(row["lot_base"]) != Fraction(row["lot_wire"])*Fraction(row["contract_value"]):
                raise ValueError("OKX contract multiplier mismatch")
            tick, lot = Fraction(row["tick"]), Fraction(row["lot_base"])
            if venue == 21:
                b = row["binding"]
                if (int(row["instrument"]) != b["instrument"] or row["rules_version"] != b["rules_version"]
                        or b["product"] != "isolated_linear"
                        or tick != Fraction(b["tick_atoms"], 10**b["price_scale"])
                        or lot != Fraction(b["lot_atoms"], 10**b["quantity_scale"])):
                    raise ValueError("Hyperliquid binding units mismatch")
                if row.get("hl_discovered") and b.get("quote_token", 0) != 0:
                    raise ValueError("Hyperliquid collateral binding mismatch")
                if row.get("hl_discovered") and (int(row["settlement_asset"]) not in assets or
                        not row.get("asset_associations") and assets[int(row["settlement_asset"])]["code"] != "USDC"):
                    raise ValueError("Hyperliquid settlement asset mismatch")
            entry = self._entry(row, assets)
            if entry.identity in self.bindings:
                raise ValueError("duplicate scanner binding")
            self.bindings[entry.identity] = dict(row)
            if "okx_binding" in row or row.get("hl_discovered"):
                key = str(row["venue"]) + ":" + row["environment"]
                self.discovery_status.setdefault(key, dict(state="unloaded", error=""))
            entries.append(entry)
        self.source = CanonicalSource(entries, subscribe=self.acquire, unsubscribe=self.release, assets=configuration["assets"])
        self.source.runtime_status = self.status
        self.workers, self.observations, self.evidence, self.failures = {}, {}, {}, {}
        self.blocked = set()
        self.cursor = 0
        self.console = ScannerConsole(self.source, History(), clock=clock,
            config_path=self.directory/"scanner-config.json")
        self.closing = threading.Event()
        self.thread = None
        if automatic:
            self.thread = threading.Thread(target=self._run, daemon=True, name="public-scanner-feeds")
            self.thread.start()

    @staticmethod
    def _entry(row, assets):
        base, quote = int(row["base_asset"]), int(row["quote_asset"])
        tick, lot = Fraction(row["tick"]), Fraction(row["lot_base"])
        minimum = Fraction(row.get("minimum_size", row["lot_wire"])) / Fraction(row["lot_wire"])
        rules = economics.InstrumentRules(int(row["instrument"]), row["rules_version"], base, quote,
            tick * Fraction(10**assets[quote]["atomic_scale"], 10**assets[base]["atomic_scale"]),
            lot * 10**assets[base]["atomic_scale"], -(-minimum.numerator // minimum.denominator), 0, 0, (1<<64)-1)
        return CatalogueEntry(row["venue"], int(row["observation_identity"]), row["product"], rules, row["environment"], row.get("specification"))

    def request_discovery(self, setting, *, refresh=False):
        key = setting["venue"] + ":" + setting["environment"]
        if (setting["type"], setting["venue"]) not in (("okx", "1"), ("hyperliquid", "21")):
            raise ValueError("unsupported discovery source")
        with self.lock:
            self.discovery_settings[key] = dict(setting)
            status = self.discovery_status.get(key, {})
            if key in self.discovery_inflight or (not refresh and (
                status.get("state") == "loading" or
                status.get("state") == "ready" and status.get("count", 0) > 0
            )):
                return
            generation = self.source_generations.get(key, 0)
            self.discovery_inflight[key] = generation
            self.discovery_status[key] = dict(state="loading", error="")
            thread = threading.Thread(target=self._discover_requested, args=(dict(setting), key, generation), daemon=True, name=setting["type"]+"-catalogue")
            self.discovery_threads = [t for t in self.discovery_threads if t.is_alive()]
            self.discovery_threads.append(thread)
            thread.start()

    def _discover_requested(self, setting, key, generation):
        try:
            self.discover(setting, generation=generation)
        finally:
            with self.lock:
                if self.discovery_inflight.get(key) == generation:
                    self.discovery_inflight.pop(key, None)

    def _current_setting(self, setting, generation):
        key = setting["venue"]+":"+setting["environment"]
        if self.source_generations.get(key, 0) != generation:
            return False
        store = self.console.exchange_settings
        return store is None or any((s["identity"], s["venue"], s["environment"]) ==
            (setting["identity"], setting["venue"], setting["environment"]) for s in store.view()["exchanges"])

    def settings_changed(self, before, after):
        """Caller holds the console lock; other consumers retain their workers."""
        with self.source.lock, self.lock:
            for old in before:
                if any((s["identity"], s["venue"], s["environment"]) == (old["identity"], old["venue"], old["environment"]) for s in after):
                    continue
                key = old["venue"]+":"+old["environment"]
                self.source_generations[key] = self.source_generations.get(key, 0)+1
                self.discovery_inflight.pop(key, None)
                self.discovery_settings.pop(key, None)
                self.discovery_status.pop(key, None)
                self.next_discovery.pop(key, None)
                self.discovery_success.pop(key, None)
            for setting in after:
                changed = not any((s["identity"], s["venue"], s["environment"]) == (setting["identity"], setting["venue"], setting["environment"]) for s in before)
                pending = setting["venue"]+":"+setting["environment"] in self.console.config.get("pending_catalogues", [])
                # A persisted ready cache cannot prove this process reconciled its scopes.
                self.request_discovery(setting, refresh=changed or pending or
                    setting["venue"]+":"+setting["environment"] not in self.discovery_success)

    def discover(self, setting, *, generation=None):
        """Replace one source snapshot and reconcile its existing consumer scopes."""
        key = setting["venue"] + ":" + setting["environment"]
        if (setting["type"], setting["venue"]) not in (("okx", "1"), ("hyperliquid", "21")) or (int(setting["venue"]), setting["environment"]) not in ROUTES:
            raise ValueError("unsupported discovery setting")
        with self.discovery_lock:
            with self.lock:
                generation = self.source_generations.get(key, 0) if generation is None else generation
                if not self._current_setting(setting, generation):
                    return
                self.discovery_settings[key] = dict(setting)
                self.next_discovery[key] = self.clock() + CATALOGUE_REFRESH_NS
                self.discovery_status[key] = dict(state="loading", error="")
            try:
                rows, rejected, evidence = [], [], []
                registry = AssetBindings(self.asset_provider(),
                    allow_fixture=getattr(self.transport, "input_kind", "venue_public") == "synthetic_protocol_fixture")
                if self.asset_binding_digest != registry.digest:
                    # A known association change revokes all old observations before rebind.
                    with self.poll_lock, self.console.lock, self.source.lock, self.lock:
                        affected = set(self.bindings)
                        self.source.unavailable.update(affected)
                        self._catalogue_changed(affected, restore=False)
                        self.next_discovery.update((k, 0) for k in self.discovery_settings if k != key)
                    self.asset_bindings, self.asset_binding_digest = registry, registry.digest
                assets_by_id = {a["identity"]: a for a in self.source.assets}
                for product in (("spot", "linear") if setting["type"] == "okx" else ("linear",)):
                    if self.closing.is_set():
                        return
                    row = dict(venue=int(setting["venue"]), product=product, environment=setting["environment"], symbol="",
                        instrument=str(self._stable_id("scanner-catalogue-v1", key)),
                        rules_version=1, tick="1", lot_wire="1")
                    worker = self._open(None, row=row, discovery=True)
                    capture = dict(raw_path=worker[3], requested_environment=setting["environment"],
                        actual_environment=ROUTES[int(setting["venue"]), setting["environment"]][1], product=product)
                    evidence.append(capture)
                    try:
                        result = self._input(worker, "discover", self.transport.catalogue(setting, product))
                        audit = self._input(worker, "audit", "")
                        capture.update(raw_sha256=result["raw_sha256"], raw_sequence=result["raw_sequence"], captures=audit["captures"])
                    finally:
                        self._close_worker(worker)
                    for result_row in result["items"]:
                        if result_row["failure"]:
                            rejected.append(dict(symbol=result_row["symbol"], reason=result_row["failure"]))
                            continue
                        item = result_row["item"]
                        if setting["type"] == "hyperliquid":
                            rows.append(self._hyperliquid_row(setting, item, assets_by_id))
                            continue
                        if item["product"] != product:
                            raise ValueError("OKX catalogue product mismatch")
                        base = self._asset(setting, item["base"], assets_by_id)
                        quote = self._asset(setting, item["quote"], assets_by_id)
                        instrument = OKX_LEGACY_IDENTITIES.get(item["symbol"], self._stable_id("okx-instrument-v1", item["symbol"]))
                        version = self._stable_id("okx-rules-v1", json.dumps(item, sort_keys=True, separators=(",", ":"))) & ((1<<53)-1) or 1
                        lot_base = Fraction(item["lot"]) * Fraction(item["contract_value"] or "1")
                        if (lot_base * 10**18).denominator != 1:
                            rejected.append(dict(symbol=item["symbol"], reason="UnsupportedDecimalUnits")); continue
                        previous = next((r for r in self.bindings.values() if (r["venue"], r["environment"], r["symbol"]) ==
                                         (1, setting["environment"], item["symbol"])), None)
                        observation_identity = previous["observation_identity"] if previous else str(self._stable_id("scanner-source-v1", key))
                        rows.append(dict(venue=1, environment=setting["environment"], symbol=item["symbol"], product=product,
                            instrument=str(instrument), observation_identity=observation_identity, rules_version=version,
                            base_asset=base, quote_asset=quote,
                            asset_associations=self._associations(setting, base=item["base"], quote=item["quote"]),
                            tick=item["tick"], lot_wire=item["lot"], lot_base=str(lot_base), minimum_size=item["minimum_size"], contract_value=item["contract_value"], specification=item,
                            okx_binding=dict(symbol=item["symbol"], instrument=instrument, product=product, base=item["base"], quote=item["quote"])))
                assets = list(assets_by_id.values())
                asset_definitions = {int(a["identity"]): a for a in assets}
                entries = [self._entry(row, asset_definitions) for row in rows]
                if len({e.identity for e in entries}) != len(entries):
                    raise ValueError("duplicate catalogue identity")
                if not entries and rejected:
                    raise ValueError("catalogue has no usable instruments: " + str(rejected[:8]))
                with self.poll_lock, self.console.lock, self.source.lock, self.lock:
                    if self.closing.is_set() or not self._current_setting(setting, generation):
                        return
                    incoming = {e.identity for e in entries}
                    source_identities = {i for i,r in self.bindings.items() if (r["venue"], r["environment"]) ==
                                         (int(setting["venue"]), setting["environment"])}
                    affected = source_identities
                    updated = {i:r for i,r in self.bindings.items() if i not in affected}
                    updated.update((entry.identity, row) for entry, row in zip(entries, rows))
                    if len(updated) > MAX_CATALOGUE:
                        raise ValueError("scanner catalogue capacity")
                    state = dict(state="ready", error="", rejected=rejected, evidence=evidence,
                                 count=len(entries), complete=True, refresh_ns=str(CATALOGUE_REFRESH_NS), ttl_ns=str(CATALOGUE_TTL_NS),
                                 asset_binding_digest=registry.digest,
                                 asset_binding_gaps=[dict(symbol=r["symbol"], missing=[role for role, binding in r["asset_associations"].items() if binding is None])
                                     for r in rows if any(binding is None for binding in r["asset_associations"].values())])
                    sources = {k:v for k,v in self.discovery_status.items() if v["state"] == "ready"}
                    sources[key] = state
                    missing = source_identities - incoming
                    changed = missing | (incoming - source_identities) | {i for i in affected if i not in updated or self.bindings[i] != updated[i]}
                    changed.update(i for i in incoming if i not in self.workers and any(
                        i in identities for identities in self.source.owners.values()))
                    # A switched scope admits its first complete directory, then resumes
                    # the saved new-instrument policy for subsequent refreshes.
                    console = self.console
                    candidate = None
                    codes = {a["identity"]:a["code"] for a in assets}
                    # Keep each source's original code when a registered Asset has aliases.
                    for old in self.bindings.values():
                        if (old["venue"], old["environment"]) == (int(setting["venue"]), setting["environment"]):
                            spec = old["specification"]
                            codes[old["base_asset"]] = spec.get("base", old["symbol"])
                            codes[old["quote_asset"]] = spec.get("quote", spec.get("price_quote"))
                    base_ids = {r["specification"].get("base", r["symbol"]):r["base_asset"] for r in rows}
                    quote_ids = {r["specification"].get("quote", r["specification"].get("price_quote")):r["quote_asset"] for r in rows}
                    def rebind(identity, identities, role):
                        if identity in identities.values():
                            return identity
                        code = codes.get(identity)
                        if code is None:
                            return identity
                        if code not in identities:
                            # A missing instrument must still retain its filter in the target namespace.
                            identities[code] = self._asset(setting, code, assets_by_id)
                        return identities[code]
                    scopes = []
                    for scope in console.config["scopes"]:
                        if (scope["venue"], scope["environment"]) == (setting["venue"], setting["environment"]):
                            scope = dict(scope,
                                include_assets=[rebind(i, base_ids, "perp") for i in scope["include_assets"]],
                                exclude_assets=[rebind(i, base_ids, "perp") for i in scope["exclude_assets"]],
                                quote_asset=rebind(scope["quote_asset"], quote_ids, "price-denomination"))
                        scopes.append(scope)
                    pending = key in console.config.get("pending_catalogues", [])
                    if pending or scopes != console.config["scopes"]:
                        candidate = dict(console.config, version=str(int(console.config["version"])+1),
                            scopes=scopes)
                        if pending:
                            candidate["registered"] = [list(map(str, i)) for i in sorted(
                                {tuple(map(int, i)) for i in console.config["registered"]} | incoming)]
                        candidate["pending_catalogues"] = [k for k in console.config.get("pending_catalogues", []) if k != key]
                        if not candidate["pending_catalogues"]:
                            candidate.pop("pending_catalogues")
                        assets = list(assets_by_id.values())
                    atomic_json(self.directory/"scanner-discovery.json", dict(schema=1, assets=assets,
                        bindings=list(updated.values()), sources=sources), MAX_DISCOVERY_BYTES)
                    if candidate is not None:
                        if console.config_store is not None:
                            console.config_store.save(candidate)
                        console.config = candidate
                    self.source.registered = {i:e for i,e in self.source.registered.items() if i not in affected}
                    self.source.register(entries)
                    self.bindings, self.source.assets = updated, assets
                    self.source.unavailable.difference_update(source_identities)
                    self.discovery_success[key] = self.clock()
                    self.discovery_status[key] = state
                    self._catalogue_changed(changed)
            except (OSError, ValueError, KeyError, TypeError) as error:
                with self.poll_lock, self.console.lock, self.source.lock, self.lock:
                    if not self._current_setting(setting, generation):
                        return
                    affected = {i for i,r in self.bindings.items() if (r["venue"], r["environment"]) ==
                                (int(setting["venue"]), setting["environment"])}
                    self.source.unavailable.update(affected)
                    self._catalogue_changed(affected, restore=False)
                    self.discovery_status[key] = dict(state="failed", error=str(error)[:2048], evidence=evidence,
                                                     rejected=rejected, complete=False)

    def _catalogue_changed(self, changed, *, restore=True):
        # Caller serializes polling and holds console/source/runtime locks.
        for identity in changed:
            owned = any(identity in identities for identities in self.source.owners.values())
            self.release(identity)
            if restore and owned and identity in self.bindings:
                self.acquire(identity)
        console = self.console
        console.snapshot["candidates"] = [r for r in console.snapshot["candidates"]
            if not any(tuple(map(int, leg)) in changed for leg in r["pair"])]
        if console.desired == "running":
            before = set(self.source.owners.get(console.session, ()))
            selected = console._selected()
            self.source.acquire(console.session, selected)
            console.warming.intersection_update(selected)
            console.warming.update((selected - before) | (selected & changed))
            console.phase = "Warming" if console.warming or console.config.get("pending_catalogues") else "Running"

    def _refresh_catalogues(self):
        settings = (self.console.exchange_settings.view()["exchanges"] if self.console.exchange_settings is not None
                    else tuple(self.discovery_settings.values()))
        with self.console.lock, self.source.lock:
            selected = {(r["venue"], r["environment"]) for r in self.console.config["scopes"]} if self.console.desired == "running" else set()
            selected.update((str(self.bindings[i]["venue"]), self.bindings[i]["environment"])
                            for identities in self.source.owners.values() for i in identities if i in self.bindings)
        for setting in settings:
            key = setting["venue"] + ":" + setting["environment"]
            if key not in self.discovery_status or (setting["venue"], setting["environment"]) not in selected:
                continue
            if key not in self.discovery_success or self.clock() - self.discovery_success[key] >= CATALOGUE_TTL_NS:
                with self.poll_lock, self.console.lock, self.source.lock, self.lock:
                    if key not in self.discovery_success or self.clock() - self.discovery_success[key] >= CATALOGUE_TTL_NS:
                        affected = {i for i,r in self.bindings.items() if (r["venue"], r["environment"]) ==
                                    (int(setting["venue"]), setting["environment"])}
                        if not affected <= self.source.unavailable:
                            self.source.unavailable.update(affected)
                            self._catalogue_changed(affected)
                        self.discovery_status[key].update(state="failed", error="catalogue TTL expired", complete=False)
            if self.clock() >= self.next_discovery.get(key, 0):
                self.request_discovery(setting, refresh=True)

    def _asset(self, setting, code, assets):
        binding = self.asset_bindings.resolve(setting["venue"], setting["environment"], code)
        if binding is None:
            identity = str(self._stable_id("scanner-source-asset-v2",
                setting["venue"]+":"+setting["environment"]+":"+code))
            label = code
        else:
            identity = str(self._stable_id("scanner-registered-asset-v1",
                setting["environment"]+":"+binding["asset"]))
            label = self.asset_bindings.label(binding)
        # Scanner quantities use independent fixed observation units, never ledger atoms.
        assets[identity] = dict(identity=identity, code=label, atomic_scale=18)
        return identity

    @classmethod
    def _validate_associations(cls, row):
        associations = row.get("asset_associations")
        if associations is None:  # Old caches must still undergo fresh discovery before use.
            return
        spec = row["specification"]
        codes = dict(base=spec.get("base", row["symbol"]),
                     quote=spec.get("quote", spec.get("price_quote")))
        if row["venue"] == 21:
            codes["settlement"] = "USDC"
        if type(associations) is not dict or set(associations) != set(codes):
            raise ValueError("saved asset associations")
        registry = AssetBindings(dict(schema=1, bindings=[r for r in associations.values() if r is not None]), allow_fixture=True)
        for role, code in codes.items():
            binding = registry.resolve(row["venue"], row["environment"], code)
            if binding != associations[role]:
                raise ValueError("saved asset association scope")
            namespace, value = (("scanner-registered-asset-v1", row["environment"]+":"+binding["asset"])
                if binding else ("scanner-source-asset-v2", str(row["venue"])+":"+row["environment"]+":"+code))
            if row[role+"_asset"] != str(cls._stable_id(namespace, value)):
                raise ValueError("saved asset association identity")

    def _associations(self, setting, **codes):
        return {role: self.asset_bindings.resolve(setting["venue"], setting["environment"], code)
                for role, code in codes.items()}

    def _hyperliquid_row(self, setting, item, assets):
        key = "21:" + setting["environment"]
        coin = item["coin"]
        # Protocol coin identity is scoped to the standard perp namespace and environment.
        base = self._asset(setting, coin, assets)
        quote = self._asset(setting, item["price_quote"], assets)
        settlement = self._asset(setting, "USDC", assets)
        instrument = self._stable_id("hyperliquid-standard-perp-v1", key+":"+coin)
        version = self._stable_id("hyperliquid-rules-v1", json.dumps(item, sort_keys=True, separators=(",", ":"))) & ((1<<53)-1) or 1
        size = item["size_decimals"]
        tick = "0."+"0"*(5-size)+"1" if size < 6 else "1"
        lot = "0."+"0"*(size-1)+"1" if size else "1"
        binding = dict(instrument=instrument, coin=coin, product="isolated_linear", universe_index=item["universe_index"],
            size_decimals=size, rules_version=version, expected_metadata_digest=item["metadata_digest"],
            price_scale=6-size, tick_atoms=1, quantity_scale=size, lot_atoms=1)
        return dict(venue=21, environment=setting["environment"], symbol=coin, product="linear", instrument=str(instrument),
            observation_identity=str(self._stable_id("scanner-source-v1", key)), rules_version=version,
            base_asset=base, quote_asset=quote, settlement_asset=settlement, tick=tick, lot_wire=lot, lot_base=lot,
            asset_associations=self._associations(setting, base=coin, quote=item["price_quote"], settlement="USDC"),
            specification=dict(item, product="linear", quote=item["price_quote"], settlement="USDC", collateral_token=0,
                underlying_binding=self.asset_bindings.resolve(21, setting["environment"], coin),
                max_significant_digits=5, integer_price_exception=True), binding=binding, hl_discovered=True)

    @staticmethod
    def _stable_id(namespace, value):
        return int.from_bytes(hashlib.sha256((namespace+"\0"+value).encode()).digest()[:15], "big") or 1

    def acquire(self, identity):
        # Source owns subscription serialization. Network work occurs outside its lock.
        with self.lock:
            if identity not in self.workers:
                if len(self.workers) >= 16:
                    raise ValueError("scanner active subscription capacity (16); narrow the asset scope")
                self.workers[identity] = None
                self.blocked.discard(identity)

    def release(self, identity):
        with self.lock:
            worker = self.workers.pop(identity, None)
            self.blocked.discard(identity)
            self.observations.pop(identity, None)
            self.evidence.pop(identity, None)
            self.failures.pop(identity, None)
        if worker:
            self._close_worker(worker)

    @staticmethod
    def _close_worker(worker):
        process, channel, _, _ = worker
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)
        channel.pipes.close()

    def _open(self, identity, *, row=None, discovery=False):
        row = self.bindings[identity] if row is None else row
        session = secrets.randbelow((1<<53)-1)+1
        if sum(p.stat().st_size for p in self.directory.glob("market-*.raw/**/*") if p.is_file()) >= 64 * 1024 * 1024:
            raise OSError("scanner RawIngress capacity exhausted; archive files before restarting")
        path = self.directory / ("market-" + secrets.token_hex(16) + ".raw")
        executable = ROOT/"zig-out/bin"/("ringwin-scanner-market.exe" if os.name == "nt" else "ringwin-scanner-market")
        process = subprocess.Popen([str(executable), str(path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        # Full Hyperliquid metadata also travels inside the JSON request envelope.
        channel = NativeAuthority(process, timeout=15 if discovery else 5,
            max_frame_bytes=5*1024*1024 if discovery or row["venue"] == 21 else 256*1024)
        config = dict(schema=1, discovery=discovery, requested_environment=row["environment"], session=session, venue=row["venue"], environment=ROUTES[row["venue"], row["environment"]][1],
            instrument=int(row["instrument"]), rules_version=row["rules_version"], tick=row["tick"], lot=row["lot_wire"])
        config["minimum_size"] = row.get("minimum_size")
        if discovery:
            config["discovery_product"] = row["product"]
        config["raw_budget_bytes"] = row.get("raw_budget_bytes", 4*1024*1024)
        if row["venue"] == 1:
            if not discovery:
                config["okx_binding"] = row["okx_binding"]
                config["okx_specification"] = row["specification"]
            config["contract_value"] = row.get("contract_value")
        elif row["venue"] == 21 and not discovery:
            config["binding"] = row["binding"]
        try:
            channel.request(config)
        except Exception:
            self._close_worker((process, channel, None, None))
            raise
        return process, channel, dict(session=session, sequence=0, epoch=0, next_metadata_ns=0, venue=row["venue"]), str(path)

    def _input(self, worker, operation, payload):
        _, channel, state, _ = worker
        limit = MAX_DISCOVERY_BYTES if operation == "discover" else MAX_HL_METADATA_BYTES if operation == "metadata" and state["venue"] == 21 else MAX_FRAME
        if len(payload.encode()) > limit:
            raise ValueError("public frame capacity")
        state["sequence"] += 1
        request = dict(schema=1, session=state["session"], sequence=state["sequence"], epoch=state["epoch"], operation=operation, payload=payload,
                       monotonic_ns=self.clock(), utc_ns=self.utc_clock())
        result = channel.request(request)
        if (result.get("schema"), result.get("session"), result.get("sequence")) != (1, state["session"], state["sequence"]):
            raise ValueError("native market response identity")
        return result

    def audit(self):
        """Read and validate committed RawIngress through the native replay interface."""
        with self.poll_lock:
            return {str(identity): self._input(worker, "audit", "")
                    for identity, worker in tuple(self.workers.items()) if worker is not None}

    def step(self):
        self._refresh_catalogues()
        with self.poll_lock:
            self._step()

    def _step(self):
        """One bounded poll; deterministic transport/clock may drive this in acceptance."""
        session = self.console.session
        version = self.console.config["version"]
        with self.lock:
            selected = tuple(self.workers.items())
        for identity, worker in selected:
            with self.lock:
                if identity in self.source.unavailable or identity in self.blocked or identity not in self.workers or self.workers[identity] is not worker:
                    continue
            row = self.bindings[identity]
            try:
                if worker is None:
                    worker = self._open(identity)
                    with self.lock:
                        if identity not in self.workers:
                            self._close_worker(worker)
                            continue
                        self.workers[identity] = worker
                    result = self._input(worker, "metadata", self.transport.metadata(row))
                    if result["failure"]:
                        raise ValueError(result["failure"])
                    worker[2]["next_metadata_ns"] = self.clock()+30_000_000_000
                    worker[2]["epoch"] += 1
                    result = self._input(worker, "subscribe", json.dumps({"event":"polling_started"}))
                if self.clock() >= worker[2]["next_metadata_ns"]:
                    result = self._input(worker, "metadata", self.transport.metadata(row))
                    worker[2]["next_metadata_ns"] = self.clock()+30_000_000_000
                    if result["failure"]:
                        raise ValueError(result["failure"])
                result = self._input(worker, "book", self.transport.book(row))
                if result["failure"]:
                    raise ValueError(result["failure"])
                payload = result["depth"]
                with self.lock:
                    if identity not in self.workers or self.workers.get(identity) is not worker:
                        continue  # Late input from a released incarnation.
                    if payload is not None:
                        entry = self.source.registered[identity]
                        self.observations[identity] = Observation(entry.venue, entry.account, entry.kind, entry.rules,
                            bytes.fromhex(payload), result["healthy"], entry.environment)
                    self.evidence[identity] = dict(result, venue=str(row["venue"]), instrument=row["instrument"], raw_path=worker[3], requested_environment=row["environment"],
                        actual_environment=ROUTES[row["venue"], row["environment"]][1], input_kind=getattr(self.transport, "input_kind", "venue_public"))
                    self.failures.pop(identity, None)
            except (OSError, ValueError, KeyError) as error:
                with self.lock:
                    if identity not in self.workers or self.workers.get(identity) is not worker:
                        continue
                    old = self.observations.get(identity)
                    if old:
                        self.observations[identity] = replace(old, continuous=False)
                    self.failures[identity] = str(error)[:2048]
                    if "Unavailable" in str(error) or "capacity exhausted" in str(error):
                        self.blocked.add(identity)
                    self.workers[identity] = None
                if worker:
                    self._close_worker(worker)
        with self.lock:
            observations = tuple(self.observations.values())
            evidence = {str(k): v for k, v in self.evidence.items()}
            self.cursor += 1
            cursor = self.cursor
        # Publish with evidence through the same console public seam. No HTTP input route.
        with self.console.lock:
            if self.console.desired == "running" and self.console.session == session and self.console.config["version"] == version:
                at_ns = self.clock()
                selected_ids = self.console._selected()
                selected_observations = tuple(o for o in observations if o.identity in selected_ids)
                plans, failures, versions = self.evaluation.build(selected_observations, at_ns=at_ns,
                    max_age_ns=self.console.max_age_ns, max_skew_ns=self.console.max_skew_ns, bindings=self.bindings)
                evidence["evaluation"] = dict(self.evaluation.state, input_versions=versions)
                self.console.publish(session, cursor, observations, plans, at_ns=at_ns,
                    evidence=evidence, plan_failures=failures, input_versions=versions)

    def status(self):
        observations = []
        for o in self.observations.copy().values():
            book = decode_depth_snapshot(o.book)
            ratio = lambda value: [str(value.numerator), str(value.denominator)]
            scale = next(a["atomic_scale"] for a in self.source.assets if int(a["identity"]) == o.rules.base_asset)
            healthy = o.continuous and self.clock()-book["visible_at_ns"] < self.console.max_age_ns
            observations.append(dict(venue=str(o.venue), instrument=str(o.rules.instrument), environment=o.environment,
                base_asset=str(o.rules.base_asset), quote_asset=str(o.rules.quote_asset), continuous=healthy,
                bid_quote_atoms=ratio(book["bids"][0][0]*o.rules.tick_quote_atoms_per_base_atom*10**scale),
                ask_quote_atoms=ratio(book["asks"][0][0]*o.rules.tick_quote_atoms_per_base_atom*10**scale),
                bid_depth_atoms=ratio(sum(o.rules.notional(t,l) for t,l in book["bids"])) if all(l is not None for _,l in book["bids"]) else None,
                ask_depth_atoms=ratio(sum(o.rules.notional(t,l) for t,l in book["asks"])) if all(l is not None for _,l in book["asks"]) else None,
                bid_levels=len(book["bids"]), ask_levels=len(book["asks"]),
                truncated=book["bids_truncated"] or book["asks_truncated"],
                visible_at_ns=str(book["visible_at_ns"]), rules_version=str(o.rules.version)))
        return dict(discovery=copy.deepcopy(self.discovery_status), active_subscriptions=len(self.workers), routes=[dict(venue=str(v), requested_environment=e, actual_environment=a, endpoint=url,
                                products=["spot", "linear"] if v == 1 else ["linear"])
                            for (v, e), (url, a) in ROUTES.items()],
                    failures={str(k): v for k, v in self.failures.copy().items()}, observations=observations,
                    evidence=list(self.evidence.copy().values()), trading_qualified=False,
                    evaluation=copy.deepcopy(self.evaluation.state),
                    missing_evaluation=list(self.evaluation.state["missing"]))

    def _run(self):
        while not self.closing.wait(.5) and not self.console.shutdown.is_set():
            try:
                self.step()
            except Exception as error:
                with self.console.lock:
                    self.console.stop()
                    self.console.errors.append(str(error)[:2048])
                    self.console.errors[:] = self.console.errors[-64:]
                    self.console.phase = "Faulted"

    def close(self):
        self.console.close()
        self.closing.set()
        for thread in self.discovery_threads:
            thread.join(timeout=30)
        if self.thread:
            self.thread.join(timeout=20)
            if self.thread.is_alive():
                raise OSError("public scanner worker did not stop")
        for identity in tuple(self.workers):
            self.release(identity)
