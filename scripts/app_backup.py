#!/usr/bin/env python3
"""Back up the local Orvlet app and keep the latest two completed backups."""
import argparse
import datetime
import fcntl
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from build_workspace import RUN_ENV, use_workspace


def is_orvlet(bundle):
    if bundle.is_symlink() or not bundle.is_dir():
        return False
    try:
        with (bundle / 'Contents/Info.plist').open('rb') as stream:
            return plistlib.load(stream).get('CFBundleIdentifier') == 'app.orvlet.desktop'
    except (FileNotFoundError, plistlib.InvalidFileException):
        return False


def rotate(root, source=None):
    folder = root / '.local/build-backups'
    if folder.resolve() != folder:
        raise ValueError('Backup directory must be inside the project')
    folder.mkdir(parents=True, exist_ok=True)
    lock = os.open(folder, os.O_RDONLY)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if source is not None:
            if not is_orvlet(source) or source.resolve().is_relative_to(folder):
                raise ValueError('Expected an Orvlet application outside the backup directory')
            stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S%f')
            target = folder / f'Orvlet-backup-{stamp}.app'
            with tempfile.TemporaryDirectory(prefix='.staging-', dir=os.environ.get(RUN_ENV, folder)) as temporary:
                staged = Path(temporary) / 'Orvlet.app'
                subprocess.run(['ditto', source, staged], check=True)
                subprocess.run(['codesign', '--verify', '--deep', '--strict', staged], check=True)
                staged.rename(target)

        backups = []
        for bundle in folder.iterdir():
            match = re.fullmatch(r'Orvlet-.*?(\d{8}-\d{6})(\d{1,6})?\.app', bundle.name)
            if match and is_orvlet(bundle):
                stamp = match[1] + (match[2] or '').ljust(6, '0')
                backups.append((stamp, bundle))
        for _, old in sorted(backups, reverse=True)[2:]:
            shutil.rmtree(old)
    finally:
        os.close(lock)


if __name__ == '__main__':
    use_workspace()
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--prune', action='store_true', help='Rotate existing backups only')
    action.add_argument('app', nargs='?', type=Path, help='Application bundle to back up')
    args = parser.parse_args()
    rotate(Path(__file__).resolve().parents[1], args.app)
