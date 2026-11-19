"""Real HTTP -> control plane -> native adapters/projection -> scan.

Synthetic protocol fixtures replace only the external public transport.
"""
import http.client
import json
from fractions import Fraction
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

import control_plane
import control_plane_web
import owner_session
from opportunity_scanner.scanner_runtime import ScannerRuntime as PublicScannerRuntime, PublicTransport


def registered_assets():
    """Explicit activated-registry fixture, not inferred from discovery names."""
    rows = []
    for index, code in enumerate(("USDT", "USDC", "BTC", "ETH", "SOL", "DOGE", "HYPE", "PURR"), 1):
        for venue, environments in (("1", ("production", "demo")), ("21", ("production", "testnet"))):
            for environment in environments:
                rows.append(dict(asset=str(index), atomic_scale=8, version="1", barrier="10",
                    source_identity="100", source_digest="ab"*32, source_kind="test_fixture", venue=venue,
                    environment=environment, code=code))
    return dict(schema=1, bindings=rows)


class ScannerRuntime(PublicScannerRuntime):
    def __init__(self, *args, **kwargs):
        kwargs.setdefault("asset_provider", registered_assets)
        super().__init__(*args, **kwargs)


class PublicTransportTests(unittest.TestCase):
    def test_public_requests_omit_user_agent_on_the_wire(self):
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        captured = []

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                captured.append((self.command, self.headers.get("User-Agent"),
                    self.rfile.read(int(self.headers.get("Content-Length", "0")))))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{"code":"0"}')

            do_POST = do_GET

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            transport = PublicTransport()
            url = f"http://127.0.0.1:{server.server_port}/public"
            self.assertEqual(json.loads(transport.request(url)), {"code": "0"})
            self.assertEqual(json.loads(transport.request(url, {"type": "meta"})), {"code": "0"})
            self.assertEqual(captured, [("GET", None, b""), ("POST", None, b'{"type":"meta"}')])
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)


class DynamicOkxTransport(PublicTransport):
    input_kind = "synthetic_protocol_fixture"

    def __init__(self, now):
        self.now, self.urls = now, []

    def request(self, url, body=None, **kwargs):
        self.urls.append(url)
        if "/instruments?" in url:
            linear = "instType=SWAP" in url
            row = dict(instId="ETH-USDT-SWAP" if linear else "ETH-USDT", instType="SWAP" if linear else "SPOT",
                baseCcy="" if linear else "ETH", quoteCcy="" if linear else "USDT", ctType="linear" if linear else "",
                ctVal="0.1" if linear else "", ctMult="1" if linear else "", ctValCcy="ETH" if linear else "", settleCcy="USDT" if linear else "",
                state="live", ruleType="normal", tickSz="0.01", lotSz="1" if linear else "0.001", minSz="1" if linear else "0.001", tradeQuoteCcyList=[], upcChg=[])
            return json.dumps(dict(code="0", data=[row]))
        return json.dumps(dict(code="0", data=[dict(seqId=self.now[0], ts=str(self.now[1]//1_000_000),
            bids=[["3000.00", "2", "0", "1"]], asks=[["3000.01", "3", "0", "1"]])]))


class DynamicHyperliquidTransport(PublicTransport):
    input_kind = "synthetic_protocol_fixture"

    def __init__(self, now):
        self.now, self.requests = now, []
        self.metadata_document = dict(collateralToken=0, universe=[dict(name="ETH", szDecimals=4, maxLeverage=25, marginTableId=53)],
            marginTables=[[53, dict(marginTiers=[dict(lowerBound="0", maxLeverage=25)])]])

    def request(self, url, body=None, **kwargs):
        self.requests.append((url, body))
        if body == {"type": "meta"}:
            return json.dumps(self.metadata_document)
        if body == {"type": "l2Book", "coin": "ETH"}:
            return json.dumps(dict(coin="ETH", time=self.now[1]//1_000_000,
                levels=[[dict(px="3000", sz="2.0001", n=1)], [dict(px="3000.1", sz="3", n=1)]]))
        raise ValueError("unexpected public request")


class ProtocolTransport(PublicTransport):
    """Two dynamic sources; faults change only public protocol input."""
    input_kind = "synthetic_protocol_fixture"

    def __init__(self, clock):
        self.clock = clock
        self.coin = "ETH"
        self.requests = []
        self.okx = DynamicOkxTransport(clock)
        self.hl = DynamicHyperliquidTransport(clock)
        self.fail, self.captured = set(), {}
        self.bad_rules = self.stale = self.oversize = self.replay = False

    def request(self, url, body=None, **kwargs):
        venue = 21 if body else 1
        self.requests.append((url, body))
        if venue in self.fail:
            raise OSError("synthetic transport disconnected")
        if body and body.get("coin") == self.coin:
            body = dict(body, coin="ETH")
        return (self.hl if venue == 21 else self.okx).request(url.replace(self.coin, "ETH"), body, **kwargs).replace("ETH", self.coin)

    def metadata(self, binding):
        value = json.loads(super().metadata(binding))
        if self.bad_rules and binding["venue"] == 1:
            value["data"][0]["tickSz"] = "0.2"
        return json.dumps(value)

    def book(self, binding):
        venue = binding["venue"]
        if venue in self.fail:
            raise OSError("synthetic transport disconnected")
        if self.replay:
            return self.captured[venue]
        if self.oversize:
            return "x" * (130*1024 if venue == 1 else 1024*1024+1)
        value = json.loads(super().book(binding))
        if self.stale:
            if venue == 1:
                value["data"][0]["ts"] = str(int(value["data"][0]["ts"]) - 60000)
            else:
                value["time"] -= 60000
        payload = json.dumps(value)
        self.captured[venue] = payload
        return payload



def scope(venue, environment="production"):
    return dict(venue=str(venue), product="spot" if venue == 1 else "linear", environment=environment,
        include_assets=[], exclude_assets=[], quote_asset=None, min_depth_atoms=None,max_depth_atoms=None,new_instruments=False)


class RefreshTransport(PublicTransport):
    """Mutable full-snapshot protocol input for lifecycle acceptance."""
    input_kind = "synthetic_protocol_fixture"

    def __init__(self, now, hyperliquid=False):
        self.base = DynamicHyperliquidTransport(now) if hyperliquid else DynamicOkxTransport(now)
        self.hyperliquid, self.mode = hyperliquid, "initial"

    def request(self, url, body=None, **kwargs):
        if self.mode == "failed":
            raise OSError("synthetic catalogue disconnected")
        if self.hyperliquid and body == {"type":"l2Book", "coin":"SOL"}:
            value = json.loads(self.base.request(url, dict(type="l2Book", coin="ETH"), **kwargs))
            value["coin"] = "SOL"
            return json.dumps(value)
        value = json.loads(self.base.request(url, body, **kwargs))
        metadata = body == {"type":"meta"} if self.hyperliquid else "/instruments?" in url
        if self.hyperliquid and not metadata and self.mode == "rules":
            value["levels"][0][0]["sz"] = "2.001"
        if metadata:
            field = "universe" if self.hyperliquid else "data"
            if self.mode == "capacity":
                value[field] *= 4097
            elif self.mode == "gone":
                value[field] = []
            else:
                if self.mode == "rules":
                    value[field][0]["szDecimals" if self.hyperliquid else "tickSz"] = 3 if self.hyperliquid else "0.001"
                if self.mode == "added":
                    row = dict(value[field][0])
                    if self.hyperliquid:
                        row["name"] = "SOL"
                    else:
                        row["instId"] = row["instId"].replace("ETH", "SOL")
                        row["ctValCcy" if row["instType"] == "SWAP" else "baseCcy"] = "SOL"
                    value[field].append(row)
                if not self.hyperliquid and "&instId=" in url:
                    value[field] = [r for r in value[field] if r["instId"] == url.split("&instId=")[1]]
        return json.dumps(value)


class DynamicCatalogueTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.now = [2_000_000_000, 1_800_000_000_000_000_000]
        self.transport = DynamicOkxTransport(self.now)
        self.runtime = ScannerRuntime(self.temp.name, transport=self.transport,
            clock=lambda:self.now[0], utc_clock=lambda:self.now[1], automatic=False)
        self.addCleanup(self.runtime.close)
        self.setting = dict(identity="a"*32, venue="1", type="okx", name="我的 OKX", environment="demo")

    def test_removed_setting_discards_inflight_catalogue_before_cache_commit(self):
        from opportunity_scanner.exchange_settings import ExchangeSettings
        store = ExchangeSettings(Path(self.temp.name)/"exchange-settings.json")
        setting = store.save(dict(expected_version="0", type="okx", name="目录来源", environment="demo"))["exchanges"][0]
        self.runtime.console.exchange_settings = store
        entered, released = threading.Event(), threading.Event()
        original = self.transport.request
        def delayed(*args, **kwargs):
            entered.set()
            if not released.wait(10):
                raise OSError("test catalogue release missing")
            return original(*args, **kwargs)
        self.transport.request = delayed
        self.runtime.request_discovery(setting)
        try:
            self.assertTrue(entered.wait(5))
            store.save(dict(expected_version="1", identity=setting["identity"], operation="delete"))
            self.runtime.settings_changed([setting], [])
        finally:
            released.set()
            for thread in self.runtime.discovery_threads:
                thread.join(timeout=10)
                self.assertFalse(thread.is_alive())
        self.assertEqual(self.runtime.source.registered, {})
        self.assertNotIn("1:demo", self.runtime.discovery_status)
        self.assertFalse((Path(self.temp.name)/"scanner-discovery.json").exists())

    def test_refresh_retires_disappeared_inputs_and_rewarms_changed_rules(self):
        self.runtime.discover(self.setting)
        console = self.runtime.console
        console.configure(dict(expected_version="0", scopes=[dict(scope(1, "demo"), quote_asset=None)]))
        console.start()
        self.runtime.step()
        identity, = self.runtime.workers
        old = self.runtime.workers[identity]
        original = self.transport.request
        mode = ["changed"]
        def response(url, *args, **kwargs):
            value = json.loads(original(url, *args, **kwargs))
            if "/instruments?" in url:
                if mode[0] == "gone" and "SPOT" in url:
                    value["data"] = []
                elif mode[0] == "changed":
                    value["data"][0]["tickSz"] = "0.001"
            return json.dumps(value)
        self.transport.request = response
        self.runtime.discover(self.setting)
        self.assertNotIn(identity, self.runtime.observations)
        self.assertIsNone(self.runtime.workers[identity])
        self.assertIsNotNone(old[0].poll())
        self.assertIn(identity, console.warming)
        self.runtime.step()
        self.assertTrue(self.runtime.status()["observations"][0]["continuous"])
        mode[0] = "gone"
        self.runtime.discover(self.setting)
        self.assertNotIn(identity, self.runtime.source.registered)
        self.assertNotIn(identity, self.runtime.workers)
        self.assertFalse(console.view()["snapshot"]["candidates"])

    def test_periodic_refresh_ttl_and_other_consumer_ownership(self):
        transport = RefreshTransport(self.now)
        self.runtime.transport = transport
        self.runtime.discover(self.setting)
        console = self.runtime.console
        console.configure(dict(expected_version="0", scopes=[dict(scope(1, "demo"), quote_asset=None, new_instruments=True)]))
        console.start(); self.runtime.step()
        original = set(self.runtime.workers)
        self.runtime.source.acquire("other-consumer", original)
        transport.mode = "added"
        self.now[0] += 30_000_000_000; self.now[1] += 30_000_000_000
        self.runtime.step()
        for thread in self.runtime.discovery_threads:
            thread.join(timeout=20)
            self.assertFalse(thread.is_alive())
        self.assertEqual(len(self.runtime.workers), 2)
        self.assertEqual(self.runtime.source.owners["other-consumer"], original)
        # A stalled metadata request must not keep old inputs alive beyond TTL.
        entered, resume = threading.Event(), threading.Event()
        catalogue = transport.catalogue
        def stalled(*args):
            entered.set()
            if not resume.wait(20): raise OSError("fixture timeout")
            return catalogue(*args)
        transport.catalogue = stalled
        self.now[0] += 30_000_000_000; self.now[1] += 30_000_000_000
        self.runtime.step()
        self.assertTrue(entered.wait(5))
        try:
            self.now[0] += 90_000_000_000; self.now[1] += 90_000_000_000
            self.runtime.step()
            view = console.view()
            self.assertEqual(view["market"]["observations"], [])
            self.assertIn("TTL", view["market"]["discovery"]["1:demo"]["error"])
            self.assertEqual(self.runtime.source.owners["other-consumer"], original)
        finally:
            resume.set()
            for thread in self.runtime.discovery_threads: thread.join(timeout=20)
        self.runtime.step()
        self.assertTrue(all(o["continuous"] for o in console.view()["market"]["observations"]))
        console.stop()
        self.assertEqual(set(self.runtime.workers), original)
        self.runtime.source.release("other-consumer")
        self.assertEqual(self.runtime.workers, {})

    def test_subscription_capacity_never_leaves_partial_healthy_coverage(self):
        self.runtime.discover(self.setting)
        console = self.runtime.console
        console.configure(dict(expected_version="0", scopes=[dict(scope(1, "demo"), quote_asset=None, new_instruments=True)]))
        console.start(); self.runtime.step()
        original = self.transport.request
        def large(url, *args, **kwargs):
            value = json.loads(original(url, *args, **kwargs))
            if "/instruments?" in url and "&instId=" not in url:
                row = value["data"][0]
                value["data"] = [dict(row, instId=row["instId"].replace("ETH", "TOKEN"+str(i)),
                    **{"ctValCcy" if row["instType"] == "SWAP" else "baseCcy": "TOKEN"+str(i)}) for i in range(17)]
            return json.dumps(value)
        self.transport.request = large
        self.runtime.discover(self.setting)
        state = self.runtime.status()["discovery"]["1:demo"]
        self.assertEqual(state["state"], "failed")
        self.assertIn("subscription capacity", state["error"])
        self.assertFalse(state["complete"])
        self.assertEqual(self.runtime.observations, {})
        self.assertEqual(self.runtime.workers, {})
        self.assertEqual(self.runtime.source.owners[console.session], set())

    def test_returning_other_consumer_subscription_cannot_bypass_active_capacity(self):
        self.runtime.discover(self.setting)
        source = self.runtime.source
        original_identity = next(i for i,e in source.registered.items() if e.kind == "spot")
        source.acquire("retained", {original_identity})
        request = self.transport.request
        returning = [False]
        def directory(url, *args, **kwargs):
            value = json.loads(request(url, *args, **kwargs))
            if "/instruments?" in url and "&instId=" not in url:
                template = value["data"][0]
                value["data"] = [] if "SWAP" in url else [dict(template, instId="TOKEN"+str(i)+"-USDT", baseCcy="TOKEN"+str(i)) for i in range(16)]
                if returning[0] and "SPOT" in url:
                    value["data"].append(template)
            return json.dumps(value)
        self.transport.request = directory
        self.runtime.discover(self.setting)
        source.acquire("full", set(source.registered))
        self.assertEqual(len(self.runtime.workers), 16)
        returning[0] = True
        self.runtime.discover(self.setting)
        state = self.runtime.status()["discovery"]["1:demo"]
        self.assertEqual(state["state"], "failed")
        self.assertIn("subscription capacity", state["error"])
        self.assertLessEqual(len(self.runtime.workers), 16)
        self.assertEqual(source.owners["retained"], {original_identity})
        source.release("full")
        self.runtime.discover(self.setting)
        self.assertEqual(set(self.runtime.workers), {original_identity})

    def test_restart_refreshes_cached_bindings_even_without_saved_ready_state(self):
        self.runtime.discover(self.setting)
        cache = Path(self.temp.name, "scanner-discovery.json")
        value = json.loads(cache.read_bytes())
        value["sources"] = {}  # Another source committed while this source was loading/failed.
        cache.write_bytes(json.dumps(value).encode())
        self.runtime.close()
        self.runtime = ScannerRuntime(self.temp.name, transport=self.transport,
            clock=lambda:self.now[0], utc_clock=lambda:self.now[1], automatic=False)
        self.addCleanup(self.runtime.close)
        self.assertEqual(self.runtime.status()["discovery"]["1:demo"]["state"], "unloaded")
        self.assertEqual(self.runtime.workers, {})
        self.runtime.console.configure(dict(expected_version="0", scopes=[dict(scope(1, "demo"), quote_asset=None)]))
        from opportunity_scanner.exchange_settings import ExchangeSettings
        settings = ExchangeSettings(Path(self.temp.name)/"exchange-settings.json")
        settings.save(dict(expected_version="0", type="okx", name="我的 OKX", environment="demo"))
        self.runtime.console.exchange_settings = settings
        self.runtime.console.start()
        self.runtime.step()
        for thread in self.runtime.discovery_threads:
            thread.join(timeout=20)
            self.assertFalse(thread.is_alive())
        self.assertEqual(self.runtime.status()["discovery"]["1:demo"]["state"], "ready", self.runtime.status()["discovery"])

    def test_stopped_restart_and_pause_do_not_refresh_until_start_or_explicit_load(self):
        from opportunity_scanner.exchange_settings import ExchangeSettings
        settings = ExchangeSettings(Path(self.temp.name)/"exchange-settings.json")
        self.setting = settings.save(dict(expected_version="0", type="okx", name="我的 OKX", environment="demo"))["exchanges"][0]
        self.runtime.discover(self.setting)
        self.runtime.console.exchange_settings = settings
        self.runtime.console.configure(dict(expected_version="0", scopes=[dict(scope(1, "demo"), quote_asset=None)]))
        self.runtime.close()
        self.runtime = ScannerRuntime(self.temp.name, transport=self.transport,
            clock=lambda:self.now[0], utc_clock=lambda:self.now[1], automatic=False)
        self.addCleanup(self.runtime.close)
        self.runtime.console.exchange_settings = settings
        requests = len(self.transport.urls)
        self.now[0] += 120_000_000_000; self.now[1] += 120_000_000_000
        self.runtime.step()
        for thread in self.runtime.discovery_threads: thread.join(timeout=20)
        self.assertEqual(self.runtime.console.desired, "stopped")
        self.assertEqual(len(self.transport.urls), requests)
        self.assertEqual(self.runtime.workers, {})
        self.runtime.console.start()
        self.runtime.step()
        for thread in self.runtime.discovery_threads: thread.join(timeout=20)
        self.assertGreater(len(self.transport.urls), requests)
        self.runtime.console.pause()
        requests = len(self.transport.urls)
        self.now[0] += 120_000_000_000; self.now[1] += 120_000_000_000
        self.runtime.step()
        for thread in self.runtime.discovery_threads: thread.join(timeout=20)
        self.assertEqual(len(self.transport.urls), requests)
        # Explicit directory loading remains available while paused.
        self.runtime.discover(self.setting)
        self.assertGreater(len(self.transport.urls), requests)
        identity = next(i for i,e in self.runtime.source.registered.items() if e.kind == "spot")
        self.runtime.source.acquire("other-consumer", {identity})
        requests = sum(url.endswith("instType=SPOT") for url in self.transport.urls)
        self.now[0] += 30_000_000_000; self.now[1] += 30_000_000_000
        self.runtime.step()
        for thread in self.runtime.discovery_threads: thread.join(timeout=20)
        self.assertGreater(sum(url.endswith("instType=SPOT") for url in self.transport.urls), requests)
        self.assertEqual(self.runtime.console.desired, "paused")
        self.assertEqual(self.runtime.source.owners["other-consumer"], {identity})
        self.runtime.source.release("other-consumer")

    def test_unverifiable_contract_units_are_visible_and_never_subscribed(self):
        original = self.transport.request
        def wrong_units(url, *args, **kwargs):
            value = json.loads(original(url, *args, **kwargs))
            if "SWAP" in url:
                value["data"][0]["ctValCcy"] = "BTC"
            return json.dumps(value)
        self.transport.request = wrong_units
        self.runtime.discover(self.setting)
        view = self.runtime.status()
        state = view["discovery"]["1:demo"]
        self.assertEqual(state["state"], "ready", state)
        self.assertEqual(state["rejected"], [dict(symbol="ETH-USDT-SWAP", reason="UnsupportedAssetUnits")])
        self.assertEqual(len(self.runtime.source.registered), 1)
        self.assertEqual(view["active_subscriptions"], 0)
        self.assertTrue(all(e["requested_environment"] == "demo" and e["actual_environment"] == "production" and e["captures"] == 1 for e in state["evidence"]))
        self.assertTrue(all(url.startswith("https://www.okx.com/api/v5/public/instruments?instType=") for url in self.transport.urls))

    def test_large_directory_is_captured_and_duplicate_or_capacity_error_keeps_previous(self):
        original = self.transport.request
        mode = ["large"]
        def response(url, *args, **kwargs):
            value = json.loads(original(url, *args, **kwargs))
            if mode[0] == "large":
                value["padding"] = "x" * (130*1024)
            elif mode[0] == "duplicate":
                value["data"] *= 2
            else:
                value["data"] *= 4097
            return json.dumps(value)
        self.transport.request = response
        self.runtime.discover(self.setting)
        before = set(self.runtime.source.registered)
        self.assertEqual(len(before), 2, self.runtime.status())
        cache = Path(self.temp.name, "scanner-discovery.json").read_bytes()
        self.runtime.discover(self.setting)
        self.assertEqual(set(self.runtime.source.registered), before)
        for error_mode in ("duplicate", "capacity"):
            mode[0] = error_mode
            self.runtime.discover(self.setting)
            self.assertEqual(self.runtime.status()["discovery"]["1:demo"]["state"], "failed")
            self.assertEqual(set(self.runtime.source.registered), before)
        # Failed discovery does not persist a partial catalogue.
        self.assertEqual(set(json.loads(cache)["sources"]), {"1:demo"})
        restored = ScannerRuntime(self.temp.name, transport=self.transport, automatic=False)
        self.addCleanup(restored.close)
        self.assertEqual(set(restored.source.registered), before)
        self.assertEqual(restored.status()["active_subscriptions"], 0)


class HyperliquidCatalogueTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.now = [2_000_000_000, 1_800_000_000_000_000_000]
        self.transport = DynamicHyperliquidTransport(self.now)
        self.runtime = ScannerRuntime(self.temp.name, transport=self.transport,
            clock=lambda:self.now[0], utc_clock=lambda:self.now[1], automatic=False)
        self.addCleanup(self.runtime.close)
        self.setting = dict(identity="b"*32, venue="21", type="hyperliquid", name="永续", environment="production")

    def test_environment_switch_preserves_filters_for_temporarily_missing_assets_after_restart(self):
        from opportunity_scanner.exchange_settings import ExchangeSettings
        store = ExchangeSettings(Path(self.temp.name)/"exchange-settings.json")
        setting = store.save(dict(expected_version="0", type="hyperliquid", name="市场", environment="production"))["exchanges"][0]
        self.runtime.console.exchange_settings = store
        eth = dict(self.transport.metadata_document["universe"][0])
        sol = dict(eth, name="SOL")
        self.transport.metadata_document["universe"] = [eth, sol]
        self.runtime.discover(setting)
        old_sol = next(r["base_asset"] for r in self.runtime.bindings.values() if r["symbol"] == "SOL")
        rows = [dict(scope(21), quote_asset=None, exclude_assets=[old_sol], new_instruments=True)]
        self.runtime.console.configure(dict(expected_version="0", scopes=rows))
        setting = store.save(dict(expected_version="1", identity=setting["identity"], type="hyperliquid",
            name=setting["name"], environment="testnet"))["exchanges"][0]
        self.runtime.console.reconcile_settings()
        self.transport.metadata_document["universe"] = [eth]
        self.runtime.discover(setting)
        excluded = self.runtime.console.config["scopes"][0]["exclude_assets"][0]
        self.runtime.close()
        self.runtime = ScannerRuntime(self.temp.name, transport=self.transport,
            clock=lambda:self.now[0], utc_clock=lambda:self.now[1], automatic=False)
        self.addCleanup(self.runtime.close)
        self.runtime.console.exchange_settings = store
        self.assertEqual(next(a["code"] for a in self.runtime.source.assets if a["identity"] == excluded), "SOL")
        self.transport.metadata_document["universe"] = [eth, sol]
        self.runtime.discover(setting)
        self.runtime.console.start()
        selected = self.runtime.source.owners[self.runtime.console.session]
        self.assertEqual({self.runtime.bindings[i]["symbol"] for i in selected}, {"ETH"})
        target_sol = next(r["base_asset"] for r in self.runtime.bindings.values()
                          if r["symbol"] == "SOL" and r["environment"] == "testnet")
        self.assertEqual(self.runtime.console.config["scopes"][0]["exclude_assets"], [target_sol])
        # The same identity must also retain an explicit include while SOL is absent.
        self.runtime.console.stop()
        self.runtime.console.configure(dict(expected_version=self.runtime.console.config["version"],
            scopes=[dict(scope(21, "testnet"), quote_asset=None, include_assets=[target_sol], new_instruments=True)]))
        setting = store.save(dict(expected_version="2", identity=setting["identity"], type="hyperliquid",
            name=setting["name"], environment="production"))["exchanges"][0]
        self.runtime.console.reconcile_settings()
        self.transport.metadata_document["universe"] = [eth]
        self.runtime.discover(setting)
        self.transport.metadata_document["universe"] = [eth, sol]
        self.runtime.discover(setting)
        self.runtime.console.start()
        selected = self.runtime.source.owners[self.runtime.console.session]
        self.assertEqual({self.runtime.bindings[i]["symbol"] for i in selected}, {"SOL"})

    def test_rejected_metadata_is_visible_and_never_registers_or_subscribes(self):
        original = json.loads(json.dumps(self.transport.metadata_document))
        for mode, reason in (("collateral", "UnsupportedCollateral"), ("precision", "UnsupportedDecimalUnits"),
                ("delisted", "UnsupportedInstrument"), ("margin", "MissingMarginTable"), ("name", "UnsupportedInstrument")):
            with self.subTest(mode=mode):
                document = json.loads(json.dumps(original))
                if mode == "collateral": document["collateralToken"] = 1
                if mode == "precision": document["universe"][0]["szDecimals"] = 7
                if mode == "delisted": document["universe"][0]["isDelisted"] = True
                if mode == "margin": document["marginTables"] = []
                if mode == "name": document["universe"][0]["name"] = "xyz:ETH"
                self.transport.metadata_document = document
                self.runtime.discover(self.setting)
                state = self.runtime.status()["discovery"]["21:production"]
                self.assertEqual(state["state"], "failed", state)
                self.assertEqual(state["rejected"][0]["reason"], reason)
                self.assertEqual(state["evidence"][0]["captures"], 1)
                self.assertEqual(self.runtime.source.registered, {})
                self.assertEqual(self.runtime.status()["active_subscriptions"], 0)

    def test_duplicate_and_capacity_fail_without_replacing_persisted_directory(self):
        self.runtime.discover(self.setting)
        cache = Path(self.temp.name, "scanner-discovery.json").read_bytes()
        identities = set(self.runtime.source.registered)
        for count in (2, 4097):
            self.transport.metadata_document["universe"] = [self.transport.metadata_document["universe"][0]] * count
            self.runtime.discover(self.setting)
            self.assertEqual(self.runtime.status()["discovery"]["21:production"]["state"], "failed")
            self.assertEqual(set(self.runtime.source.registered), identities)
            self.assertEqual(Path(self.temp.name, "scanner-discovery.json").read_bytes(), cache)

    def test_complete_large_metadata_and_reordered_universe_preserve_identity(self):
        self.transport.metadata_document["padding"] = "x" * (300*1024)
        self.transport.metadata_document["universe"].append(dict(name="SOL", szDecimals=2, maxLeverage=25, marginTableId=53))
        self.runtime.discover(self.setting)
        identities = {row["symbol"]: identity for identity, row in self.runtime.bindings.items()}
        self.assertEqual(len(identities), 2, self.runtime.status())
        self.transport.metadata_document["universe"].reverse()
        self.runtime.discover(self.setting)
        self.assertEqual({row["symbol"]: identity for identity, row in self.runtime.bindings.items()}, identities)
        self.runtime.acquire(identities["ETH"])
        self.runtime.step()
        self.assertEqual(self.runtime.status()["failures"], {})
        self.assertTrue(self.runtime.status()["observations"][0]["continuous"])
        self.assertEqual(next(iter(self.runtime.audit().values()))["captures"], 3)

    def previous_isolated_asset_cache(self, *, include_eth=True):
        from opportunity_scanner.exchange_settings import ExchangeSettings
        store = ExchangeSettings(Path(self.temp.name)/"exchange-settings.json")
        self.setting = store.save(dict(expected_version="0", type="hyperliquid", name=self.setting["name"], environment="production"))["exchanges"][0]
        self.runtime.console.exchange_settings = store
        self.runtime.discover(self.setting)
        row = next(iter(self.runtime.bindings.values()))
        self.runtime.console.configure(dict(expected_version="0", scopes=[dict(scope(21),
            include_assets=[row["base_asset"]], quote_asset=row["quote_asset"])]))
        self.runtime.close()
        # Persisted v1 values from the predecessor's source-local ETH/USDT namespace.
        previous_base = "325296720532232951174307413933328207"
        previous_quote = "235876055870610484460362939402242130"
        cache = Path(self.temp.name, "scanner-discovery.json")
        document = json.loads(cache.read_bytes())
        document["bindings"][0].pop("asset_associations", None)
        document["bindings"][0].update(base_asset=previous_base, quote_asset=previous_quote)
        document["assets"] += [dict(identity=previous_base, code="ETH", atomic_scale=18),
                               dict(identity=previous_quote, code="USDT", atomic_scale=18)]
        cache.write_bytes(json.dumps(document).encode())
        config = Path(self.temp.name, "scanner-config.json")
        saved = json.loads(config.read_bytes())
        saved["config"]["scopes"][0].update(include_assets=[previous_base] if include_eth else [], quote_asset=previous_quote)
        config.write_bytes(json.dumps(saved).encode())
        requests = len(self.transport.requests)
        self.runtime = ScannerRuntime(self.temp.name, transport=self.transport,
            clock=lambda:self.now[0], utc_clock=lambda:self.now[1], automatic=False)
        self.addCleanup(self.runtime.close)
        self.assertEqual(self.runtime.console.desired, "stopped")
        self.assertEqual(len(self.transport.requests), requests)
        return row

    def test_asset_rebind_preserves_registration_when_new_instruments_disabled(self):
        self.previous_isolated_asset_cache(include_eth=False)
        self.runtime.console.start()
        self.assertEqual(self.runtime.status()["active_subscriptions"], 1)
        self.transport.metadata_document["universe"].append(dict(name="SOL", szDecimals=2, maxLeverage=25, marginTableId=53))
        self.runtime.discover(self.setting)
        self.assertEqual(len(self.runtime.console.config["registered"]), 1)
        self.assertEqual(len(self.runtime.console.view()["catalogue"]), 2)
        self.runtime.console.start()
        self.assertEqual(self.runtime.status()["active_subscriptions"], 1)
        self.assertEqual({self.runtime.bindings[i]["symbol"] for i in self.runtime.source.owners[self.runtime.console.session]}, {"ETH"})

    def test_asset_rebind_write_failure_recovers_after_restart_by_saving_existing_settings(self):
        row = self.previous_isolated_asset_cache()
        with patch.object(self.runtime.console.config_store, "save", side_effect=OSError("scope disk unavailable")):
            self.runtime.discover(self.setting)
        self.assertEqual(self.runtime.status()["discovery"]["21:production"]["state"], "failed")
        self.runtime.close()
        self.runtime = ScannerRuntime(self.temp.name, transport=self.transport,
            clock=lambda:self.now[0], utc_clock=lambda:self.now[1], automatic=False)
        self.addCleanup(self.runtime.close)
        self.assertEqual(self.runtime.status()["discovery"]["21:production"]["state"], "ready")
        app = control_plane_web.ControlPlaneApp(self.temp.name, control_plane.CommandServer(b"f"*32), scanner_console=self.runtime.console)
        self.addCleanup(app.command_server.close)
        app.scanner_runtime = self.runtime
        app.authorize = lambda headers: (200, {})
        # The persisted ready cache must not suppress recovery through Save Settings.
        with self.assertRaisesRegex(ValueError, "registered instrument"):
            self.runtime.console.start()
        status, body = app.exchange_settings({}, dict(expected_version="1", identity=self.setting["identity"], type="hyperliquid",
            name=self.setting["name"], environment="production"))
        self.assertEqual(status, 200, body)
        for thread in self.runtime.discovery_threads:
            thread.join(timeout=15)
        scope_row = self.runtime.console.config["scopes"][0]
        self.assertEqual(scope_row["include_assets"], [row["base_asset"]])
        self.assertEqual(scope_row["quote_asset"], row["quote_asset"])
        self.assertEqual(self.runtime.console.config["version"], "2")
        self.runtime.console.start(); self.runtime.step()
        self.assertEqual(len(self.runtime.status()["observations"]), 1)
        self.assertTrue(self.runtime.status()["observations"][0]["continuous"])
        self.runtime.close()
        restored = ScannerRuntime(self.temp.name, transport=self.transport, automatic=False)
        self.addCleanup(restored.close)
        self.assertEqual(restored.console.config["scopes"], self.runtime.console.config["scopes"])

    def test_environment_and_same_named_assets_are_isolated(self):
        self.runtime.discover(self.setting)
        self.runtime.discover(dict(self.setting, environment="testnet"))
        rows = list(self.runtime.bindings.values())
        self.assertEqual(len(rows), 2)
        self.assertNotEqual(rows[0]["instrument"], rows[1]["instrument"])
        self.assertNotEqual(rows[0]["base_asset"], rows[1]["base_asset"])
        self.assertNotEqual(rows[0]["settlement_asset"], rows[1]["settlement_asset"])
        self.assertEqual({url for url, _ in self.transport.requests},
            {"https://api.hyperliquid.xyz/info", "https://api.hyperliquid-testnet.xyz/info"})
        with self.assertRaises(ValueError): self.runtime.discover(dict(self.setting, type="okx"))
        with self.assertRaises(ValueError): self.runtime.discover(dict(self.setting, environment="demo"))

    def test_dynamic_identity_and_scope_survive_restart(self):
        self.runtime.close()
        self.runtime = ScannerRuntime(self.temp.name, transport=self.transport,
            clock=lambda:self.now[0], utc_clock=lambda:self.now[1], automatic=False)
        self.addCleanup(self.runtime.close)
        self.transport.metadata_document["universe"][0]["name"] = "BTC"
        original_request = self.transport.request
        def request(url, body=None, **kwargs):
            if body == dict(type="l2Book", coin="BTC"):
                book = json.loads(original_request(url, dict(type="l2Book", coin="ETH"), **kwargs))
                book["coin"] = "BTC"
                return json.dumps(book)
            return original_request(url, body, **kwargs)
        self.transport.request = request
        self.runtime.discover(self.setting)
        identity, row = next((identity, row) for identity, row in self.runtime.bindings.items() if row.get("hl_discovered"))
        before = set(self.runtime.source.registered)
        self.runtime.console.configure(dict(expected_version="0", scopes=[dict(scope(21),
            include_assets=[row["base_asset"]], quote_asset=row["quote_asset"])]))
        self.runtime.console.start()
        self.runtime.step()
        for thread in self.runtime.discovery_threads: thread.join(timeout=15)
        self.now[0] += 100_000_000; self.now[1] += 100_000_000
        self.runtime.step()
        self.assertEqual(set(self.runtime.workers), {identity})
        self.assertTrue(self.runtime.status()["observations"][0]["continuous"])
        saved_scope = self.runtime.console.view()["config"]
        self.runtime.close()
        requests = len(self.transport.requests)
        self.runtime = ScannerRuntime(self.temp.name, transport=self.transport,
            clock=lambda:self.now[0], utc_clock=lambda:self.now[1], automatic=False)
        self.addCleanup(self.runtime.close)
        self.assertEqual(set(self.runtime.source.registered), before)
        self.assertEqual(self.runtime.console.view()["config"], saved_scope)
        self.assertEqual(self.runtime.console.desired, "stopped")
        self.assertEqual(self.runtime.status()["active_subscriptions"], 0)
        self.runtime.request_discovery(self.setting)
        self.assertEqual(len(self.transport.requests), requests)
        self.runtime.console.start()
        self.now[0] += 100_000_000; self.now[1] += 100_000_000
        self.runtime.step()
        for thread in self.runtime.discovery_threads: thread.join(timeout=15)
        self.now[0] += 100_000_000; self.now[1] += 100_000_000
        self.runtime.step()
        self.assertEqual(set(self.runtime.workers), {identity})
        self.assertEqual(self.runtime.status()["failures"], {})
        self.assertTrue(self.runtime.status()["observations"][0]["continuous"])

    def test_changed_rules_wrong_binding_and_invalid_book_never_publish_healthy_input(self):
        self.runtime.discover(self.setting)
        identity, = self.runtime.bindings
        row = self.runtime.bindings[identity]
        for mode in ("rules", "binding", "unit", "book"):
            with self.subTest(mode=mode):
                original = json.loads(json.dumps(row))
                if mode == "rules": self.transport.metadata_document["universe"][0]["maxLeverage"] = 24
                if mode == "binding": row["binding"]["instrument"] += 1
                if mode == "unit": row["tick"] = "0.1"
                book = self.transport.book
                if mode == "book":
                    self.transport.book = lambda binding: json.dumps(dict(coin="BTC", time=self.now[1]//1_000_000, levels=[[], []]))
                self.runtime.acquire(identity)
                self.runtime.step()
                status = self.runtime.status()
                self.assertTrue(status["failures"], status)
                self.assertFalse(any(o["continuous"] for o in status["observations"]))
                self.runtime.release(identity)
                row.clear(); row.update(original)
                self.transport.metadata_document["universe"][0]["maxLeverage"] = 25
                self.transport.book = book


class IntegrationTests(unittest.TestCase):
    def test_scaled_okx_contract_uses_registered_exposure_and_archives_basis(self):
        self.runtime.console.exchange_settings = self.app.exchange_settings_store
        self.save_settings()
        self.call("configure", dict(expected_version="0", scopes=[dict(scope(1), product="linear"), scope(21)]))
        self.call("start")
        self.tick()
        view = self.call("start")
        self.assertTrue(view["snapshot"]["candidates"])
        okx = next(o for o in view["market"]["observations"] if o["venue"] == "1")
        basis = okx["asset_basis"]
        self.assertEqual(basis["bindings"]["base"]["asset"], "4")
        self.assertEqual(basis["bindings"]["base"]["atomic_scale"], 8)
        self.assertEqual(basis["base_units_per_lot"], "1/10")
        self.assertEqual(okx["bid_depth_atoms"], ["600000000000000000000", "1"])
        digest, = self.runtime.console.last_evidence
        from opportunity_scanner.scanner_archive import load
        saved = load(self.runtime.console.history.artifact(digest))
        self.assertTrue(any(row.get("asset_basis") == basis for row in saved["supplied_evidence"].values()))
        self.assertTrue(self.runtime.console.replay(digest)["matches"])

    def test_projection_failure_revokes_both_sources_and_recovers(self):
        self.start()
        self.assertTrue(self.call("start")["snapshot"]["candidates"])
        def unavailable():
            raise OSError("registry unavailable")
        self.runtime.asset_provider = unavailable
        settings = self.app.exchange_settings_store.view()["exchanges"]
        self.runtime.discover(settings[0])
        view = self.call("start")
        self.assertEqual(view["snapshot"]["candidates"], [])
        self.assertEqual(view["market"]["observations"], [])
        self.assertTrue(all("registry unavailable" in s["error"] for s in view["market"]["discovery"].values()))
        self.runtime.asset_provider = registered_assets
        for setting in settings:
            self.runtime.discover(setting)
        self.tick()
        self.assertTrue(self.call("start")["snapshot"]["candidates"])

    def test_registered_SOL_enters_native_cross_venue_pairing(self):
        self.transport.coin = "SOL"
        self.start()
        view = self.call("start")
        self.assertEqual(len(view["market"]["observations"]), 2)
        self.assertEqual(len(view["snapshot"]["candidates"]), 3)
        self.assertTrue(all(a["captures"] == 3 for a in self.runtime.audit().values()))
        rows = list(self.runtime.bindings.values())
        self.assertEqual(len({r["base_asset"] for r in rows}), 1)
        self.assertTrue(all(r["asset_associations"]["base"]["asset"] == "5" for r in rows))

    def test_registered_DOGE_enters_native_cross_venue_pairing(self):
        self.transport.coin = "DOGE"
        self.start()
        view = self.call("start")
        self.assertEqual(len(view["market"]["observations"]), 2)
        self.assertEqual(len(view["snapshot"]["candidates"]), 3)
        self.assertTrue(all(a["captures"] == 3 for a in self.runtime.audit().values()))

    def test_same_named_registered_different_assets_do_not_pair(self):
        document = registered_assets()
        for binding in document["bindings"]:
            if binding["venue"] == "21" and binding["code"] == "ETH":
                binding["asset"] = "99"
        self.runtime.asset_provider = lambda: document
        self.start()
        view = self.call("start")
        self.assertEqual(len(view["market"]["observations"]), 2)
        self.assertEqual(view["snapshot"]["candidates"], [])

    def test_scaled_contract_name_cannot_inherit_registered_asset_by_prefix(self):
        self.transport.coin = "SOL"
        request = self.transport.request
        def scaled(url, body=None, **kwargs):
            if body and body.get("coin") == "kSOL":
                body = dict(body, coin="SOL")
            result = request(url, body, **kwargs)
            return result.replace("SOL", "kSOL") if body else result
        self.transport.request = scaled
        self.start()
        view = self.call("start")
        self.assertEqual(len(view["market"]["observations"]), 2)
        self.assertEqual(view["snapshot"]["candidates"], [])
        hl = next(r for r in self.runtime.bindings.values() if r["venue"] == 21)
        self.assertIsNone(hl["asset_associations"]["base"])
        self.assertTrue(any(r["symbol"] == "kSOL" and "base" in r["missing"]
            for r in view["market"]["discovery"]["21:production"]["asset_binding_gaps"]))

    def test_unregistered_assets_including_BTC_have_no_special_pairing(self):
        self.runtime.asset_provider = lambda: dict(schema=1, bindings=[])
        self.transport.coin = "BTC"
        self.start()
        view = self.call("start")
        self.assertEqual(len(view["market"]["observations"]), 2)
        self.assertEqual(view["snapshot"]["candidates"], [])

    def test_missing_quote_registration_reports_exact_source_code(self):
        document = registered_assets()
        document["bindings"] = [r for r in document["bindings"] if
                                (r["venue"], r["environment"], r["code"]) != ("21", "production", "USDT")]
        self.runtime.asset_provider = lambda: document
        self.start()
        view = self.call("start")
        self.assertEqual(view["snapshot"]["candidates"], [])
        gap, = view["market"]["discovery"]["21:production"]["asset_binding_gaps"]
        self.assertEqual(gap["missing"], ["quote"])
        self.assertEqual(gap["codes"]["quote"], "USDT")

    def test_registry_change_revokes_old_pair_and_preserves_registration_and_filter(self):
        self.transport.coin = "SOL"
        self.start()
        registered = self.runtime.console.config["registered"]
        settings = self.app.exchange_settings_store.view()["exchanges"]
        hl = next(s for s in settings if s["venue"] == "21")
        old = next(r["base_asset"] for r in self.runtime.bindings.values() if r["venue"] == 21)
        rows = [scope(1), dict(scope(21), include_assets=[old])]
        self.call("configure", dict(expected_version=self.runtime.console.config["version"], scopes=rows))
        self.tick()
        self.assertTrue(self.call("start")["snapshot"]["candidates"])
        digest, = self.runtime.console.last_evidence
        document = registered_assets()
        for binding in document["bindings"]:
            if binding["venue"] == "21" and binding["code"] == "SOL":
                binding.update(asset="99", version="2", source_digest="cd"*32)
        self.runtime.asset_provider = lambda: document
        self.runtime.discover(hl)
        self.assertEqual(self.runtime.console.snapshot["candidates"], [])
        self.assertEqual(self.runtime.console.config["registered"], registered)
        newer = next(r["base_asset"] for r in self.runtime.bindings.values() if r["venue"] == 21)
        self.assertNotEqual(old, newer)
        self.assertEqual(self.runtime.console.config["scopes"][1]["include_assets"], [newer])
        from opportunity_scanner.scanner_archive import load
        archived = load(self.runtime.console.history.artifact(digest))
        hl_evidence = next(r for r in archived["supplied_evidence"].values() if r.get("venue") == "21")
        self.assertEqual(hl_evidence["asset_basis"]["bindings"]["base"]["version"], "1")
        self.assertTrue(self.runtime.console.replay(digest)["matches"])

    def test_explicit_source_alias_pairs_and_survives_restart(self):
        document = registered_assets()
        # The alias is published in the same activated definition as ETH.
        document["bindings"].append(dict(next(b for b in document["bindings"]
            if b["venue"] == "21" and b["code"] == "ETH" and b["environment"] == "production"), code="ALIAS"))
        self.runtime.asset_provider = lambda: document
        request = self.transport.request
        def aliased(url, body=None, **kwargs):
            if body and body.get("coin") == "ALIAS":
                body = dict(body, coin="ETH")
            result = request(url, body, **kwargs)
            return result.replace("ETH", "ALIAS") if body else result
        self.transport.request = aliased
        self.start()
        self.assertEqual(len(self.call("start")["snapshot"]["candidates"]), 3)
        before = set(self.runtime.source.registered)
        self.runtime.close()
        current = dict(document, bindings=[dict(r, version="2") if r["asset"] == "4" else r
                                          for r in reversed(document["bindings"])])
        self.runtime = ScannerRuntime(self.temp.name, transport=self.transport,
            clock=lambda:self.now[0], utc_clock=lambda:self.now[1], automatic=False,
            asset_provider=lambda: current)
        self.app.scanner_runtime, self.app.scanner_console = self.runtime, self.runtime.console
        self.runtime.console.exchange_settings = self.app.exchange_settings_store
        self.assertEqual(set(self.runtime.source.registered), before)
        self.assertEqual(self.runtime.console.desired, "stopped")
        for setting in self.app.exchange_settings_store.view()["exchanges"]:
            self.runtime.discover(setting)
        self.call("start"); self.tick()
        view = self.call("start")
        self.assertEqual(len(view["snapshot"]["candidates"]), 3)
        self.assertEqual({row["asset_basis"]["bindings"]["base"]["version"]
                          for row in view["market"]["observations"]}, {"2"})

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.now = [2_000_000_000, 1_800_000_000_000_000_000]
        self.transport = ProtocolTransport(self.now)
        self.runtime = ScannerRuntime(self.temp.name, transport=self.transport,
            clock=lambda:self.now[0], utc_clock=lambda:self.now[1], automatic=False)
        self.app = control_plane_web.ControlPlaneApp(self.temp.name,control_plane.CommandServer(b"k"*32),
                                                   scanner_console=self.runtime.console)
        self.app.scanner_runtime = self.runtime
        self.addCleanup(self.app.command_server.close)
        self.app.setup("internal-protocol-fixture-only")
        self.server = control_plane_web.serve(self.app)
        self.thread = threading.Thread(target=self.server.serve_forever,daemon=True)
        self.thread.start()
        status, result = self.http("/login", dict(passphrase="internal-protocol-fixture-only",
            code=owner_session.totp_at(self.app.totp.read_secret(), self.app.clock())))
        self.assertEqual(status,200,result)
        self.headers = {"Cookie":self.cookie,"X-Owner-CSRF":result["csrf_token"]}

    def http(self, path, payload=None, headers=None):
        connection=http.client.HTTPConnection("127.0.0.1",self.server.server_port,timeout=15)
        connection.request("POST" if payload is not None else "GET",path,
            None if payload is None else json.dumps(payload),headers=headers or {})
        response=connection.getresponse()
        if response.getheader("Set-Cookie"):
            self.cookie=response.getheader("Set-Cookie").split(";",1)[0]
        body=json.loads(response.read()); status=response.status; connection.close()
        return status,body

    def call(self, operation, payload=None):
        request=dict(operation=operation)
        if payload is not None: request["payload"]=payload
        status, result=self.http("/api/scanner",request,self.headers)
        self.assertEqual(status,200,result)
        return result["result"]

    def tick(self):
        self.now[0]+=100_000_000; self.now[1]+=100_000_000
        self.runtime.step()

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join()
        self.runtime.close(); self.temp.cleanup()

    def start(self):
        self.runtime.console.exchange_settings = self.app.exchange_settings_store
        self.app.scanner_runtime = self.runtime
        self.save_settings()
        self.call("configure",dict(expected_version="0",scopes=[scope(1),scope(21)]))
        self.assertEqual(self.call("start")["phase"],"Warming")
        self.tick()

    def save_settings(self):
        status, body = self.http("/api/exchange-settings", headers=self.headers)
        self.assertEqual(status, 200, body)
        for kind, name, environment in (("okx", "我的现货", "production"), ("hyperliquid", "我的永续", "production")):
            if any(row["type"] == kind and row["environment"] == environment for row in body["result"]["exchanges"]):
                continue
            status, body = self.http("/api/exchange-settings", dict(expected_version=body["result"]["version"],
                type=kind, name=name, environment=environment), self.headers)
            self.assertEqual(status, 200, body)
        for thread in self.runtime.discovery_threads:
            thread.join(timeout=15)
        return body["result"]

    def test_formal_runtime_native_http_evaluates_and_archive_replays(self):
        self._assert_formal_evaluation("HYPE")

    def test_second_non_whitelisted_asset_reaches_formal_evaluation(self):
        self._assert_formal_evaluation("PURR")

    def _assert_formal_evaluation(self, coin):
        from dataclasses import replace
        from opportunity_scanner.scanner_evaluation import publish_inputs
        from strategies.cross_venue import arbitrage_evaluation as evaluation
        from test_scanner_evaluation import native_inputs
        self.transport.coin = coin
        original = self.transport.request
        def response(url, body=None, **kwargs):
            payload = original(url, body, **kwargs)
            if body is None:
                return payload.replace("USDT", "USDC")
            if body.get("type") == "l2Book":
                value = json.loads(payload)
                value["levels"][0][0]["px"] = "3100"
                value["levels"][1][0]["px"] = "3100.1"
                return json.dumps(value)
            return payload
        self.transport.request = response
        self.start()
        self.now[1] += 3_000_000_000-self.now[0]
        self.now[0] = 3_000_000_000
        self.runtime.step()
        observations = tuple(sorted(self.runtime.observations.values(),key=lambda o:o.identity))
        self.assertEqual(len(observations),2)
        document = native_inputs(observations,self.now[0],self.runtime.evaluation.clock_id)
        publish_inputs(self.runtime.evaluation.path,document)
        self.runtime.step()
        view = self.call("start")
        row = next(r for r in view["snapshot"]["candidates"] if r["mode"] == "taker_taker")
        self.assertEqual(row["status"],"evaluated",(row,self.runtime.evaluation.state))
        self.assertTrue(row["recommended"])
        self.assertIsNotNone(row["quantity_base"])
        self.assertGreater(int(row["plan_atoms"]),0)
        self.assertEqual(row["input_versions"]["fees"],"native-fees-v1")
        material, = self.runtime.console.last_evidence.values()
        from opportunity_scanner.scanner_archive import load
        archive = load(material)
        plan, = archive["frozen_plans"]
        expected = evaluation.evaluate(plan.scenarios,plan.policy,plan.estimator,plan.calibration,
                                       plan.simulation_error,plan.limits)
        self.assertEqual(row["plan_atoms"],str(expected.plan_atoms))
        self.assertEqual(row["scenario_digest"],expected.scenario_digest)
        digest, = self.runtime.console.last_evidence
        self.assertTrue(self.runtime.console.replay(digest)["matches"])
        case = document["cases"][0]
        document["version"] = 2
        original_fees = case["entry_fees"]
        case["entry_fees"] = tuple(replace(f,taker_ppm=100000) for f in original_fees)
        publish_inputs(self.runtime.evaluation.path,document)
        self.runtime.step()
        rejected = next(r for r in self.call("start")["snapshot"]["candidates"] if r["id"] == row["id"])
        self.assertEqual((rejected["status"],rejected["reason"]),("rejected","reference_profit"))
        self.assertFalse(rejected["recommended"])
        self.assertGreater(int(rejected["observed_edge_bp"][0]),0)
        document["version"] = 3
        case["entry_fees"] = tuple(replace(f,valid_until_ns=self.now[0]) for f in original_fees)
        publish_inputs(self.runtime.evaluation.path,document)
        self.runtime.step()
        current = self.call("start")["snapshot"]["candidates"]
        target = next(r for r in current if r["id"] == row["id"])
        self.assertEqual(target["reason"],"fees_expired")
        self.assertFalse(target["recommended"])
        self.assertIsNone(target["plan_atoms"])

    def test_settings_rename_delete_and_retained_history_through_http(self):
        self.start()
        console = self.runtime.console
        saved = self.save_settings()
        okx = next(r for r in saved["exchanges"] if r["type"] == "okx")
        workers = dict(self.runtime.workers)
        ids = [r["id"] for r in console.view()["snapshot"]["candidates"]]
        status, body = self.http("/api/exchange-settings", dict(expected_version=saved["version"],
            identity=okx["identity"], type="okx", name="改名后的来源", environment="production"), self.headers)
        self.assertEqual(status, 200, body)
        self.assertEqual(dict(self.runtime.workers), workers)
        self.assertEqual([r["id"] for r in console.view()["snapshot"]["candidates"]], ids)
        history = self.call("history", dict(kind="batches", limit=50))
        self.assertIn("改名后的来源", json.dumps(history, ensure_ascii=False))
        shared = next(i for i in workers if i[0] == 1)
        self.runtime.source.acquire("other-consumer", {shared})
        self.addCleanup(self.runtime.source.release, "other-consumer")
        status, body = self.http("/api/exchange-settings", dict(expected_version=body["result"]["version"],
            identity=okx["identity"], operation="delete"), self.headers)
        self.assertEqual(status, 200, body)
        view = console.view()
        self.assertEqual([r["venue"] for r in view["config"]["scopes"]], ["21"])
        self.assertEqual(view["snapshot"]["candidates"], [])
        self.assertIs(self.runtime.workers[shared], workers[shared])
        self.tick()
        self.assertEqual(console.view()["snapshot"]["candidates"], [])
        history = self.call("history", dict(kind="batches", limit=50))
        self.assertIn("改名后的来源", json.dumps(history, ensure_ascii=False))

    def test_settings_reconciliation_failure_stops_and_restart_repairs_saved_scope(self):
        self.start()
        saved = self.save_settings()
        row = next(s for s in saved["exchanges"] if s["type"] == "okx")
        with patch.object(self.runtime.console.config_store, "save", side_effect=OSError("scope disk unavailable")):
            status, body = self.http("/api/exchange-settings", dict(expected_version=saved["version"],
                identity=row["identity"], operation="delete"), self.headers)
        self.assertEqual(status, 503, body)
        self.assertEqual(self.runtime.console.desired, "stopped")
        self.assertEqual(self.runtime.console.snapshot["candidates"], [])
        restarted = ScannerRuntime(self.temp.name, transport=self.transport, automatic=False)
        self.addCleanup(restarted.close)
        app = control_plane_web.ControlPlaneApp(self.temp.name, self.app.command_server, scanner_console=restarted.console)
        self.assertEqual([r["venue"] for r in restarted.console.config["scopes"]], ["21"])
        self.assertEqual(restarted.console.desired, "stopped")

    def test_settings_environment_switch_fences_late_poll_and_keeps_other_workers(self):
        self.start()
        saved = self.save_settings()
        setting = next(r for r in saved["exchanges"] if r["type"] == "okx")
        workers = dict(self.runtime.workers)
        old = next(i for i in workers if i[0] == 1)
        other = next(i for i in workers if i[0] == 21)
        self.runtime.source.acquire("other-consumer", {old})
        self.addCleanup(self.runtime.source.release, "other-consumer")
        entered, released = threading.Event(), threading.Event()
        original = self.transport.book
        def delayed(binding):
            if binding["venue"] == 1 and binding["environment"] == "production":
                entered.set()
                if not released.wait(10):
                    raise TimeoutError("test transport release missing")
            return original(binding)
        self.transport.book = delayed
        poller = threading.Thread(target=self.runtime.step)
        poller.start()
        try:
            self.assertTrue(entered.wait(5))
            status, body = self.http("/api/exchange-settings", dict(expected_version=saved["version"],
                identity=setting["identity"], type="okx", name=setting["name"], environment="demo"), self.headers)
            self.assertEqual(status, 200, body)
            self.assertEqual(self.runtime.console.view()["phase"], "Warming", self.runtime.console.view())
            self.assertEqual(self.runtime.console.snapshot["candidates"], [])
        finally:
            released.set(); poller.join(timeout=10)
        self.assertFalse(poller.is_alive())
        for thread in self.runtime.discovery_threads: thread.join(timeout=15)
        self.assertEqual(self.runtime.console.snapshot["candidates"], [])
        self.tick()
        view = self.runtime.console.view()
        self.assertEqual({r["environment"] for r in view["market"]["observations"]}, {"demo", "production"})
        self.assertEqual(view["snapshot"]["candidates"], [])
        self.assertIs(self.runtime.workers[old], workers[old])
        self.assertIs(self.runtime.workers[other], workers[other])
        self.assertEqual(view["config"]["scopes"][0]["setting_id"], setting["identity"])

    def test_settings_hyperliquid_environment_switch_rebinds_saved_asset_filters(self):
        self.runtime.close()
        self.runtime = ScannerRuntime(self.temp.name,
            transport=DynamicHyperliquidTransport(self.now), clock=lambda:self.now[0], utc_clock=lambda:self.now[1], automatic=False)
        self.app.scanner_console, self.app.scanner_runtime = self.runtime.console, self.runtime
        self.runtime.console.exchange_settings = self.app.exchange_settings_store
        status, body = self.http("/api/exchange-settings", dict(expected_version="0", type="hyperliquid", name="永续来源", environment="production"), self.headers)
        self.assertEqual(status, 200, body)
        setting = body["result"]["exchanges"][0]
        self.runtime.discover(setting)
        assets = {a["code"]:a["identity"] for a in self.runtime.source.assets}
        self.call("configure", dict(expected_version="0", scopes=[dict(scope(21), include_assets=[assets["ETH"]], quote_asset=assets["USDT"])]))
        self.call("start"); self.tick()
        old = set(self.runtime.workers)
        status, body = self.http("/api/exchange-settings", dict(expected_version="1", identity=setting["identity"],
            type="hyperliquid", name=setting["name"], environment="testnet"), self.headers)
        self.assertEqual(status, 200, body)
        for thread in self.runtime.discovery_threads:
            thread.join(timeout=10)
            self.assertFalse(thread.is_alive())
        self.tick()
        view = self.runtime.console.view()
        self.assertEqual(view["phase"], "Running", view["market"]["discovery"])
        self.assertEqual([r["environment"] for r in view["market"]["observations"]], ["testnet"])
        self.assertFalse(old & set(self.runtime.workers))
        self.assertNotEqual(view["config"]["scopes"][0]["include_assets"], [assets["ETH"]])
        # A failed reverse switch survives a stopped restart and explicit retry.
        self.runtime.transport.request = lambda *a, **kw: (_ for _ in ()).throw(OSError("catalogue unavailable"))
        status, body = self.http("/api/exchange-settings", dict(expected_version="2", identity=setting["identity"],
            type="hyperliquid", name=setting["name"], environment="production"), self.headers)
        self.assertEqual(status, 200, body)
        for thread in self.runtime.discovery_threads:
            thread.join(timeout=10)
        self.assertIn("21:production", self.runtime.console.config["pending_catalogues"])
        self.runtime.close()
        self.runtime = ScannerRuntime(self.temp.name,
            transport=DynamicHyperliquidTransport(self.now), clock=lambda:self.now[0], utc_clock=lambda:self.now[1], automatic=False)
        recovered = control_plane_web.ControlPlaneApp(self.temp.name, self.app.command_server, scanner_console=self.runtime.console)
        recovered.scanner_runtime = self.runtime
        recovered.authorize = lambda headers: (200, {})
        self.assertEqual(self.runtime.console.desired, "stopped")
        self.assertEqual(self.runtime.workers, {})
        status, body = recovered.exchange_settings({}, dict(expected_version="3", identity=setting["identity"],
            type="hyperliquid", name=setting["name"], environment="production"))
        self.assertEqual(status, 200, body)
        for thread in self.runtime.discovery_threads:
            thread.join(timeout=10)
        self.assertNotIn("pending_catalogues", self.runtime.console.config)
        self.runtime.console.start(); self.tick()
        self.assertEqual([r["environment"] for r in self.runtime.console.view()["market"]["observations"]], ["production"])

    def test_dynamic_refresh_lifecycle_through_http_and_native_adapters(self):
        settings = self.save_settings()["exchanges"]
        for hyperliquid in (False, True):
            with self.subTest(hyperliquid=hyperliquid):
                self.runtime.close()
                venue = 21 if hyperliquid else 1
                transport = RefreshTransport(self.now, hyperliquid)
                self.runtime = ScannerRuntime(Path(self.temp.name)/str(venue),
                    transport=transport, clock=lambda:self.now[0], utc_clock=lambda:self.now[1], automatic=False)
                self.app.scanner_console = self.runtime.console
                self.runtime.console.exchange_settings = self.app.exchange_settings_store
                setting = next(s for s in settings if s["venue"] == str(venue))
                self.runtime.discover(setting)
                row = dict(scope(venue), quote_asset=None)
                self.call("configure", dict(expected_version="0", scopes=[row]))
                self.call("start"); self.tick()
                initial = set(self.runtime.workers)
                self.assertEqual(len(initial), 1)
                transport.mode = "added"
                self.runtime.discover(setting)
                self.assertEqual(set(self.runtime.workers), initial)
                self.call("configure", dict(expected_version="1", scopes=[dict(row, new_instruments=True)]))
                self.tick()
                self.assertEqual(len(self.runtime.workers), 2)
                self.assertTrue(all(o["continuous"] for o in self.http("/api/scanner", headers=self.headers)[1]["result"]["market"]["observations"]))
                transport.mode = "rules"
                self.runtime.discover(setting)
                self.assertEqual(self.http("/api/scanner", headers=self.headers)[1]["result"]["market"]["observations"], [])
                self.assertEqual(len(self.runtime.workers), 1)
                self.assertEqual(len(self.http("/api/scanner", headers=self.headers)[1]["result"]["warming"]), 1)
                self.tick()
                self.assertTrue(self.http("/api/scanner", headers=self.headers)[1]["result"]["market"]["observations"][0]["continuous"])
                for mode in ("failed", "capacity", "gone"):
                    transport.mode = mode
                    self.runtime.discover(setting)
                    view = self.http("/api/scanner", headers=self.headers)[1]["result"]
                    self.assertFalse(view["snapshot"]["candidates"])
                    self.assertFalse(view["market"]["observations"])
                    self.assertEqual(view["exchanges"][0 if venue == 1 else 1]["catalogue_state"], "ready" if mode == "gone" else "failed")
                    self.assertEqual(len(view["exchanges"]), 2)
                    transport.mode = "initial"
                    self.runtime.discover(setting); self.tick()
                    self.assertTrue(self.http("/api/scanner", headers=self.headers)[1]["result"]["market"]["observations"][0]["continuous"])

    def test_refresh_failure_and_scope_changes_leave_other_source_running(self):
        settings = self.save_settings()["exchanges"]
        self.runtime.close()
        okx, hl = RefreshTransport(self.now), RefreshTransport(self.now, True)
        transport = PublicTransport()
        transport.input_kind = "synthetic_protocol_fixture"
        transport.request = lambda url, body=None, **kw: (hl if body else okx).request(url, body, **kw)
        self.runtime = ScannerRuntime(Path(self.temp.name)/"mixed",
            transport=transport, clock=lambda:self.now[0], utc_clock=lambda:self.now[1], automatic=False)
        self.app.scanner_console = self.runtime.console
        self.runtime.console.exchange_settings = self.app.exchange_settings_store
        for setting in settings: self.runtime.discover(setting)
        rows = [dict(scope(v), quote_asset=None, new_instruments=True) for v in (1, 21)]
        self.call("configure", dict(expected_version="0", scopes=rows))
        self.call("start"); self.tick()
        identity = next(i for i in self.runtime.workers if i[0] == 21)
        worker = self.runtime.workers[identity]
        self.runtime.source.acquire("other-consumer", {identity})
        okx.mode = "failed"
        self.runtime.discover(settings[0]); self.tick()
        self.assertIs(self.runtime.workers[identity], worker)
        observations = self.http("/api/scanner", headers=self.headers)[1]["result"]["market"]["observations"]
        self.assertEqual([o["venue"] for o in observations], ["21"])
        self.assertTrue(observations[0]["continuous"])
        okx.mode = "initial"
        self.runtime.discover(settings[0]); self.tick()
        rows[0]["exclude_assets"] = sorted({str(e.rules.base_asset) for e in self.runtime.source.registered.values() if e.venue == 1})
        self.call("configure", dict(expected_version="1", scopes=rows))
        self.tick()
        self.assertEqual(set(self.runtime.workers), {identity})
        self.assertIs(self.runtime.workers[identity], worker)
        self.call("stop")
        self.assertIs(self.runtime.workers[identity], worker)
        self.runtime.source.release("other-consumer")
        self.assertEqual(self.runtime.workers, {})

    def test_failed_catalogue_immediately_revokes_existing_candidates(self):
        self.start()
        before = self.call("start")
        self.assertEqual(len(before["snapshot"]["candidates"]), 3)
        identity = next(i for i in self.runtime.workers if i[0] == 21)
        worker = self.runtime.workers[identity]
        def disconnected(*args):
            raise OSError("synthetic catalogue disconnected")
        self.transport.catalogue = disconnected
        self.runtime.discover(next(s for s in self.app.exchange_settings_store.view()["exchanges"] if s["type"] == "okx"))
        view = self.http("/api/scanner", headers=self.headers)[1]["result"]
        self.assertEqual(view["snapshot"]["candidates"], [])
        self.assertEqual([o["venue"] for o in view["market"]["observations"]], ["21"])
        self.assertIs(self.runtime.workers[identity], worker)

    def test_complete_catalogue_revokes_missing_dynamic_inputs_and_candidates(self):
        self.start()
        self.assertEqual(len(self.call("start")["snapshot"]["candidates"]), 3)
        removed = next(i for i in self.runtime.workers if i[0] == 1)
        healthy = next(i for i in self.runtime.workers if i[0] == 21)
        worker = self.runtime.workers[healthy]
        self.runtime.source.acquire("other-consumer", {removed, healthy})
        catalogue = self.transport.catalogue
        def gone(setting, product):
            return json.dumps(dict(code="0", data=[]))
        self.transport.catalogue = gone
        self.runtime.discover(next(s for s in self.app.exchange_settings_store.view()["exchanges"] if s["type"] == "okx"))
        view = self.http("/api/scanner", headers=self.headers)[1]["result"]
        self.assertEqual(view["market"]["discovery"]["1:production"]["state"], "ready")
        self.assertEqual(view["snapshot"]["candidates"], [])
        self.assertEqual([o["venue"] for o in view["market"]["observations"]], ["21"])
        self.assertIs(self.runtime.workers[healthy], worker)
        self.assertEqual(self.runtime.source.owners["other-consumer"], {removed, healthy})
        self.tick()
        self.assertEqual([o["venue"] for o in self.runtime.status()["observations"]], ["21"])
        self.assertIs(self.runtime.workers[healthy], worker)
        self.transport.catalogue = catalogue
        self.runtime.discover(next(s for s in self.app.exchange_settings_store.view()["exchanges"] if s["type"] == "okx"))
        self.assertIn(list(map(str, removed)), self.call("start")["warming"])
        self.tick()
        view = self.call("start")
        self.assertEqual(len(view["snapshot"]["candidates"]), 3, view)
        self.assertTrue(all(o["continuous"] for o in view["market"]["observations"]))
        self.assertIs(self.runtime.workers[healthy], worker)

    def test_dynamic_hyperliquid_settings_scope_native_scan_and_restart(self):
        self.runtime.close()
        transport = DynamicHyperliquidTransport(self.now)
        self.runtime = ScannerRuntime(self.temp.name, transport=transport,
            clock=lambda:self.now[0], utc_clock=lambda:self.now[1], automatic=False)
        self.app.scanner_console = self.runtime.console
        self.app.scanner_runtime = self.runtime
        self.runtime.console.exchange_settings = self.app.exchange_settings_store
        status, body = self.http("/api/exchange-settings", dict(expected_version="0", type="hyperliquid",
            name="动态永续", environment="testnet"), self.headers)
        self.assertEqual(status, 200, body)
        for thread in self.runtime.discovery_threads:
            thread.join(timeout=20)
            self.assertFalse(thread.is_alive())
        view = self.call("stop")
        self.assertEqual(len(view["catalogue"]), 1, view["market"])
        assets = {a["code"]: a["identity"] for a in view["assets"]}
        self.assertEqual(set(assets), {"ETH", "USDT", "USDC"})
        self.call("configure", dict(expected_version="0", scopes=[dict(scope(21, "testnet"),
            quote_asset=assets["USDT"], include_assets=[assets["ETH"]])]))
        self.call("start"); self.tick()
        view = self.http("/api/scanner", headers=self.headers)[1]["result"]
        observation, = view["market"]["observations"]
        self.assertTrue(observation["continuous"], view["market"])
        self.assertEqual(observation["ask_quote_atoms"], [str(30001*10**17), "1"])
        entry, = self.runtime.source.registered.values()
        self.assertEqual(entry.rules.base_atoms_per_lot, 10**14)
        self.assertEqual(entry.rules.tick_quote_atoms_per_base_atom, Fraction(1, 100))
        row, = self.runtime.bindings.values()
        self.assertEqual(row["specification"]["settlement"], "USDC")
        self.assertNotEqual(row["quote_asset"], row["settlement_asset"])
        self.assertEqual(next(iter(self.runtime.audit().values()))["captures"], 3)
        self.assertTrue(all(url == "https://api.hyperliquid-testnet.xyz/info" for url, _ in transport.requests))
        self.assertEqual(transport.requests[-1][1], dict(type="l2Book", coin="ETH"))
        identities = set(self.runtime.source.registered)
        self.runtime.discover(body["result"]["exchanges"][0])
        self.assertEqual(set(self.runtime.source.registered), identities)
        self.runtime.close()
        self.runtime = ScannerRuntime(self.temp.name, transport=transport, automatic=False)
        self.assertEqual(set(self.runtime.source.registered), identities)
        self.assertEqual(self.runtime.console.desired, "stopped")
        self.assertEqual(self.runtime.status()["active_subscriptions"], 0)

    def test_dynamic_okx_discovery_and_scan_outside_original_allowlist(self):
        self.runtime.close()
        self.runtime = ScannerRuntime(self.temp.name,
            transport=DynamicOkxTransport(self.now), clock=lambda:self.now[0], utc_clock=lambda:self.now[1], automatic=False)
        self.app.scanner_console = self.runtime.console
        self.app.scanner_runtime = self.runtime
        self.runtime.console.exchange_settings = self.app.exchange_settings_store
        setting = next(s for s in self.save_settings()["exchanges"] if s["type"] == "okx")
        self.runtime.discover(setting)
        view = self.call("stop")
        self.assertEqual(view["market"]["active_subscriptions"], 0)
        self.assertEqual({a["code"] for a in view["assets"]}, {"ETH", "USDT"})
        self.assertEqual(len(view["catalogue"]), 2)
        assets = {a["code"]:a["identity"] for a in view["assets"]}
        rows = [dict(scope(1), product=product, quote_asset=assets["USDT"], include_assets=[assets["ETH"]]) for product in ("spot", "linear")]
        self.call("configure", dict(expected_version="0", scopes=rows))
        self.call("start"); self.tick()
        self.call("summary")
        view = self.http("/api/scanner", headers=self.headers)[1]["result"]
        self.assertEqual(len(view["market"]["observations"]), 2, view)
        self.assertTrue(all(o["continuous"] for o in view["market"]["observations"]))
        linear = next(r for r in view["catalogue"] if r["product"] == "linear")
        entry = next(r for r in self.runtime.source.registered.values() if str(r.rules.instrument) == linear["instrument"])
        self.assertEqual(entry.rules.base_atoms_per_lot, 10**17)
        self.assertEqual(entry.rules.tick_quote_atoms_per_base_atom, Fraction(1, 100))
        self.assertEqual(len(self.runtime.audit()), 2)
        identities = {(r["product"], r["instrument"]) for r in view["catalogue"]}
        self.runtime.close()
        self.runtime = ScannerRuntime(self.temp.name, transport=DynamicOkxTransport(self.now), automatic=False)
        self.assertEqual({(r.kind, str(r.rules.instrument)) for r in self.runtime.source.registered.values()}, identities)
        self.assertEqual(self.runtime.console.desired, "stopped")

    def test_settings_auth_scope_reference_loading_failure_and_service_restart(self):
        self.assertEqual(self.http("/api/exchange-settings")[0], 401)
        self.assertEqual(self.http("/api/exchange-settings", dict(expected_version="0", type="okx", name="市场", environment="production"), {"Cookie": self.cookie})[0], 403)
        self.assertEqual(self.call("stop")["exchanges"], [])
        self.assertEqual(self.runtime.status()["active_subscriptions"], 0)
        self.assertEqual(self.http("/api/scanner", dict(operation="configure", payload=dict(expected_version="0", scopes=[scope(1)])), self.headers)[0], 400)
        self.save_settings()
        view = self.call("stop")
        status, body = self.http("/api/exchange-settings", dict(expected_version="2", type="okx", name="  ", environment="demo"), self.headers)
        self.assertEqual(status, 400, body)
        status, body = self.http("/api/exchange-settings", dict(expected_version="0", type="okx", name="旧版本", environment="demo"), self.headers)
        self.assertEqual(status, 409, body)
        replace_file = os.replace
        def fail_settings_write(source, destination):
            if Path(destination).name == "exchange-settings.json":
                raise OSError("settings disk failure")
            return replace_file(source, destination)
        with patch("os.replace", side_effect=fail_settings_write):
            status, body = self.http("/api/exchange-settings", dict(expected_version="2", type="okx", name="失败保存", environment="demo"), self.headers)
        self.assertEqual(status, 503, body)
        self.assertEqual(self.http("/api/exchange-settings", headers=self.headers)[1]["result"]["version"], "2")
        self.assertEqual([r["name"] for r in view["exchanges"]], ["我的现货", "我的永续"])
        self.assertTrue(all(r["catalogue_state"] == "ready" for r in view["exchanges"]))
        forged = dict(scope(1), setting_id="0"*32)
        status, body = self.http("/api/scanner", dict(operation="configure", payload=dict(expected_version="0", scopes=[forged])), self.headers)
        self.assertEqual(status, 400, body)
        self.assertEqual(self.call("stop")["config_version"], "0")
        self.call("configure", dict(expected_version="0", scopes=[scope(1), scope(21)]))
        self.assertTrue(all(r["setting_id"] in {s["identity"] for s in view["exchanges"]} for r in self.call("stop")["config"]["scopes"]))
        self.call("start")
        self.tick()
        self.assertEqual(len(self.call("start")["snapshot"]["candidates"]), 3)
        self.transport.fail.add(21); self.tick()
        failed = self.call("start")
        self.assertEqual(next(s for s in failed["exchanges"] if s["type"] == "hyperliquid")["catalogue_state"], "failed")
        self.assertIn("disconnected", next(s for s in failed["exchanges"] if s["type"] == "hyperliquid")["catalogue_error"])
        self.assertEqual(next(s for s in failed["exchanges"] if s["type"] == "hyperliquid")["name"], "我的永续")
        self.runtime.close()
        self.runtime = ScannerRuntime(self.temp.name, transport=self.transport, automatic=False)
        restored = control_plane_web.ControlPlaneApp(self.temp.name, self.app.command_server, scanner_console=self.runtime.console)
        restored_view = restored.scanner_console.view()
        self.assertEqual([r["name"] for r in restored_view["exchanges"]], [r["name"] for r in view["exchanges"]])
        self.assertEqual((restored_view["desired"], restored_view["config_version"]), ("stopped", "1"))
        self.assertEqual(self.runtime.status()["active_subscriptions"], 0)

    def test_explicit_save_recovers_a_stopped_empty_source_without_recreating_settings(self):
        self.start()
        self.call("configure", dict(expected_version="1", scopes=[scope(1)]))
        saved = self.app.exchange_settings_store.view()
        setting = next(s for s in saved["exchanges"] if s["type"] == "okx")
        catalogue = self.transport.catalogue
        self.transport.catalogue = lambda setting, product: json.dumps(dict(code="0", data=[]))
        self.runtime.discover(setting)
        self.call("stop")
        self.assertEqual(self.runtime.status()["discovery"]["1:production"]["count"], 0)
        self.assertEqual(self.http("/api/scanner", dict(operation="start"), self.headers)[0], 400)
        self.transport.catalogue = catalogue
        status, body = self.http("/api/exchange-settings", dict(expected_version=saved["version"],
            identity=setting["identity"], type=setting["type"], name=setting["name"], environment=setting["environment"]), self.headers)
        self.assertEqual(status, 200, body)
        for thread in self.runtime.discovery_threads: thread.join(timeout=15)
        self.call("start"); self.tick()
        self.assertEqual([o["venue"] for o in self.call("start")["market"]["observations"]], ["1"])

    def test_restart_cannot_publish_cached_units_before_fresh_discovery(self):
        self.start()
        self.runtime.close()
        self.runtime = ScannerRuntime(self.temp.name, transport=self.transport,
            clock=lambda:self.now[0], utc_clock=lambda:self.now[1], automatic=False)
        self.app.scanner_runtime, self.app.scanner_console = self.runtime, self.runtime.console
        self.runtime.console.exchange_settings = self.app.exchange_settings_store
        entered, released = threading.Event(), threading.Event()
        catalogue = self.transport.catalogue
        def delayed(setting, product):
            entered.set()
            if not released.wait(10): raise TimeoutError("catalogue release missing")
            return catalogue(setting, product)
        self.transport.catalogue = delayed
        try:
            self.call("start"); self.tick()
            self.assertTrue(entered.wait(5))
            view = self.call("start")
            self.assertEqual(view["market"]["observations"], [])
            self.assertEqual(view["snapshot"]["candidates"], [])
        finally:
            released.set()
            for thread in self.runtime.discovery_threads: thread.join(timeout=15)
        self.tick()
        self.assertEqual(len(self.call("start")["snapshot"]["candidates"]), 3)

    def test_removed_unknown_source_assets_cannot_become_okx_asset_aliases(self):
        self.transport.coin = "UNKNOWN"
        self.start()
        settings = self.app.exchange_settings_store.view()["exchanges"]
        okx = next(s for s in settings if s["venue"] == "1")
        hl = next(s for s in settings if s["venue"] == "21")
        catalogue = self.transport.catalogue
        self.transport.catalogue = lambda setting, product: (
            json.dumps(dict(collateralToken=0, universe=[], marginTables=[]))
            if setting["venue"] == "21" else catalogue(setting, product))
        self.runtime.discover(hl)
        self.runtime.discover(okx)
        self.transport.catalogue = catalogue
        self.runtime.discover(hl); self.tick()
        view = self.call("start")
        self.assertEqual(len(view["market"]["observations"]), 2)
        self.assertEqual(view["snapshot"]["candidates"], [])

    def test_verified_underlying_pairs_but_wrapped_or_unknown_labels_never_pair(self):
        self.transport.coin = "BTC"
        self.start()
        view = self.call("start")
        self.assertEqual(len(view["snapshot"]["candidates"]), 3)
        self.assertTrue(all(c["reason"] == "evaluation_inputs_missing" and not c["recommended"] for c in view["snapshot"]["candidates"]))
        okx = next(r for r in self.runtime.bindings.values() if r["venue"] == 1)
        hl = next(r for r in self.runtime.bindings.values() if r["venue"] == 21)
        self.assertEqual(okx["base_asset"], hl["base_asset"])
        self.assertEqual(okx["quote_asset"], hl["quote_asset"])
        self.assertNotEqual(hl["quote_asset"], hl["settlement_asset"])
        self.assertNotEqual(okx["instrument"], hl["instrument"])
        for coin in ("WETH", "UNKNOWN", "HYPE", "PURR"):
            with self.subTest(coin=coin):
                self.call("stop")
                self.transport.coin = coin
                self.runtime.console.configure(dict(expected_version=self.runtime.console.config["version"], scopes=[]))
                for setting in self.app.exchange_settings_store.view()["exchanges"]:
                    self.runtime.discover(setting)
                self.runtime.console.configure(dict(expected_version=self.runtime.console.config["version"], scopes=[scope(1), scope(21)]))
                self.call("start"); self.tick()
                view = self.call("start")
                self.assertEqual(len(view["market"]["observations"]), 2, view["market"])
                self.assertTrue(all(o["continuous"] for o in view["market"]["observations"]))
                self.assertEqual(view["snapshot"]["candidates"], [])
                row = next(r for r in self.runtime.bindings.values() if r["venue"] == 21)
                self.assertEqual(row["specification"]["quote"], "USDC" if coin in ("HYPE", "PURR") else "USDT")

    def test_authenticated_full_chain_missing_evidence_history_and_restart(self):
        self.assertEqual(self.http("/api/scanner")[0],401)
        self.assertEqual(self.http("/api/scanner",dict(operation="start"),{"Cookie":self.cookie})[0],403)
        self.start()
        view=self.call("start")
        self.assertEqual(view["phase"],"Running",view)
        self.assertEqual(len(view["snapshot"]["candidates"]),3)
        self.assertTrue(all(c["reason"]=="evaluation_inputs_missing" and not c["recommended"] for c in view["snapshot"]["candidates"]))
        self.assertEqual(len(view["market"]["observations"]),2)
        self.assertTrue(all(x["raw_sequence"]>=3 for x in view["market"]["evidence"]))
        self.assertTrue(self.call("history",dict(kind="batches",limit=10))["rows"])
        self.assertEqual(self.call("pause")["phase"],"Paused")
        self.assertFalse(self.call("pause")["snapshot"]["candidates"])
        self.call("start"); self.tick()
        self.assertEqual(self.call("stop")["phase"],"Stopped")
        self.assertEqual(self.call("stop")["phase"],"Stopped")
        self.runtime.close()
        self.runtime=ScannerRuntime(self.temp.name,transport=self.transport,automatic=False)
        self.assertEqual(self.runtime.console.view()["phase"],"Stopped")
        self.assertEqual(self.runtime.console.config["version"],"1")
        self.assertFalse(self.runtime.console.history.query(kind="batches",limit=10))

    def test_disconnect_is_local_and_reconnect_rewarms(self):
        self.start(); self.transport.fail.add(21); self.tick()
        view=self.call("start")
        self.assertEqual(view["phase"],"Degraded")
        self.assertTrue(all(c["reason"]=="data_gap" for c in view["snapshot"]["candidates"]))
        self.assertTrue(next(x for x in view["market"]["observations"] if x["venue"]=="1")["continuous"])
        self.transport.fail.clear(); self.tick()
        self.assertEqual(self.call("start")["phase"],"Running")

    def test_rules_mismatch_does_not_publish_healthy_book(self):
        self.transport.bad_rules=True
        self.start()
        view=self.call("start")
        self.assertFalse(view["snapshot"]["candidates"])
        self.assertTrue(view["market"]["failures"])

    def test_ttl_expires_without_new_input_and_releases_shared_subscriptions(self):
        self.start()
        shared = set(self.runtime.source.registered)
        self.runtime.source.acquire("other-public-consumer",shared)
        self.now[0] += 6_000_000_000
        expired = self.call("start")
        self.assertTrue(all(c["reason"] == "expired" for c in expired["snapshot"]["candidates"]))
        self.assertTrue(all(not o["continuous"] for o in expired["market"]["observations"]))
        self.call("stop")
        self.assertEqual(self.runtime.status()["active_subscriptions"],len(shared))
        self.runtime.source.release("other-public-consumer")
        self.assertEqual(self.runtime.status()["active_subscriptions"],0)

    def test_invalid_environment_config_conflict_and_empty_filter(self):
        status, body=self.http("/api/scanner",dict(operation="configure",payload=dict(expected_version="0",scopes=[scope(21,"demo")])),self.headers)
        self.assertEqual(status,400,body)
        self.start()
        status,_=self.http("/api/scanner",dict(operation="configure",payload=dict(expected_version="0",scopes=[])),self.headers)
        self.assertEqual(status,409)
        rows=[scope(1),scope(21)]
        for row in rows: row["exclude_assets"] = sorted({str(e.rules.base_asset) for e in self.runtime.source.registered.values() if str(e.venue) == row["venue"]})
        self.call("configure",dict(expected_version="1",scopes=rows)); self.tick()
        self.assertFalse(self.call("start")["snapshot"]["candidates"])
        self.assertEqual(self.runtime.status()["active_subscriptions"],0)

    def test_protocol_capacity_and_old_source_time_revoke_coverage(self):
        self.start(); self.transport.stale=True; self.tick()
        self.assertFalse(any(o["continuous"] for o in self.call("start")["market"]["observations"]))
        self.transport.stale=False; self.tick()
        self.transport.oversize=True; self.tick()
        self.assertEqual(self.call("start")["phase"],"Degraded")

    def test_raw_evidence_is_append_only_and_binds_synthetic_input(self):
        import hashlib
        self.start()
        evidence = self.call("start")["market"]["evidence"]
        self.assertTrue(all(record["input_kind"]=="synthetic_protocol_fixture" for record in evidence))
        audited = self.runtime.audit()
        self.assertEqual(len(audited),2)
        for value in audited.values():
            self.assertEqual(value["captures"],3)
            self.assertEqual(value["records"],6)
            digests={hashlib.sha256(payload.encode()).hexdigest() for payload in self.transport.captured.values()}
            self.assertIn(value["digest"],digests)

    def test_declared_nonproduction_routes_keep_actual_source_identity(self):
        self.runtime.close()
        self.runtime=ScannerRuntime(self.temp.name,transport=self.transport,
            clock=lambda:self.now[0],utc_clock=lambda:self.now[1],automatic=False)
        self.app.scanner_console=self.runtime.console
        self.app.scanner_runtime=self.runtime
        self.runtime.console.exchange_settings = self.app.exchange_settings_store
        for version, kind, environment in (("0", "okx", "demo"), ("1", "hyperliquid", "testnet")):
            status, body = self.http("/api/exchange-settings", dict(expected_version=version,
                type=kind, name="测试 "+kind, environment=environment), self.headers)
            self.assertEqual(status, 200, body)
        for thread in self.runtime.discovery_threads: thread.join(timeout=15)
        self.call("configure",dict(expected_version="0",scopes=[scope(1,"demo"),scope(21,"testnet")]))
        self.call("start"); self.tick()
        view=self.call("start")
        self.assertEqual(len(view["market"]["observations"]),2)
        self.assertFalse(view["snapshot"]["candidates"],"different environments cannot form a pair")
        sources={(r["requested_environment"],r["actual_environment"]) for r in view["market"]["evidence"]}
        self.assertEqual(sources,{("demo","production"),("testnet","testnet")})

    def test_raw_write_capacity_revokes_input(self):
        self.save_settings()
        for row in self.runtime.bindings.values():
            if row["venue"] == 1:
                row["raw_budget_bytes"] = 8000
        self.start(); self.tick()
        view=self.call("start")
        self.assertEqual(view["phase"],"Degraded")
        self.assertTrue(any("Unavailable" in value for value in view["market"]["failures"].values()))
        self.assertFalse(any(c["recommended"] for c in view["snapshot"]["candidates"]))

    def test_duplicate_protocol_does_not_refresh_depth_time(self):
        self.start()
        previous={o["venue"]:o["visible_at_ns"] for o in self.call("start")["market"]["observations"]}
        self.transport.replay=True; self.tick()
        self.assertEqual(previous,{o["venue"]:o["visible_at_ns"] for o in self.call("start")["market"]["observations"]})
        self.now[0]+=6_000_000_000
        self.assertTrue(all(c["reason"]=="expired" for c in self.call("start")["snapshot"]["candidates"]))

    def test_local_scope_change_keeps_other_source_incarnation(self):
        self.start()
        before={e["venue"]:e["session"] for e in self.call("start")["market"]["evidence"]}
        self.call("configure",dict(expected_version="1",scopes=[scope(21)])); self.tick()
        self.assertFalse(self.call("start")["snapshot"]["candidates"])
        self.call("configure",dict(expected_version="2",scopes=[scope(1),scope(21)])); self.tick()
        after={e["venue"]:e["session"] for e in self.call("start")["market"]["evidence"]}
        self.assertEqual(before["21"],after["21"])
        self.assertNotEqual(before["1"],after["1"])

    def test_environment_switch_discards_late_transport_and_rewarms_new_sources(self):
        self.start()
        saved = self.save_settings()
        for kind, environment in (("okx", "demo"), ("hyperliquid", "testnet")):
            status, body = self.http("/api/exchange-settings", dict(expected_version=saved["version"],
                type=kind, name="备用 "+kind, environment=environment), self.headers)
            self.assertEqual(status, 200, body)
            saved = body["result"]
        for thread in self.runtime.discovery_threads: thread.join(timeout=15)
        old_sessions={e["session"] for e in self.call("start")["market"]["evidence"]}
        entered,released=threading.Event(),threading.Event()
        original=self.transport.book
        def delayed(binding):
            if binding["venue"]==1 and binding["environment"]=="production":
                entered.set()
                if not released.wait(10): raise TimeoutError("test transport release missing")
            return original(binding)
        self.transport.book=delayed
        poller=threading.Thread(target=self.runtime.step)
        poller.start()
        try:
            self.assertTrue(entered.wait(5))
            switched=self.call("configure",dict(expected_version="1",scopes=[scope(1,"demo"),scope(21,"testnet")]))
            self.assertEqual(switched["phase"],"Warming")
            self.assertFalse(switched["snapshot"]["candidates"])
        finally:
            released.set(); poller.join(timeout=10)
        self.assertFalse(poller.is_alive())
        self.tick()
        view=self.call("start")
        self.assertEqual(view["phase"],"Running")
        self.assertEqual({o["environment"] for o in view["market"]["observations"]},{"demo","testnet"})
        self.assertFalse(view["snapshot"]["candidates"])
        self.assertFalse(old_sessions & {e["session"] for e in view["market"]["evidence"]})

    def test_missing_catalogue_and_missing_rules_are_explicit(self):
        self.app.scanner_console=None
        status,body=self.http("/api/scanner",headers=self.headers)
        self.assertEqual(status,503)
        self.assertIn("unavailable",body["error"])
        self.app.scanner_console=self.runtime.console
        self.app.scanner_runtime=self.runtime
        self.transport.metadata=lambda binding: "{}"
        self.start()
        view=self.call("start")
        self.assertEqual(view["phase"],"Degraded")
        self.assertFalse(view["market"]["observations"])
        self.assertFalse(view["snapshot"]["candidates"])

    def test_unknown_quantity_and_sequence_regression_revoke_inputs(self):
        self.start()
        original=self.transport.book
        def unknown(binding):
            data=json.loads(original(binding))
            if binding["venue"]==21: data["levels"][0][0]["sz"]=None
            else: data["data"][0]["seqId"]=-1
            return json.dumps(data)
        self.transport.book=unknown
        self.tick()
        view=self.call("start")
        self.assertEqual(view["phase"],"Degraded")
        self.assertFalse(any(o["continuous"] for o in view["market"]["observations"]))
        self.assertFalse(any(c["recommended"] for c in view["snapshot"]["candidates"]))

    def test_normal_app_ignores_retired_market_file_and_stays_empty(self):
        for legacy in (None, "not valid JSON", "x" * 70000):
            with self.subTest(legacy_size=None if legacy is None else len(legacy)), tempfile.TemporaryDirectory() as directory:
                if legacy is not None:
                    Path(directory, "scanner-market.json").write_text(legacy)
                channel = control_plane.CommandServer(b"k"*32)
                app = None
                try:
                    app = control_plane_web.ControlPlaneApp(directory, channel)
                    view = app.scanner_console.view()
                    self.assertEqual(view["phase"], "Stopped")
                    self.assertEqual(view["exchanges"], [])
                    self.assertEqual(app.scanner_runtime.source.registered, {})
                    self.assertEqual(app.scanner_runtime.status()["active_subscriptions"], 0)
                finally:
                    if app is not None:
                        app.scanner_runtime.close()
                    channel.close()

    def test_relative_run_directory_starts_the_normal_native_feed(self):
        import os
        self.runtime.close()
        with tempfile.TemporaryDirectory(dir=Path.cwd()/".scratch/build") as directory:
            self.runtime=ScannerRuntime(os.path.relpath(directory),transport=self.transport,
                clock=lambda:self.now[0],utc_clock=lambda:self.now[1],automatic=False)
            self.app.scanner_console=self.runtime.console
            self.app.scanner_runtime=self.runtime
            self.start()
            self.assertEqual(self.call("start")["phase"],"Running")
            self.runtime.close()


if __name__ == "__main__": unittest.main()
