"""Public REST polling -> native MarketFeedAdapter -> canonical depth -> scanner.

Only the public transport is replaceable. No credentials or execution capability.
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
from strategy_instance import NativeAuthority

ROOT = Path(__file__).resolve().parents[2]
MAX_FRAME = 120 * 1024
MAX_CATALOGUE = 8192
MAX_DISCOVERY_BYTES = 4 * 1024 * 1024
MAX_HL_METADATA_BYTES = 1024 * 1024
ROUTES = {
    (1, "production"): ("https://www.okx.com", "production"),
    (1, "demo"): ("https://www.okx.com", "production"),
    (21, "production"): ("https://api.hyperliquid.xyz", "production"),
    (21, "testnet"): ("https://api.hyperliquid-testnet.xyz", "testnet"),
}
OKX = {"BTC-USDC": (0x4f4b5800000003, "btc_usdc_spot", "spot"),
       "BTC-USDT": (0x4f4b5800000001, "btc_usdt_spot", "spot"),
       "BTC-USDT-SWAP": (0x4f4b5800000002, "btc_usdt_swap", "linear")}


class PublicTransport:
    def request(self, url, body=None, *, max_bytes=MAX_FRAME):
        data = None if body is None else json.dumps(body, separators=(",", ":")).encode()
        request = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=3) as response:
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
    def __init__(self, directory, configuration, *, transport=None, clock=time.monotonic_ns,
                 utc_clock=time.time_ns, automatic=True):
        if configuration.get("schema") != 1 or set(configuration) != {"schema", "assets", "bindings"}:
            raise ValueError("scanner market configuration schema")
        bindings = configuration["bindings"]
        if type(bindings) is not list or not 0 <= len(bindings) <= MAX_CATALOGUE:
            raise ValueError("scanner market binding capacity")
        self.directory = Path(directory).resolve()
        self.directory.mkdir(parents=True, exist_ok=True)
        self.clock, self.utc_clock, self.transport = clock, utc_clock, transport or PublicTransport()
        self.lock = threading.RLock()
        self.poll_lock = threading.Lock()
        self.bindings, entries = {}, []
        self.discovery_status, self.discovery_threads = {}, []
        self.discovery_lock = threading.Lock()
        cache = self.directory / "scanner-discovery.json"
        if cache.is_file():
            if cache.stat().st_size > MAX_DISCOVERY_BYTES:
                raise ValueError("saved discovery capacity")
            saved = json.loads(cache.read_text(encoding="utf-8"), object_pairs_hook=_object)
            if saved.get("schema") != 1 or set(saved) != {"schema", "assets", "bindings", "sources"}:
                raise ValueError("saved discovery schema")
            configured_identities = {(b["venue"], int(b["observation_identity"]), int(b["instrument"])) for b in bindings}
            configuration = dict(schema=1, assets=configuration["assets"] + [a for a in saved["assets"] if a["identity"] not in {x["identity"] for x in configuration["assets"]}],
                bindings=bindings + [b for b in saved["bindings"] if (b["venue"], int(b["observation_identity"]), int(b["instrument"])) not in configured_identities])
            bindings = configuration["bindings"]
            self.discovery_status = saved["sources"]
            if len(bindings) > MAX_CATALOGUE:
                raise ValueError("saved discovery binding capacity")
        assets = {int(a["identity"]): a for a in configuration["assets"]}
        for row in bindings:
            venue, environment = row["venue"], row["environment"]
            if (venue, environment) not in ROUTES:
                raise ValueError("unsupported venue/environment; Hyperliquid uses testnet, not demo")
            if venue == 1 and "okx_binding" not in row:
                instrument, _, product = OKX.get(row["symbol"], (None, None, None))
                if (instrument, product) != (int(row["instrument"]), row["product"]):
                    raise ValueError("unsupported OKX instrument/product")
            elif venue == 21 and (row["product"] != "linear" or row["symbol"] != row["binding"]["coin"]):
                raise ValueError("Hyperliquid supports configured standard linear perpetuals only")
            base, quote = int(row["base_asset"]), int(row["quote_asset"])
            if base not in assets or quote not in assets:
                raise ValueError("missing trusted asset definition")
            if (venue == 1 and assets[quote]["code"] != row["symbol"].split("-")[1]
                    or venue == 21 and assets[quote]["code"] != ("USDT" if "hl_discovered" in row else "USDC")):
                raise ValueError("settlement/quote asset mismatch")
            if assets[base]["code"] != (row["symbol"].split("-")[0] if venue == 1 else row["symbol"]):
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
                if row.get("hl_discovered") and (int(row["settlement_asset"]) not in assets or assets[int(row["settlement_asset"])]["code"] != "USDC"):
                    raise ValueError("Hyperliquid settlement asset mismatch")
            entry = self._entry(row, assets)
            if entry.identity in self.bindings:
                raise ValueError("duplicate scanner binding")
            self.bindings[entry.identity] = dict(row)
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

    def request_discovery(self, setting):
        key = setting["venue"] + ":" + setting["environment"]
        if (setting["type"], setting["venue"]) not in (("okx", "1"), ("hyperliquid", "21")):
            raise ValueError("unsupported discovery source")
        with self.lock:
            if key in self.discovery_status and self.discovery_status[key]["state"] != "failed":
                return
            self.discovery_status[key] = dict(state="loading", error="")
            thread = threading.Thread(target=self.discover, args=(dict(setting),), daemon=True, name=setting["type"]+"-catalogue")
            self.discovery_threads.append(thread)
            thread.start()

    def discover(self, setting):
        """Explicit settings action; discovery never acquires a market subscription."""
        key = setting["venue"] + ":" + setting["environment"]
        if (setting["type"], setting["venue"]) not in (("okx", "1"), ("hyperliquid", "21")) or (int(setting["venue"]), setting["environment"]) not in ROUTES:
            raise ValueError("unsupported discovery setting")
        with self.discovery_lock:
            with self.lock:
                self.discovery_status[key] = dict(state="loading", error="")
            try:
                rows, rejected, evidence = [], [], []
                assets_by_id = {a["identity"]: a for a in self.source.assets}
                hl_assets = {r[field] for r in self.bindings.values() if r.get("hl_discovered")
                    for field in ("base_asset", "quote_asset", "settlement_asset")}
                okx_assets = {a["code"]: a for a in self.source.assets if a["identity"] not in hl_assets}
                for product in (("spot", "linear") if setting["type"] == "okx" else ("linear",)):
                    if self.closing.is_set():
                        return
                    row = dict(venue=int(setting["venue"]), product=product, environment=setting["environment"], symbol="BTC-USDT" if setting["type"] == "okx" else "",
                        instrument=str(OKX["BTC-USDT"][0] if setting["type"] == "okx" else self._stable_id("scanner-catalogue-v1", key)),
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
                        for code in (item["base"], item["quote"]):
                            if code not in okx_assets:
                                # Observation-only fixed precision, independent of core AssetDefinition.
                                identity = str(self._stable_id("scanner-asset-v1", code))
                                assets_by_id[identity] = okx_assets[code] = dict(identity=identity, code=code, atomic_scale=18)
                        instrument = OKX[item["symbol"]][0] if item["symbol"] in OKX else self._stable_id("okx-instrument-v1", item["symbol"])
                        version = self._stable_id("okx-rules-v1", json.dumps(item, sort_keys=True, separators=(",", ":"))) & ((1<<53)-1) or 1
                        lot_base = Fraction(item["lot"]) * Fraction(item["contract_value"] or "1")
                        if (lot_base * 10**18).denominator != 1:
                            rejected.append(dict(symbol=item["symbol"], reason="UnsupportedDecimalUnits")); continue
                        previous = next((r for r in self.bindings.values() if (r["venue"], r["environment"], r["symbol"]) ==
                                         (1, setting["environment"], item["symbol"])), None)
                        observation_identity = previous["observation_identity"] if previous else str(self._stable_id("scanner-source-v1", key))
                        rows.append(dict(venue=1, environment=setting["environment"], symbol=item["symbol"], product=product,
                            instrument=str(instrument), observation_identity=observation_identity, rules_version=version,
                            base_asset=okx_assets[item["base"]]["identity"], quote_asset=okx_assets[item["quote"]]["identity"],
                            tick=item["tick"], lot_wire=item["lot"], lot_base=str(lot_base), minimum_size=item["minimum_size"], contract_value=item["contract_value"], specification=item,
                            okx_binding=dict(symbol=item["symbol"], instrument=instrument, product=product, base=item["base"], quote=item["quote"])))
                assets = list(assets_by_id.values())
                asset_definitions = {int(a["identity"]): a for a in assets}
                entries = [self._entry(row, asset_definitions) for row in rows]
                if len({e.identity for e in entries}) != len(entries):
                    raise ValueError("duplicate catalogue identity")
                if not entries:
                    raise ValueError("catalogue has no usable instruments: " + str(rejected[:8]))
                with self.console.lock, self.source.lock, self.lock:
                    if self.closing.is_set():
                        return
                    updated = dict(self.bindings)
                    updated.update((entry.identity, row) for entry, row in zip(entries, rows))
                    if len(updated) > MAX_CATALOGUE:
                        raise ValueError("scanner catalogue capacity")
                    state = dict(state="ready", error="", rejected=rejected, evidence=evidence)
                    sources = {k:v for k,v in self.discovery_status.items() if v["state"] == "ready"}
                    sources[key] = state
                    atomic_json(self.directory/"scanner-discovery.json", dict(schema=1, assets=assets,
                        bindings=[r for r in updated.values() if "okx_binding" in r or "hl_discovered" in r], sources=sources), MAX_DISCOVERY_BYTES)
                    self.source.register(entries)
                    self.bindings, self.source.assets = updated, assets
                    self.discovery_status[key] = state
            except (OSError, ValueError, KeyError, TypeError) as error:
                with self.lock:
                    self.discovery_status[key] = dict(state="failed", error=str(error)[:2048], evidence=evidence, rejected=rejected)

    def _hyperliquid_row(self, setting, item, assets):
        key = "21:" + setting["environment"]
        coin = item["coin"]
        # Protocol coin identity is scoped to the standard perp namespace and environment.
        def asset(role, code):
            identity = str(self._stable_id("hyperliquid-observation-asset-v1", key+":"+role+":"+code))
            assets[identity] = dict(identity=identity, code=code, atomic_scale=18)
            return identity
        base, quote, settlement = asset("perp", coin), asset("price-denomination", "USDT"), asset("collateral-0", "USDC")
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
            specification=dict(item, product="linear", quote="USDT", settlement="USDC", collateral_token=0,
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
            if "okx_binding" in row:
                config["okx_binding"] = row["okx_binding"]
                config["okx_specification"] = row.get("specification")
            else:
                config["okx_instrument"] = OKX[row["symbol"]][1]
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
        with self.poll_lock:
            self._step()

    def _step(self):
        """One bounded poll; deterministic transport/clock may drive this in acceptance."""
        with self.lock:
            selected = tuple(self.workers.items())
        for identity, worker in selected:
            with self.lock:
                if identity in self.blocked or identity not in self.workers or self.workers[identity] is not worker:
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
            if self.console.desired == "running":
                self.console.publish(self.console.session, cursor, observations, (), at_ns=self.clock(), evidence=evidence)

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
                    missing_evaluation=["research_plan", "model", "calibration", "fees"])

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
