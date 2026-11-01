"""StrategyPackage acceptance through authenticated Web release operations."""

import hashlib
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import threading
import unittest

import control_plane
import control_plane_web
import owner_session
import release_lifecycle
from verify_control_plane_wave import Client
from verify_release_lifecycle import KEY, write_artifact as write_release_artifact


DEFINITION = "a21994db11534bf5b193c5aa89000010"
REGISTRY = 0x0102030405060708090A0B0C0D0E0F10
LIMITS = dict(zip((
    "max_private_state_bytes", "max_input_record_bytes", "max_output_frame_bytes",
    "max_output_frames_per_event", "max_callback_ns", "max_warmup_events",
    "max_warmup_ns", "max_memory_bytes"),
    (1024, 512, 512, 1, 1000000, 100, 1000000000, 1048576)))


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=True).encode("utf-8")


def descriptor(path, data):
    return {"path": path, "size_bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest()}


def write_artifact(*args, **kwargs):
    kwargs.setdefault("schema_registry", REGISTRY)
    return write_release_artifact(*args, **kwargs)


def bundle_files():
    runtime = {"ringwin": b"synthetic engine, never executed",
               "runtime/python": b"synthetic approved interpreter, never executed",
               "runtime/host.py": b"raise RuntimeError('must not execute on install')\n"}
    compatibility = {"host_build": "1112131415161718191a1b1c1d1e1f20",
                     "python_abi": 0x03090000, "host_protocol": 1,
                     "schema_registry": "0102030405060708090a0b0c0d0e0f10"}
    lock = canonical({"format_version": 1, "compatibility": compatibility,
                      "python_path": "runtime/python", "host_path": "runtime/host.py",
                      "files": [descriptor(p, b) for p, b in sorted(runtime.items())]})
    compatibility = dict(compatibility, runtime_lock_sha256=hashlib.sha256(lock).hexdigest())
    code = {"code/observer.py": b"raise RuntimeError('must not import on install')\n",
            "contracts/config.json": b'{"fields":[]}',
            "contracts/state.json": b'{"fields":[]}'}
    manifest = {"format_version": 1, "definition_identity": DEFINITION,
                "name": "Offline observer", "runtime": "python",
                "entrypoint": "observer:create", "strategy_api_version": 1,
                "compatibility": compatibility,
                "config_schema": {"identity": "11111111111111111111111111111111",
                                  "version": 1, "path": "contracts/config.json"},
                "state_schema": {"identity": "22222222222222222222222222222222",
                                 "version": 1, "path": "contracts/state.json",
                                 "encoding": "portable_json_v1"},
                "subscriptions": [{"event_type": 19, "schema_version": 1}],
                "output_kinds": [], "limits": LIMITS,
                "files": [descriptor(p, b) for p, b in sorted(code.items())], "evidence": []}
    prefix = f"strategies/{DEFINITION}/"
    manifest_bytes = canonical(manifest)
    files = dict(runtime, **{"runtime-lock.json": lock})
    files.update({prefix + p: b for p, b in code.items()})
    files[prefix + "manifest.json"] = manifest_bytes
    files["strategy-index.json"] = canonical({"format_version": 1, "strategies": [{
        "definition_identity": DEFINITION, "manifest_path": prefix + "manifest.json",
        "package_manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest()}]})
    return files, {"compatibility": compatibility, "limits": LIMITS,
                   "subscriptions": [{"event_type": 19, "schema_version": 1}]}


def write_bundle(root, name, files, extra=()):
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for path, payload in list(sorted(files.items())) + list(extra):
            item = path if isinstance(path, tarfile.TarInfo) else tarfile.TarInfo(path)
            item.size = len(payload)
            item.mode = 0o555 if item.name in ("ringwin", "runtime/python") else 0o444
            archive.addfile(item, io.BytesIO(payload))
    return write_artifact(str(root), name, data.getvalue(), KEY,
                          payload_format="strategy_bundle_v1")


class PackageReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ringwin-package-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        if os.name == "nt":
            self.addCleanup(self._windows_cleanup)
        self.files, self.policy = bundle_files()
        self.restarts = []
        self.manager = release_lifecycle.ReleaseManager(
            str(self.root), str(self.root / "versions"), str(self.root / "records.jsonl"),
            KEY, candidate_check=lambda artifact: True,
            applier=(release_lifecycle.WindowsFilesystemApplier(
                str(self.root / "versions"), runtime_runner=lambda: self.restarts.append("restart"))
                if os.name == "nt" else release_lifecycle.FilesystemApplier(
                str(self.root / "versions"), systemd_runner=self.restarts.append)),
            strategy_policy=self.policy)
        self.command_server = control_plane.CommandServer(KEY)
        self.addCleanup(self.command_server.close)
        (self.root / "owner").mkdir()
        self.app = control_plane_web.ControlPlaneApp(
            str(self.root / "owner"), self.command_server, clock=lambda: 1700000000,
            ui_path=str(Path(__file__).with_name("operator_ui.html")),
            release_manager=self.manager,
            lifecycle_outbox=release_lifecycle.LifecycleOutbox(str(self.root / "outbox"), KEY))
        self.http = control_plane_web.serve(self.app)
        threading.Thread(target=self.http.serve_forever, daemon=True).start()
        self.addCleanup(self.http.server_close)
        self.addCleanup(self.http.shutdown)
        self.client = Client(self.http.server_address[1])
        status, setup = self.client.call("POST", "/setup", {"passphrase": "correct horse battery staple"})
        self.assertEqual(status, 200)
        self.totp_secret = setup["totp_secret"]
        status, login = self.client.call("POST", "/login", {
            "passphrase": "correct horse battery staple",
            "code": owner_session.totp_at(setup["totp_secret"], 1700000000)})
        self.assertEqual(status, 200)
        self.client.csrf = login["csrf_token"]

    def _windows_cleanup(self):
        import strategy_windows
        for root, directories, files in os.walk(self.root):
            strategy_windows.set_permissions(root, writable=True)
            for name in files:
                strategy_windows.set_permissions(Path(root) / name, writable=True)

    def deploy(self, manifest, identity="1001", expected=None, **overrides):
        command = {"kind": "deploy_release", "command_identity": identity,
                   "target_identity": "1", "manifest_path": str(manifest),
                   "expected_active": expected, "manifest_sha256": hashlib.sha256(
                       canonical(json.loads(Path(manifest).read_bytes()))).hexdigest()}
        command.update(overrides)
        status, warning = self.client.call("POST", "/risk-warning", command)
        self.assertEqual(status, 200)
        command.update(risk_warning_acknowledged=True,
                       risk_warning_identity=warning["warning_identity"])
        self.last_command = command
        status, body = self.client.call("POST", "/lifecycle", command)
        self.assertEqual(status, 200, body)
        return body["result"]

    @unittest.skipIf(os.name == "nt", "POSIX current symlink and mode bits; Windows lifecycle/ACL checks are separate")
    def test_signed_bundle_installs_and_web_lists_the_registered_definition(self):
        manifest = write_bundle(self.root, "bundle-a", self.files)
        result = self.deploy(manifest)
        self.assertEqual(result["status"], "activated", result)
        for path, content in self.files.items():
            self.assertEqual((self.root / "versions" / "current" / path).read_bytes(), content)
        status, body = self.client.call("GET", "/api/releases")
        self.assertEqual(status, 200)
        package = body["strategy_packages"][0]
        self.assertEqual(package["definition_identity"], DEFINITION)
        self.assertEqual(package["release_artifact"], "bundle-a")
        self.assertEqual(package["package_manifest_sha256"], hashlib.sha256(
            self.files[f"strategies/{DEFINITION}/manifest.json"]).hexdigest())
        self.assertEqual(package["validation"], "passed")
        self.assertFalse(package["trading_authorized"])
        self.assertEqual(package["qualifications"], [])
        self.assertEqual(len(self.restarts), 1)
        status, page = self.client.call("GET", "/")
        self.assertEqual(status, 200)
        self.assertIn("策略包登记与发布结果", page)
        for installed in [self.root / "versions" / "bundle-a"] + list((self.root / "versions" / "bundle-a").rglob("*")):
            self.assertEqual(installed.stat().st_mode & 0o222, 0, str(installed))

    def changed_manifest(self, change):
        files = dict(self.files)
        name = f"strategies/{DEFINITION}/manifest.json"
        manifest = json.loads(files[name])
        change(manifest)
        files[name] = canonical(manifest)
        index = json.loads(files["strategy-index.json"])
        index["strategies"][0]["package_manifest_sha256"] = hashlib.sha256(files[name]).hexdigest()
        files["strategy-index.json"] = canonical(index)
        return files

    def test_invalid_signed_packages_do_not_install_or_register(self):
        cases = []
        for label, change in (
                ("boolean version", lambda m: m.update(format_version=True)),
                ("unknown field", lambda m: m.update(unexpected=1)),
                ("zero identity", lambda m: m.update(definition_identity="0" * 32)),
                ("bad entrypoint", lambda m: m.update(entrypoint="os:system")),
                ("missing entrypoint", lambda m: m.update(entrypoint="absent:create")),
                ("compatibility", lambda m: m["compatibility"].update(host_protocol=2)),
                ("boolean size", lambda m: m["files"][0].update(size_bytes=True)),
                ("oversize", lambda m: m["files"][0].update(size_bytes=67108865)),
                ("resource limit", lambda m: m["limits"].update(max_callback_ns=1000001)),
                ("subscription", lambda m: m.update(subscriptions=[{"event_type": 20, "schema_version": 1}])),
                ("bad schema", lambda m: m["state_schema"].update(path=[])),
                ("float", lambda m: m["limits"].update(max_callback_ns=1.5))):
            cases.append((label, self.changed_manifest(change), ()))
        for label, changed in (
                ("noncanonical index", {"strategy-index.json": self.files["strategy-index.json"] + b"\n"}),
                ("duplicate key", {"strategy-index.json": b'{"format_version":1,"format_version":1,"strategies":[]}'}),
                ("tampered code", {f"strategies/{DEFINITION}/code/observer.py": b"tampered"}),
                ("tampered runtime", {"runtime/python": b"different interpreter"}),
                ("extra file", {"unlisted.py": b"not declared"}),
                ("traversal", {"../escape": b"outside"}),
                ("backslash", {"runtime\\escape": b"outside"}),
                ("case collision", {"RUNTIME/PYTHON": b"collision"})):
            cases.append((label, dict(self.files, **changed), ()))
        missing = dict(self.files)
        del missing[f"strategies/{DEFINITION}/contracts/state.json"]
        cases.append(("missing file", missing, ()))
        index = json.loads(self.files["strategy-index.json"])
        index["strategies"] *= 2
        cases.append(("duplicate identity", dict(self.files, **{"strategy-index.json": canonical(index)}), ()))
        link = tarfile.TarInfo("runtime/link")
        link.type, link.linkname = tarfile.SYMTYPE, "../../outside"
        cases.append(("link", self.files, ((link, b""),)))
        cases.append(("duplicate archive", self.files, (("ringwin", self.files["ringwin"]),)))
        for number, (label, files, extra) in enumerate(cases):
            with self.subTest(label=label):
                manifest = write_bundle(self.root, f"invalid-{number}", files, extra)
                result = self.deploy(manifest, identity=str(2000 + number))
                self.assertEqual(result["status"], "rejected", result)
                self.assertTrue(result["reason"])
                self.assertFalse((self.root / "versions" / "current").exists())
                self.assertEqual(self.client.call("GET", "/api/releases")[1]["strategy_packages"], [])

    def test_same_identity_cannot_bind_new_content_and_install_fault_keeps_current(self):
        self.assertEqual(self.deploy(write_bundle(self.root, "bundle-a", self.files))["status"], "activated")
        changed = self.changed_manifest(lambda m: m.update(name="Different content"))
        conflict = self.deploy(write_bundle(self.root, "bundle-conflict", changed), "3001", "bundle-a")
        self.assertEqual(conflict["status"], "rejected")
        self.assertIn("definition identity", conflict["reason"])
        (self.root / "versions" / "bundle-fault").write_bytes(b"not a version directory")
        failed = self.deploy(write_bundle(self.root, "bundle-fault", self.files), "3002", "bundle-a")
        self.assertEqual(failed["status"], "rejected")
        self.assertEqual(self.manager.applier.current_artifact(), "bundle-a")
        self.assertEqual(len(self.restarts), 1)
        self.assertEqual(self.client.call("GET", "/api/releases")[1]["strategy_packages"][0]["release_artifact"], "bundle-a")
        self.assertFalse(list((self.root / "versions").glob(".*.tmp")))

    def test_external_signed_scope_evidence_does_not_rewrite_the_package(self):
        self.deploy(write_bundle(self.root, "bundle-a", self.files))
        package_hash = hashlib.sha256(self.files[f"strategies/{DEFINITION}/manifest.json"]).hexdigest()
        scope = {"platform": "linux", "os_build": "synthetic-test-os",
                 "node_identity": "33333333333333333333333333333333",
                 "environment": "offline", "mode": "observation",
                 "config_sha256": "a" * 64, "venues": ["1" * 32],
                 "exchange_accounts": ["2" * 32], "instruments": ["3" * 32],
                 "products": ["spot"], "capabilities": ["observation"]}
        report = {"package_manifest_sha256": package_hash,
                  "compatibility": self.policy["compatibility"], "scope": scope,
                  "qualified": False}
        report_path = write_artifact(str(self.root), "external-evidence", b"fixed measured report", KEY,
                                     test_results={"strategy_packages": [report]})
        self.app.release_manager = release_lifecycle.ReleaseManager(
            str(self.root), str(self.root / "versions"), str(self.root / "records.jsonl"), KEY,
            candidate_check=lambda artifact: True, applier=self.manager.applier,
            strategy_policy=self.policy, qualification_manifests=(report_path,))
        package = self.client.call("GET", "/api/releases")[1]["strategy_packages"][0]
        self.assertEqual(package["qualifications"][0]["status"], "not_qualified")
        self.assertEqual(package["qualifications"][0]["scope"], scope)
        self.assertFalse(package["trading_authorized"])
        report["qualified"] = True
        write_artifact(str(self.root), "external-evidence", b"fixed measured report", KEY,
                       test_results={"strategy_packages": [report]})
        package = self.client.call("GET", "/api/releases")[1]["strategy_packages"][0]
        self.assertEqual(package["qualifications"][0]["status"], "qualified")
        self.assertFalse(package["trading_authorized"])
        self.assertEqual(self.manager.applier.current_artifact(), "bundle-a")
        for path, content in self.files.items():
            self.assertEqual((self.root / "versions" / "bundle-a" / path).read_bytes(), content)
        for label, change in (
                ("wrong package", lambda r: r.update(package_manifest_sha256="b" * 64)),
                ("wrong runtime", lambda r: r["compatibility"].update(host_protocol=2)),
                ("missing scope", lambda r: r["scope"].pop("config_sha256")),
                ("boolean verdict", lambda r: r.update(qualified=1))):
            changed = json.loads(canonical(report))
            change(changed)
            write_artifact(str(self.root), "external-evidence", b"fixed measured report", KEY,
                           test_results={"strategy_packages": [changed]})
            body = self.client.call("GET", "/api/releases")[1]
            self.assertEqual(body["strategy_packages"][0]["qualifications"], [], label)
            self.assertTrue(body["qualification_rejections"][0]["reason"], label)
        write_artifact(str(self.root), "external-evidence", b"fixed measured report", b"x" * 32,
                       test_results={"strategy_packages": [report]})
        body = self.client.call("GET", "/api/releases")[1]
        self.assertEqual(body["strategy_packages"][0]["qualifications"], [])
        self.assertIn("signature", body["qualification_rejections"][0]["reason"])

    def test_signed_release_tampering_and_missing_index_fail_before_install(self):
        for number, label in enumerate(("signature", "payload", "index")):
            files = dict(self.files)
            if label == "index":
                del files["strategy-index.json"]
            manifest = write_bundle(self.root, "bad-" + label, files)
            if label == "signature":
                value = json.loads(Path(manifest).read_bytes())
                value["signature"] = "0" * 64
                Path(manifest).write_bytes(canonical(value))
            elif label == "payload":
                with open(self.root / "bad-payload.elf", "ab") as handle:
                    handle.write(b"changed after signing")
            result = self.deploy(manifest, str(4000 + number))
            self.assertEqual(result["status"], "rejected", label)
            self.assertFalse((self.root / "versions" / "current").exists())

    def test_web_restart_retries_once_and_reports_version_and_identity_conflicts(self):
        manifest = write_bundle(self.root, "bundle-a", self.files)
        first = self.deploy(manifest)
        command = dict(self.last_command)
        self.http.shutdown()
        self.http.server_close()
        manager = release_lifecycle.ReleaseManager(
            str(self.root), str(self.root / "versions"), str(self.root / "records.jsonl"), KEY,
            candidate_check=lambda artifact: True, applier=self.manager.applier,
            strategy_policy=self.policy)
        app = control_plane_web.ControlPlaneApp(
            str(self.root / "owner"), self.command_server, clock=lambda: 1700000030,
            release_manager=manager,
            lifecycle_outbox=release_lifecycle.LifecycleOutbox(str(self.root / "outbox"), KEY))
        http = control_plane_web.serve(app)
        threading.Thread(target=http.serve_forever, daemon=True).start()
        self.addCleanup(http.server_close)
        self.addCleanup(http.shutdown)
        self.client = Client(http.server_address[1])
        status, login = self.client.call("POST", "/login", {
            "passphrase": "correct horse battery staple",
            "code": owner_session.totp_at(self.totp_secret, 1700000030)})
        self.assertEqual(status, 200)
        self.client.csrf = login["csrf_token"]
        status, replay = self.client.call("POST", "/lifecycle", command)
        self.assertEqual(status, 200)
        self.assertEqual(replay["result"], first)
        self.assertEqual(len(self.restarts), 1)
        conflict = self.deploy(manifest, "5001", "not-current")
        self.assertEqual(conflict["status"], "rejected")
        self.assertIn("precondition", conflict["reason"])
        command["manifest_path"] = str(self.root / "different.json")
        self.assertEqual(self.client.call("POST", "/lifecycle", command)[0], 409)

    def test_missing_result_history_keeps_complete_registry_and_blocks_new_publication(self):
        manifest = write_bundle(self.root, "bundle-a", self.files)
        self.deploy(manifest)
        (self.root / "records.jsonl").unlink()
        self.app.release_manager = release_lifecycle.ReleaseManager(
            str(self.root), str(self.root / "versions"), str(self.root / "records.jsonl"), KEY,
            candidate_check=lambda artifact: True, applier=self.manager.applier,
            strategy_policy=self.policy)
        body = self.client.call("GET", "/api/releases")[1]
        self.assertIsNone(body["active_artifact"])
        self.assertEqual(body["strategy_packages"][0]["definition_identity"], DEFINITION)
        self.assertFalse(body["strategy_packages"][0]["trading_authorized"])
        self.assertEqual(self.deploy(manifest, "6001")["status"], "unknown")
        self.assertEqual(len(self.restarts), 1)

    def test_bundle_requires_the_exact_manifest_digest_confirmed_by_the_owner(self):
        manifest = write_bundle(self.root, "bundle-a", self.files)
        result = self.deploy(manifest, manifest_sha256="0" * 64)
        self.assertEqual(result["status"], "rejected")
        self.assertIn("manifest", result["reason"])
        result = self.deploy(manifest, "7001", manifest_sha256=None)
        self.assertEqual(result["status"], "rejected")
        self.assertFalse((self.root / "versions" / "current").exists())

    def test_release_registry_identity_must_match_the_approved_bundle_runtime(self):
        manifest = write_bundle(self.root, "bundle-a", self.files)
        value = json.loads(Path(manifest).read_bytes())
        value["schema_registry"] = 6
        value["signature"] = release_lifecycle.sign_manifest(value, KEY)
        Path(manifest).write_bytes(canonical(value))
        result = self.deploy(manifest)
        self.assertEqual(result["status"], "rejected")
        self.assertIn("registry", result["reason"])

    def test_strategy_binaries_and_cache_are_not_runtime_dependencies(self):
        for number, suffix in enumerate((".pyd", ".pyc")):
            name, content = "code/extension" + suffix, b"compiled artifact"
            def add_file(manifest):
                manifest["files"].append(descriptor(name, content))
                manifest["files"].sort(key=lambda item: item["path"])
            files = self.changed_manifest(add_file)
            files[f"strategies/{DEFINITION}/" + name] = content
            result = self.deploy(write_bundle(self.root, "extension-" + str(number), files),
                                 str(8000 + number))
            self.assertEqual(result["status"], "rejected", suffix)

    def test_result_storage_fault_reports_unknown_without_partial_registration(self):
        (self.root / "records.jsonl").mkdir()
        manifest = write_bundle(self.root, "bundle-a", self.files)
        result = self.deploy(manifest)
        self.assertEqual(result["status"], "unknown")
        body = self.client.call("GET", "/api/releases")[1]
        self.assertIsNone(body["active_artifact"])
        self.assertEqual(len(body["strategy_packages"]), 1)
        self.assertEqual(body["strategy_packages"][0]["definition_identity"], DEFINITION)
        self.assertFalse(body["strategy_packages"][0]["trading_authorized"])
        self.assertEqual(self.deploy(manifest, "9001")["status"], "unknown")
        self.assertEqual(len(self.restarts), 1)

    def test_new_definition_cannot_redefine_a_published_schema_identity_and_version(self):
        self.deploy(write_bundle(self.root, "bundle-a", self.files))
        new_identity = "a21994db11534bf5b193c5aa89000011"
        old_prefix, new_prefix = f"strategies/{DEFINITION}/", f"strategies/{new_identity}/"
        files = {p.replace(old_prefix, new_prefix, 1): data for p, data in self.files.items()}
        manifest = json.loads(files[new_prefix + "manifest.json"])
        manifest["definition_identity"] = new_identity
        content = b'{"fields":[{"name":"new-semantic-field"}]}'
        files[new_prefix + "contracts/config.json"] = content
        for item in manifest["files"]:
            if item["path"] == "contracts/config.json":
                item.update(size_bytes=len(content), sha256=hashlib.sha256(content).hexdigest())
        files[new_prefix + "manifest.json"] = canonical(manifest)
        files["strategy-index.json"] = canonical({"format_version": 1, "strategies": [{
            "definition_identity": new_identity, "manifest_path": new_prefix + "manifest.json",
            "package_manifest_sha256": hashlib.sha256(files[new_prefix + "manifest.json"]).hexdigest()}]})
        result = self.deploy(write_bundle(self.root, "bundle-b", files), "10001", "bundle-a")
        self.assertEqual(result["status"], "rejected")
        self.assertIn("schema", result["reason"])
        self.assertEqual(self.manager.applier.current_artifact(), "bundle-a")


@unittest.skipUnless(os.name == "nt", "Windows signed publication adapter")
class WindowsPackageReleaseTests(unittest.TestCase):
    setUp = PackageReleaseTests.setUp
    deploy = PackageReleaseTests.deploy
    _windows_cleanup = PackageReleaseTests._windows_cleanup

    def test_failed_restart_restores_previous_file_pointer(self):
        self.assertEqual(self.deploy(write_bundle(self.root, "bundle-a", self.files))["status"], "activated")
        calls = []

        def restart():
            calls.append(True)
            if len(calls) == 1:
                raise OSError("injected Windows runtime restart failure")

        self.manager.applier.runtime_runner = restart
        result = self.deploy(write_bundle(self.root, "bundle-b", self.files), "1002", "bundle-a")
        self.assertEqual(result["status"], "rejected", result)
        self.assertEqual(self.manager.applier.current_artifact(), "bundle-a")
        self.assertEqual((self.root / "versions/current").read_bytes(), b"bundle-a\n")
        self.assertEqual(len(calls), 2)
        self.assertFalse(list((self.root / "versions").glob("*.tmp")))

    def test_failed_first_restart_leaves_publication_unknown(self):
        def restart():
            raise OSError("injected Windows runtime restart failure")

        self.manager.applier.runtime_runner = restart
        result = self.deploy(write_bundle(self.root, "bundle-a", self.files))
        self.assertEqual(result["status"], "unknown", result)
        self.assertIsNone(self.manager.applier.current_artifact())
        self.assertEqual(self.manager._registrations(), [])

    def test_existing_version_junction_is_rejected_without_touching_target(self):
        import _winapi
        foreign = self.root / "foreign"
        foreign.mkdir()
        marker = foreign / "marker"
        marker.write_bytes(b"must remain writable")
        versions = self.root / "versions"
        versions.mkdir()
        junction = versions / "bundle-a"
        _winapi.CreateJunction(str(foreign), str(junction))
        self.addCleanup(os.rmdir, junction)
        result = self.deploy(write_bundle(self.root, "bundle-a", self.files))
        self.assertEqual(result["status"], "rejected", result)
        self.assertIn("regular version directory", result["reason"])
        marker.write_bytes(b"still writable")
        self.assertIsNone(self.manager.applier.current_artifact())


if __name__ == "__main__":
    unittest.main()
