#!/usr/bin/env python3
"""Run real-provider acceptance in the signed app; export evidence via stdout.

The app writes only in its own temporary directory. Inherited pipes carry the
synthetic test state across launches without widening macOS file permissions.
"""
import argparse
import base64
import json
from pathlib import Path
import subprocess
import sys

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--app', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
mode = p.add_mutually_exclusive_group()
mode.add_argument('--restore', action='store_true')
mode.add_argument('--media', action='store_true')
mode.add_argument('--history', action='store_true')
mode.add_argument('--clock-only', action='store_true', help='Only clock creation and timezone correction')
p.add_argument('--allow-live-services', action='store_true', required=True)
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=True)
flag = '--delivery-history' if a.history else '--delivery-restore' if a.restore else '--delivery-media' if a.media else '--delivery-check'
saved = (a.output / 'orvlet-delivery-tasks.json').read_bytes() if a.restore or a.media else b''
result = subprocess.run([str(a.app.resolve() / 'Contents/MacOS/Orvlet'), flag,
                         '--allow-live-services'] + (['--clock-only'] if a.clock_only else []), input=saved,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=900)
artifacts = []
for line in result.stdout.splitlines():
    try:
        item = json.loads(line)
        name = item['artifact']
        if Path(name).name != name or not name.startswith('orvlet-delivery'):
            continue
        (a.output / name).write_bytes(base64.b64decode(item['base64'], validate=True))
        artifacts.append(name)
    except (ValueError, KeyError, TypeError):
        pass
(a.output / ('restore.stderr.log' if a.restore else 'media.stderr.log' if a.media else 'run.stderr.log')).write_bytes(result.stderr)
report_name = 'orvlet-delivery-history.json' if a.history else 'orvlet-delivery-restore.json' if a.restore else 'orvlet-delivery-media.json' if a.media else 'orvlet-delivery-check.json'
if report_name not in artifacts:
    sys.exit('No fresh acceptance report; inspect app stderr.')
report = json.loads((a.output / report_name).read_text())
print(json.dumps(report, ensure_ascii=False, indent=2))
sys.exit(0 if result.returncode == 0 and report.get('ok') else 1)
