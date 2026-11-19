"""Activated identity bindings, not symbol guesses, feed existing pairing rules."""
import copy
import tempfile
import unittest
from types import SimpleNamespace

import control_plane
import control_plane_web
from opportunity_scanner.scanner_assets import AssetBindings as CheckedBindings
from test_scanner_integration import registered_assets


def AssetBindings(document):
    return CheckedBindings(document, allow_fixture=True)


class BindingTests(unittest.TestCase):
    def test_fixture_sources_are_not_admitted_for_public_transport(self):
        with self.assertRaisesRegex(ValueError, "source kind"):
            CheckedBindings(registered_assets())

    def test_exact_source_code_environment_and_order_are_preserved(self):
        document = registered_assets()
        a = AssetBindings(document)
        z = AssetBindings(dict(schema=1, bindings=list(reversed(document["bindings"]))))
        self.assertEqual(a.digest, z.digest)
        self.assertEqual(a.resolve(21, "production", "SOL")["asset"], "5")
        self.assertIsNone(a.resolve(21, "production", "sol"))
        self.assertIsNone(a.resolve(21, "production", "kSOL"))
        self.assertIsNone(a.resolve(21, "demo", "SOL"))

    def test_registered_alias_uses_existing_identity_without_changing_units(self):
        document = registered_assets()
        alias = dict(document["bindings"][0], venue="21", code="SOURCE_ALIAS")
        document["bindings"].append(alias)
        bindings = AssetBindings(document)
        self.assertEqual(bindings.resolve(21, "production", "SOURCE_ALIAS")["asset"],
                         bindings.resolve(1, "production", "USDT")["asset"])
        self.assertEqual(bindings.resolve(21, "production", "SOURCE_ALIAS")["atomic_scale"], 8)

    def test_ambiguous_code_and_conflicting_units_are_rejected(self):
        for changes in (dict(asset="999"), dict(atomic_scale=9), dict(version="2")):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                document = registered_assets()
                document["bindings"].append(dict(document["bindings"][0], **changes))
                AssetBindings(document)

    def test_inactive_malformed_or_unversioned_source_is_rejected(self):
        for changes in (dict(barrier="0"), dict(version="0"), dict(source_digest="short"),
                        dict(environment="unknown"), dict(source_identity="0"), dict(code="SOL ")):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                document = registered_assets()
                document["bindings"][0].update(changes)
                AssetBindings(document)

    def test_input_mutation_cannot_change_admitted_binding(self):
        document = registered_assets()
        bindings = AssetBindings(document)
        before = copy.deepcopy(bindings.resolve(1, "production", "USDT"))
        document["bindings"][0]["asset"] = "999"
        self.assertEqual(bindings.resolve(1, "production", "USDT"), before)

    def test_same_numeric_id_from_different_definitions_cannot_merge_across_venues(self):
        document = registered_assets()
        for row in document["bindings"]:
            if row["venue"] == "21" and row["code"] == "SOL":
                row["source_digest"] = "cd"*32
        with self.assertRaisesRegex(ValueError, "definition conflict"):
            AssetBindings(document)

    def test_duplicate_projection_barriers_do_not_change_binding_with_file_order(self):
        document = registered_assets()
        document["bindings"].append(dict(document["bindings"][0], barrier="20"))
        a = AssetBindings(document)
        z = AssetBindings(dict(schema=1, bindings=list(reversed(document["bindings"]))))
        self.assertEqual(a.digest, z.digest)

    def test_normal_web_assembly_supplies_existing_projection_source(self):
        with tempfile.TemporaryDirectory() as directory:
            server = control_plane.CommandServer(b"k"*32)
            self.addCleanup(server.close)
            provider = SimpleNamespace(asset_bindings=registered_assets)
            app = control_plane_web.ControlPlaneApp(directory, server, projection_provider=provider)
            self.addCleanup(app.scanner_runtime.close)
            self.assertEqual(app.scanner_runtime.asset_provider(), registered_assets())
            self.assertEqual(app.scanner_runtime.console.desired, "stopped")


if __name__ == "__main__":
    unittest.main()
