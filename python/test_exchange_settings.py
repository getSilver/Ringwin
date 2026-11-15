"""Settings storage and authenticated Web behavior, without Venue IO."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import control_plane
import control_plane_web
from opportunity_scanner.exchange_settings import ExchangeSettings


class SettingsTests(unittest.TestCase):
    def test_edit_source_and_delete_keep_versioned_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            settings = ExchangeSettings(Path(directory)/"exchange-settings.json")
            row = settings.save(dict(expected_version="0", type="okx", name="行情", environment="production"))["exchanges"][0]
            changed = settings.save(dict(expected_version="1", identity=row["identity"], type="okx", name="测试行情", environment="demo"))
            self.assertEqual(changed["exchanges"][0]["identity"], row["identity"])
            deleted = settings.save(dict(expected_version="2", identity=row["identity"], operation="delete"))
            self.assertEqual(deleted["exchanges"], [])
            self.assertEqual(ExchangeSettings(settings.path).view(), deleted)
            with self.assertRaisesRegex(ValueError, "unknown"):
                settings.save(dict(expected_version="3", identity=row["identity"], operation="delete"))

    def test_save_reload_and_failed_writes_preserve_previous_version(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/"exchange-settings.json"
            settings = ExchangeSettings(path)
            self.assertEqual(settings.view()["exchanges"], [])
            saved = settings.save(dict(expected_version="0", type="okx", name="  我的行情  ", environment="demo"))
            row = saved["exchanges"][0]
            self.assertEqual((row["venue"], row["name"], saved["version"]), ("1", "我的行情", "1"))
            for target in ("os.replace", "os.fsync"):
                with patch(target, side_effect=OSError("disk unavailable")):
                    with self.assertRaises(OSError):
                        settings.save(dict(expected_version="1", type="hyperliquid", name="第二来源", environment="testnet"))
                self.assertEqual(settings.view(), saved)
                self.assertEqual(ExchangeSettings(path).view(), saved)
            (path.parent/".exchange-settings-incomplete.tmp").write_text("{")
            self.assertEqual(ExchangeSettings(path).view(), saved)
            with self.assertRaisesRegex(ValueError, "conflict"):
                settings.save(dict(expected_version="0", type="hyperliquid", name="新来源", environment="production"))
            for changes in (dict(name="  "), dict(type="unknown"), dict(environment="testnet")):
                with self.assertRaises(ValueError):
                    settings.save(dict(dict(expected_version="1", type="okx", name="行情", environment="production"), **changes))
            with self.assertRaisesRegex(ValueError, "duplicate"):
                settings.save(dict(expected_version="1", type="okx", name="重复", environment="demo"))
            renamed = settings.save(dict(expected_version="1", identity=row["identity"], type="okx", name="新名称", environment="demo"))
            self.assertEqual(renamed["exchanges"][0]["identity"], row["identity"])
            self.assertEqual(ExchangeSettings(path).view(), renamed)
            path.write_text('{"schema":"broken"}')
            with self.assertRaisesRegex(ValueError, "saved exchange settings"):
                ExchangeSettings(path)

    @patch("urllib.request.urlopen", side_effect=OSError("offline discovery failure"))
    def test_empty_settings_and_unloaded_option_survive_restart(self, _network):
        with tempfile.TemporaryDirectory() as directory:
            channel = control_plane.CommandServer(b"s"*32)
            self.addCleanup(channel.close)
            app = control_plane_web.ControlPlaneApp(directory, channel)
            self.addCleanup(app.scanner_runtime.close)
            self.assertEqual(app.exchange_settings({})[0], 401)
            # The real OwnerSession/CSRF boundary is covered in scanner integration.
            app.authorize = lambda headers: (200, {})
            self.assertEqual(app.exchange_settings({})[1]["result"]["exchanges"], [])
            self.assertEqual(app.scanner({})[1]["result"]["exchanges"], [])
            status, body = app.exchange_settings({}, dict(expected_version="0", type="okx", name="公共市场", environment="production"))
            self.assertEqual(status, 200, body)
            view = app.scanner({})[1]["result"]
            self.assertEqual([r["name"] for r in view["exchanges"]], ["公共市场"])
            self.assertIn(view["exchanges"][0]["catalogue_state"], ("loading", "failed"))
            self.assertEqual(view["desired"], "stopped")
            self.assertEqual(app.exchange_settings({}, dict(expected_version="0", type="okx", name="旧版本", environment="demo"))[0], 409)
            app.scanner_runtime.close()
            restored = control_plane_web.ControlPlaneApp(directory, channel)
            self.addCleanup(restored.scanner_runtime.close)
            restored.authorize = app.authorize
            self.assertEqual(restored.exchange_settings({})[1], body)
            self.assertEqual(restored.scanner({})[1]["result"]["desired"], "stopped")


if __name__ == "__main__":
    unittest.main()
