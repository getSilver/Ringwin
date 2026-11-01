"""Frozen-contract lifecycle checks through existing authenticated Web/node seams."""
import hashlib
import json
import os
from pathlib import Path
import unittest

import strategy_instance
import test_native_strategy_instance as native
import test_strategy_instance as python


def capture(test, steps, artifacts):
    """Keep exact signed package/dependency identities before temporary cleanup."""
    releases = {}
    for artifact in artifacts:
        root = test.root / 'versions' / artifact
        releases[artifact] = dict(
            signed_manifest=json.loads((test.root / (artifact + '.json')).read_bytes()),
            files=[dict(path=p.relative_to(root).as_posix(), size=p.stat().st_size,
                        sha256=hashlib.sha256(p.read_bytes()).hexdigest())
                   for p in sorted(root.rglob('*')) if p.is_file()])
    print('CONTRACT_E2E=' + json.dumps(dict(test=test.id(), steps=steps, releases=releases,
        final_records=test.instances.view()), sort_keys=True))


def enable(test, steps):
    status, body = test.instance_command('enable_trading')
    test.assertEqual(status, 200, body)
    test.assertTrue(body['result']['trading_authorized'], body)
    steps.append(body['result'])


@unittest.skipUnless(python.MEMORY_ENFORCED, 'actual OS hard-memory enforcement unavailable')
class PythonLifecycleTests(unittest.TestCase):
    setUp = python.WebInstanceTests.setUp
    deploy = python.WebInstanceTests.deploy
    _windows_cleanup = python.WebInstanceTests._windows_cleanup
    install = python.WebInstanceTests.install
    create = python.WebInstanceTests.create
    native_authority = python.WebInstanceTests.native_authority
    node_batch = staticmethod(python.WebInstanceTests.node_batch)
    instance_command = python.WebInstanceTests.instance_command
    replacement = python.WebInstanceTests.replacement
    update_config = python.WebInstanceTests.update_config

    def test_python_install_recover_enable_keep_replace_and_forward_rollback(self):
        authority = self.native_authority()
        transitions = {'Keep': dict(mutable_config_fields=['warmup_events'], rebuild_state_fields=[])}
        self.install(transitions=transitions)
        packages = self.client.call('GET', '/api/releases')[1]['strategy_packages']
        self.assertEqual(len(packages), 1)
        self.assertEqual(packages[0]['qualifications'], [])
        self.assertFalse(packages[0]['trading_authorized'])
        original = dict(self.binding)
        steps = []

        def ready(response):
            status, body = response
            self.assertEqual(status, 200, body)
            result = body['result']
            self.assertEqual(result['status'], 'Ready', result)
            self.assertFalse(result['trading_authorized'])
            steps.append(result)
            return result

        first = ready(self.create())
        identity = self.binding['strategy_identity']
        self.assertEqual(authority.request(dict(operation='status', strategy_identity=identity))['orders'], 0)
        self.instances.close()
        self.instances = strategy_instance.InstanceManager(self.root / 'instances', self.manager, self.source)
        self.addCleanup(self.instances.close)
        self.app.instance_manager = self.instances
        restored = ready(self.client.call('POST', '/api/strategy-instances',
            dict(operation='recover', strategy_identity=identity)))
        self.assertEqual(restored['binding'], first['binding'])
        self.assertGreater(restored['evidence']['host_generation'], first['evidence']['host_generation'])
        enable(self, steps)
        first_sequence = authority.request(dict(operation='status', strategy_identity=identity))['cursor'] + 1
        cursor = authority.request(dict(operation='advance'))['cursor']
        self.instances.deliver(identity, self.node_batch(cursor, first_sequence))
        cursor = authority.request(dict(operation='status', strategy_identity=identity))['cursor']
        self.source.batches = (self.node_batch(cursor, 1),)
        updated = ready(self.update_config(config='{"warmup_events":2}'))
        self.assertEqual(updated['binding']['strategy_identity'], identity)
        self.assertEqual(updated['binding']['config_version'], 2)
        enable(self, steps)
        cursor = authority.request(dict(operation='status', strategy_identity=identity))['cursor']
        self.source.batches = (self.node_batch(cursor, 1),)
        ready(self.update_config(version=3, expected=2))
        enable(self, steps)

        for definition, operation, artifact in (('b' * 32, 'replace', 'candidate-b'),
                                                  (original['definition_identity'], 'forward_rollback', 'candidate-a')):
            old = dict(self.binding)
            cursor = authority.request(dict(operation='status', strategy_identity=old['strategy_identity']))['cursor']
            self.source.batches = (self.node_batch(cursor, 1),)
            if operation == 'replace':
                self.install(definition=definition, artifact=artifact, transitions=transitions)
            else:
                rollback = self.deploy(self.root / 'candidate-a.json', identity='11002',
                                       expected='candidate-b', kind='forward_rollback')
                self.assertEqual(rollback['status'], 'activated', rollback)
                self.binding = original
            request = self.replacement(old, operation)
            response = self.client.call('POST', '/api/strategy-instances', request)
            successor = ready(response)
            self.assertEqual(successor['successor_transition']['status'], 'completed')
            self.assertNotIn(successor['binding']['strategy_identity'], (identity, old['strategy_identity']))
            self.assertEqual(successor['binding']['portfolio_identity'], original['portfolio_identity'])
            self.assertEqual(self.client.call('POST', '/api/strategy-instances', request), response)
            self.binding = successor['binding']
            enable(self, steps)
        self.assertEqual(self.instance_command('trading_pause')[0], 200)
        capture(self, steps, ('candidate-a', 'candidate-b'))


@unittest.skipUnless(os.name == 'nt', 'frozen Windows native lifecycle acceptance')
class NativeLifecycleTests(unittest.TestCase):
    setUpClass = classmethod(native.NativeWebTests.setUpClass.__func__)
    setUp = native.NativeWebTests.setUp
    deploy = native.NativeWebTests.deploy
    _windows_cleanup = native.NativeWebTests._windows_cleanup
    native_authority = native.NativeWebTests.native_authority
    node_batch = staticmethod(native.NativeWebTests.node_batch)
    instance_command = native.NativeWebTests.instance_command
    create = native.NativeWebTests.create
    install_native = native.NativeWebTests.install_native
    start_node = native.NativeWebTests.start_node

    def test_native_install_recover_enable_config_refusal_replace_and_forward_rollback(self):
        authority = self.start_node()
        self.install_native()
        original = dict(self.binding)
        status, body = self.create()
        self.assertEqual(status, 200, body)
        self.assertEqual(body['result']['status'], 'Ready')
        self.assertFalse(body['result']['trading_authorized'])
        steps = [body['result']]
        authority.request(dict(operation='native_reference'))
        self.instances.deliver(self.binding['strategy_identity'], b'')
        self.instances.close()
        self.instances = strategy_instance.InstanceManager(self.root / 'instances', self.manager, self.source)
        self.addCleanup(self.instances.close)
        self.app.instance_manager = self.instances
        status, body = self.client.call('POST', '/api/strategy-instances',
            dict(operation='recover', strategy_identity=original['strategy_identity']))
        self.assertEqual(status, 200, body)
        self.assertEqual(body['result']['status'], 'Ready')
        self.assertFalse(body['result']['trading_authorized'])
        self.assertEqual(body['result']['checkpoint']['state']['observations'], 1)
        steps.append(body['result'])
        enable(self, steps)
        status, body = self.client.call('POST', '/api/strategy-instances', dict(operation='update_config',
            strategy_identity=self.binding['strategy_identity'], expected_config_version=1,
            config_version=2, config_json=self.binding['config_json'], config_sha256=self.binding['config_sha256'],
            transition='Keep'))
        self.assertEqual(status, 400, body)
        self.assertIn('native parameter transitions are not supported', body['error'])
        self.assertEqual(self.instances.view()[0]['binding'], original)
        self.assertTrue(self.instances.view()[0]['trading_authorized'])
        for definition, operation, artifact in ((native.B, 'replace', 'native-b'),
                                                  (native.A, 'forward_rollback', 'native-a')):
            old = dict(self.binding)
            if operation == 'replace':
                self.install_native(definition, artifact)
            else:
                rollback = self.deploy(self.root / 'native-a.json', identity='11003',
                                       expected='native-b', kind='forward_rollback')
                self.assertEqual(rollback['status'], 'activated', rollback)
                self.binding = original
            request = dict(operation=operation, strategy_identity=old['strategy_identity'],
                expected_definition_identity=old['definition_identity'], operation_identity=f'{len(steps):032x}',
                release_artifact=artifact, definition_identity=definition,
                package_manifest_sha256=self.binding['package_manifest_sha256'])
            status, body = self.client.call('POST', '/api/strategy-instances', request)
            self.assertEqual(status, 200, body)
            result = body['result']
            self.assertEqual(result['status'], 'Ready', result)
            self.assertFalse(result['trading_authorized'])
            self.assertNotIn(result['binding']['strategy_identity'],
                             (original['strategy_identity'], old['strategy_identity']))
            self.assertEqual(result['binding']['portfolio_identity'], original['portfolio_identity'])
            self.assertEqual(self.client.call('POST', '/api/strategy-instances', request), (status, body))
            steps.append(result)
            self.binding = result['binding']
            enable(self, steps)
        self.assertEqual(authority.request(dict(operation='status',
            strategy_identity=self.binding['strategy_identity']))['orders'], 0)
        self.assertEqual(self.instance_command('trading_pause')[0], 200)
        capture(self, steps, ('native-a', 'native-b'))


if __name__ == '__main__':
    unittest.main()
