"""Native bundle validation uses build output, never a Python runtime."""
import hashlib
import io
import json
from pathlib import Path
import tarfile
import unittest

import strategy_package as package

ROOT = Path(__file__).resolve().parents[1]


def native_files(binary=None, build=None):
    build = build or json.loads((ROOT / 'zig-out/share/ringwin/native-strategies.json').read_bytes())
    files = {build['binary_path']: binary or (ROOT / 'zig-out' / build['binary_path']).read_bytes(),
             'share/ringwin/native-strategies.json': package.canonical(build)}
    for definition in build['definitions']:
        for kind in ('config_schema', 'state_schema'):
            name = definition[kind]['path']
            files[name] = (ROOT / 'zig-out' / name).read_bytes()
    files['strategy-index.json'] = package.canonical(dict(format_version=2, strategies=[dict(
        definition_identity=d['definition_identity'], manifest_path='share/ringwin/native-strategies.json',
        package_manifest_sha256=hashlib.sha256(package.canonical(dict(
            build={k: v for k, v in build.items() if k != 'definitions'}, definition=d))).hexdigest())
        for d in build['definitions']]))
    return files, dict(native_build=build)


def archive(files):
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode='w', format=tarfile.USTAR_FORMAT) as tar:
        for name, data in sorted(files.items()):
            item = tarfile.TarInfo(name)
            item.size = len(data)
            tar.addfile(item, io.BytesIO(data))
    return out.getvalue()


class NativeBundleTests(unittest.TestCase):
    def test_native_build_installs_without_python_and_is_explicitly_versioned(self):
        files, policy = native_files()
        bundle = package.validate_bundle(archive(files), policy, version=2)
        self.assertEqual(bundle.files['ringwin'], bundle.files[policy['native_build']['binary_path']])
        self.assertEqual(bundle.executable_paths, (policy['native_build']['binary_path'], 'ringwin'))
        self.assertEqual(bundle.packages[0]['runtime'], 'native_static')
        self.assertFalse(bundle.packages[0]['trading_authorized'])
        with self.assertRaises(package.PackageError):
            package.validate_bundle(archive(files), policy)

    def test_native_build_rejects_policy_schema_index_and_extra_runtime_mismatches(self):
        files, policy = native_files(binary=b'validation-only binary')
        build = policy['native_build']
        schema = build['definitions'][0]['config_schema']['path']
        for name, data, diagnostic in (
            (schema, b'wrong contract', 'native schema digest mismatch'),
            ('runtime/python', b'not part of a native bundle', 'undeclared native bundle file'),
            ('strategy-index.json', package.canonical(dict(format_version=1, strategies=[])), 'unsupported native strategy index format'),
        ):
            with self.subTest(file=name):
                with self.assertRaisesRegex(package.PackageError, diagnostic):
                    package.validate_bundle(archive(dict(files, **{name: data})), policy, version=2)
        wrong = json.loads(package.canonical(build))
        wrong['optimize'] = 'unapproved'
        with self.assertRaisesRegex(package.PackageError, 'native approved build mismatch'):
            package.validate_bundle(archive(files), dict(native_build=wrong), version=2)


if __name__ == '__main__':
    unittest.main()
