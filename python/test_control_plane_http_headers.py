"""Proxy-normalized HTTP header names must preserve OwnerSession authorization."""
import http.client
import json
from pathlib import Path
import secrets
import socket
import struct
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import control_plane
import control_plane_node
import control_plane_web
import owner_session
import strategy_package


class HttpHeaderAuthenticationTest(unittest.TestCase):
    def test_strategy_pair_revocation_recovers_lost_receipt_after_web_restart(self):
        strategy, portfolio, approval = (f"{value:032x}" for value in (9, 10, 98766))
        path = "/api/strategy-pairs"
        binding = dict(strategy_identity=strategy, portfolio_identity=portfolio)
        revoke = dict(binding, operation="revoke_pair", identity=approval)
        query = dict(revoke, operation="pair_revocation_status")
        receipt = dict(identity="98766", status="accepted", core_version="2", barrier="70")
        pair = dict(identity=approval)
        frames = []
        effective = [pair]

        def relay_responses(stream, operations):
            with stream, stream.makefile("rb") as reader:
                for operation in operations:
                    prefix = reader.read(5)
                    request = json.loads(reader.read(struct.unpack("<I", prefix[1:])[0]))
                    frames.append((prefix[0:1], request))
                    if operation == "drop_revocation_reply":
                        effective.clear()
                        return
                    if operation == "strategy_instances":
                        response = {"instances": [{"binding": binding, "pair_trading_list": effective}]}
                    else:
                        response = receipt
                    payload = strategy_package.canonical(response)
                    stream.sendall(struct.pack("<I", len(payload)) + payload)

        with tempfile.TemporaryDirectory() as directory:
            password = secrets.token_urlsafe(24)
            owner_session.PassphraseStore(directory).set(password)
            totp = owner_session.TotpStore(directory).initialize()
            started_at = int(time.time())
            for restart, operations in enumerate((
                    ("strategy_instances", "drop_revocation_reply"),
                    ("pair_revocation_status", "revoke_pair", "strategy_instances"))):
                web, relay = socket.socketpair()
                with web, relay:
                    relay.settimeout(5)
                    worker = threading.Thread(target=relay_responses, args=(relay, operations), daemon=True)
                    worker.start()
                    authority = control_plane_node.EngineStrategyAuthority(web)
                    commands = control_plane.CommandServer(secrets.token_bytes(32))
                    with control_plane_node.open_node_web(directory=directory, ui_path=Path(directory, "index.html"),
                            port=0, projection=None, command_server=commands,
                            engine_strategy_authority=authority) as (app, server):
                        now = started_at + restart * owner_session.TOTP_STEP
                        app.clock = lambda: now
                        status, login = app.login(password, owner_session.totp_at(totp, now), "test")
                        self.assertEqual(status, 200)
                        headers = {"Cookie": "owner_session=" + login["session_token"],
                                   "X-Owner-CSRF": login["csrf_token"]}
                        web_thread = threading.Thread(target=server.serve_forever, daemon=True)
                        web_thread.start()
                        connection = http.client.HTTPConnection(*server.server_address, timeout=5)

                        def send(method, url, document=None, request_headers=headers):
                            connection.request(method, url, json.dumps(document) if document else None, request_headers)
                            response = connection.getresponse()
                            return response.status, json.load(response)

                        try:
                            if not restart:
                                self.assertEqual(send("POST", path, revoke, {})[0], 401)
                                self.assertEqual(send("POST", path, revoke, {"Cookie": headers["Cookie"]})[0], 403)
                                status, result = send("GET", "/api/strategy-instances")
                                self.assertEqual(status, 200)
                                self.assertEqual(result["instances"][0]["pair_trading_list"], [pair])
                                self.assertEqual(send("POST", path, revoke)[0], 503)
                            else:
                                for request in (query, revoke):
                                    status, result = send("POST", path, request)
                                    self.assertEqual(status, 200)
                                    self.assertEqual(result["result"], receipt)
                                status, result = send("GET", "/api/strategy-instances")
                                self.assertEqual(status, 200)
                                self.assertEqual(result["instances"][0]["pair_trading_list"], [])
                        finally:
                            connection.close()
                            server.shutdown()
                            web_thread.join(timeout=5)
                            worker.join(timeout=5)
        revoke_frame = (b"Q", dict(operation="revoke_pair", strategy="9", portfolio="10", identity="98766"))
        query_frame = (b"P", dict(operation="pair_revocation_status", strategy_identity=strategy,
                                  portfolio="10", identity="98766"))
        instances_frame = (b"P", {"operation": "strategy_instances"})
        self.assertEqual(frames, [instances_frame, revoke_frame, query_frame, revoke_frame, instances_frame])

    def test_node_supplies_strategy_management_to_the_existing_web_launcher(self):
        with tempfile.TemporaryDirectory() as directory:
            strategy = f"{9:032x}"
            accounts = [f"{20:032x}", f"{30:032x}"]
            Path(directory, "strategy-instances.jsonl").write_bytes(strategy_package.canonical({
                "binding": {"strategy_identity": strategy, "scopes": [
                    {"venue": venue, "exchange_account": account}
                    for venue, account in zip(("okx", "bybit"), accounts)]},
                "status": "Stopped",
            }) + b"\n")

            def request(value):
                self.assertEqual(value, dict(operation="pair_trading_list",
                                             strategy_identity=strategy, scope_accounts=accounts))
                return {"pairs": []}

            source = SimpleNamespace(authority=SimpleNamespace(request=request))
            commands = control_plane.CommandServer(secrets.token_bytes(32))

            with patch.object(owner_session.PassphraseStore, "exists", return_value=True), \
                    patch.object(control_plane_web.ControlPlaneApp, "authorize", return_value=(200, {})):
                with control_plane_node.open_node_web(directory=directory, ui_path=Path(directory, "index.html"),
                        port=0, projection=None, command_server=commands, release_manager=object(),
                        lifecycle_outbox=object(), instance_source=source) as (app, server):
                    self.assertIs(app.instance_manager.source, source)
                    thread = threading.Thread(target=server.serve_forever, daemon=True)
                    thread.start()
                    try:
                        connection = http.client.HTTPConnection(*server.server_address, timeout=5)
                        try:
                            connection.request("GET", "/api/strategy-instances")
                            response = connection.getresponse()
                            self.assertEqual(response.status, 200)
                            result = json.load(response)
                            self.assertEqual(result["instances"][0]["pair_trading_list"], [])
                        finally:
                            connection.close()
                    finally:
                        server.shutdown()
                        thread.join(timeout=5)

    def test_engine_pair_list_framing_distinguishes_empty_list_entries_and_failure(self):
        web, relay = socket.socketpair()
        with web, relay:
            relay.settimeout(5)
            authority = control_plane_node.EngineStrategyAuthority(web)
            request = dict(operation="pair_trading_list", strategy_identity=f"{9:032x}",
                           scope_accounts=[f"{20:032x}", f"{30:032x}"])
            instances_request = {"operation": "strategy_instances"}
            frames = []
            pair = {"identity": f"{99:032x}", "direction": 1, "mode": "approve",
                    "legs": [{"venue": 1}, {"venue": 2}]}

            def serve():
                with relay.makefile("rb") as stream:
                    for result in ({"pairs": []}, {"pairs": [pair]}, {"error": "DecisionLogUnavailable"},
                                   {"instances": []}, {"error": "DecisionLogUnavailable"}):
                        prefix = stream.read(5)
                        frames.append((prefix[:1], json.loads(stream.read(struct.unpack("<I", prefix[1:])[0]))))
                        response = strategy_package.canonical(result)
                        relay.sendall(struct.pack("<I", len(response)) + response)
                relay.shutdown(socket.SHUT_RDWR)

            worker = threading.Thread(target=serve, daemon=True)
            worker.start()
            try:
                self.assertEqual(authority.request(request), {"pairs": []})
                self.assertEqual(authority.request(request), {"pairs": [pair]})
                with self.assertRaisesRegex(ValueError, "DecisionLogUnavailable"):
                    authority.request(request)
                self.assertEqual(authority.instances(), [])
                with self.assertRaisesRegex(ValueError, "DecisionLogUnavailable"):
                    authority.instances()
                with self.assertRaises(OSError):
                    authority.instances()
            finally:
                worker.join(timeout=5)
            self.assertEqual(frames, [(b"P", request)] * 3 + [(b"P", instances_request)] * 2)

    def test_browser_history_routes_reload_the_ui_and_keep_api_authentication(self):
        with tempfile.TemporaryDirectory() as directory:
            page = Path(directory, "index.html")
            page.write_bytes(b"<!doctype html><title>Ringwin scanner</title>")
            commands = control_plane.CommandServer(secrets.token_bytes(32))
            self.addCleanup(commands.close)
            app = control_plane_web.ControlPlaneApp(directory, commands, ui_path=page)
            self.addCleanup(app.scanner_runtime.close)
            server = control_plane_web.serve(app)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                for path, expected in (("/app/scanner/opportunities", 200),
                        ("/app/control/overview?view=health", 200),
                        ("/api/scanner", 401), ("/api/not-found", 404)):
                    with self.subTest(path=path):
                        connection = http.client.HTTPConnection(*server.server_address, timeout=5)
                        self.addCleanup(connection.close)
                        connection.request("GET", path)
                        response = connection.getresponse()
                        body = response.read()
                        self.assertEqual(response.status, expected, body)
                        if expected == 200:
                            self.assertEqual(body, page.read_bytes())
                            self.assertIn("text/html", response.getheader("Content-Type"))
                        connection.close()
            finally:
                server.shutdown(); server.server_close(); thread.join()

    def test_lowercase_and_mixed_case_proxy_headers(self):
        with tempfile.TemporaryDirectory() as directory:
            commands = control_plane.CommandServer(secrets.token_bytes(32))
            app = control_plane_web.ControlPlaneApp(directory, commands)
            self.addCleanup(app.scanner_runtime.close)
            _, setup = app.setup("correct horse battery staple")
            status, session = app.login("correct horse battery staple", owner_session.totp_at(setup["totp_secret"], app.clock()), "127.0.0.1")
            self.assertEqual(status, 200)
            server = control_plane_web.serve(app)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                for cookie_name, csrf_name in [("cookie", "x-owner-csrf"), ("COOKIE", "X-OWNER-CSRF"), ("Cookie", "X-Owner-CSRF")]:
                    with self.subTest(cookie=cookie_name, csrf=csrf_name):
                        headers = {cookie_name: "owner_session=" + session["session_token"], csrf_name: session["csrf_token"]}
                        self.assertEqual(app.authorize(headers)[0], 200)
                        connection = http.client.HTTPConnection(*server.server_address, timeout=5)
                        connection.request("POST", "/command", json.dumps({"kind": "cancel_open_orders", "target_identity": "1", "expected_version": 0}), headers)
                        response = connection.getresponse()
                        self.assertEqual(response.status, 200, response.read())
                        connection.close()
                self.assertEqual(app.authorize({"cookie": "owner_session=" + session["session_token"], "x-owner-csrf": "wrong"})[0], 403)
                self.assertEqual(app.authorize({"x-owner-csrf": session["csrf_token"]})[0], 401)
                self.assertEqual(len(commands._pending), 3)
            finally:
                server.shutdown()
                server.server_close()
                thread.join()
                commands.close()


if __name__ == "__main__":
    unittest.main()
