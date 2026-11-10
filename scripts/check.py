#!/usr/bin/env python3
"""Run local Debug-app suites serially; never select a live/provider check."""
from __future__ import annotations

import argparse
import datetime
import json
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
SUITES = {
    'model-api': ('--model-api-check', 'orvlet-model-api-checks.json'),
    'local-data': ('--local-data-check', 'orvlet-local-data-checks.json'),
    'builtin-cards': ('--builtin-cards-check', 'orvlet-builtin-cards-checks.json'),
    'setup': ('--setup-check', 'orvlet-setup-checks.json'),
    'task-history': ('--task-history-check', 'orvlet-task-history-checks.json'),
    'self': ('--self-check', 'orvlet-checks.json'),
    'consistency': ('--consistency-check', 'orvlet-consistency-checks.json'),
    'side-screen': ('--side-screen-check', 'orvlet-side-screen-checks.json'),
    'command-window': ('--command-window-check', 'orvlet-command-window-checks.json'),
    'listening': ('--listening-check', 'orvlet-listening-checks.json'),
    'music': ('--music-check', 'orvlet-music-check.json'),
    'motion': ('--motion-check', 'orvlet-motion-checks.json'),
    'protection': ('--protection-check', 'orvlet-protection-checks.json'),
}


def verify_report(path: Path, started: float) -> int:
    if not path.is_file() or path.stat().st_mtime < started:
        raise RuntimeError('Missing or stale suite report')
    report = json.loads(path.read_text())
    count = len(report.get('checks', []))
    if count == 0 or not (report.get('ok') is True or report.get('passed') == count):
        raise RuntimeError('Suite report did not confirm success; inspect local logs')
    return count


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--full', action='store_true', help='Run every distinct suite; default is core behavior only')
    parser.add_argument('suites', nargs='*', help=', '.join(SUITES))
    args = parser.parse_args()
    if args.full and args.suites:
        parser.error('Choose --full or explicit suites, not both')
    selected = list(dict.fromkeys(args.suites or (list(SUITES) if args.full else ['self', 'consistency'])))
    if any(name not in SUITES for name in selected):
        parser.error('Only local suite names are accepted: ' + ', '.join(SUITES))
    if sys.platform != 'darwin':
        parser.error('Native checks require a logged-in macOS desktop session')
    if not args.skip_build:
        subprocess.run([str(ROOT / 'scripts/build.sh'), 'Debug'], cwd=ROOT, check=True)
    app = ROOT / '.build/Build/Products/Debug/Orvlet.app/Contents/MacOS/Orvlet'
    if not app.is_file():
        parser.error('Debug app missing; run scripts/build.sh Debug first')
    with socket.socket() as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            probe.bind(('127.0.0.1', 19244))
        except OSError:
            parser.error('Port 19244 is already occupied; stop the old fixture before running')
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    output = ROOT / '.local/checks' / stamp
    output.mkdir(parents=True)
    with (output / 'fixture.log').open('w') as log:
        server = subprocess.Popen([sys.executable, str(ROOT / 'Tests/mock_server.py')], cwd=ROOT, stdout=log, stderr=log)
        try:
            ready = False
            for _ in range(40):
                if server.poll() is not None:
                    raise RuntimeError('Fixture failed to start; inspect its local log')
                try:
                    with urlopen('http://127.0.0.1:19244/fixture', timeout=1) as response:
                        ready = b'Test library' in response.read()
                    if ready:
                        break
                except OSError:
                    time.sleep(0.1)
            if not ready:
                raise RuntimeError('Fixture did not become ready')
            total = 0
            failed = []
            for name in selected:
                flag, filename = SUITES[name]
                report = Path('/tmp') / filename
                started = time.time()
                try:
                    with (output / f'{name}.log').open('w') as suite_log:
                        subprocess.run([str(app), flag], cwd=ROOT, stdout=suite_log, stderr=suite_log, timeout=240, check=True)
                    count = verify_report(report, started)
                    total += count
                    print(f'{name}: {count} checks passed', flush=True)
                except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
                    failed.append(name)
                    print(f'{name}: FAILED ({type(error).__name__}); continuing independent suites', flush=True)
                finally:
                    if report.is_file() and report.stat().st_mtime >= started:
                        shutil.copy2(report, output / filename)
            result = {'ok': not failed, 'passedChecks': total, 'suites': selected, 'failedSuites': failed}
            (output / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
            print(f'{"FAIL" if failed else "PASS"}: {total} checks. Local evidence: {output.relative_to(ROOT)}')
            return 1 if failed else 0
        finally:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
        print(f'Check run failed ({type(error).__name__}); inspect .local/checks for details.', file=sys.stderr)
        sys.exit(1)
