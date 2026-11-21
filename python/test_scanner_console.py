"""Scanner public lifecycle/history and authenticated Web boundaries."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from dataclasses import replace
from fractions import Fraction
import http.client
import socket
import struct
import threading
import time

import control_plane
import control_plane_node
import control_plane_web
import owner_session

from opportunity_scanner import scanner_console as c
from strategies.cross_venue.arbitrage_economics import FxRate
from test_arbitrage_scanner import fixture
from test_arbitrage_evaluation import T


class ConsoleTests(unittest.TestCase):
    def test_authenticated_approval_maps_only_the_selected_demo_testnet_route(self):
        from verify_production_strategy_web import child, receive
        from verify_scanner_console import canonical_fixture, PASSPHRASE, ROOT
        from strategy_host import encode_depth_snapshot
        binary = "ringwin-strategy-authority-probe" + (".exe" if os.name == "nt" else "")
        probe = os.environ.get("RINGWIN_SCANNER_APPROVAL_PROBE", str(ROOT / "zig-out" / "bin" / binary))
        web, writer = socket.socketpair()
        with tempfile.TemporaryDirectory() as directory, web, writer, child(
                [probe, "-", "deployed-scanner"], stdin=subprocess.PIPE, stdout=subprocess.PIPE) as core:
            writer.settimeout(10)
            authority = control_plane_node.EngineStrategyAuthority(web)
            observations, plan = canonical_fixture(
                accounts=(701, 702), environments=("demo", "testnet"), instruments=(201, 102),
                market_sources=(("production", "fixture-demo-feed", "synthetic_protocol_fixture"),
                                ("testnet", "fixture-testnet-feed", "synthetic_protocol_fixture")))
            a = observations[0]
            book = c.scanner.decode_depth_snapshot(a.book)
            book["instrument"] = 105
            other = replace(a, rules=replace(a.rules, instrument=105), book=encode_depth_snapshot(book))
            observation_rows = observations + (other,)
            now = [T]
            console = c.ScannerConsole(c.CanonicalSource(observation_rows), c.History(clock=lambda: 1000),
                clock=lambda: now[0], wall_clock=lambda: 1000)
            self.addCleanup(console.close)
            commands = control_plane.CommandServer(b"s"*32)
            self.addCleanup(commands.close)
            app = control_plane_web.ControlPlaneApp(directory, commands, scanner_console=console,
                engine_strategy_authority=authority)
            for version, (kind, environment) in enumerate((("okx", "demo"), ("hyperliquid", "testnet"))):
                app.exchange_settings_store.save(dict(expected_version=str(version), type=kind, name=kind,
                    environment=environment))
            self.assertEqual(app.setup(PASSPHRASE)[0], 200)
            status, session = app.login(PASSPHRASE, owner_session.totp_at(app.totp.read_secret(), int(time.time())), "offline")
            self.assertEqual(status, 200)
            headers = {"Cookie": "owner_session=" + session["session_token"], "X-Owner-CSRF": session["csrf_token"]}
            server = control_plane_web.serve(app)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()

            def post(operation, payload=None, headers=headers):
                request = {"operation": operation}
                if payload is not None:
                    request["payload"] = payload
                client = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)
                try:
                    client.request("POST", "/api/scanner", json.dumps(request), headers=headers)
                    response = client.getresponse()
                    return response.status, json.load(response)
                finally:
                    client.close()

            pair = dict(direction=1, mode="taker_taker", legs=[
                dict(venue=1, environment="demo", account=f"{20:032x}", instrument=f"{103:032x}"),
                dict(venue=21, environment="testnet", account=f"{30:032x}", instrument=f"{102:032x}")])
            pair["identity"] = f"{100:032x}"
            frames = []
            errors = []
            ready = threading.Event()

            def relay():
                try:
                    if core.stdout.read(2) != b"HV":
                        raise EOFError("offline Writer did not start")
                    ready.set()
                    for _ in range(6):
                        prefix = receive(writer, 5)
                        size, = struct.unpack("<I", prefix[1:])
                        payload = receive(writer, size)
                        frames.append((prefix[:1], json.loads(payload)))
                        core.stdin.write(prefix + payload)
                        core.stdin.flush()
                        length = core.stdout.read(4)
                        if len(length) != 4:
                            raise EOFError("offline Writer disconnected")
                        reply_size, = struct.unpack("<I", length)
                        writer.sendall(length + core.stdout.read(reply_size))
                except (OSError, EOFError) as error:
                    errors.append(error)

            worker = threading.Thread(target=relay, daemon=True)
            worker.start()
            try:
                self.assertTrue(ready.wait(30), errors)
                self.assertEqual(post("approval_targets", headers={})[0], 401)
                status, result = post("approval_targets")
                self.assertEqual(status, 200, result)
                self.assertEqual(result["result"]["bindings"],
                    [dict(strategy_identity="9", portfolio_identity="10")])
                scopes = [dict(venue=str(x.venue), environment=x.environment, product=x.kind, include_assets=[],
                    exclude_assets=[], quote_asset="1", min_depth_atoms=None, max_depth_atoms=None,
                    new_instruments=False) for x in observations]
                status, result = post("configure", dict(expected_version="0", scopes=scopes))
                self.assertEqual(status, 200, result)
                run = post("start")[1]["result"]
                console.publish(run["session"], 1, observation_rows, (plan,), at_ns=T,
                    input_versions={plan.policy.scope: {str(plan.policy.original_base): {"fees": "0"}}})
                candidates = console.view()["snapshot"]["candidates"]
                candidate, = [row for row in candidates if row["status"] == "evaluated"]
                self.assertTrue(any(row["pair"][0][-1] == "105" for row in candidates))
                mapping = Path(directory, "scanner-trading-instruments.json")
                mapping.write_text(json.dumps({"1:demo:201": {"instrument": "103", "account": "20"}}))
                selection = dict(identity="100", candidate_id=candidate["id"], strategy_identity="9",
                    portfolio_identity="10", expected_config_version="1", expected_core_version=None, enabled=True)
                self.assertEqual(post("approve", selection, headers={"Cookie": headers["Cookie"]})[0], 403)
                status, result = post("approve", selection)
                self.assertEqual(status, 200, result)
                receipt = result["result"]
                self.assertEqual(receipt["pair"], pair)
                self.assertEqual(receipt["core_version"], "1")
                self.assertEqual([row["account"] for row in receipt["observation_legs"]], ["701", "702"])
                self.assertEqual([row["actual_environment"] for row in receipt["observation_legs"]], ["production", "testnet"])
                self.assertEqual(post("approve", selection)[1], result)
                self.assertEqual(post("approval_status", "100")[1]["result"], receipt)
                mapping.unlink()
                self.assertEqual(post("approve", dict(selection, identity="101"))[1]["result"]["reason"], "UnmappedPairFirstLeg")
                now[0] = T+50
                status, result = post("approve", dict(selection, identity="102"))
                self.assertEqual(status, 400)
                self.assertIn("expired", result["error"])
                client = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)
                try:
                    client.request("GET", "/api/strategy-instances", headers=headers)
                    response = client.getresponse()
                    self.assertEqual(response.status, 200)
                    instance, = json.load(response)["instances"]
                    self.assertEqual(instance["pair_trading_list"], [pair])
                    self.assertFalse(instance["trading_authorized"])
                finally:
                    client.close()
                worker.join(timeout=5)
                self.assertFalse(worker.is_alive())
                self.assertFalse(errors)
                self.assertEqual([prefix for prefix, _ in frames], [b"P", b"P", b"Q", b"P", b"Q", b"P"])
                submitted = frames[2][1]
                self.assertEqual((submitted["strategy"], submitted["portfolio"], submitted["direction"], submitted["mode"]),
                    ("9", "10", 1, "taker_taker"))
                self.assertEqual(submitted["legs"], [
                    dict(venue=1, environment="demo", instrument="103", account="20", product="isolated_linear",
                         base_asset="4346947", settlement_asset="1"),
                    dict(venue=21, environment="testnet", instrument="102", product="isolated_linear",
                         base_asset="4346947", settlement_asset="1"),
                ])
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=5)

    def test_offline_development_http_does_not_require_login(self):
        from verify_scanner_console import Fixture
        with tempfile.TemporaryDirectory() as directory:
            node = Fixture(directory, development=True)
            self.addCleanup(node.close)
            client = http.client.HTTPConnection("127.0.0.1", node.server.server_port, timeout=5)
            self.addCleanup(client.close)
            client.request("GET", "/api/scanner")
            response = client.getresponse()
            self.assertEqual(response.status, 200)
            view = json.loads(response.read())["result"]
            self.assertEqual(view["desired"], "stopped")
            scopes = [{"venue": row["venue"], "product": row["product"], "environment": row["environment"],
                       "include_assets": [], "exclude_assets": [], "quote_asset": None,
                       "min_depth_atoms": None, "max_depth_atoms": None, "new_instruments": False}
                      for row in view["catalogue"]]
            client.request("POST", "/api/scanner", json.dumps({"operation": "configure", "payload": {
                "expected_version": view["config_version"], "scopes": scopes}}), {"Content-Type": "application/json"})
            response = client.getresponse()
            self.assertEqual(response.status, 200, response.read())
            client.request("POST", "/api/scanner", json.dumps({"operation": "start"}),
                           {"Content-Type": "application/json"})
            response = client.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(json.loads(response.read())["result"]["desired"], "running")

    def make_console(self, directory, now=None):
        observations, plan = fixture()
        now = now if now is not None else [T]
        console = c.ScannerConsole(c.CanonicalSource(observations), c.History(clock=lambda: 1000),
                                   clock=lambda: now[0], wall_clock=lambda: 1000, max_age_ns=1000)
        self.addCleanup(console.close)
        config = {"expected_version": "0", "scopes": [
            {"venue": str(x.venue), "product": x.kind, "environment": x.environment,
             "include_assets": [], "exclude_assets": [], "quote_asset": "1",
             "min_depth_atoms": None, "max_depth_atoms": None, "new_instruments": False} for x in observations]}
        console.configure(config)
        return console, observations, plan, config

    def test_duplicate_order_old_session_ttl_and_replay(self):
        with tempfile.TemporaryDirectory() as directory:
            now = [T]
            console, observations, plan, _ = self.make_console(directory, now)
            try:
                run = console.start()
                rate = FxRate(Fraction(998, 1000), T, "USDC-USDT spot")
                state = console.publish(run["session"], 1, observations, (plan,), at_ns=T, fx_rate=rate)
                self.assertEqual(state, console.publish(run["session"], 1, observations, (plan,), at_ns=T, fx_rate=rate))
                with self.assertRaisesRegex(ValueError, "identity conflict"):
                    console.publish(run["session"], 1, observations, (plan,), at_ns=T, fx_rate=replace(rate, source="other"))
                with self.assertRaisesRegex(ValueError, "identity conflict"):
                    console.publish(run["session"], 1, observations, (), at_ns=T)
                batch = console.history.query("batches")[0]["payload"]
                self.assertIn("USDC-USDT spot", console.history.artifact(batch["evidence"][0]))
                self.assertTrue(console.replay(batch["evidence"][0])["matches"])
                now[0] = T+50
                expired = console.view()
                self.assertFalse(any(x["recommended"] for x in expired["snapshot"]["candidates"]))
                self.assertEqual(expired["sequence"], console.view()["sequence"])
                console.stop()
                newer = console.start()
                self.assertNotEqual(run["session"], newer["session"])
                with self.assertRaisesRegex(ValueError, "inactive scanner session"):
                    console.publish(run["session"], 2, observations, (), at_ns=T+50)
            finally:
                console.close()

    def test_pause_revokes_projection_and_resume_uses_new_warmup_session(self):
        with tempfile.TemporaryDirectory() as directory:
            console, observations, plan, _ = self.make_console(directory)
            run = console.start()
            console.publish(run["session"], 1, observations, (plan,), at_ns=T)
            console.source.acquire("other-consumer", set(console.source.registered))
            paused = console.pause()
            self.assertEqual((paused["phase"], paused["desired"]), ("Paused", "paused"))
            self.assertEqual(paused["snapshot"]["candidates"], [])
            self.assertIn("other-consumer", console.source.owners)
            self.assertEqual(console.history.query("events")[0]["end_reason"], "paused")
            self.assertEqual(console.pause()["sequence"], paused["sequence"])
            with self.assertRaisesRegex(ValueError, "inactive scanner session"):
                console.publish(run["session"], 2, observations, (plan,), at_ns=T)
            resumed = console.start()
            self.assertNotEqual(run["session"], resumed["session"])
            self.assertEqual(resumed["phase"], "Warming")
            console.stop()

    def test_new_instruments_policy_replays_effective_registered_scope(self):
        from test_arbitrage_evaluation import wire
        with tempfile.TemporaryDirectory() as directory:
            console, observations, _, config = self.make_console(directory)
            try:
                config["expected_version"] = "1"
                for row in config["scopes"]:
                    row["new_instruments"] = True
                console.configure(config)
                run = console.start()
                added = replace(observations[0], rules=replace(observations[0].rules, instrument=3),
                                book=wire(3, T, 1000, 1001))
                console.source.register((added,))
                console.publish(run["session"], 1, observations+(added,), at_ns=T)
                self.assertEqual(len(console.view()["snapshot"]["candidates"]), 12)
                digest = console.history.query("batches")[0]["payload"]["evidence"][0]
                self.assertTrue(console.replay(digest)["matches"])
            finally:
                console.close()

    def test_config_conflict_invalid_bounds_and_empty_filter(self):
        with tempfile.TemporaryDirectory() as directory:
            console, observations, _, config = self.make_console(directory)
            try:
                with self.assertRaisesRegex(ValueError, "version conflict"):
                    console.configure(config)
                changed = json.loads(json.dumps(config))
                changed["expected_version"] = "1"
                changed["scopes"][0].update(min_depth_atoms="10", max_depth_atoms="1")
                with self.assertRaisesRegex(ValueError, "scan_depth_range"):
                    console.configure(changed)
                self.assertEqual(console.view()["config"]["version"], "1")
                changed["scopes"][0].update(min_depth_atoms="0", max_depth_atoms="0")
                console.configure(changed)
                run = console.start()
                state = console.publish(run["session"], 1, observations, at_ns=T)
                self.assertEqual(state["snapshot"]["candidates"], [])
                self.assertEqual(state["phase"], "Running")
            finally:
                console.close()

    def test_shared_subscription_release_and_failed_core_cannot_grant_authority(self):
        with tempfile.TemporaryDirectory() as directory:
            console, observations, plan, _ = self.make_console(directory)
            try:
                console.source.acquire("other_consumer", {observations[0].identity})
                run = console.start()
                console.publish(run["session"], 1, observations, (plan,), at_ns=T)
                candidate = next(x for x in console.view()["snapshot"]["candidates"] if x["recommended"])
                with self.assertRaisesRegex(ValueError, "core pair authorization unavailable"):
                    console.request_approval(dict(identity="1", candidate_id=candidate["id"], strategy_identity="9",
                        portfolio_identity="10", expected_config_version="1", expected_core_version="0", enabled=True))
                console.stop()
                self.assertEqual(console.source.owners, {"other_consumer": {observations[0].identity}})
            finally:
                console.close()

    def test_memory_history_idempotence_conflict_events_and_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            console, observations, plan, _ = self.make_console(directory)
            try:
                run = console.start()
                console.publish(run["session"], 1, observations, (plan,), at_ns=T)
                stored = console.history.query("batches")[0]["payload"]
                console.history.batch(stored, wall_ms=1000, threshold=console.config["statistics"], evidence={})
                changed = dict(stored, config_version="999")
                with self.assertRaisesRegex(ValueError, "identity conflict"):
                    console.history.batch(changed, wall_ms=1000, threshold=console.config["statistics"], evidence={})
                console.stop()
                events = console.history.query("events")
                self.assertEqual(len(events), 1)
                self.assertTrue(events[0]["right_censored"])
                self.assertEqual(events[0]["duration_ns"], "0")
                self.assertTrue(events[0]["replayable"])
                summary = console.history.summarize()
                self.assertEqual(sum(x["events"] for x in summary["groups"].values()), 1)
                self.assertEqual(summary, console.history.summarize())
                self.assertEqual(console.history.status()["storage"], "memory")
                self.assertTrue(console.history.status()["restart_clears_history"])
                self.assertEqual(list(Path(directory).iterdir()), [])
            finally:
                console.close()

    def test_http_authorization_csrf_and_no_market_or_receipt_injection(self):
        with tempfile.TemporaryDirectory() as directory:
            from verify_scanner_console import canonical_fixture
            observations, _ = canonical_fixture()
            console = c.ScannerConsole(c.CanonicalSource(observations), c.History())
            channel = control_plane.CommandServer(b"s"*32)
            app = control_plane_web.ControlPlaneApp(directory, channel, scanner_console=console)
            for index, kind in enumerate(("okx", "hyperliquid")):
                app.exchange_settings_store.save(dict(expected_version=str(index), type=kind, name=kind, environment="production"))
            console.configure(dict(expected_version="0", scopes=[dict(venue=str(o.venue), product=o.kind,
                environment=o.environment, include_assets=[], exclude_assets=[], quote_asset=None,
                min_depth_atoms=None, max_depth_atoms=None, new_instruments=False) for o in observations]))
            token = app.sessions.issue(app.clock)
            import hashlib
            app.csrf_by_token_hash[hashlib.sha256(token.encode()).hexdigest()] = "scanner-csrf"
            server = control_plane_web.serve(app)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            def call(body, headers):
                client = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)
                client.request("POST", "/api/scanner", body=json.dumps(body), headers=headers)
                response = client.getresponse()
                result = response.status, json.loads(response.read())
                client.close()
                return result
            try:
                self.assertEqual(call({"operation": "start"}, {})[0], 401)
                headers = {"Cookie": "owner_session="+token}
                self.assertEqual(call({"operation": "start"}, headers)[0], 403)
                headers["X-Owner-CSRF"] = "scanner-csrf"
                self.assertEqual(call({"operation": "start"}, headers)[0], 200)
                lower = {"cookie": "owner_session="+token}
                self.assertEqual(call({"operation": "pause"}, lower)[0], 403)
                lower["x-owner-csrf"] = "scanner-csrf"
                self.assertEqual(call({"operation": "pause"}, lower)[0], 200)
                self.assertEqual(call({"operation": "start"}, headers)[0], 200)
                pause_status, pause_body = call({"operation": "pause"}, headers)
                self.assertEqual(pause_status, 200)
                self.assertEqual(pause_body["result"]["desired"], "paused")
                self.assertEqual(call({"operation": "start"}, headers)[0], 200)
                self.assertEqual(call({"operation": "receipt", "payload": {"status": "accepted"}}, headers)[0], 400)
                self.assertEqual(call({"operation": "publish", "payload": {}}, headers)[0], 400)
                self.assertEqual(call({"operation": "stop"}, headers)[0], 200)
            finally:
                server.shutdown()
                server.server_close()
                thread.join()
                channel.close()
                console.close()

    def test_start_publish_stop_and_restart_clear_history_without_authority(self):
        observations, plan = fixture()
        with tempfile.TemporaryDirectory() as directory:
            source = c.CanonicalSource(observations)
            history = c.History(clock=lambda: 1000)
            console = c.ScannerConsole(source, history, clock=lambda: T, wall_clock=lambda: 1000)
            self.assertEqual(console.view()["phase"], "Stopped")
            console.configure({"expected_version": "0", "scopes": [
                {"venue": str(x.venue), "product": x.kind, "environment": "simulation",
                 "include_assets": [], "exclude_assets": [], "quote_asset": "1",
                 "min_depth_atoms": None, "max_depth_atoms": None, "new_instruments": False}
                for x in observations]})
            run = console.start()
            self.assertEqual(run["phase"], "Warming")
            console.publish(run["session"], 1, observations, (plan,), at_ns=T)
            self.assertEqual(console.view()["phase"], "Running")
            self.assertTrue(any(x["recommended"] for x in console.view()["snapshot"]["candidates"]))
            console.stop()
            self.assertFalse(console.view()["snapshot"]["candidates"])
            self.assertEqual(history.query("events")[0]["end_reason"], "stopped")
            console.close()
            restored = c.ScannerConsole(source, c.History(clock=lambda: 1000),
                                         clock=lambda: T, wall_clock=lambda: 1000)
            self.assertEqual(restored.view()["desired"], "stopped")
            self.assertEqual(restored.history.query("batches"), [])
            self.assertEqual(restored.history.query("events"), [])
            self.assertEqual(restored.view()["config"]["version"], "0")
            restored.close()

    def test_config_file_survives_restart_while_history_and_receipts_clear(self):
        observations, _ = fixture()
        with tempfile.TemporaryDirectory() as directory:
            console, _, _, config = self.make_console(directory)
            target = Path(directory)/"scanner-config.json"
            console.bind_config(target)
            saved = target.read_text(encoding="utf-8")
            console.history.request("1", {"selection": {}}, {"status": "unknown"})
            change = {**config, "expected_version": "1", "scopes": [{**row, "min_depth_atoms": "0"} for row in config["scopes"]]}
            with patch("opportunity_scanner.scanner_config.os.replace", side_effect=OSError("injected config rename failure")):
                with self.assertRaisesRegex(OSError, "rename failure"):
                    console.configure(change)
            self.assertEqual(console.view()["config"]["version"], "1")
            self.assertEqual(target.read_text(encoding="utf-8"), saved)
            self.assertEqual(list(Path(directory).glob("*.tmp")), [])
            console.close()
            restored = c.ScannerConsole(c.CanonicalSource(observations), c.History(clock=lambda: 1000),
                config_path=target, clock=lambda: T, wall_clock=lambda: 1000)
            try:
                self.assertEqual(restored.view()["phase"], "Stopped")
                self.assertEqual(restored.view()["config"]["version"], "1")
                self.assertEqual(len(restored.view()["config"]["scopes"]), 2)
                self.assertEqual(restored.history.query("events"), [])
                self.assertEqual(restored.history.query("operations"), [])
                with self.assertRaisesRegex(ValueError, "unknown scanner request"):
                    restored.history.request("1")
            finally:
                restored.close()

    def test_corrupt_saved_config_is_rejected_instead_of_reset(self):
        observations, _ = fixture()
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)/"scanner-config.json"
            target.write_text('{"schema":"scanner_config_v1","config":{}}', encoding="utf-8")
            with self.assertRaises(ValueError):
                c.ScannerConsole(c.CanonicalSource(observations), c.History(), config_path=target)


class BrowserFixtureTests(unittest.TestCase):
    def test_browser_timescale_rebinds_evidence_and_keeps_expiry(self):
        from verify_scanner_console import canonical_fixture, browser_inputs
        observations, plan = canonical_fixture()
        scale = 10_000_000_000
        observations, plan = browser_inputs(observations, plan, scale)
        snapshot = c.scanner.scan(observations, (plan,), at_ns=plan.policy.at_ns,
            cursor=1, max_age_ns=1000*scale, max_skew_ns=10*scale)
        row = next(x for x in snapshot["candidates"] if x["recommended"])
        self.assertEqual(row["plan_atoms"], "8000000")
        self.assertEqual(int(row["valid_until_ns"])-plan.policy.at_ns, 50*scale)
        expired = c.scanner.scan(observations, (plan,), at_ns=int(row["valid_until_ns"]),
            cursor=2, max_age_ns=1000*scale, max_skew_ns=10*scale)
        self.assertFalse(any(x["recommended"] for x in expired["candidates"]))


if __name__ == "__main__":
    unittest.main()
