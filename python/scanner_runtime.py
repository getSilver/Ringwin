"""Public REST polling -> native MarketFeedAdapter -> canonical depth -> scanner.

Only the public transport is replaceable. No credentials or execution capability.
"""
from dataclasses import replace
from fractions import Fraction
import json
import os
from pathlib import Path
import secrets
import subprocess
import threading
import time
import urllib.request

import arbitrage_economics as economics
from arbitrage_scanner import Observation, decode_depth_snapshot
from scanner_console import CanonicalSource, CatalogueEntry, ScannerConsole
from scanner_history import History
from strategy_instance import NativeAuthority

ROOT = Path(__file__).resolve().parents[1]
MAX_FRAME = 120 * 1024
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
    def request(self, url, body=None):
        data = None if body is None else json.dumps(body, separators=(",", ":")).encode()
        request = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=3) as response:
            payload = response.read(MAX_FRAME + 1)
        if len(payload) > MAX_FRAME:
            raise ValueError("public transport capacity exceeded")
        return payload.decode("utf-8")

    def metadata(self, binding):
        base, _ = ROUTES[binding["venue"], binding["environment"]]
        if binding["venue"] == 1:
            kind = "SPOT" if binding["product"] == "spot" else "SWAP"
            return self.request(base + "/api/v5/public/instruments?instType=" + kind + "&instId=" + binding["symbol"])
        return self.request(base + "/info", {"type": "meta"})

    def book(self, binding):
        base, _ = ROUTES[binding["venue"], binding["environment"]]
        if binding["venue"] == 1:
            return self.request(base + "/api/v5/market/books?instId=" + binding["symbol"] + "&sz=5")
        return self.request(base + "/info", {"type": "l2Book", "coin": binding["symbol"]})


class ScannerRuntime:
    def __init__(self, directory, configuration, *, transport=None, clock=time.monotonic_ns,
                 utc_clock=time.time_ns, automatic=True):
        if configuration.get("schema") != 1 or set(configuration) != {"schema", "assets", "bindings"}:
            raise ValueError("scanner market configuration schema")
        bindings = configuration["bindings"]
        if type(bindings) is not list or not 1 <= len(bindings) <= 16:
            raise ValueError("scanner market binding capacity")
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.clock, self.utc_clock, self.transport = clock, utc_clock, transport or PublicTransport()
        self.lock = threading.RLock()
        self.bindings, entries = {}, []
        assets = {int(a["identity"]): a for a in configuration["assets"]}
        for row in bindings:
            venue, environment = row["venue"], row["environment"]
            if (venue, environment) not in ROUTES:
                raise ValueError("unsupported venue/environment; Hyperliquid uses testnet, not demo")
            if venue == 1:
                instrument, _, product = OKX.get(row["symbol"], (None, None, None))
                if (instrument, product) != (int(row["instrument"]), row["product"]):
                    raise ValueError("unsupported OKX instrument/product")
            elif row["product"] != "linear" or row["symbol"] != row["binding"]["coin"]:
                raise ValueError("Hyperliquid supports configured standard linear perpetuals only")
            base, quote = int(row["base_asset"]), int(row["quote_asset"])
            if base not in assets or quote not in assets:
                raise ValueError("missing trusted asset definition")
            if (venue == 1 and assets[quote]["code"] != ("USDC" if row["symbol"] == "BTC-USDC" else "USDT")
                    or venue == 21 and assets[quote]["code"] != "USDC"):
                raise ValueError("settlement/quote asset mismatch")
            if assets[base]["code"] != row["symbol"].split("-")[0]:
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
            rules = economics.InstrumentRules(int(row["instrument"]), row["rules_version"], base, quote,
                tick * Fraction(10**assets[quote]["atomic_scale"], 10**assets[base]["atomic_scale"]),
                lot * 10**assets[base]["atomic_scale"], 1, 0, 0, (1<<64)-1)
            entry = CatalogueEntry(venue, int(row["observation_identity"]), row["product"], rules, environment)
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

    def acquire(self, identity):
        # Source owns subscription serialization. Network work occurs outside its lock.
        with self.lock:
            if identity not in self.workers:
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

    def _open(self, identity):
        row = self.bindings[identity]
        session = secrets.randbelow((1<<53)-1)+1
        if sum(p.stat().st_size for p in self.directory.glob("market-*.raw")) >= 64 * 1024 * 1024:
            raise OSError("scanner RawIngress capacity exhausted; archive files before restarting")
        path = self.directory / ("market-" + secrets.token_hex(16) + ".raw")
        executable = ROOT/"zig-out/bin"/("ringwin-scanner-market.exe" if os.name == "nt" else "ringwin-scanner-market")
        process = subprocess.Popen([str(executable), str(path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        channel = NativeAuthority(process, timeout=5)
        config = dict(schema=1, session=session, venue=row["venue"], environment=ROUTES[row["venue"], row["environment"]][1],
            instrument=int(row["instrument"]), rules_version=row["rules_version"], tick=row["tick"], lot=row["lot_wire"])
        config["raw_budget_bytes"] = row.get("raw_budget_bytes", 4*1024*1024)
        if row["venue"] == 1:
            config["okx_instrument"] = OKX[row["symbol"]][1]
            config["contract_value"] = row.get("contract_value")
        else:
            config["binding"] = row["binding"]
        try:
            channel.request(config)
        except Exception:
            self._close_worker((process, channel, None, None))
            raise
        return process, channel, dict(session=session, sequence=0, epoch=0, next_metadata_ns=0), str(path)

    def _input(self, worker, operation, payload):
        _, channel, state, _ = worker
        if len(payload.encode()) > MAX_FRAME:
            raise ValueError("public frame capacity")
        state["sequence"] += 1
        request = dict(schema=1, session=state["session"], sequence=state["sequence"], epoch=state["epoch"], operation=operation, payload=payload,
                       monotonic_ns=self.clock(), utc_ns=self.utc_clock())
        result = channel.request(request)
        if (result.get("schema"), result.get("session"), result.get("sequence")) != (1, state["session"], state["sequence"]):
            raise ValueError("native market response identity")
        return result

    def step(self):
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
                    self.evidence[identity] = dict(result, raw_path=worker[3], requested_environment=row["environment"],
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
        return dict(active_subscriptions=len(self.workers), routes=[dict(venue=str(v), requested_environment=e, actual_environment=a, endpoint=url,
                                products=["spot", "linear"] if v == 1 else ["linear"])
                            for (v, e), (url, a) in ROUTES.items()],
                    failures={str(k): v for k, v in self.failures.copy().items()}, observations=observations,
                    evidence=list(self.evidence.copy().values()), trading_qualified=False,
                    missing_evaluation=["research_plan", "model", "calibration", "fees"])

    def _run(self):
        while not self.closing.wait(.5):
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
        if self.thread:
            self.thread.join(timeout=20)
            if self.thread.is_alive():
                raise OSError("public scanner worker did not stop")
        for identity in tuple(self.workers):
            self.release(identity)
