"""Proxy-normalized HTTP header names must preserve OwnerSession authorization."""
import http.client
import json
from pathlib import Path
import secrets
import tempfile
import threading
import unittest

import control_plane
import control_plane_web
import owner_session


class HttpHeaderAuthenticationTest(unittest.TestCase):
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
