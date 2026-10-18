"""Run a frozen offline command plan once; persist progress across UI interruptions."""
from pathlib import Path
import argparse
import datetime
import json
import os

from capture import ROOT, OUT, capture, sha, source_manifest


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('plan', type=Path)
    args = parser.parse_args()
    plan = json.loads(args.plan.read_bytes())
    wave = plan['wave']
    if not wave or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-' for c in wave):
        raise ValueError('Invalid wave label')
    directory = OUT / 'runs' / wave
    directory.mkdir(parents=True, exist_ok=False)
    state = {'wave': wave, 'controller_pid': os.getpid(), 'started_utc': utc(),
             'plan_sha256': sha(args.plan), 'status': 'starting', 'completed': []}

    def save():
        temporary = directory / 'state.tmp'
        temporary.write_bytes((json.dumps(state, indent=2) + '\n').encode())
        temporary.replace(directory / 'state.json')

    def verify():
        if source_manifest() != plan['source']:
            raise RuntimeError('Frozen source mismatch')
        for row in plan['producers']:
            if sha(ROOT / row['path']) != row['sha256']:
                raise RuntimeError('Frozen producer mismatch: ' + row['path'])

    save()
    try:
        verify()
        for index, step in enumerate(plan['steps']):
            verify()
            state.update(status='running', active_step=index, active_label=step['label'])
            save()
            label = wave + '-' + step['label']
            code = capture(label, step['command'], step.get('timeout', 10800), plan['source'])
            row = {'label': label, 'exit_code': code,
                   'result_sha256': sha(OUT / 'runs' / label / 'result.json')}
            state['completed'].append(row)
            save()
            if code != 0:
                raise RuntimeError('Offline step failed: ' + label + ' exit=' + str(code))
            verify()
        state.update(status='passed', finished_utc=utc())
        state.pop('active_step', None)
        state.pop('active_label', None)
        save()
        return 0
    except Exception as error:
        state.update(status='failed', finished_utc=utc(),
                     error=type(error).__name__ + ': ' + str(error))
        save()
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
