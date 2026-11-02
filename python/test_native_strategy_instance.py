"""Signed native bundles through authenticated Web and the actual node/core."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

import strategy_package as package
import strategy_instance
from test_native_strategy_package import ROOT, archive, native_files
import test_strategy_instance as python_instances
import test_strategy_package_release as release_tests
from verify_release_lifecycle import KEY, write_artifact

A = 'a21994db11534bf5b193c5aa89000001'
B = 'a21994db11534bf5b193c5aa89000004'


class NativeWebTests(unittest.TestCase):
    setUp = python_instances.WebInstanceTests.setUp
    deploy = release_tests.PackageReleaseTests.deploy
    _windows_cleanup = release_tests.PackageReleaseTests._windows_cleanup
    native_authority = python_instances.WebInstanceTests.native_authority
    node_batch = staticmethod(python_instances.WebInstanceTests.node_batch)
    instance_command = python_instances.WebInstanceTests.instance_command
    create = python_instances.WebInstanceTests.create

    @classmethod
    def setUpClass(cls):
        # Two registered observer definitions exercise selection without adding a shipping definition.
        cls.fixture = tempfile.TemporaryDirectory(prefix='ringwin-native-node-')
        cls.addClassCleanup(cls.fixture.cleanup)
        root = Path(cls.fixture.name)
        shutil.copytree(ROOT / 'src', root / 'src')
        shutil.copyfile(ROOT / 'build.zig', root / 'build.zig')
        registry = root / 'src/strategy/native_registry.zig'
        registry.write_text(registry.read_text().replace('pub const registrations = .{observer};', '''
const second = struct {
    pub const implementation = observer.implementation;
    pub const definition: contract.Definition = blk: {
        var value = observer.definition;
        value.definition_identity = "a21994db11534bf5b193c5aa89000004";
        break :blk value;
    };
};
pub const registrations = .{ observer, second };'''))
        manifest = root / 'src/strategy/native_manifest.zig'
        text = manifest.read_text().replace('pub const definitions = [_]Definition{.{', 'const base: Definition = .{')
        text = text.rstrip().removesuffix('}};') + '''};
pub const definitions = [_]Definition{ base, blk: {
    var value = base;
    value.definition_identity = "a21994db11534bf5b193c5aa89000004";
    break :blk value;
} };
'''
        manifest.write_text(text)
        result = subprocess.run(['zig', 'build', 'strategy-authority-probe', '-Doptimize=ReleaseSafe', '--summary', 'all'],
                                cwd=root, capture_output=True, text=True, timeout=600)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        cls.node = root / ('zig-out/bin/ringwin-strategy-authority-probe' + ('.exe' if os.name == 'nt' else ''))
        cls.build = json.loads((root / 'zig-out/share/ringwin/native-strategies.json').read_bytes())

    def install_native(self, definition=A, artifact='native-a', binary=None):
        files, self.manager.strategy_policy = native_files(binary=binary or self.node.read_bytes(), build=self.build)
        manifest = write_artifact(str(self.root), artifact, archive(files), KEY,
                                  payload_format='strategy_bundle_v2',
                                  schema_registry=self.build['definitions'][0]['compatibility']['schema_registry'])
        result = self.deploy(manifest, identity=str(time.time_ns() % 2**62), expected=self.manager.active_artifact())
        self.assertEqual(result['status'], 'activated', result)
        installed = self.root / 'versions' / artifact
        self.assertEqual((installed / 'ringwin').read_bytes(), files[self.build['binary_path']])
        entry = next(p for p in package.parse_json(files['strategy-index.json'])['strategies'] if p['definition_identity'] == definition)
        config = '{"instrument":3,"max_observations":100}'
        self.binding = dict(release_artifact=artifact, definition_identity=definition,
            package_manifest_sha256=entry['package_manifest_sha256'], strategy_identity=f'{16:032x}', initialization='new',
            config_version=1, config_json=config, config_sha256=hashlib.sha256(config.encode()).hexdigest(), **self.source.scope)

    def start_node(self):
        # Use the same startup helper and scope as Python acceptance, with our compiled static registry.
        self.engine = self.node.with_name('ringwin-strategy-candidate' + ('.exe' if os.name == 'nt' else ''))
        return self.native_authority()

    def test_native_web_ready_enable_pause_and_backend_reopen_without_python(self):
        authority = self.start_node()
        self.install_native()
        status, body = self.create()
        self.assertEqual(status, 200, body)
        self.assertEqual(body['result']['status'], 'Ready', body)
        self.assertFalse(body['result']['trading_authorized'])
        authority.request(dict(operation='native_reference'))
        self.assertEqual(self.instances.deliver(self.binding['strategy_identity'], b''), [])
        observed = authority.request(dict(operation='native_catchup', strategy_identity=self.binding['strategy_identity']))
        self.assertEqual(observed['checkpoint']['state']['observations'], 1)
        status, body = self.instance_command('enable_trading')
        self.assertEqual(status, 200, body)
        self.assertTrue(body['result']['trading_authorized'], body)
        with self.assertRaisesRegex(package.PackageError, 'UnsupportedNativeOutput'):
            authority.request(dict(operation='output', strategy_identity=self.binding['strategy_identity'], frame=''))
        self.assertEqual(authority.request(dict(operation='status', strategy_identity=self.binding['strategy_identity']))['orders'], 0)
        status, body = self.instance_command('trading_pause')
        self.assertEqual(status, 200, body)
        self.assertFalse(body['result']['trading_authorized'])
        self.instances.close()
        self.instances = strategy_instance.InstanceManager(self.root / 'instances', self.manager, self.source)
        self.addCleanup(self.instances.close)
        self.app.instance_manager = self.instances
        status, body = self.client.call('POST', '/api/strategy-instances', dict(operation='recover', strategy_identity=self.binding['strategy_identity']))
        self.assertEqual(status, 200, body)
        self.assertEqual(body['result']['status'], 'Ready', body)
        self.assertFalse(body['result']['trading_authorized'])
        self.assertEqual(body['result']['checkpoint']['state']['observations'], 1)

    def test_native_runtime_inventory_mismatch_and_closed_gate_refuse_authority(self):
        authority = self.start_node()
        self.install_native()
        for mismatch in ('algorithm', 'target', 'compatibility'):
            wrong = json.loads(package.canonical(self.build))
            if mismatch == 'algorithm':
                wrong['definitions'][0]['algorithm_sha256'] = 'f' * 64
            elif mismatch == 'target':
                wrong['target'] = 'wrong-platform'
            else:
                wrong['definitions'][0]['compatibility']['native_api'] = 2
            with self.subTest(mismatch=mismatch), self.assertRaisesRegex(package.PackageError, 'NativeBuildMismatch'):
                authority.request(dict(operation='native_prepare', strategy_identity=self.binding['strategy_identity'],
                    definition_identity=A, config_json=self.binding['config_json'], config_version=1,
                    release_identity=1, binary_sha256=hashlib.sha256(self.node.read_bytes()).hexdigest(),
                    build_inventory=package.canonical(wrong).decode('ascii')))
        status, body = self.create()
        self.assertEqual(status, 200, body)
        self.assertEqual(self.instance_command('enable_trading')[0], 200)
        authority.request(dict(operation='gate'))
        deadline = time.monotonic() + 3
        records = self.instances.view()
        while records[0]['status'] != 'Stopped' and time.monotonic() < deadline:
            time.sleep(0.05)
            records = self.instances.view()
        self.assertEqual(records[0]['status'], 'Stopped')
        self.assertFalse(records[0]['trading_authorized'])
        status, body = self.client.call('POST', '/api/strategy-instances', dict(operation='recover', strategy_identity=self.binding['strategy_identity']))
        self.assertEqual(status, 200, body)
        self.assertEqual(body['result']['status'], 'Ready', body)
        self.assertFalse(body['result']['trading_authorized'])

    def test_native_replacement_and_forward_rollback_require_fresh_successors(self):
        authority = self.start_node()
        self.install_native()
        status, body = self.create()
        self.assertEqual(status, 200, body)
        original = self.binding['strategy_identity']
        self.assertEqual(self.instance_command('enable_trading')[0], 200)
        original_binding = dict(self.binding)
        for definition, operation, artifact in ((B, 'replace', 'native-b'), (A, 'forward_rollback', 'native-a')):
            old = dict(self.binding)
            if operation == 'forward_rollback':
                result = self.deploy(self.root / 'native-a.json', identity=str(time.time_ns() % 2**62),
                                     expected='native-b', kind='forward_rollback')
                self.assertEqual(result['status'], 'activated', result)
                self.binding = original_binding
            else:
                self.install_native(definition, artifact)
            status, body = self.client.call('POST', '/api/strategy-instances', dict(
                operation=operation, strategy_identity=old['strategy_identity'], expected_definition_identity=old['definition_identity'],
                operation_identity=f'{time.time_ns():032x}', release_artifact=artifact, definition_identity=definition,
                package_manifest_sha256=self.binding['package_manifest_sha256']))
            self.assertEqual(status, 200, body)
            result = body['result']
            self.assertEqual(result['status'], 'Ready', result)
            self.assertEqual(result['successor_transition']['status'], 'completed', result)
            self.assertNotIn(result['binding']['strategy_identity'], (original, old['strategy_identity']))
            self.assertFalse(result['trading_authorized'])
            self.binding = result['binding']
            with self.assertRaisesRegex(package.PackageError, 'StrategyIdentityMismatch'):
                authority.request(dict(operation='status', strategy_identity=old['strategy_identity']))
            self.assertEqual(self.instance_command('enable_trading')[0], 200)

    def test_native_running_binary_mismatch_is_rejected_before_ready(self):
        self.start_node()
        self.install_native(binary=b'wrong running node')
        status, body = self.create()
        self.assertEqual(status, 400, body)
        self.assertIn('NativeRunningBinaryMismatch', body['error'])

    def test_native_lost_cutover_ack_blocks_predecessor_recovery(self):
        authority = self.start_node()
        self.install_native()
        status, body = self.create()
        self.assertEqual(status, 200, body)
        old = dict(self.binding)
        self.install_native(B, 'native-b')
        exchange = authority.request
        def lose_commit_ack(request):
            response = exchange(request)
            if request['operation'] == 'commit_successor':
                raise package.PackageError('lost native cutover ACK')
            return response
        authority.request = lose_commit_ack
        status, body = self.client.call('POST', '/api/strategy-instances', dict(
            operation='replace', strategy_identity=old['strategy_identity'], expected_definition_identity=A,
            operation_identity=f'{time.time_ns():032x}', release_artifact='native-b', definition_identity=B,
            package_manifest_sha256=self.binding['package_manifest_sha256']))
        self.assertEqual(status, 200, body)
        progress = body['result']['successor_transition']
        self.assertEqual(progress['status'], 'unknown', body)
        self.assertFalse(exchange(dict(operation='status', strategy_identity=progress['to_instance']))['trading_authorized'])
        self.assertEqual(self.client.call('POST', '/api/strategy-instances',
            dict(operation='recover', strategy_identity=old['strategy_identity']))[0], 400)


if __name__ == '__main__':
    unittest.main()
