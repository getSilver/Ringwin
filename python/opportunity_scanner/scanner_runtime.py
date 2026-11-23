"""Public REST polling -> native MarketFeedAdapter -> canonical depth -> scanner.

Public protocol transport is replaceable; asset bindings come from node-owned
activated-registry projection. No credentials or execution capability.
"""
from concurrent.futures import Future, ThreadPoolExecutor, wait
from dataclasses import replace
from fractions import Fraction
from functools import cache
import hashlib
import copy
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import threading
import time
from typing import NamedTuple, Optional
import urllib.request
from urllib.parse import urlsplit

from strategies.cross_venue import arbitrage_economics as economics
from strategies.cross_venue.arbitrage_fx_archive import read_fx_sample
from opportunity_scanner.arbitrage_scanner import Observation, compatible_pairs, decode_depth_snapshot
from opportunity_scanner.scanner_console import CanonicalSource, CatalogueEntry, ScannerConsole
from opportunity_scanner.scanner_config import atomic_json, _object
from opportunity_scanner.scanner_history import History
from opportunity_scanner.scanner_segments import CaptureSegments, CaptureStorageError
from opportunity_scanner.scanner_assets import AssetBindings
from opportunity_scanner.scanner_evaluation import EvaluationInputs
from strategy_instance import NativeAuthority

ROOT = Path(__file__).resolve().parents[2]
MAX_FRAME = 120 * 1024
MAX_CATALOGUE = 8192
MAX_DISCOVERY_BYTES = 4 * 1024 * 1024
MAX_HL_METADATA_BYTES = 1024 * 1024
ACTIVE_BOOKS = 16
VENUE_CONCURRENCY = 2
DISPLAY_PAIRS = 42  # Six candidate variants per pair, below the snapshot limit.
CATALOGUE_REFRESH_NS = 30_000_000_000
CATALOGUE_TTL_NS = 90_000_000_000
METADATA_REUSE_NS = 5_000_000_000
METADATA_REFRESH_NS = 30_000_000_000
# Stable historical identities, never an admission list or a worker configuration.
OKX_LEGACY_IDENTITIES = {"BTC-USDT": 0x4f4b5800000001, "BTC-USDT-SWAP": 0x4f4b5800000002,
                         "BTC-USDC": 0x4f4b5800000003}


class MetadataScope(NamedTuple):
    source: tuple[int, str, str]
    product: str
    symbol: Optional[str]


class NativeScannerAdapter:
    """Public requests and native worker binding for one registered Venue."""

    executable = ROOT/"zig-out/bin"/("ringwin-scanner-market.exe" if os.name == "nt" else "ringwin-scanner-market")
    metadata_limit = MAX_FRAME
    channel_capacity = 256*1024
    settlement_code = None
    batch_quotes = False
    shared_metadata = False

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
    batch_quotes = True
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

    def quotes(self, transport, endpoint, product):
        kind = "SPOT" if product == "spot" else "SWAP"
        value = json.loads(transport.request(endpoint + "/api/v5/market/tickers?instType=" + kind,
                                             max_bytes=MAX_DISCOVERY_BYTES))
        if value["code"] != "0":
            raise ValueError("OKX ticker batch rejected")
        return {row["instId"]: (row["bidPx"], row["askPx"]) for row in value["data"]}

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
    batch_quotes = True
    routes = {"production": ("https://api.hyperliquid.xyz", "production"),
              "testnet": ("https://api.hyperliquid-testnet.xyz", "testnet")}
    metadata_limit = MAX_HL_METADATA_BYTES
    channel_capacity = 5*1024*1024

    def request_public(self, transport, endpoint, operation, product, symbol):
        if operation == "book":
            return transport.request(endpoint + "/info", {"type": "l2Book", "coin": symbol})
        return transport.request(endpoint + "/info", {"type": "meta"}, max_bytes=self.metadata_limit)

    def quotes(self, transport, endpoint, product):
        values = json.loads(transport.request(endpoint + "/info", {"type": "allMids"}))
        return {symbol: (mid, mid) for symbol, mid in values.items()}

    settlement_code = "USDC"
    shared_metadata = True

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


class BookRequestDeferred(Exception):
    """A competing public request took the paired book window."""


class PublicTransport:
    def __init__(self, adapters=DEFAULT_SCANNER_ADAPTERS):
        self.adapters = {adapter.venue: adapter for adapter in adapters}
        self._request_lock = threading.Lock()
        self._request_after = {}
        self._retry_after = {}
        self._backoff = {}
        self._paired_request = threading.local()

    @staticmethod
    def _budget(endpoint):
        if endpoint in ("api.hyperliquid.xyz", "api.hyperliquid-testnet.xyz"):
            return "hyperliquid"
        return "okx" if endpoint.endswith(".okx.com") else endpoint

    def _retry_deadline(self, endpoint, budget):
        return max(self._retry_after.get(endpoint, 0), self._retry_after.get(budget, 0))

    def _request_deadline(self, sources):
        return max(max(self._request_after.get(budget, 0), self._retry_deadline(endpoint, budget))
                   for endpoint, budget in sources)

    def request_delay(self, urls):
        """Seconds until all sources can make a request, using the transport clock."""
        with self._request_lock:
            return max(0, self._request_deadline(self._sources(urls)) - time.monotonic())

    def _sources(self, urls):
        endpoints = (urlsplit(url).netloc for url in urls)
        return tuple((endpoint, self._budget(endpoint)) for endpoint in endpoints)

    @staticmethod
    def _spacing(budget, *, light):
        if budget != "hyperliquid":
            return .10
        return .12 if light else 1.20

    def paired_book_admission(self, urls):
        sources = self._sources(urls)
        start_at = None

        def admit():
            nonlocal start_at
            with self._request_lock:
                if start_at is None:
                    now = time.monotonic()
                    earliest = max(now, self._request_deadline(sources))
                    # A second book batch can use the next book interval. Yield
                    # to metadata spacing and Retry-After in the next scan step.
                    backing_off = any(now < self._retry_deadline(endpoint, budget)
                                      for endpoint, budget in sources)
                    if backing_off or earliest > now + .12:
                        start_at = -1
                    else:
                        start_at = earliest
                        for _, budget in sources:
                            spacing = self._spacing(budget, light=True)
                            self._request_after[budget] = start_at + spacing
            if start_at < 0:
                raise BookRequestDeferred
            delay = start_at - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            with self._request_lock:
                now = time.monotonic()
                if any(now < self._retry_deadline(endpoint, budget) for endpoint, budget in sources):
                    raise BookRequestDeferred

        return admit

    def paired_book(self, binding, admit):
        self._paired_request.admit = admit
        try:
            return self.book(binding)
        finally:
            del self._paired_request.admit

    def request(self, url, body=None, *, max_bytes=MAX_FRAME):
        # Conservative per-IP spacing, including catalogue/metadata requests.
        endpoint = urlsplit(url).netloc
        budget = self._budget(endpoint)
        admit = getattr(self._paired_request, "admit", None)
        if admit is not None:
            admit()
        else:
            while True:
                with self._request_lock:
                    now = time.monotonic()
                    if now < self._retry_deadline(endpoint, budget):
                        raise OSError("public source temporarily backing off")
                    delay = self._request_after.get(budget, 0) - now
                    if delay <= 0:
                        light = body and body.get("type") in ("l2Book", "allMids")
                        self._request_after[budget] = now + self._spacing(budget, light=light)
                        break
                time.sleep(delay)
        data = None if body is None else json.dumps(body, separators=(",", ":")).encode()
        request = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
        # urllib's default client signature is rejected by the OKX public gateway.
        opener = urllib.request.build_opener()
        opener.addheaders = []
        try:
            with opener.open(request, timeout=3) as response:
                payload = response.read(max_bytes + 1)
        except OSError as error:
            with self._request_lock:
                retry_key = budget if getattr(error, "code", None) == 429 else endpoint
                delay = min(30, 2 * self._backoff.get(retry_key, .25))
                retry = getattr(error, "headers", None)
                seconds = retry.get("Retry-After", "") if retry else ""
                if len(seconds) <= 6 and seconds.isdecimal():
                    delay = max(delay, min(300, int(seconds)))
                self._backoff[retry_key] = min(delay, 30)
                self._retry_after[retry_key] = max(self._retry_after.get(retry_key, 0), time.monotonic() + delay)
            raise
        with self._request_lock:
            for key in (endpoint, budget):
                if time.monotonic() >= self._retry_after.get(key, 0):
                    self._backoff.pop(key, None)
        if len(payload) > max_bytes:
            raise ValueError("public transport capacity exceeded")
        return payload.decode("utf-8")

    def quote_batch(self, source):
        venue, endpoint, product = source
        return self.adapters[venue].quotes(self, endpoint, product)

    def catalogue(self, setting, product):
        return self.adapters[int(setting["venue"])].request(self, "catalogue", setting["environment"], product)

    def metadata(self, binding):
        return self.adapters[binding["venue"]].request(self, "metadata", binding["environment"], binding["product"], binding["symbol"])

    def book(self, binding):
        return self.adapters[binding["venue"]].request(self, "book", binding["environment"], binding["product"], binding["symbol"])


@cache
def _system_evaluation_clock_id():
    """Keep registered deadlines across process restarts within the same OS clock."""
    try:
        if os.name == "nt":
            powershell = Path(os.environ["SystemRoot"])/"System32/WindowsPowerShell/v1.0/powershell.exe"
            identity = subprocess.check_output(
                [str(powershell), "-NoProfile", "-NonInteractive", "-Command",
                 "$ErrorActionPreference='Stop'; $os=Get-CimInstance Win32_OperatingSystem; "
                 "$os.CSName + ':' + $os.LastBootUpTime.ToUniversalTime().Ticks"],
                timeout=5, stderr=subprocess.DEVNULL, text=True, creationflags=subprocess.CREATE_NO_WINDOW).strip()
            if identity and identity.rpartition(":")[2].isdigit():
                return "windows:" + hashlib.sha256(identity.encode()).hexdigest()
        elif sys.platform == "linux":
            boot = Path("/proc/sys/kernel/random/boot_id").read_text(encoding="ascii").strip()
            namespace = Path("/proc/self/ns/time")
            if boot:
                return f"linux:{boot}:{namespace.stat().st_ino if namespace.exists() else 0}"
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        pass
    return None


class ScannerRuntime:
    def __init__(self, directory, *, transport=None, clock=time.monotonic_ns,
                 utc_clock=time.time_ns, automatic=True, asset_provider=None, adapters=DEFAULT_SCANNER_ADAPTERS,
                 evaluation_clock_id=None):
        configuration = dict(schema=1, assets=[], bindings=[])
        bindings = []
        self.directory = Path(directory).resolve()
        self.directory.mkdir(parents=True, exist_ok=True)
        adapters = tuple(adapters)
        self.adapters = {adapter.venue: adapter for adapter in adapters}
        if len(self.adapters) != len(adapters) or len({adapter.kind for adapter in adapters}) != len(adapters):
            raise ValueError("duplicate scanner adapter")
        self.segments = CaptureSegments(self.directory, self.adapters)
        self.clock, self.utc_clock, self.transport = clock, utc_clock, transport or PublicTransport(adapters)
        self.asset_provider = asset_provider or (lambda: dict(schema=1, bindings=[]))
        self.asset_bindings = AssetBindings(dict(schema=1, bindings=[]))
        self.asset_binding_digest = None
        from opportunity_scanner.fee_schedules import FeeSchedules
        self.fees = FeeSchedules(self.directory/"manual-fees.json")
        clock_id = evaluation_clock_id
        if clock_id is None and clock is time.monotonic_ns:
            clock_id = _system_evaluation_clock_id()
        self.evaluation = EvaluationInputs(self.directory/"scanner-evaluation.json", clock_id or secrets.token_hex(16),
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
        self.source.replay_raw_book = self.segments.replay
        self.workers, self.observations, self.evidence, self.failures = {}, {}, {}, {}
        self.pending, self.generations, self.touched = {}, {}, {}
        self.quotes, self.quote_pending = {}, {}
        self.book_requests, self.metadata_requests = {}, {}
        self.coverage_key = None
        self.coverage_routes, self.attempted = {}, {}
        self.skew_retried = set()
        self.paired_markets = set()
        self.diagnostic_markets = set()
        self.round_remaining = set()
        self.round_started_ns = self.round_duration_ns = None
        self.completed_rounds = 0
        self.executor = ThreadPoolExecutor(max_workers=ACTIVE_BOOKS, thread_name_prefix="scanner-market")
        self.cursor = self.dispatch = 0
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
        rate = read_fx_sample(self.directory/"stablecoin-fx.json")
        if rate is not None:
            age = self.utc_clock() - rate.at_ns
            if 0 <= age < self.console.max_age_ns and age <= at_ns:
                return replace(rate, at_ns=at_ns-age, market_at_ns=rate.at_ns)
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
                self._invalidate_metadata_source(int(old["venue"]), old["environment"])
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
                        if result.get("failure"):
                            raise ValueError(result["failure"])
                        audit = self._input(worker, "audit", "")
                        capture.update(raw_sha256=result["raw_sha256"], raw_sequence=result["raw_sequence"], captures=audit["captures"])
                        self.segments.report_capture(row["venue"], row["environment"], row["instrument"])
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
                    changed_products = {rows_by_id[i]["product"] for rows_by_id in (self.bindings, updated)
                                        for i in changed if i in rows_by_id}
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
                    if changed_products:
                        self._invalidate_metadata_source(int(setting["venue"]), setting["environment"], changed_products)
                    self._catalogue_changed(changed)
            except (OSError, ValueError, KeyError, TypeError) as error:
                with self.poll_lock, self.console.lock, self.source.lock, self.lock:
                    if not self._current_setting(setting, generation):
                        return
                    affected = {i for i,r in self.bindings.items() if (r["venue"], r["environment"]) ==
                                (int(setting["venue"]), setting["environment"])}
                    self.source.unavailable.update(affected)
                    self._invalidate_metadata_source(int(setting["venue"]), setting["environment"])
                    self._catalogue_changed(affected, restore=False)
                    self.discovery_status[key] = dict(state="failed", error=str(error)[:2048], evidence=evidence,
                                                     rejected=rejected, complete=False)

    def _invalidate_asset_bindings(self, current_key, error=None):
        with self.poll_lock, self.console.lock, self.source.lock, self.lock:
            affected = set(self.bindings)
            self.source.unavailable.update(affected)
            self.metadata_requests.clear()
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
                            self._invalidate_metadata_source(int(setting["venue"]), setting["environment"])
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
                self.workers[identity] = None
                self.generations[identity] = object()

    def release(self, identity):
        with self.lock:
            self.segments.forget_capture(identity[0], identity[2])
            worker = self.workers.pop(identity, None)
            generation = self.generations.pop(identity, None)
            self.touched.pop(identity, None)
            pending = self.pending.get(identity)
            if pending and pending[0] is generation:
                worker = None  # The in-flight job owns the worker until it returns.
            self.observations.pop(identity, None)
            self.evidence.pop(identity, None)
            self.failures.pop(identity, None)
        if worker:
            self._close_worker(worker)

    def _close_worker(self, worker):
        process, channel, _, path = worker
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)
        channel.pipes.close()
        self.segments.retire(path)

    def _open(self, identity, *, row=None, discovery=False):
        row = self.bindings[identity] if row is None else row
        session = secrets.randbelow((1<<53)-1)+1
        self.segments.check_space(row["venue"], row["environment"], row["instrument"])
        path = self.segments.hot_path(row["venue"], row["environment"], session)
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
            self._close_worker((process, channel, None, str(path)))
            raise
        return process, channel, dict(session=session, sequence=0, epoch=0, next_metadata_ns=0, venue=row["venue"],
            environment=row["environment"], instrument=row["instrument"], budget=config["raw_budget_bytes"],
            capture_bytes=0, sampled=False), str(path)

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
        if result.get("capture_failed"):
            error = "RawIngress write Unavailable"
            self.segments.report_capture(state["venue"], state["environment"], state["instrument"], error)
            raise CaptureStorageError(error)
        if result.get("capture_full"):
            if not state["sampled"]:
                self.segments.report_capture(state["venue"], state["environment"], state["instrument"],
                                             "RawIngress segment budget Unavailable")
            else:
                raise CaptureStorageError("RawIngress segment full")
        state["capture_bytes"] = result.get("capture_bytes", state["capture_bytes"])
        return result

    def audit(self):
        """Read and validate committed RawIngress through the native replay interface."""
        with self.poll_lock:
            return {str(identity): self._input(worker, "audit", "")
                    for identity, worker in tuple(self.workers.items()) if worker is not None and identity not in self.pending}

    def step(self, *, blocking=True):
        """Advance scheduling. The service publishes without waiting on network jobs."""
        self.segments.retry()
        self._refresh_catalogues()
        with self.poll_lock:
            self._collect_samples()
            futures = self._schedule_samples()
        if blocking and futures:
            wait(futures)
            with self.poll_lock:
                warmed = self._collect_samples()
                futures = self._schedule_samples(warmed=warmed) if warmed else ()
            if futures:
                wait(futures)
        with self.poll_lock:
            self._collect_samples()
            self._publish()

    def _quote_source(self, row):
        return row["venue"], self.adapters[row["venue"]].routes[row["environment"]][0], row["product"]

    def _shared_request(self, cache, key, fetch):
        with self.lock:
            request = cache.get(key)
            owner = request is None
            if owner:
                request = cache[key] = Future()
        if owner:
            try:
                request.set_result(fetch())
            except Exception as error:
                request.set_exception(error)
        return request.result()

    def _book(self, row, admit):
        key = (*self._quote_source(row), row["symbol"])
        fetch = (lambda: self.transport.paired_book(row, admit)) if admit else (lambda: self.transport.book(row))
        return self._shared_request(self.book_requests, key, fetch)

    def _metadata_source(self, venue, environment):
        endpoint, actual = self.adapters[venue].routes[environment]
        return venue, endpoint, actual

    def _invalidate_metadata_source(self, venue, environment, products=None):
        # Called under the runtime lock when catalogue authority changes.
        source = self._metadata_source(venue, environment)
        for key in tuple(self.metadata_requests):
            if key.source == source and (products is None or key.product in products):
                del self.metadata_requests[key]

    def _invalidate_metadata(self, key, request):
        with self.lock:
            if self.metadata_requests.get(key) is request:
                self.metadata_requests.pop(key, None)

    def _metadata_key(self, row):
        venue = row["venue"]
        adapter = self.adapters[venue]
        symbol = None if adapter.shared_metadata else row["symbol"]
        return MetadataScope(self._metadata_source(venue, row["environment"]), row["product"], symbol)

    def _metadata(self, row, key):
        with self.lock:
            request = self.metadata_requests.get(key)
            owner = request is None or (key.symbol is None and request.done()
                and self.clock() - request.result()[1] >= METADATA_REUSE_NS)
            if owner:
                request = self.metadata_requests[key] = Future()
        if owner:
            try:
                payload = self.transport.metadata(row)
                fetched_at = self.clock()
                with self.lock:
                    if self.metadata_requests.get(key) is not request:
                        raise ValueError("public metadata invalidated during refresh")
                    request.set_result((payload, fetched_at))
            except Exception as error:
                self._invalidate_metadata(key, request)
                request.set_exception(error)
        payload, fetched_at = request.result()
        return payload, fetched_at, request

    def _validate_worker_metadata(self, worker, row, key):
        payload, fetched_at, request = self._metadata(row, key)
        result = self._input(worker, "metadata", payload)
        if result["failure"]:
            self._invalidate_metadata(key, request)
            raise ValueError(result["failure"])
        worker[2]["next_metadata_ns"] = fetched_at + METADATA_REFRESH_NS
        return request

    @staticmethod
    def _needs_rotation(worker):
        state = worker[2]
        reserve = min(MAX_FRAME + 8192, state["budget"] // 4)
        return state["sampled"] and state["budget"] - state["capture_bytes"] < reserve

    def _warm(self, identity, row, worker):
        try:
            if worker is not None and self._needs_rotation(worker):
                retired, worker = worker, None
                self._close_worker(retired)
            opening = worker is None
            if opening:
                worker = self._open(identity, row=row)
            self._validate_worker_metadata(worker, row, self._metadata_key(row))
            if opening:
                worker[2]["epoch"] += 1
                result = self._input(worker, "subscribe", json.dumps({"event":"polling_started"}))
                if result["failure"]:
                    raise ValueError(result["failure"])
            return worker, None, None
        except Exception as error:
            return worker, None, (str(error) or type(error).__name__)[:2048]

    def _sample(self, identity, row, worker, admit):
        try:
            metadata_key = self._metadata_key(row)
            with self.lock:
                metadata_request = self.metadata_requests.get(metadata_key)
            try:
                payload = self._book(row, admit)
            except BookRequestDeferred:
                return worker, None, None
            except OSError:
                self._invalidate_metadata(metadata_key, metadata_request)
                raise
            result = self._input(worker, "book", payload)
            if result["failure"]:
                self._invalidate_metadata(metadata_key, metadata_request)
                raise ValueError(result["failure"])
            worker[2]["sampled"] = True
            self.segments.report_capture(row["venue"], row["environment"], row["instrument"])
            return worker, result, None
        except Exception as error:
            return worker, None, (str(error) or type(error).__name__)[:2048]

    def _collect_samples(self):
        warmed = set()
        with self.lock:
            for source, future in tuple(self.quote_pending.items()):
                if not future.done():
                    continue
                self.quote_pending.pop(source)
                try:
                    self.quotes[source] = self.clock(), future.result()
                except (OSError, ValueError, KeyError, TypeError):
                    self.quotes[source] = self.clock(), {}
            for identity, (generation, future, stage) in tuple(self.pending.items()):
                if not future.done():
                    continue
                self.pending.pop(identity)
                worker, result, error = future.result()
                if self.generations.get(identity) is not generation:
                    self.segments.forget_capture(identity[0], identity[2])
                    if worker:
                        self._close_worker(worker)
                    continue
                if error is not None:
                    old = self.observations.get(identity)
                    if old:
                        self.observations[identity] = replace(old, continuous=False)
                    self.failures[identity] = error
                    if worker:
                        self._close_worker(worker)
                    self.workers[identity] = None
                    continue
                self.workers[identity] = worker
                if result is None:
                    if stage == "warm":
                        warmed.add(identity)
                    continue
                row = self.bindings[identity]
                if result["depth"] is not None:
                    depth = bytes.fromhex(result["depth"])
                    previous = self.observations.get(identity)
                    if (previous and result["healthy"] and (previous.book == depth or
                            self.evidence[identity]["raw_sha256"] == result["raw_sha256"])):
                        # A reopened worker can accept the last frame in a new native epoch.
                        # Preserve its canonical time and matching archive evidence.
                        self.failures.pop(identity, None)
                        continue
                    self.observations[identity] = replace(self._observation(identity),
                        book=depth, continuous=result["healthy"])
                elif not result["healthy"] and identity in self.observations:
                    self.observations[identity] = replace(self.observations[identity], continuous=False)
                self.evidence[identity] = dict(result, venue=str(row["venue"]), instrument=row["instrument"],
                    raw_path=worker[3], requested_environment=row["environment"],
                    actual_environment=self.adapters[row["venue"]].routes[row["environment"]][1],
                    input_kind=getattr(self.transport, "input_kind", "venue_public"), asset_basis=self._asset_basis(row))
                self.failures.pop(identity, None)

        return warmed

    def _observation(self, identity):
        entry = self.source.registered[identity]
        binding = self.bindings[identity]
        endpoint, actual = self.adapters[entry.venue].routes[entry.environment]
        associations = binding.get("asset_associations", {})
        assets = tuple(associations.get(role) for role in ("base", "quote"))
        registered_assets = (tuple((int(asset["asset"]), asset["atomic_scale"]) for asset in assets)
                             if all(assets) else None)
        return Observation(entry.venue, entry.account, entry.kind, entry.rules, None, False, entry.environment,
            market_source=(actual, endpoint, getattr(self.transport, "input_kind", "venue_public")),
            registered_assets=registered_assets)

    def _quote_edge(self, pair, now):
        if not economics.compatible_quotes(*(self.source.registered[i].rules for i in pair)):
            return None
        prices = []
        for identity in pair:
            row = self.bindings[identity]
            at, values = self.quotes.get(self._quote_source(row), (0, {}))
            if not 0 <= now-at < self.console.max_age_ns:
                return None
            try:
                bid, ask = map(Fraction, values[row["symbol"]])
                if not 0 < bid <= ask:
                    return None
                prices.append((bid, ask))
            except (ValueError, KeyError, TypeError, ZeroDivisionError):
                return None
        (bid, ask), (other_bid, other_ask) = prices
        return max(other_bid/ask, bid/other_ask) - 1

    def _refresh_coverage_scope(self, selected, now):
        console = self.console
        key = (console.session, console.config["version"], frozenset(selected),
               tuple((identity, self.generations.get(identity)) for identity in sorted(selected)))
        if key == self.coverage_key:
            return
        previous = dict(self.coverage_key[3]) if self.coverage_key and self.coverage_key[0] == console.session else {}
        self.coverage_key = key
        self.coverage_routes = {
            pair: self.coverage_routes.get(pair)
            if all(i in previous and previous[i] is self.generations.get(i) for i in pair) else None
            for pair in compatible_pairs(self._observation(i) for i in selected)
        }
        self.paired_markets = {identity for pair in self.coverage_routes for identity in pair}
        # Keep small one-Venue diagnostic scopes usable.
        self.diagnostic_markets = (selected if len(selected) <= ACTIVE_BOOKS
                                   and len({i[0] for i in selected}) == 1 else set())
        self.attempted = {}
        self.skew_retried.clear()
        self.round_remaining = set(self.coverage_routes)
        self.round_started_ns = now
        self.round_duration_ns = None
        self.completed_rounds = 0

    def _schedule_samples(self, *, warmed=None):
        with self.console.lock, self.source.lock, self.lock:
            console = self.console
            selected = console._selected(include_unavailable=True) if console.desired == "running" else set()
            now = self.clock()
            self._refresh_coverage_scope(selected, now)
            external = {identity for owner, identities in self.source.owners.items() if owner != console.session for identity in identities}
            for key, request in tuple(self.book_requests.items()):
                if request.done():
                    del self.book_requests[key]
            for key, request in tuple(self.metadata_requests.items()):
                if key.symbol is not None and request.done():
                    del self.metadata_requests[key]
            wanted_markets = self.paired_markets | self.diagnostic_markets | external
            for identity in self.workers.keys() - wanted_markets - self.pending.keys():
                worker = self.workers[identity]
                if worker is not None:
                    self._close_worker(worker)
                    self.workers[identity] = None
            inflight = {}
            for venue, *_ in (*self.pending, *self.quote_pending):
                inflight[venue] = inflight.get(venue, 0) + 1
            futures = []
            request_delay = getattr(self.transport, "request_delay", None)
            paired_book_admission = getattr(self.transport, "paired_book_admission", None)
            wide = len(self.paired_markets) > ACTIVE_BOOKS
            if warmed is None and wide and getattr(self.transport, "supports_batch_quotes",
                    getattr(self.transport, "input_kind", "") != "synthetic_protocol_fixture"):
                for source in sorted({self._quote_source(self.bindings[i]) for i in self.paired_markets
                                      if self.adapters[i[0]].batch_quotes}):
                    if (sum(inflight.values()) < ACTIVE_BOOKS
                            and inflight.get(source[0], 0) == 0
                            and (request_delay is None or not request_delay((source[1],)))
                            and now - self.quotes.get(source, (-2_000_000_000, {}))[0] >= 2_000_000_000):
                        future = self.executor.submit(self.transport.quote_batch, source)
                        self.quote_pending[source] = future
                        inflight[source[0]] = inflight.get(source[0], 0) + 1
                        futures.append(future)
            edges = {pair: self._quote_edge(pair, now) for pair in self.coverage_routes} if wide else {}
            # A single paired retry can repair skew introduced by a slow book response.
            # Subsequent attempts resume their normal position in the rotation.
            retries = {pair for pair in self.round_remaining - self.skew_retried
                       if pair in self.attempted
                       and all(self.workers.get(i) is not None and i not in self.pending
                               and i in self.observations and self.observations[i].continuous for i in pair)
                       and abs(decode_depth_snapshot(self.observations[pair[0]].book)["visible_at_ns"]
                               - decode_depth_snapshot(self.observations[pair[1]].book)["visible_at_ns"]) > console.max_skew_ns}
            # Low-edge routes with recent depth yield their repeat poll to other routes.
            routes = [pair for pair, sampled in self.coverage_routes.items()
                      if pair in self.round_remaining or sampled is None or now-sampled >= console.max_age_ns//2
                      or edges.get(pair) is None or edges[pair] > 0]
            routes.sort(key=lambda pair: (pair not in retries, self.attempted.get(pair, -1),
                                          -(edges.get(pair) or 0), pair))
            active = set(self.pending) | {i for i, worker in self.workers.items() if worker is not None}
            protected = set()
            singles = sorted((self.diagnostic_markets | external) - self.paired_markets,
                             key=lambda i: (self.touched.get(i, -1), i))
            for pair in (*routes, *((i,) for i in singles)):
                if warmed is not None and warmed.isdisjoint(pair):
                    continue
                if any(i not in self.workers or i in self.source.unavailable for i in pair):
                    continue
                if any(i in self.pending for i in pair):
                    protected.update(pair)
                    continue
                endpoints = tuple(self._quote_source(self.bindings[i])[1] for i in pair)
                if request_delay is not None and request_delay(endpoints):
                    continue
                warming = [i for i in pair if self.workers[i] is None
                           or self._needs_rotation(self.workers[i])
                           or now >= self.workers[i][2]["next_metadata_ns"]]
                if warming and warmed is not None:
                    continue
                wanted = warming or pair
                if sum(inflight.values()) + len(wanted) > ACTIVE_BOOKS or any(
                        inflight.get(i[0], 0) >= VENUE_CONCURRENCY for i in wanted):
                    continue
                if any(self._quote_source(self.bindings[i]) in self.quote_pending
                       and self._quote_source(self.bindings[i]) not in self.quotes for i in pair):
                    continue
                idle = active - self.pending.keys() - protected - set(pair)
                # Leave room for both legs while either leg is warming.
                needed = max(0, len(active.union(pair)) - ACTIVE_BOOKS)
                if needed > len(idle):
                    continue
                for victim in sorted(idle, key=lambda i: (self.touched.get(i, 0), i))[:needed]:
                    self._close_worker(self.workers[victim])
                    self.workers[victim] = None
                    active.remove(victim)
                protected.update(pair)
                admit = (paired_book_admission(endpoints)
                         if not warming and len(pair) == 2 and paired_book_admission else None)
                if len(pair) == 2 and (not warming or any(i in self.failures for i in warming)):
                    self.dispatch += 1
                    self.attempted[pair] = self.dispatch
                    if not warming and pair in retries:
                        self.skew_retried.add(pair)
                for identity in wanted:
                    active.add(identity)
                    self.touched[identity] = now
                    inflight[identity[0]] = inflight.get(identity[0], 0) + 1
                    args = identity, self.bindings[identity], self.workers[identity]
                    future = (self.executor.submit(self._warm, *args) if warming
                              else self.executor.submit(self._sample, *args, admit))
                    self.pending[identity] = self.generations[identity], future, "warm" if warming else "book"
                    futures.append(future)
            return futures

    def _coverage(self, now, *, advance=False):
        selected = self.coverage_key[2] if self.coverage_key else ()
        routes = self.coverage_routes
        times = {i: decode_depth_snapshot(o.book)["visible_at_ns"] for i, o in self.observations.items()}
        counts = dict(pending=0, pending_depth=0, fresh=0, expired=0, unevaluable=0)
        recent = []
        for pair, sampled in routes.items():
            a, z = (times.get(i) for i in pair)
            books = (a, z) if a is not None and z is not None and all(
                self.observations[i].continuous for i in pair) else None
            if books is not None and abs(a-z) <= self.console.max_skew_ns:
                cutoff = min(a, z)
                if sampled is None or cutoff > sampled:
                    sampled = cutoff
                    if advance:
                        routes[pair] = cutoff
                        if cutoff >= self.round_started_ns:
                            self.round_remaining.discard(pair)
            if any(i in self.failures or i in self.source.unavailable or
                   (i in self.observations and not self.observations[i].continuous) for i in pair):
                state = "unevaluable"
            elif sampled is not None and a is not None and z is not None and min(a, z) == sampled and (
                    0 <= now-sampled < self.console.max_age_ns and abs(a-z) <= self.console.max_skew_ns
                    and all(self.observations[i].continuous and
                            self.observations[i].rules.valid_from_ns <= now < self.observations[i].rules.valid_until_ns for i in pair)):
                state = "fresh"
            elif sampled is not None:
                state = "expired"
            elif a is not None and z is not None:
                state = "unevaluable"
            else:
                edge = self._quote_edge(pair, now)
                state = "pending_depth" if edge is not None and edge > 0 else "pending"
            counts[state] += 1
            recent.append((pair, sampled, state, books))
        if advance and routes and not self.round_remaining:
            self.round_duration_ns = now-self.round_started_ns
            self.completed_rounds += 1
            self.round_started_ns = now
            self.round_remaining = set(routes)
            self.skew_retried.clear()
        recent.sort(key=lambda item: (item[2] != "fresh", -(item[1] or 0), item[0]))
        metrics = dict(selected=len(selected), discovered=len(routes),
            unpaired_markets=len(set(selected) - self.paired_markets),
            backlog=len(self.round_remaining), active=len(self.pending),
            completed_rounds=self.completed_rounds,
            full_round_ns=str(self.round_duration_ns) if self.round_duration_ns is not None else None,
            **counts)
        return metrics, recent[:256]

    def _publish(self):
        # Scope changes and publication serialize on the console lock.
        with self.console.lock:
            if self.console.desired == "running" and not self.console.settings_pending:
                session = self.console.session
                at_ns = self.clock()
                selected_ids = self.console._selected()
                with self.source.lock, self.lock:
                    self._refresh_coverage_scope(self.console._selected(include_unavailable=True), at_ns)
                    _, recent = self._coverage(at_ns, advance=True)
                    pairs, ids = [], set()
                    for pair, _, _, _ in recent:
                        if set(pair) <= selected_ids and len(ids.union(pair)) <= 64:
                            pairs.append(pair)
                            ids.update(pair)
                        if len(pairs) == DISPLAY_PAIRS:
                            break
                    pairs = tuple(pairs)
                    selected_observations = tuple(replace(
                        self.observations[i] if i in self.observations else self._observation(i), market_error=self.failures.get(i))
                        for i in sorted(ids))
                    fresh_ids = (selected_ids - self.paired_markets - self.diagnostic_markets) | {
                        i for i, o in self.observations.items() if o.continuous and
                        0 <= at_ns-decode_depth_snapshot(o.book)["visible_at_ns"] < self.console.max_age_ns}
                    # Archive only evidence for pairs represented by the snapshot.
                    evidence = {str(i): self.evidence[i] for i in sorted(ids) if i in self.evidence}
                    for i in ids:
                        evidence.setdefault(str(i), dict(asset_basis=self._asset_basis(self.bindings[i])))
                plans, failures, versions = self.evaluation.build(
                    tuple(o for o in selected_observations if o.book is not None), at_ns=at_ns,
                    max_age_ns=self.console.max_age_ns, max_skew_ns=self.console.max_skew_ns,
                    bindings=self.bindings, pairs=pairs)
                evidence["evaluation"] = dict(self.evaluation.state, input_versions=versions)
                self.cursor += 1
                self.console.publish(session, self.cursor, selected_observations, plans, at_ns=at_ns,
                    evidence=evidence, plan_failures=failures, input_versions=versions, fx_rate=self._fx_rate(at_ns),
                    pairs=pairs, fresh_ids=fresh_ids)

    def status(self):
        observations = []
        with self.console.lock, self.source.lock, self.lock:
            coverage = None
            if self.console.desired == "running" and not self.console.settings_pending:
                now = self.clock()
                self._refresh_coverage_scope(self.console._selected(include_unavailable=True), now)
                coverage, recent = self._coverage(now)
                coverage["routes"] = [dict(pair=[list(map(str, i)) for i in pair], status=state,
                    book_times_ns=list(map(str, books)) if books is not None else None,
                    sampled_at_ns=str(sampled) if sampled is not None else None,
                    sample_age_ms=(now-sampled)//1_000_000 if sampled is not None else None)
                    for pair, sampled, state, books in recent]
            scales = {int(a["identity"]): a["atomic_scale"] for a in self.source.assets}
            bases = {identity: row.get("asset_basis") for identity, row in self.evidence.items()}
            active = {i for i, worker in self.workers.items() if worker is not None} | set(self.pending)
            visible = sorted(active)
            books = [(i, self.observations[i]) for i in visible if i in self.observations]
            evidence = [self.evidence[i] for i in visible if i in self.evidence]
            failures = {str(k): v for k, v in self.failures.items()}
        for identity, o in books:
            book = decode_depth_snapshot(o.book)
            ratio = lambda value: [str(value.numerator), str(value.denominator)]
            scale = scales[o.rules.base_asset]
            healthy = o.continuous and self.clock()-book["visible_at_ns"] < self.console.max_age_ns
            observations.append(dict(venue=str(o.venue), account=str(o.account), instrument=str(o.rules.instrument), environment=o.environment,
                base_asset=str(o.rules.base_asset), quote_asset=str(o.rules.quote_asset), continuous=healthy,
                asset_basis=bases.get(identity),
                bid_quote_atoms=ratio(book["bids"][0][0]*o.rules.tick_quote_atoms_per_base_atom*10**scale),
                ask_quote_atoms=ratio(book["asks"][0][0]*o.rules.tick_quote_atoms_per_base_atom*10**scale),
                bid_depth_atoms=ratio(sum(o.rules.notional(t,l) for t,l in book["bids"])) if all(l is not None for _,l in book["bids"]) else None,
                ask_depth_atoms=ratio(sum(o.rules.notional(t,l) for t,l in book["asks"])) if all(l is not None for _,l in book["asks"]) else None,
                bid_levels=len(book["bids"]), ask_levels=len(book["asks"]),
                truncated=book["bids_truncated"] or book["asks_truncated"],
                visible_at_ns=str(book["visible_at_ns"]), rules_version=str(o.rules.version)))
        return dict(discovery=copy.deepcopy(self.discovery_status), active_subscriptions=len(active), coverage=coverage, routes=[
                        dict(venue=str(adapter.venue), requested_environment=environment, actual_environment=actual,
                             endpoint=url, products=list(adapter.products))
                        for adapter in self.adapters.values() for environment, (url, actual) in adapter.routes.items()],
                    failures=failures, observations=observations,
                    evidence=evidence, trading_qualified=False,
                    capture_storage=self.segments.status(),
                    evaluation=copy.deepcopy(self.evaluation.state),
                    missing_evaluation=list(self.evaluation.state["missing"]))

    def _run(self):
        while not self.closing.wait(.5) and not self.console.shutdown.is_set():
            try:
                self.step(blocking=False)
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
        self.executor.shutdown(wait=True)
        with self.poll_lock:
            self._collect_samples()
            for identity in tuple(self.workers):
                self.release(identity)
        self.segments.close()
