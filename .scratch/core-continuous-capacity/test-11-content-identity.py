"""Resource allocation observations may change without changing durable file bytes."""
from pathlib import Path
import copy
import importlib.util
import unittest

spec = importlib.util.spec_from_file_location('processes', Path(__file__).with_name('run-10-file-processes.py'))
processes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(processes)


class FileContentIdentity(unittest.TestCase):
    def setUp(self):
        self.before = [{'path': 'shard-0/order-history.objects', 'bytes': 3,
                        'sha256': 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
                        'allocated_bytes': 262144, 'raw_st_blocks': 512}]

    def test_allocation_change_preserves_identical_content(self):
        after = copy.deepcopy(self.before)
        after[0].update(allocated_bytes=208896, raw_st_blocks=408)
        self.assertTrue(processes.same_file_content(self.before, after))

    def test_same_length_corruption_is_rejected(self):
        after = copy.deepcopy(self.before)
        after[0]['sha256'] = '0' * 64
        self.assertFalse(processes.same_file_content(self.before, after))

    def test_missing_renamed_and_truncated_files_are_rejected(self):
        self.assertFalse(processes.same_file_content(self.before, []))
        for key, value in (('path', 'other.objects'), ('bytes', 2)):
            after = copy.deepcopy(self.before)
            after[0][key] = value
            self.assertFalse(processes.same_file_content(self.before, after))


if __name__ == '__main__':
    unittest.main()
