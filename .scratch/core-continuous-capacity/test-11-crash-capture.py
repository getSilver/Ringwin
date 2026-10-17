"""Exercise real direct-child capture: fatal diagnostics fail fast; ordinary negatives do not."""
from pathlib import Path
import json
import os
import subprocess
import sys

OUT = Path(__file__).resolve().parent


def main():
    prefix = sys.argv[1]
    environment = dict(os.environ, RINGWIN_CAPTURE_ABORT_ON_CRASH='1', RINGWIN_CAPTURE_TIMEOUT_SECONDS='20')
    cases = (
        ('panic', "import os,time; os.write(2,b'thread 7 panic: switch on corrupt value\\n'); time.sleep(30)", True),
        ('segfault', "import os,time; os.write(2,b'84/624 test...Segmentation fault at address 0x1234\\n'); time.sleep(30)", True),
        ('ordinary-negative', "import os; os.write(2,b'okx_private_translate_failed=NativeAssetCapacityExceeded\\nexpected panic rejection tested\\n')", False),
    )
    for label, code, fatal in cases:
        name = prefix + '-' + label
        result = subprocess.run([sys.executable, str(OUT / 'run-10-command.py'), name, sys.executable, '-c', code],
                                env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
        record = json.loads((OUT / (name + '.result.json')).read_text())
        assert not record['timed_out'] and record['capture_error'] is None
        assert (record['fatal_diagnostic'] is not None) == fatal
        assert (result.returncode != 0) == fatal
        assert record['elapsed_ns'] < 10_000_000_000
        assert record['source_mismatches_after'] == record['producer_mismatches_after'] == 0
        print(label, 'passed', flush=True)


if __name__ == '__main__':
    main()
