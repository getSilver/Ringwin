"""Scanner public lifecycle/history and authenticated Web boundaries."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from dataclasses import replace
import http.client
import threading

import control_plane
import control_plane_web

import scanner_console as c
from test_arbitrage_scanner import fixture
from test_arbitrage_evaluation import T


class ConsoleTests(unittest.TestCase):
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
                state = console.publish(run["session"], 1, observations, (plan,), at_ns=T)
                self.assertEqual(state, console.publish(run["session"], 1, observations, (plan,), at_ns=T))
                with self.assertRaisesRegex(ValueError, "identity conflict"):
                    console.publish(run["session"], 1, observations, (), at_ns=T)
                batch = console.history.query("batches")[0]["payload"]
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
            console, _, _, _ = self.make_console(directory)
            channel = control_plane.CommandServer(b"s"*32)
            app = control_plane_web.ControlPlaneApp(directory, channel, scanner_console=console)
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
            with patch("scanner_config.os.replace", side_effect=OSError("injected config rename failure")):
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
