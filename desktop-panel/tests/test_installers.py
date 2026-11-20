"""Run installers in a temporary home without downloading release assets."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipIf(os.name == 'nt', 'Unix installers')
class InstallerTests(unittest.TestCase):
    def test_source_install_accepts_platforms_without_release_assets(self):
        with tempfile.TemporaryDirectory(prefix='agy-installer-') as tmp:
            base = Path(tmp)
            source = base / 'source'
            panel = source / 'desktop-panel'
            backend = panel / 'sidecars/status/agy-desktop-backend'
            backend.parent.mkdir(parents=True)
            shutil.copyfile(ROOT / 'install.sh', source / 'install.sh')
            shutil.copyfile(ROOT / 'desktop-panel/install.sh', panel / 'install.sh')
            (panel / 'install.sh').chmod(0o755)
            (source / 'main.zig').touch()
            (panel / 'backend.zig').touch()
            (panel / 'plugin.json').write_text('{"version":"0.4.0"}')
            for path in (source / 'agy-statusline', backend):
                path.write_text('#!/bin/sh\necho test-version\n')
                path.chmod(0o755)
            mocks = base / 'mocks'
            mocks.mkdir()
            uname = mocks / 'uname'
            uname.write_text('#!/bin/sh\ncase "$1" in -s) echo Linux;; -m) echo riscv64;; esac\n')
            uname.chmod(0o755)
            env = dict(os.environ, HOME=str(base / 'home'), PATH=str(mocks) + os.pathsep + os.environ['PATH'])
            proc = subprocess.run(['bash', str(source / 'install.sh')], env=env, text=True,
                                  capture_output=True, timeout=30)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertTrue((base / 'home/.gemini/antigravity-cli/agy-statusline').is_file())
            self.assertTrue((base / 'home/.gemini/config/plugins/agy-desktop-status/sidecars/status/agy-desktop-backend').is_file())
            remote = subprocess.run(['bash'], input=(source / 'install.sh').read_text(), env=env,
                                    text=True, capture_output=True, timeout=30)
            self.assertNotEqual(remote.returncode, 0)
            self.assertIn('尚不支持 Linux riscv64', remote.stderr)

    def test_detect_platform_supports_linux_arm64(self):
        script = (ROOT / 'install.sh').read_text()
        detect = script[script.index('detect_platform() {'):script.index('\nfetch()')]
        for machine in ('aarch64', 'arm64'):
            with tempfile.TemporaryDirectory(prefix='agy-uname-') as tmp:
                mocks = Path(tmp)
                uname = mocks / 'uname'
                uname.write_text(f'#!/bin/sh\ncase "$1" in -s) echo Linux;; -m) echo {machine};; esac\n')
                uname.chmod(0o755)
                env = dict(os.environ, PATH=str(mocks) + os.pathsep + os.environ['PATH'])
                proc = subprocess.run(['bash', '-c', detect + '\ndetect_platform'], env=env, text=True,
                                      capture_output=True, timeout=30)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertEqual(proc.stdout.strip(), 'linux-arm64')


if __name__ == '__main__':
    unittest.main()
