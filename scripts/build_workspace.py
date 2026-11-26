"""Own a private directory and process group for one Orvlet build or test run."""
from contextlib import contextmanager
import ctypes
import fcntl
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
POOL = ROOT / '.local/build-runs'
RUN_ENV = 'ORVLET_RUN_DIR'


def use_workspace():
    if not os.environ.get(RUN_ENV):
        os.execv(sys.executable, [sys.executable, __file__, sys.executable, *sys.argv])


def group_alive(group):
    try:
        os.killpg(group, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def native_profile_path(directory):
    # The native harness requires a direct child of Foundation's per-user temp directory.
    system_tmp = subprocess.check_output(['/usr/bin/getconf', 'DARWIN_USER_TEMP_DIR'], text=True).strip()
    return Path(system_tmp) / ('orvlet-native-check-' + directory.name)


@contextmanager
def native_check_profile():
    directory = Path(os.environ[RUN_ENV])
    profile = native_profile_path(directory)
    profile.mkdir(mode=0o700)
    marker = directory / 'owns-native-profile'
    marker.touch()
    try:
        yield str(profile)
    finally:
        shutil.rmtree(profile)
        marker.unlink()


def reclaim():
    # A surviving compiler or test helper still owns its workspace after a parent crash.
    if POOL.resolve() != POOL:
        raise ValueError('Build scratch directory must be inside the checkout')
    POOL.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = os.open(POOL, os.O_RDONLY)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        for directory in POOL.iterdir():
            name = re.fullmatch(r'run-([1-9][0-9]*)-[a-f0-9]{8}', directory.name)
            if name and not directory.is_symlink() and directory.is_dir() and not group_alive(int(name[1])):
                if (directory / 'owns-native-profile').is_file():
                    profile = native_profile_path(directory)
                    if profile.is_dir() and not profile.is_symlink():
                        shutil.rmtree(profile)
                shutil.rmtree(directory)
    finally:
        os.close(lock)


def worker(command):
    # The directory name is created by the session leader before it execs the tool.
    assert os.getpid() == os.getpgrp()
    directory = POOL / f'run-{os.getpid()}-{uuid.uuid4().hex[:8]}'
    directory.mkdir(mode=0o700)
    os.environ[RUN_ENV] = str(directory)
    os.environ['TMPDIR'] = str(directory)
    os.execvp(command[0], command)


def supervise(command):
    reclaim()

    def interrupt(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
    child = subprocess.Popen([sys.executable, __file__, '--worker', *command], start_new_session=True)
    try:
        code = child.wait()
        return code if code >= 0 else 128 - code
    finally:
        if group_alive(child.pid):
            try:
                os.killpg(child.pid, signal.SIGTERM)
                for _ in range(50):
                    child.poll()
                    if not group_alive(child.pid):
                        break
                    time.sleep(.1)
                else:
                    os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        child.wait()
        reclaim()


def keep_debug_app(source, destination):
    # Both the default scratch directory and product are on the checkout volume.
    destination.parent.mkdir(parents=True, exist_ok=True)
    lock = os.open(destination.parent, os.O_RDONLY)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not destination.exists():
            source.rename(destination)
        else:
            if destination.is_symlink() or not (destination / 'Contents/MacOS/Orvlet').is_file():
                raise ValueError(f'Unexpected Debug product at {destination}')
            # macOS RENAME_SWAP puts the previous product in this run's scratch directory.
            if ctypes.CDLL(None, use_errno=True).renamex_np(os.fsencode(source), os.fsencode(destination), 2):
                error = ctypes.get_errno()
                raise OSError(error, os.strerror(error))
    finally:
        os.close(lock)


if __name__ == '__main__':
    if len(sys.argv) < 2:
        sys.exit('Usage: build_workspace.py COMMAND [ARG ...]')
    if sys.argv[1] == '--worker':
        worker(sys.argv[2:])
    elif sys.argv[1] == '--keep-debug':
        keep_debug_app(Path(sys.argv[2]), Path(sys.argv[3]))
    else:
        try:
            sys.exit(supervise(sys.argv[1:]))
        except KeyboardInterrupt:
            sys.exit(130)
