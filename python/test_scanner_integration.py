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
from opportunity_scanner.scanner_runtime import ScannerRuntime, PublicTransport


def configuration(environment="production"):
    return dict(schema=1, assets=[dict(identity="1", code="USDT", atomic_scale=6),
        dict(identity="3", code="USDC", atomic_scale=6), dict(identity="2", code="BTC", atomic_scale=8)], bindings=[
        dict(venue=1, environment=environment, symbol="BTC-USDC", product="spot", instrument=str(0x4f4b5800000003),
             observation_identity="1001", base_asset="2", quote_asset="3", rules_version=1,
             tick="0.1", lot_wire="0.00000001", lot_base="0.00000001"),
        dict(venue=21, environment="testnet" if environment == "demo" else "production", symbol="BTC", product="linear", instrument="2101",
             observation_identity="1021", base_asset="2", quote_asset="3", rules_version=1,
             tick="0.000001", lot_wire="0.0001", lot_base="0.0001",
             binding=dict(instrument=2101, coin="BTC", product="isolated_linear", universe_index=0, size_decimals=0,
                 rules_version=1, expected_metadata_digest=list(bytes.fromhex("57ad35cf0cdae7c2f454b350c9a2b05e89e21bebd3c37b3ab99c8077b843c209")),
                 price_scale=6, tick_atoms=1, quantity_scale=4, lot_atoms=1))])


class ProtocolTransport:
    """Synthetic bytes, never a final candidate or canonical snapshot."""
    input_kind = "synthetic_protocol_fixture"

    def __init__(self, clock):
        self.clock = clock
        self.sequence = 0
        self.fail = set()
        self.bad_rules = False
        self.stale = False
        self.oversize = False
        self.replay = False
        self.captured = {}

    def metadata(self, binding):
        if binding["venue"] == 21:
            return '{"collateralToken":0,"universe":[{"name":"BTC","szDecimals":0,"maxLeverage":40,"marginTableId":54}],"marginTables":[[54,{"marginTiers":[{"lowerBound":"0","maxLeverage":40}]}]]}'
        row=dict(instType="SPOT",instId=binding["symbol"],state="live",ruleType="normal",
            tickSz="0.2" if self.bad_rules else binding["tick"],lotSz=binding["lot_wire"],minSz="0.00001",tradeQuoteCcyList=[],upcChg=[])
        if binding["product"]=="linear":
            row.update(instType="SWAP",ctType="linear",ctVal=binding["contract_value"],ctValCcy="BTC",settleCcy="USDT")
        return json.dumps(dict(code="0",data=[row]))

    def book(self, binding):
        if self.replay: return self.captured[binding["venue"]]
        if binding["venue"] in self.fail:
            raise OSError("synthetic transport disconnected")
        if self.oversize: return "x" * (130*1024)
        self.sequence += 1
        milliseconds = self.clock[1]//1_000_000 - (60_000 if self.stale else 0)
        if binding["venue"] == 21:
            payload=json.dumps(dict(coin="BTC", time=milliseconds,
                levels=[[dict(px="50100",sz="2",n=1)],[dict(px="50101",sz="3",n=1)]]))
            self.captured[21]=payload
            return payload
        payload=json.dumps(dict(code="0",data=[dict(ts=str(milliseconds),seqId=self.sequence,
            bids=[["49999","2","0","1"]], asks=[["50000","3","0","1"]])]))
        self.captured[1]=payload
        return payload


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


def scope(venue, environment="production"):
    return dict(venue=str(venue), product="spot" if venue == 1 else "linear", environment=environment,
        include_assets=[], exclude_assets=[], quote_asset="3", min_depth_atoms=None,max_depth_atoms=None,new_instruments=False)


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
        self.runtime = ScannerRuntime(self.temp.name, dict(schema=1, assets=[], bindings=[]), transport=self.transport,
            clock=lambda:self.now[0], utc_clock=lambda:self.now[1], automatic=False)
        self.addCleanup(self.runtime.close)
        self.setting = dict(identity="a"*32, venue="1", type="okx", name="我的 OKX", environment="demo")

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

    def test_legacy_assembly_does_not_skip_settings_driven_discovery(self):
        self.runtime.close()
        self.runtime = ScannerRuntime(self.temp.name, configuration(), transport=self.transport, automatic=False)
        self.addCleanup(self.runtime.close)
        before = set(self.runtime.source.registered)
        original = self.transport.request
        def with_legacy(url, *args, **kwargs):
            value = json.loads(original(url, *args, **kwargs))
            if "instType=SPOT" in url:
                legacy = json.loads(json.dumps(value["data"][0]))
                legacy.update(instId="BTC-USDC", baseCcy="BTC", quoteCcy="USDC")
                value["data"].append(legacy)
            return json.dumps(value)
        self.transport.request = with_legacy
        self.setting["environment"] = "production"
        self.runtime.request_discovery(self.setting)
        for thread in self.runtime.discovery_threads:
            thread.join(timeout=20)
            self.assertFalse(thread.is_alive())
        self.assertEqual(self.runtime.status()["discovery"]["1:production"]["state"], "ready")
        self.assertTrue(before <= set(self.runtime.source.registered))
        self.assertTrue(any(r["symbol"] == "ETH-USDT" for r in self.runtime.bindings.values()))
        self.assertEqual(self.runtime.status()["active_subscriptions"], 0)

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
        restored = ScannerRuntime(self.temp.name, dict(schema=1, assets=[], bindings=[]), transport=self.transport, automatic=False)
        self.addCleanup(restored.close)
        self.assertEqual(set(restored.source.registered), before)
        self.assertEqual(restored.status()["active_subscriptions"], 0)


class HyperliquidCatalogueTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.now = [2_000_000_000, 1_800_000_000_000_000_000]
        self.transport = DynamicHyperliquidTransport(self.now)
        self.runtime = ScannerRuntime(self.temp.name, dict(schema=1, assets=[], bindings=[]), transport=self.transport,
            clock=lambda:self.now[0], utc_clock=lambda:self.now[1], automatic=False)
        self.addCleanup(self.runtime.close)
        self.setting = dict(identity="b"*32, venue="21", type="hyperliquid", name="永续", environment="production")

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

    def test_legacy_symbol_does_not_hide_saved_dynamic_identity_and_scope_after_restart(self):
        self.runtime.close()
        legacy = configuration()
        self.runtime = ScannerRuntime(self.temp.name, legacy, transport=self.transport,
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
        self.assertEqual(set(self.runtime.workers), {identity})
        self.assertTrue(self.runtime.status()["observations"][0]["continuous"])
        saved_scope = self.runtime.console.view()["config"]
        self.runtime.close()
        requests = len(self.transport.requests)
        self.runtime = ScannerRuntime(self.temp.name, legacy, transport=self.transport,
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
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.now = [2_000_000_000, 1_800_000_000_000_000_000]
        self.transport = ProtocolTransport(self.now)
        self.runtime = ScannerRuntime(self.temp.name, configuration(), transport=self.transport,
            clock=lambda:self.now[0], utc_clock=lambda:self.now[1], automatic=False)
        self.app = control_plane_web.ControlPlaneApp(self.temp.name,control_plane.CommandServer(b"k"*32),
                                                   scanner_console=self.runtime.console)
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
        return body["result"]

    def test_dynamic_refresh_lifecycle_through_http_and_native_adapters(self):
        settings = self.save_settings()["exchanges"]
        for hyperliquid in (False, True):
            with self.subTest(hyperliquid=hyperliquid):
                self.runtime.close()
                venue = 21 if hyperliquid else 1
                transport = RefreshTransport(self.now, hyperliquid)
                self.runtime = ScannerRuntime(Path(self.temp.name)/str(venue), dict(schema=1, assets=[], bindings=[]),
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
        transport.request = lambda url, body=None, **kw: (hl if body else okx).request(url, body, **kw)
        self.runtime = ScannerRuntime(Path(self.temp.name)/"mixed", dict(schema=1, assets=[], bindings=[]),
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

    def test_dynamic_hyperliquid_settings_scope_native_scan_and_restart(self):
        self.runtime.close()
        transport = DynamicHyperliquidTransport(self.now)
        self.runtime = ScannerRuntime(self.temp.name, dict(schema=1, assets=[], bindings=[]), transport=transport,
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
        self.runtime = ScannerRuntime(self.temp.name, dict(schema=1, assets=[], bindings=[]), transport=transport, automatic=False)
        self.assertEqual(set(self.runtime.source.registered), identities)
        self.assertEqual(self.runtime.console.desired, "stopped")
        self.assertEqual(self.runtime.status()["active_subscriptions"], 0)

    def test_dynamic_okx_discovery_and_scan_outside_original_allowlist(self):
        self.runtime.close()
        self.runtime = ScannerRuntime(self.temp.name, dict(schema=1, assets=[], bindings=[]),
            transport=DynamicOkxTransport(self.now), clock=lambda:self.now[0], utc_clock=lambda:self.now[1], automatic=False)
        self.app.scanner_console = self.runtime.console
        self.app.scanner_runtime = self.runtime
        self.runtime.console.exchange_settings = self.app.exchange_settings_store
        setting = self.save_settings()["exchanges"][0]
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
        self.runtime = ScannerRuntime(self.temp.name, dict(schema=1, assets=[], bindings=[]), transport=DynamicOkxTransport(self.now), automatic=False)
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
        self.assertTrue(all(r["catalogue_state"] == "registered" for r in view["exchanges"]))
        forged = dict(scope(1), setting_id="0"*32)
        status, body = self.http("/api/scanner", dict(operation="configure", payload=dict(expected_version="0", scopes=[forged])), self.headers)
        self.assertEqual(status, 400, body)
        self.assertEqual(self.call("stop")["config_version"], "0")
        self.call("configure", dict(expected_version="0", scopes=[scope(1), scope(21)]))
        self.assertTrue(all(r["setting_id"] in {s["identity"] for s in view["exchanges"]} for r in self.call("stop")["config"]["scopes"]))
        self.assertTrue(all(r["catalogue_state"] == "loading" for r in self.call("start")["exchanges"]))
        self.tick()
        self.assertEqual(len(self.call("start")["snapshot"]["candidates"]), 3)
        self.transport.fail.add(21); self.tick()
        failed = self.call("start")
        self.assertEqual(failed["exchanges"][1]["catalogue_state"], "failed")
        self.assertIn("disconnected", failed["exchanges"][1]["catalogue_error"])
        self.assertEqual(failed["exchanges"][1]["name"], "我的永续")
        self.runtime.close()
        self.runtime = ScannerRuntime(self.temp.name, configuration(), transport=self.transport, automatic=False)
        restored = control_plane_web.ControlPlaneApp(self.temp.name, self.app.command_server, scanner_console=self.runtime.console)
        restored_view = restored.scanner_console.view()
        self.assertEqual(restored_view["exchanges"], view["exchanges"])
        self.assertEqual((restored_view["desired"], restored_view["config_version"]), ("stopped", "1"))
        self.assertEqual(self.runtime.status()["active_subscriptions"], 0)

    def test_authenticated_full_chain_missing_evidence_history_and_restart(self):
        self.assertEqual(self.http("/api/scanner")[0],401)
        self.assertEqual(self.http("/api/scanner",dict(operation="start"),{"Cookie":self.cookie})[0],403)
        self.start()
        view=self.call("start")
        self.assertEqual(view["phase"],"Running",view)
        self.assertEqual(len(view["snapshot"]["candidates"]),3)
        self.assertTrue(all(c["reason"]=="missing_evidence" and not c["recommended"] for c in view["snapshot"]["candidates"]))
        self.assertEqual(len(view["market"]["observations"]),2)
        self.assertTrue(all(x["raw_sequence"]>=3 for x in view["market"]["evidence"]))
        self.assertTrue(self.call("history",dict(kind="batches",limit=10))["rows"])
        self.assertEqual(self.call("pause")["phase"],"Paused")
        self.assertFalse(self.call("pause")["snapshot"]["candidates"])
        self.call("start"); self.tick()
        self.assertEqual(self.call("stop")["phase"],"Stopped")
        self.assertEqual(self.call("stop")["phase"],"Stopped")
        self.runtime.close()
        self.runtime=ScannerRuntime(self.temp.name,configuration(),transport=self.transport,automatic=False)
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
        for row in rows: row["exclude_assets"]=["2"]
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
        self.runtime=ScannerRuntime(self.temp.name,configuration("demo"),transport=self.transport,
            clock=lambda:self.now[0],utc_clock=lambda:self.now[1],automatic=False)
        self.app.scanner_console=self.runtime.console
        self.call("configure",dict(expected_version="0",scopes=[scope(1,"demo"),scope(21,"testnet")]))
        self.call("start"); self.tick()
        view=self.call("start")
        self.assertEqual(len(view["market"]["observations"]),2)
        self.assertFalse(view["snapshot"]["candidates"],"different environments cannot form a pair")
        sources={(r["requested_environment"],r["actual_environment"]) for r in view["market"]["evidence"]}
        self.assertEqual(sources,{("demo","production"),("testnet","testnet")})

    def test_raw_write_capacity_revokes_input(self):
        config=configuration()
        config["bindings"][0]["raw_budget_bytes"]=8000
        self.runtime.close()
        self.runtime=ScannerRuntime(self.temp.name,config,transport=self.transport,
            clock=lambda:self.now[0],utc_clock=lambda:self.now[1],automatic=False)
        self.app.scanner_console=self.runtime.console
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
        import copy
        config=configuration()
        alternative=copy.deepcopy(configuration("demo")["bindings"])
        for row in alternative: row["observation_identity"]=str(int(row["observation_identity"])+100)
        config["bindings"]+=alternative
        self.runtime.close()
        self.runtime=ScannerRuntime(self.temp.name,config,transport=self.transport,
            clock=lambda:self.now[0],utc_clock=lambda:self.now[1],automatic=False)
        self.app.scanner_console=self.runtime.console
        self.start()
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

    def test_other_declared_okx_products_keep_contract_and_quote_units(self):
        import copy
        for symbol,instrument,product,lot_wire,lot_base in (
                ("BTC-USDT",0x4f4b5800000001,"spot","0.00000001","0.00000001"),
                ("BTC-USDT-SWAP",0x4f4b5800000002,"linear","0.01","0.0001")):
            self.runtime.close()
            with tempfile.TemporaryDirectory() as directory:
                config=configuration(); row=config["bindings"][0]
                row.update(symbol=symbol,instrument=str(instrument),product=product,quote_asset="1",lot_wire=lot_wire,lot_base=lot_base)
                if product=="linear": row["contract_value"]="0.01"
                self.runtime=ScannerRuntime(directory,config,transport=self.transport,
                    clock=lambda:self.now[0],utc_clock=lambda:self.now[1],automatic=False)
                self.app.scanner_console=self.runtime.console
                first=scope(1);first.update(product=product,quote_asset="1")
                self.call("configure",dict(expected_version="0",scopes=[first,scope(21)]));self.call("start");self.tick()
                view=self.call("start")
                self.assertEqual(view["phase"],"Running",view)
                self.assertEqual(len(view["market"]["observations"]),2)
                self.assertFalse(view["snapshot"]["candidates"],"USDT and USDC cannot pair")
                self.runtime.close()

    def test_normal_app_loads_market_assembly_and_stays_stopped(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory,"scanner-market.json").write_text(json.dumps(configuration()))
            app=control_plane_web.ControlPlaneApp(directory,control_plane.CommandServer(b"k"*32))
            try:
                self.assertEqual(app.scanner_console.view()["phase"],"Stopped")
            finally:
                app.scanner_runtime.close()
                app.command_server.close()

    def test_relative_run_directory_starts_the_normal_native_feed(self):
        import os
        self.runtime.close()
        with tempfile.TemporaryDirectory(dir=Path.cwd()/".scratch/build") as directory:
            self.runtime=ScannerRuntime(os.path.relpath(directory),configuration(),transport=self.transport,
                clock=lambda:self.now[0],utc_clock=lambda:self.now[1],automatic=False)
            self.app.scanner_console=self.runtime.console
            self.start()
            self.assertEqual(self.call("start")["phase"],"Running")
            self.runtime.close()


if __name__ == "__main__": unittest.main()
