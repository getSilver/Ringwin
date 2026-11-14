"""Credential enrollment and the scanner share one authenticated control plane."""
import tempfile
import unittest

import control_plane
import control_plane_web
import owner_session


class ScannerFixture:
    config_store = object()

    def view(self):
        return {"source": "offline-scanner"}


class CredentialScannerCoexistence(unittest.TestCase):
    def test_both_services_remain_available_after_login(self):
        with tempfile.TemporaryDirectory() as directory:
            commands = control_plane.CommandServer(bytes(range(32)))
            self.addCleanup(commands.close)
            app = control_plane_web.ControlPlaneApp(directory, commands, scanner_console=ScannerFixture())
            _, setup = app.setup("synthetic owner passphrase")
            status, session = app.login("synthetic owner passphrase", owner_session.totp_at(setup["totp_secret"], app.clock()), "127.0.0.1")
            self.assertEqual(status, 200)
            headers = {"Cookie": "owner_session=" + session["session_token"], "X-Owner-CSRF": session["csrf_token"]}
            self.assertEqual(app.credentials(headers), (200, {"ok": True, "packages": []}))
            status, result = app.scanner(headers)
            self.assertEqual(status, 200)
            self.assertEqual(result["result"], {"source": "offline-scanner"})


if __name__ == "__main__":
    unittest.main()
