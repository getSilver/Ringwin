"""Security regression tests for owner authentication persistence."""

import http.client
import json
import os
import stat
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import control_plane  # noqa: E402
import control_plane_web  # noqa: E402


class OwnerSessionSecurityTests(unittest.TestCase):
    def test_totp_secret_is_only_returned_by_initial_setup(self):
        with tempfile.TemporaryDirectory() as directory:
            app = control_plane_web.ControlPlaneApp(
                directory, control_plane.CommandServer(bytes(range(32))))
            server = control_plane_web.serve(app)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                client = http.client.HTTPConnection(
                    "127.0.0.1", server.server_address[1], timeout=5)
                body = json.dumps({"passphrase": "correct horse battery staple"})
                client.request("POST", "/setup", body=body,
                               headers={"Content-Type": "application/json"})
                setup = client.getresponse()
                setup_body = json.loads(setup.read())
                self.assertEqual(200, setup.status)
                self.assertTrue(setup_body["totp_secret"])

                client.request("GET", "/totp-secret")
                leaked = client.getresponse()
                leaked.read()
                self.assertEqual(404, leaked.status)
            finally:
                client.close()
                server.shutdown()
                server.server_close()

    def test_authentication_files_are_private(self):
        if os.name != "posix":
            self.skipTest("POSIX permission bits are enforced by the Linux deployment")
        with tempfile.TemporaryDirectory() as directory:
            app = control_plane_web.ControlPlaneApp(
                directory, control_plane.CommandServer(bytes(range(32))))
            status, _ = app.setup("correct horse battery staple")
            self.assertEqual(200, status)
            app.sessions.issue()

            for name in ("passphrase.json", "totp.secret", "session.json"):
                mode = stat.S_IMODE(os.stat(os.path.join(directory, name)).st_mode)
                self.assertEqual(0o600, mode, name)


if __name__ == "__main__":
    unittest.main()
