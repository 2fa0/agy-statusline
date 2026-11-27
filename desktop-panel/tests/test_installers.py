"""Run installers in a temporary home without downloading release assets."""
import json
import os
import shutil
import sys
import subprocess
import tempfile
import tarfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipIf(os.name == 'nt', 'Unix installers')
class InstallerTests(unittest.TestCase):
    def test_macos_release_cli_archive_installs_standalone_notch(self):
        for with_notch in (True, False):
            with self.subTest(with_notch=with_notch), tempfile.TemporaryDirectory(prefix='agy-cli-release-') as tmp:
                base = Path(tmp)
                release = base / 'release'
                release.mkdir()
                payload = base / 'payload'
                (payload / 'sidecars/status').mkdir(parents=True)
                names = ['agy-statusline']
                if with_notch:
                    names += ['sidecars/status/agy-desktop-backend', 'sidecars/status/agy-notch']
                for name in names:
                    path = payload / name
                    path.write_text('#!/bin/sh\necho test-version\n')
                    path.chmod(0o755)
                with tarfile.open(release / 'agy-statusline-macos-arm64.tar.gz', 'w:gz') as archive:
                    for name in names:
                        archive.add(payload / name, arcname=name)
                mocks = base / 'mocks'
                mocks.mkdir()
                for name, text in {
                    'uname': '#!/bin/sh\ncase "$1" in -s) echo Darwin;; -m) echo arm64;; esac\n',
                    'xattr': '#!/bin/sh\nexit 0\n',
                    'curl': '#!/bin/sh\ncp "${2#file://}" "$4"\n',
                }.items():
                    path = mocks / name
                    path.write_text(text)
                    path.chmod(0o755)
                cli = base / 'custom-cli'
                env = dict(os.environ, HOME=str(base / 'home'), AGY_CLI_DIR=str(cli),
                           AGY_STATUSLINE_RELEASE_BASE='file://' + str(release),
                           PATH=str(mocks) + os.pathsep + os.environ['PATH'])
                result = subprocess.run(['bash', '-s', '--', '--cli-only'], input=(ROOT / 'install.sh').read_text(),
                                        env=env, text=True, capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue((cli / 'agy-statusline').is_file())
                self.assertEqual((cli / 'sidecars/status/agy-notch').is_file(), with_notch)
                if not with_notch:
                    self.assertIn('仅包含终端状态栏', result.stderr)

    def test_macos_cli_only_installs_notch_without_desktop_plugin(self):
        with tempfile.TemporaryDirectory(prefix='agy-cli-installer-') as tmp:
            base = Path(tmp)
            source = base / 'source'
            sidecars = source / 'desktop-panel/sidecars/status'
            sidecars.mkdir(parents=True)
            shutil.copyfile(ROOT / 'install.sh', source / 'install.sh')
            (source / 'main.zig').touch()
            (source / 'desktop-panel/plugin.json').write_text('{}')
            for path in (source / 'agy-statusline', sidecars / 'agy-desktop-backend', sidecars / 'agy-notch'):
                path.write_text('#!/bin/sh\necho test-version\n')
                path.chmod(0o755)
            mocks = base / 'mocks'
            mocks.mkdir()
            for name, text in {
                'uname': '#!/bin/sh\ncase "$1" in -s) echo Darwin;; -m) echo arm64;; esac\n',
                'xattr': '#!/bin/sh\nexit 0\n',
            }.items():
                path = mocks / name
                path.write_text(text)
                path.chmod(0o755)
            cli = base / 'custom-cli'
            home = base / 'home'
            env = dict(os.environ, HOME=str(home), AGY_CLI_DIR=str(cli), PATH=str(mocks) + os.pathsep + os.environ['PATH'])
            result = subprocess.run(['bash', str(source / 'install.sh'), '--cli-only'], env=env,
                                    text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            for name in ('agy-desktop-backend', 'agy-notch'):
                self.assertTrue((cli / 'sidecars/status' / name).is_file())
            self.assertFalse((home / '.gemini/config/plugins/agy-desktop-status').exists())

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


class DoctorJsonTests(unittest.TestCase):
    """`--doctor --json` is the machine-readable half of the diagnosis."""

    def run_doctor(self, home):
        env = dict(os.environ, HOME=str(home))
        proc = subprocess.run(['bash', str(ROOT / 'install.sh'), '--doctor', '--json'],
                              env=env, text=True, capture_output=True, timeout=60)
        return proc, json.loads(proc.stdout)

    def test_missing_installation_reports_codes_and_remediation(self):
        with tempfile.TemporaryDirectory(prefix='agy-doctor-') as tmp:
            home = Path(tmp) / 'home'
            home.mkdir()
            proc, data = self.run_doctor(home)
            self.assertFalse(data['ok'])
            self.assertIn('cli_missing', data['codes'])
            self.assertIn('panel_missing', data['codes'])
            self.assertIn('cli_missing', data['remediation'])
            self.assertNotEqual(proc.returncode, 0)
            self.assertTrue(any(c['code'] == 'cli_missing' for c in data['checks']))

    def test_installed_but_stale_panel_is_flagged(self):
        with tempfile.TemporaryDirectory(prefix='agy-doctor-') as tmp:
            home = Path(tmp) / 'home'
            cli = home / '.gemini' / 'antigravity-cli'
            plugin = home / '.gemini' / 'config' / 'plugins' / 'agy-desktop-status'
            (plugin / 'sidecars' / 'status').mkdir(parents=True)
            cli.mkdir(parents=True)
            for path in (cli / 'agy-statusline', plugin / 'sidecars' / 'status' / 'agy-desktop-backend'):
                path.write_text('#!/bin/sh\necho stub 0.1.0\n')
                path.chmod(0o755)
            (cli / 'settings.json').write_text('{"statusLine":{"command":"agy-statusline"}}')
            (plugin / 'plugin.json').write_text('{"version":"0.1.0"}')
            _, data = self.run_doctor(home)
            self.assertIn('version_mismatch', data['codes'])
            self.assertIn('version_mismatch', data['remediation'])

    @unittest.skipIf(os.name == 'nt' or sys.platform == 'darwin',
                     'ad-hoc shell stubs cannot pass codesign on macOS')
    def test_healthy_installation_is_ok(self):
        with tempfile.TemporaryDirectory(prefix='agy-doctor-') as tmp:
            home = Path(tmp) / 'home'
            cli = home / '.gemini' / 'antigravity-cli'
            plugin = home / '.gemini' / 'config' / 'plugins' / 'agy-desktop-status'
            (plugin / 'sidecars' / 'status').mkdir(parents=True)
            cli.mkdir(parents=True)
            version = (ROOT / 'VERSION').read_text().strip()
            for path in (cli / 'agy-statusline', plugin / 'sidecars' / 'status' / 'agy-desktop-backend'):
                path.write_text('#!/bin/sh\necho stub %s\n' % version)
                path.chmod(0o755)
            (cli / 'settings.json').write_text('{"statusLine":{"command":"agy-statusline"}}')
            (plugin / 'plugin.json').write_text('{"version":"%s"}' % version)
            proc, data = self.run_doctor(home)
            self.assertTrue(data['ok'], data['codes'])
            self.assertEqual(data['codes'], [])
            self.assertEqual(proc.returncode, 0)

    def test_plugin_backend_version_mismatch_flagged_even_without_source_version(self):
        with tempfile.TemporaryDirectory(prefix='agy-doctor-') as tmp:
            home = Path(tmp) / 'home'
            cli = home / '.gemini' / 'antigravity-cli'
            plugin = home / '.gemini' / 'config' / 'plugins' / 'agy-desktop-status'
            (plugin / 'sidecars' / 'status').mkdir(parents=True)
            cli.mkdir(parents=True)
            (cli / 'agy-statusline').write_text('#!/bin/sh\necho agy-statusline 0.4.0\n')
            (cli / 'agy-statusline').chmod(0o755)
            (plugin / 'sidecars' / 'status' / 'agy-desktop-backend').write_text(
                '#!/bin/sh\necho agy-desktop-backend 0.3.0\n'
            )
            (plugin / 'sidecars' / 'status' / 'agy-desktop-backend').chmod(0o755)
            (cli / 'settings.json').write_text('{"statusLine":{"command":"agy-statusline"}}')
            (plugin / 'plugin.json').write_text('{"version":"0.4.0"}')
            # Run via stdin so LOCAL_ROOT/VERSION is absent (like curl | bash).
            env = dict(os.environ, HOME=str(home))
            proc = subprocess.run(
                ['bash', '-s', '--', '--doctor', '--json'],
                input=(ROOT / 'install.sh').read_text(),
                env=env, text=True, capture_output=True, timeout=60,
            )
            data = json.loads(proc.stdout)
            self.assertIn('version_mismatch', data['codes'])
            self.assertIn('version_mismatch', data['remediation'])

    def test_panel_installer_supports_doctor_flag(self):
        with tempfile.TemporaryDirectory(prefix='agy-panel-doctor-') as tmp:
            env = dict(os.environ, HOME=str(Path(tmp) / 'home'))
            proc = subprocess.run(
                ['bash', str(ROOT / 'desktop-panel' / 'install.sh'), '--doctor', '--json'],
                env=env, text=True, capture_output=True, timeout=60,
            )
            data = json.loads(proc.stdout)
            self.assertIn('codes', data)
            self.assertIn('panel_missing', data['codes'])

    def test_release_package_diagnoses_itself_with_valid_json(self):
        """An extracted CI archive has no ../install.sh and no sidecars backend."""
        import platform as _platform

        system, machine = _platform.system(), _platform.machine().lower()
        target = {
            ('Darwin', 'arm64'): 'macos-arm64',
            ('Linux', 'x86_64'): 'linux-x64',
            ('Linux', 'amd64'): 'linux-x64',
            ('Linux', 'aarch64'): 'linux-arm64',
            ('Linux', 'arm64'): 'linux-arm64',
        }.get((system, machine))
        if not target:
            self.skipTest(f'no release platform for {system} {machine}')

        with tempfile.TemporaryDirectory(prefix='agy-panel-release-') as tmp:
            base = Path(tmp)
            pkg = base / 'agy-desktop-status'
            shutil.copytree(ROOT / 'desktop-panel', pkg,
                            ignore=shutil.ignore_patterns('node_modules', '__pycache__'))
            self.assertFalse((base / 'install.sh').exists())
            # CI packages the native binaries under bin/<platform>/ only.
            (pkg / 'sidecars/status/agy-desktop-backend').unlink()
            packaged = pkg / 'bin' / target / 'agy-desktop-backend'
            packaged.parent.mkdir(parents=True)
            shutil.copyfile(ROOT / 'desktop-panel/sidecars/status/agy-desktop-backend', packaged)
            packaged.chmod(0o755)
            home = base / 'home'
            home.mkdir()
            env = dict(os.environ, HOME=str(home))

            def doctor():
                proc = subprocess.run(['bash', str(pkg / 'install.sh'), '--doctor', '--json'],
                                      env=env, text=True, capture_output=True, timeout=60)
                return proc, json.loads(proc.stdout)

            proc, data = doctor()
            self.assertFalse(data['ok'])
            self.assertFalse(data['installed'])
            self.assertEqual(data['scope'], 'plugin')
            self.assertFalse(data['complete'], 'a plugin-only diagnosis must not claim to be complete')
            self.assertIn('panel_missing', data['codes'])
            self.assertIn('panel_missing', data['remediation'])
            self.assertNotEqual(proc.returncode, 0)
            # The CI layout is resolved from bin/<platform>/, not sidecars/.
            self.assertEqual([c['code'] for c in data['checks'] if c['key'] == 'package.backend'], ['ok'])

            plugin = home / '.gemini' / 'config' / 'plugins' / 'agy-desktop-status'
            (plugin / 'sidecars' / 'status').mkdir(parents=True)
            installed_backend = plugin / 'sidecars' / 'status' / 'agy-desktop-backend'
            shutil.copyfile(packaged, installed_backend)
            installed_backend.chmod(0o755)
            shutil.copyfile(pkg / 'plugin.json', plugin / 'plugin.json')
            proc, data = doctor()
            self.assertTrue(data['ok'], data['codes'])
            self.assertEqual(data['codes'], [])
            self.assertEqual(proc.returncode, 0)

            # A missing manifest must still produce JSON plus a non-zero exit.
            (plugin / 'plugin.json').unlink()
            proc, data = doctor()
            self.assertIn('manifest_missing', data['codes'])
            self.assertNotEqual(proc.returncode, 0)

            # ... and an unreadable one must not abort the script before output.
            manifest = plugin / 'plugin.json'
            manifest.write_text('{"version": "%s"}' % (ROOT / 'VERSION').read_text().strip())
            manifest.chmod(0o000)
            try:
                proc, data = doctor()
            finally:
                manifest.chmod(0o644)
            self.assertIn('manifest_invalid', data['codes'])
            self.assertNotEqual(proc.returncode, 0)


if __name__ == '__main__':
    unittest.main()
