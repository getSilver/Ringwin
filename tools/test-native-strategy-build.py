"""Offline build acceptance for ticket 02; never loads credentials or deploys."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NativeStrategyBuild(unittest.TestCase):
    def assert_build_rejected(self, change, diagnostic):
        with tempfile.TemporaryDirectory(prefix="ringwin-native-") as directory:
            fixture = Path(directory)
            sources = ["build.zig", "src/model/canonical_event.zig",
                       "src/runtime/production_contract.zig"]
            sources += [str(path.relative_to(ROOT)) for path in
                        (ROOT / "src/strategy").glob("native_*")]
            for source in sources:
                destination = fixture / source
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / source, destination)
            change(fixture)
            result = subprocess.run(["zig", "build"], cwd=fixture,
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("native strategy build rejected: " + diagnostic,
                          result.stdout + result.stderr)

    def test_registered_definition_builds_and_runs(self):
        result = subprocess.run(["zig", "build", "native-contract"], cwd=ROOT,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("native_contract=passed", result.stderr)

    def test_missing_registration_rejects_build(self):
        def remove_registration(fixture):
            path = fixture / "src/strategy/native_registry.zig"
            path.write_text(path.read_text().replace(
                "pub const registrations = .{observer};",
                "pub const registrations = .{};"))
        self.assert_build_rejected(remove_registration, "MissingRegistration")

    def test_duplicate_identity_rejects_build(self):
        def duplicate_registration(fixture):
            path = fixture / "src/strategy/native_registry.zig"
            path.write_text(path.read_text().replace(
                "pub const registrations = .{observer};",
                "pub const registrations = .{ observer, observer };"))
        self.assert_build_rejected(duplicate_registration, "DuplicateDefinition")

    def test_manifest_mismatches_reject_build(self):
        for before, after in [
            ('.entrypoint = "native_observer"', '.entrypoint = "unregistered"'),
            ('a21994db11534bf5b193c5aa89000001', 'a21994db11534bf5b193c5aa89000004'),
            ('.canonical_schema = 18', '.canonical_schema = 19'),
        ]:
            with self.subTest(change=before):
                def change_manifest(fixture):
                    path = fixture / "src/strategy/native_manifest.zig"
                    path.write_text(path.read_text().replace(before, after))
                self.assert_build_rejected(change_manifest, "ManifestMismatch")

    def test_duplicate_manifest_identity_rejects_build(self):
        def duplicate_manifest(fixture):
            path = fixture / "src/strategy/native_manifest.zig"
            path.write_text(path.read_text().replace("pub const definitions =", "const original =")
                            + "\npub const definitions = original ++ original;\n")
        self.assert_build_rejected(duplicate_manifest, "DuplicateDefinition")

    def test_changed_algorithm_or_schema_bytes_reject_build(self):
        for name in ("native_observer.zig", "native_observer_config.json", "native_observer_state.json"):
            with self.subTest(file=name):
                def change_bytes(fixture):
                    with (fixture / "src/strategy" / name).open("ab") as source:
                        source.write(b"\n")
                self.assert_build_rejected(change_bytes, "ManifestMismatch")

    def test_zero_definition_identity_rejects_build(self):
        def zero_identity(fixture):
            path = fixture / "src/strategy/native_registry.zig"
            path.write_text(path.read_text().replace(
                "a21994db11534bf5b193c5aa89000001", "0" * 32))
        self.assert_build_rejected(zero_identity, "InvalidDefinition")

    def test_installed_manifest_locates_actual_binary_and_contracts(self):
        result = subprocess.run(["zig", "build"], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        installed = ROOT / "zig-out"
        manifest = json.loads((installed / "share/ringwin/native-strategies.json").read_text())
        self.assertEqual(manifest["format_version"], 1)
        self.assertEqual(manifest["runtime"], "native_static")
        self.assertEqual(len(manifest["definitions"]), 1)
        definition = manifest["definitions"][0]
        for key in ("config_schema", "state_schema"):
            schema = definition[key]
            self.assertEqual(hashlib.sha256((installed / schema["path"]).read_bytes()).hexdigest(),
                             schema["sha256"])
        self.assertEqual(hashlib.sha256((ROOT / definition["algorithm_path"]).read_bytes()).hexdigest(),
                         definition["algorithm_sha256"])
        result = subprocess.run([str(installed / manifest["binary_path"]),
                                 "--native-strategy-build-test"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("definition=" + definition["definition_identity"], result.stderr)


if __name__ == "__main__":
    unittest.main()
