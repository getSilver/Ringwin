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
import re
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
class NativeScannerAdapter:
    """Public requests and native worker binding for one registered Venue."""

    executable = ROOT/"zig-out/bin"/("ringwin-scanner-market.exe" if os.name == "nt" else "ringwin-scanner-market")
    metadata_limit = MAX_FRAME
    channel_capacity = 256*1024
    settlement_code = None

    def settings(self):
        return dict(type=self.kind, label=self.label, venue=str(self.venue),
                    environments=list(self.routes), products=list(self.products))

    def validate_saved_binding(self, row, assets):
        raise NotImplementedError

    def request(self, transport, operation, environment, product, symbol=""):
        if product not in self.products or environment not in self.routes:
            raise ValueError("unsupported public market source")
        endpoint, _ = self.routes[environment]
        return self.request_public(transport, endpoint, operation, product, symbol)


class OkxScannerAdapter(NativeScannerAdapter):
    kind, label, venue = "okx", "OKX", 1
    products = ("spot", "linear")
    routes = {"production": ("https://www.okx.com", "production"),
              "demo": ("https://www.okx.com", "production")}

    def request_public(self, transport, endpoint, operation, product, symbol):
        if operation == "book":
            return transport.request(endpoint + "/api/v5/market/books?instId=" + symbol + "&sz=5")
        kind = "SPOT" if product == "spot" else "SWAP"
        url = endpoint + "/api/v5/public/instruments?instType=" + kind
        if operation == "catalogue":
            return transport.request(url, max_bytes=MAX_DISCOVERY_BYTES)
        return transport.request(url + "&instId=" + symbol)

    def validate_saved_binding(self, row, assets):
        if "okx_binding" not in row:
            raise ValueError("missing discovered OKX binding")
        if not row.get("asset_associations"):
            base, quote = row["symbol"].split("-")[:2]
            if (assets[int(row["base_asset"])]["code"], assets[int(row["quote_asset"])]["code"]) != (base, quote):
                raise ValueError("OKX asset identity mismatch")
        lot = Fraction(row["lot_wire"])
        if row["product"] == "linear":
            lot *= Fraction(row["contract_value"])
        if Fraction(row["lot_base"]) != lot:
            raise ValueError("OKX quantity units mismatch")

    def worker_config(self, row, discovery):
        config = dict(contract_value=row.get("contract_value"))
        if not discovery:
            config.update(okx_binding=row["okx_binding"], okx_specification=row["specification"])
        return config

    def discovery_row(self, runtime, setting, product, item, assets):
        if item["product"] != product:
            raise ValueError("OKX catalogue product mismatch")
        base = runtime._asset(setting, item["base"], assets)
        quote = runtime._asset(setting, item["quote"], assets)
        instrument = OKX_LEGACY_IDENTITIES.get(item["symbol"], runtime._stable_id("okx-instrument-v1", item["symbol"]))
        version = runtime._stable_id("okx-rules-v1", json.dumps(item, sort_keys=True, separators=(",", ":"))) & ((1<<53)-1) or 1
        lot_base = Fraction(item["lot"]) * Fraction(item["contract_value"] or "1")
        if (lot_base * 10**18).denominator != 1:
            return None
        venue = int(setting["venue"])
        key = setting["venue"] + ":" + setting["environment"]
        previous = next((r for r in runtime.bindings.values() if (r["venue"], r["environment"], r["symbol"]) ==
                         (venue, setting["environment"], item["symbol"])), None)
        observation_identity = previous["observation_identity"] if previous else str(runtime._stable_id("scanner-source-v1", key))
        return dict(venue=venue, environment=setting["environment"], symbol=item["symbol"], product=product,
            instrument=str(instrument), observation_identity=observation_identity, rules_version=version,
            base_asset=base, quote_asset=quote,
            asset_associations=runtime._associations(setting, base=item["base"], quote=item["quote"]),
            tick=item["tick"], lot_wire=item["lot"], lot_base=str(lot_base), minimum_size=item["minimum_size"], contract_value=item["contract_value"], specification=item,
            okx_binding=dict(symbol=item["symbol"], instrument=instrument, product=product, base=item["base"], quote=item["quote"]))


class HyperliquidScannerAdapter(NativeScannerAdapter):
    kind, label, venue = "hyperliquid", "Hyperliquid", 21
    products = ("linear",)
    routes = {"production": ("https://api.hyperliquid.xyz", "production"),
              "testnet": ("https://api.hyperliquid-testnet.xyz", "testnet")}
    metadata_limit = MAX_HL_METADATA_BYTES
    channel_capacity = 5*1024*1024

    def request_public(self, transport, endpoint, operation, product, symbol):
        if operation == "book":
            return transport.request(endpoint + "/info", {"type": "l2Book", "coin": symbol})
        return transport.request(endpoint + "/info", {"type": "meta"}, max_bytes=self.metadata_limit)

    settlement_code = "USDC"

    def validate_saved_binding(self, row, assets):
        binding = row["binding"]
        if not row.get("hl_discovered") or row["symbol"] != binding["coin"]:
            raise ValueError("missing discovered Hyperliquid binding")
        if not row.get("asset_associations") and (
                assets[int(row["base_asset"])]["code"] != row["symbol"]
                or assets[int(row["quote_asset"])]["code"] != row["specification"]["quote"]):
            raise ValueError("Hyperliquid asset identity mismatch")
        if (int(row["instrument"]) != binding["instrument"] or row["rules_version"] != binding["rules_version"]
                or binding["product"] != "isolated_linear"
                or Fraction(row["tick"]) != Fraction(binding["tick_atoms"], 10**binding["price_scale"])
                or Fraction(row["lot_base"]) != Fraction(binding["lot_atoms"], 10**binding["quantity_scale"])):
            raise ValueError("Hyperliquid binding units mismatch")
        if binding.get("quote_token", 0) != 0:
            raise ValueError("Hyperliquid collateral binding mismatch")
        settlement = assets.get(int(row["settlement_asset"]))
        if settlement is None or not row.get("asset_associations") and settlement["code"] != self.settlement_code:
            raise ValueError("Hyperliquid settlement asset mismatch")

    def worker_config(self, row, discovery):
        return {} if discovery else dict(binding=row["binding"])

    def discovery_row(self, runtime, setting, product, item, assets):
        key = "21:" + setting["environment"]
        coin = item["coin"]
        # Protocol coin identity is scoped to the standard perp namespace and environment.
        base = runtime._asset(setting, coin, assets)
        quote = runtime._asset(setting, item["price_quote"], assets)
        settlement = runtime._asset(setting, "USDC", assets)
        instrument = runtime._stable_id("hyperliquid-standard-perp-v1", key+":"+coin)
        version = runtime._stable_id("hyperliquid-rules-v1", json.dumps(item, sort_keys=True, separators=(",", ":"))) & ((1<<53)-1) or 1
        size = item["size_decimals"]
        tick = "0."+"0"*(5-size)+"1" if size < 6 else "1"
        lot = "0."+"0"*(size-1)+"1" if size else "1"
        binding = dict(instrument=instrument, coin=coin, product="isolated_linear", universe_index=item["universe_index"],
            size_decimals=size, rules_version=version, expected_metadata_digest=item["metadata_digest"],
            price_scale=6-size, tick_atoms=1, quantity_scale=size, lot_atoms=1)
        return dict(venue=21, environment=setting["environment"], symbol=coin, product="linear", instrument=str(instrument),
            observation_identity=str(runtime._stable_id("scanner-source-v1", key)), rules_version=version,
            base_asset=base, quote_asset=quote, settlement_asset=settlement, tick=tick, lot_wire=lot, lot_base=lot,
            asset_associations=runtime._associations(setting, base=coin, quote=item["price_quote"], settlement="USDC"),
            specification=dict(item, product="linear", quote=item["price_quote"], settlement="USDC", collateral_token=0,
                underlying_binding=runtime.asset_bindings.resolve(21, setting["environment"], coin),
                max_significant_digits=5, integer_price_exception=True), binding=binding, hl_discovered=True)


DEFAULT_SCANNER_ADAPTERS = (OkxScannerAdapter(), HyperliquidScannerAdapter())


class PublicTransport:
    def __init__(self, adapters=DEFAULT_SCANNER_ADAPTERS):
        self.adapters = {adapter.venue: adapter for adapter in adapters}

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
        return self.adapters[int(setting["venue"])].request(self, "catalogue", setting["environment"], product)

    def metadata(self, binding):
        return self.adapters[binding["venue"]].request(self, "metadata", binding["environment"], binding["product"], binding["symbol"])

    def book(self, binding):
        return self.adapters[binding["venue"]].request(self, "book", binding["environment"], binding["product"], binding["symbol"])


class ScannerRuntime:
    def __init__(self, directory, *, transport=None, clock=time.monotonic_ns,
                 utc_clock=time.time_ns, automatic=True, asset_provider=None, adapters=DEFAULT_SCANNER_ADAPTERS):
        configuration = dict(schema=1, assets=[], bindings=[])
        bindings = []
        self.directory = Path(directory).resolve()
        self.directory.mkdir(parents=True, exist_ok=True)
        adapters = tuple(adapters)
        self.adapters = {adapter.venue: adapter for adapter in adapters}
        if len(self.adapters) != len(adapters) or len({adapter.kind for adapter in adapters}) != len(adapters):
            raise ValueError("duplicate scanner adapter")
        self.clock, self.utc_clock, self.transport = clock, utc_clock, transport or PublicTransport(adapters)
        self.asset_provider = asset_provider or (lambda: dict(schema=1, bindings=[]))
        self.asset_bindings = AssetBindings(dict(schema=1, bindings=[]))
        self.asset_binding_digest = None
        from opportunity_scanner.fee_schedules import FeeSchedules
        self.fees = FeeSchedules(self.directory/"manual-fees.json")
        self.evaluation = EvaluationInputs(self.directory/"scanner-evaluation.json", secrets.token_hex(16),
            fees=self.fees, synthetic=getattr(self.transport, "input_kind", "venue_public") == "synthetic_protocol_fixture")
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
            adapter = self.adapters.get(venue)
            if adapter is None or environment not in adapter.routes or row["product"] not in adapter.products:
                raise ValueError("unsupported saved market source")
            self._validate_associations(row, adapter)
            if any(int(row[field]) not in assets for field in ("base_asset", "quote_asset")):
                raise ValueError("missing trusted asset definition")
            adapter.validate_saved_binding(row, assets)
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
        self.console.fee_schedules = self.fees
        self.closing = threading.Event()
        self.thread = None
        if automatic:
            self.thread = threading.Thread(target=self._run, daemon=True, name="public-scanner-feeds")
            self.thread.start()

    @staticmethod
    def _entry(row, assets):
        base, quote = int(row["base_asset"]), int(row["quote_asset"])
        associations = row.get("asset_associations", {})
        def stable_unit(role, scale):
            binding = associations.get(role)
            if binding and binding["code"] in economics.STABLECOINS:
                return binding["code"], scale if scale is not None else binding["atomic_scale"]
            return None
        quote_unit = stable_unit("quote", assets[quote]["atomic_scale"])
        settlement_unit = stable_unit("settlement", None)
        base_binding = associations.get("base")
        registered_base = (int(base_binding["asset"]), assets[base]["atomic_scale"]) if base_binding and quote_unit else None
        settlement_id = int(row.get("settlement_asset", quote))
        settlement = ((settlement_id, *settlement_unit)
                      if settlement_id != quote and quote_unit and settlement_unit else None)
        tick, lot = Fraction(row["tick"]), Fraction(row["lot_base"])
        minimum = Fraction(row.get("minimum_size", row["lot_wire"])) / Fraction(row["lot_wire"])
        rules = economics.InstrumentRules(int(row["instrument"]), row["rules_version"], base, quote,
            tick * Fraction(10**assets[quote]["atomic_scale"], 10**assets[base]["atomic_scale"]),
            lot * 10**assets[base]["atomic_scale"], -(-minimum.numerator // minimum.denominator), 0, 0, (1<<64)-1,
            quote_unit=quote_unit, settlement=settlement, registered_base=registered_base)
        return CatalogueEntry(row["venue"], int(row["observation_identity"]), row["product"], rules, row["environment"], row.get("specification"))

    def _fx_rate(self, at_ns):
        try:
            with (self.directory/"stablecoin-fx.json").open("rb") as stream:
                raw = stream.read(2049)
            if len(raw) > 2048:
                return None
            row = json.loads(raw, object_pairs_hook=_object)
            if (type(row) is not dict or set(row) != {"at_ns", "source", "usdt_per_usdc"}
                    or type(row["usdt_per_usdc"]) is not str
                    or re.fullmatch(r"[0-9]{1,38}(?:[./][0-9]{1,38})?", row["usdt_per_usdc"]) is None
                    or type(row["at_ns"]) is not str or re.fullmatch(r"[0-9]{1,20}", row["at_ns"]) is None):
                return None
            sampled = int(row["at_ns"])
            age = self.utc_clock() - sampled
            if 0 <= age < self.console.max_age_ns and age <= at_ns:
                return economics.FxRate(Fraction(row["usdt_per_usdc"]), at_ns-age, row["source"], sampled)
        except (OSError, ValueError, TypeError, OverflowError, ZeroDivisionError, RecursionError):
            return None
        return None

    def _setting_adapter(self, setting):
        adapter = self.adapters.get(int(setting["venue"]))
        if adapter is None or setting["type"] != adapter.kind or setting["environment"] not in adapter.routes:
            raise ValueError("unsupported discovery setting")
        return adapter

    def request_discovery(self, setting, *, refresh=False):
        self._setting_adapter(setting)
        key = setting["venue"] + ":" + setting["environment"]
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
        adapter = self._setting_adapter(setting)
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
                try:
                    registry = AssetBindings(self.asset_provider(),
                        allow_fixture=getattr(self.transport, "input_kind", "venue_public") == "synthetic_protocol_fixture")
                except (OSError, ValueError, KeyError, TypeError) as error:
                    self._invalidate_asset_bindings(key, "core asset projection: " + str(error)[:2048])
                    self.asset_binding_digest = None
                    return
                if self.asset_binding_digest != registry.digest:
                    self._invalidate_asset_bindings(key)
                    self.asset_bindings, self.asset_binding_digest = registry, registry.digest
                assets_by_id = {a["identity"]: a for a in self.source.assets}
                for product in adapter.products:
                    if self.closing.is_set():
                        return
                    row = dict(venue=int(setting["venue"]), product=product, environment=setting["environment"], symbol="",
                        instrument=str(self._stable_id("scanner-catalogue-v1", key)),
                        rules_version=1, tick="1", lot_wire="1")
                    worker = self._open(None, row=row, discovery=True)
                    capture = dict(raw_path=worker[3], requested_environment=setting["environment"],
                        actual_environment=adapter.routes[setting["environment"]][1], product=product)
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
                        binding = adapter.discovery_row(self, setting, product, item, assets_by_id)
                        if binding is None:
                            rejected.append(dict(symbol=result_row["symbol"], reason="UnsupportedDecimalUnits"))
                        else:
                            rows.append(binding)
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
                                 asset_binding_gaps=[dict(symbol=r["symbol"], codes=self._asset_codes(r, adapter), missing=[role for role, binding in r["asset_associations"].items() if binding is None])
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

    def _invalidate_asset_bindings(self, current_key, error=None):
        with self.poll_lock, self.console.lock, self.source.lock, self.lock:
            affected = set(self.bindings)
            self.source.unavailable.update(affected)
            self._catalogue_changed(affected, restore=False)
            self.discovery_success.clear()
            for key in self.discovery_status:
                if error is not None:
                    self.discovery_status[key] = dict(state="failed", error=error, complete=False)
                elif key != current_key:
                    self.discovery_status[key] = dict(state="loading", error="", complete=False)
                if error is None and key != current_key:
                    self.next_discovery[key] = 0

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

    @staticmethod
    def _asset_codes(row, adapter):
        spec = row.get("specification", {})
        codes = dict(base=spec.get("base", row["symbol"]),
                     quote=spec.get("quote", spec.get("price_quote")))
        if adapter.settlement_code is not None:
            codes["settlement"] = adapter.settlement_code
        return codes

    def _asset_basis(self, row):
        return dict(symbol=row["symbol"], bindings=row.get("asset_associations", {}),
                    codes=self._asset_codes(row, self.adapters[row["venue"]]), base_units_per_lot=row["lot_base"],
                    base_units_per_wire_unit=row.get("contract_value") or "1")

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
    def _validate_associations(cls, row, adapter):
        associations = row.get("asset_associations")
        if associations is None:  # Old caches must still undergo fresh discovery before use.
            return
        spec = row["specification"]
        codes = cls._asset_codes(row, adapter)
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
        adapter = self.adapters[row["venue"]]
        process = subprocess.Popen([str(adapter.executable), str(path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        # Full Hyperliquid metadata also travels inside the JSON request envelope.
        channel = NativeAuthority(process, timeout=15 if discovery else 5,
            max_frame_bytes=5*1024*1024 if discovery else adapter.channel_capacity)
        config = dict(schema=1, discovery=discovery, requested_environment=row["environment"], session=session, venue=row["venue"], environment=adapter.routes[row["environment"]][1],
            instrument=int(row["instrument"]), rules_version=row["rules_version"], tick=row["tick"], lot=row["lot_wire"])
        config["minimum_size"] = row.get("minimum_size")
        if discovery:
            config["discovery_product"] = row["product"]
        config["raw_budget_bytes"] = row.get("raw_budget_bytes", 4*1024*1024)
        config.update(adapter.worker_config(row, discovery))
        try:
            channel.request(config)
        except Exception:
            self._close_worker((process, channel, None, None))
            raise
        return process, channel, dict(session=session, sequence=0, epoch=0, next_metadata_ns=0, venue=row["venue"]), str(path)

    def _input(self, worker, operation, payload):
        _, channel, state, _ = worker
        limit = MAX_DISCOVERY_BYTES if operation == "discover" else self.adapters[state["venue"]].metadata_limit if operation == "metadata" else MAX_FRAME
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
                        actual_environment=self.adapters[row["venue"]].routes[row["environment"]][1], input_kind=getattr(self.transport, "input_kind", "venue_public"))
                    self.evidence[identity]["asset_basis"] = self._asset_basis(row)
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
            observations = self.observations.copy()
            market_errors = self.failures.copy()
            evidence = {str(k): v for k, v in self.evidence.items()}
            self.cursor += 1
            cursor = self.cursor
        # Publish with evidence through the same console public seam. No HTTP input route.
        with self.console.lock:
            if self.console.desired == "running" and self.console.session == session and self.console.config["version"] == version:
                at_ns = self.clock()
                selected_ids = self.console._selected()
                selected_observations = []
                with self.source.lock:
                    for identity in sorted(selected_ids):
                        entry = self.source.registered[identity]
                        endpoint, actual = self.adapters[entry.venue].routes[entry.environment]
                        source = (actual, endpoint, getattr(self.transport, "input_kind", "venue_public"))
                        observation = observations.get(identity)
                        binding = self.bindings[identity]
                        if observation is None:
                            observation = Observation(entry.venue, entry.account, entry.kind, entry.rules,
                                None, False, entry.environment)
                            evidence.setdefault(str(identity), dict(asset_basis=self._asset_basis(binding)))
                        associations = binding.get("asset_associations", {})
                        assets = tuple(associations.get(role) for role in ("base", "quote"))
                        registered_assets = (tuple((int(asset["asset"]), asset["atomic_scale"]) for asset in assets)
                                             if all(assets) else None)
                        selected_observations.append(replace(observation, market_source=source,
                            market_error=market_errors.get(identity), registered_assets=registered_assets))
                plans, failures, versions = self.evaluation.build(
                    tuple(o for o in selected_observations if o.book is not None), at_ns=at_ns,
                    max_age_ns=self.console.max_age_ns, max_skew_ns=self.console.max_skew_ns, bindings=self.bindings)
                evidence["evaluation"] = dict(self.evaluation.state, input_versions=versions)
                self.console.publish(session, cursor, tuple(selected_observations), plans, at_ns=at_ns,
                    evidence=evidence, plan_failures=failures, input_versions=versions, fx_rate=self._fx_rate(at_ns))

    def status(self):
        observations = []
        for identity, o in self.observations.copy().items():
            book = decode_depth_snapshot(o.book)
            ratio = lambda value: [str(value.numerator), str(value.denominator)]
            scale = next(a["atomic_scale"] for a in self.source.assets if int(a["identity"]) == o.rules.base_asset)
            healthy = o.continuous and self.clock()-book["visible_at_ns"] < self.console.max_age_ns
            observations.append(dict(venue=str(o.venue), account=str(o.account), instrument=str(o.rules.instrument), environment=o.environment,
                base_asset=str(o.rules.base_asset), quote_asset=str(o.rules.quote_asset), continuous=healthy,
                asset_basis=self.evidence.get(identity, {}).get("asset_basis"),
                bid_quote_atoms=ratio(book["bids"][0][0]*o.rules.tick_quote_atoms_per_base_atom*10**scale),
                ask_quote_atoms=ratio(book["asks"][0][0]*o.rules.tick_quote_atoms_per_base_atom*10**scale),
                bid_depth_atoms=ratio(sum(o.rules.notional(t,l) for t,l in book["bids"])) if all(l is not None for _,l in book["bids"]) else None,
                ask_depth_atoms=ratio(sum(o.rules.notional(t,l) for t,l in book["asks"])) if all(l is not None for _,l in book["asks"]) else None,
                bid_levels=len(book["bids"]), ask_levels=len(book["asks"]),
                truncated=book["bids_truncated"] or book["asks_truncated"],
                visible_at_ns=str(book["visible_at_ns"]), rules_version=str(o.rules.version)))
        return dict(discovery=copy.deepcopy(self.discovery_status), active_subscriptions=len(self.workers), routes=[
                        dict(venue=str(adapter.venue), requested_environment=environment, actual_environment=actual,
                             endpoint=url, products=list(adapter.products))
                        for adapter in self.adapters.values() for environment, (url, actual) in adapter.routes.items()],
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
