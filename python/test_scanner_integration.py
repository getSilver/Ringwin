"""Real HTTP -> control plane -> native adapters/projection -> scan.

Synthetic protocol fixtures replace only the external public transport.
"""
import http.client
import json
from pathlib import Path
import tempfile
import threading
import unittest

import control_plane
import control_plane_web
import owner_session
from scanner_runtime import ScannerRuntime


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


def scope(venue, environment="production"):
    return dict(venue=str(venue), product="spot" if venue == 1 else "linear", environment=environment,
        include_assets=[], exclude_assets=[], quote_asset="3", min_depth_atoms=None,max_depth_atoms=None,new_instruments=False)


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
        self.call("configure",dict(expected_version="0",scopes=[scope(1),scope(21)]))
        self.assertEqual(self.call("start")["phase"],"Warming")
        self.tick()

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


if __name__ == "__main__": unittest.main()
