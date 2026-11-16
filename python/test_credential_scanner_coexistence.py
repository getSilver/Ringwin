"""Credential enrollment and the scanner share one authenticated control plane."""
import tempfile
import unittest

import control_plane
import control_plane_web
import owner_session


class CredentialScannerCoexistence(unittest.TestCase):
    def test_both_services_remain_available_after_login(self):
        with tempfile.TemporaryDirectory() as directory:
            commands = control_plane.CommandServer(bytes(range(32)))
            self.addCleanup(commands.close)
            app = control_plane_web.ControlPlaneApp(directory, commands)
            self.addCleanup(app.scanner_runtime.close)
            _, setup = app.setup("synthetic owner passphrase")
            status, session = app.login("synthetic owner passphrase", owner_session.totp_at(setup["totp_secret"], app.clock()), "127.0.0.1")
            self.assertEqual(status, 200)
            headers = {"Cookie": "owner_session=" + session["session_token"], "X-Owner-CSRF": session["csrf_token"]}
            self.assertEqual(app.credentials(headers), (200, {"ok": True, "packages": []}))
            status, result = app.scanner(headers)
            self.assertEqual(status, 200)
            self.assertEqual(result["result"]["schema"], "scanner_console_v1")
            self.assertEqual(result["result"]["phase"], "Stopped")
            self.assertEqual(result["result"]["exchanges"], [])


if __name__ == "__main__":
    unittest.main()
