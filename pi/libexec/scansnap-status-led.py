#!/usr/bin/python3
"""Root-owned helper: report scan jobs through the Pi ACT LED only."""
import fcntl
from pathlib import Path
import re
import sys

LED_DIR = Path('/sys/class/leds/ACT')
STATE_DIR = Path('/run/scansnap-status-led')


def update(action, job=None):
    if action not in ('init', 'clear', 'begin', 'end', 'fail'):
        raise ValueError('unknown LED action')
    if action not in ('init', 'clear') and (not job or not re.fullmatch(r'[a-zA-Z0-9_-]{1,64}', job)):
        raise ValueError('invalid job identifier')
    if action in ('init', 'clear') and job is not None:
        raise ValueError('init does not accept a job')
    STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (STATE_DIR / 'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        error = STATE_DIR / 'error'
        if action == 'clear':
            error.unlink(missing_ok=True)
        if action == 'begin':
            (STATE_DIR / ('job-' + job)).touch()
        elif action in ('end', 'fail'):
            (STATE_DIR / ('job-' + job)).unlink(missing_ok=True)
            if action == 'fail':
                error.touch()
        status = 'error' if error.exists() else ('busy' if any(STATE_DIR.glob('job-*')) else 'ready')
        (STATE_DIR / 'status').write_text(status + '\n')
        if not LED_DIR.exists():
            return
        if status == 'ready':
            (LED_DIR / 'trigger').write_text('none\n')
            (LED_DIR / 'brightness').write_text((LED_DIR / 'max_brightness').read_text())
        else:
            (LED_DIR / 'trigger').write_text('timer\n')
            delay = '100\n' if status == 'error' else '700\n'
            (LED_DIR / 'delay_on').write_text(delay)
            (LED_DIR / 'delay_off').write_text(delay)


if __name__ == '__main__':
    try:
        if len(sys.argv) not in (2, 3):
            raise ValueError('usage: scansnap-status-led init | begin/end/fail JOB')
        update(*sys.argv[1:])
    except (OSError, ValueError) as exc:
        print('LED status: ' + str(exc), file=sys.stderr)
        sys.exit(1)
