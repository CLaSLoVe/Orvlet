"""Exercise workspace ownership using real short-lived build processes."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BuildWorkspaceTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        scripts = self.root / 'scripts'
        scripts.mkdir()
        self.tool = scripts / 'build_workspace.py'
        shutil.copy2(ROOT / 'scripts' / self.tool.name, self.tool)
        self.pool = self.root / '.local/build-runs'

    def launch(self, code):
        return subprocess.Popen([sys.executable, str(self.tool), sys.executable, '-c', code],
                                cwd=self.root)

    def wait_for_file(self, path):
        for _ in range(250):
            if path.is_file():
                return
            time.sleep(.02)
        self.fail(f'Worker did not create {path.name}')

    def test_success_failure_and_active_neighbor(self):
        holding = self.launch("import os,time,pathlib; "
                              "pathlib.Path('holding').write_text(os.environ['TMPDIR']); time.sleep(30)")
        try:
            self.wait_for_file(self.root / 'holding')
            active = Path((self.root / 'holding').read_text())
            for status in (0, 7):
                job = self.launch("import tempfile,sys,pathlib; pathlib.Path(tempfile.gettempdir(), 'object').touch(); "
                                  f"sys.exit({status})")
                self.assertEqual(job.wait(timeout=10), status)
                self.assertEqual(list(self.pool.iterdir()), [active])
        finally:
            holding.terminate()
            holding.wait(timeout=10)
        self.assertEqual(list(self.pool.iterdir()), [])

    def test_crash_recovery_waits_for_surviving_worker(self):
        if sys.platform == 'darwin':
            setup = ("import sys; sys.path.insert(0,'scripts'); from build_workspace import native_check_profile; "
                     "ctx=native_check_profile(); profile=ctx.__enter__(); pathlib.Path('profile').write_text(profile); ")
        else:
            setup = ""
        job = self.launch("import os,time,pathlib; " + setup +
                          "pathlib.Path('worker').write_text(str(os.getpid())); time.sleep(30)")
        try:
            self.wait_for_file(self.root / 'worker')
            group = int((self.root / 'worker').read_text())
            if (self.root / 'profile').exists():
                self.addCleanup(shutil.rmtree, (self.root / 'profile').read_text(), True)
            job.kill()
            job.wait(timeout=10)
            self.assertEqual(self.launch('pass').wait(timeout=10), 0)
            self.assertEqual(len(list(self.pool.iterdir())), 1)
        finally:
            if (self.root / 'worker').exists():
                os.kill(int((self.root / 'worker').read_text()), signal.SIGKILL)
            if job.poll() is None:
                job.terminate()
                job.wait(timeout=10)
        for _ in range(100):
            try:
                os.killpg(group, 0)
            except ProcessLookupError:
                break
            except PermissionError:
                # macOS can report EPERM while launchd reaps an orphan.
                pass
            time.sleep(.02)
        foreign = self.pool / 'caller-supplied'
        foreign.mkdir()
        self.assertEqual(self.launch('pass').wait(timeout=10), 0)
        self.assertEqual(list(self.pool.iterdir()), [foreign])
        if (self.root / 'profile').exists():
            self.assertFalse(Path((self.root / 'profile').read_text()).exists())

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS bundle exchange')
    def test_replacing_debug_product_retires_only_previous_bundle(self):
        destination = self.root / '.build/Build/Products/Debug/Orvlet.app'
        for version in ('first', 'second'):
            source = self.root / version / 'Orvlet.app'
            executable = source / 'Contents/MacOS/Orvlet'
            executable.parent.mkdir(parents=True)
            executable.write_text(version)
            subprocess.run([sys.executable, str(self.tool), '--keep-debug', str(source), str(destination)],
                           check=True)
            self.assertEqual((destination / 'Contents/MacOS/Orvlet').read_text(), version)
            if version == 'second':
                self.assertEqual(executable.read_text(), 'first')
