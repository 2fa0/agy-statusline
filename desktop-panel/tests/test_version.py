"""Version strings must never drift between artifacts.

`VERSION` in the repository root is the single source of truth. plugin.json,
the UI package files and both native binaries' `--version` output are derived
from it, so this test fails loudly instead of shipping mismatched versions.
"""
import json
import os
import subprocess
import unittest
from pathlib import Path

PANEL = Path(__file__).resolve().parent.parent
ROOT = PANEL.parent
VERSION = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
VERSION = VERSION.splitlines()[0] if VERSION else ""


def binary_env(name, fallback):
    raw = os.environ.get(name)
    return Path(raw).resolve() if raw else fallback


BACKEND = binary_env(
    "AGY_DESKTOP_BACKEND",
    PANEL / "sidecars" / "status" / ("agy-desktop-backend.exe" if os.name == "nt" else "agy-desktop-backend"),
)
CLI = binary_env("AGY_STATUSLINE_BIN", ROOT / ("agy-statusline.exe" if os.name == "nt" else "agy-statusline"))


class VersionConsistency(unittest.TestCase):
    def test_version_file_is_present_and_plain(self):
        self.assertTrue(VERSION, "VERSION file is empty")
        self.assertRegex(VERSION, r"^\d+\.\d+\.\d+$")

    def test_manifests_match_version_file(self):
        plugin = json.loads((PANEL / "plugin.json").read_text(encoding="utf-8"))
        self.assertEqual(plugin["version"], VERSION, "plugin.json is out of sync with VERSION")

        ui_pkg = json.loads((PANEL / "ui" / "package.json").read_text(encoding="utf-8"))
        self.assertEqual(ui_pkg["version"], VERSION, "ui/package.json is out of sync with VERSION")

        ui_lock = json.loads((PANEL / "ui" / "package-lock.json").read_text(encoding="utf-8"))
        self.assertEqual(ui_lock["version"], VERSION, "ui/package-lock.json is out of sync with VERSION")
        self.assertEqual(
            ui_lock["packages"][""]["version"], VERSION, "ui/package-lock.json root entry is out of sync with VERSION"
        )

    def test_generated_panel_version_mirror(self):
        """build.sh mirrors the root VERSION next to backend.zig for @embedFile."""
        mirror = PANEL / "VERSION"
        if not mirror.exists():
            self.skipTest("desktop-panel/VERSION not generated yet (run build.sh)")
        self.assertEqual(mirror.read_text(encoding="utf-8").strip(), VERSION)

    def _assert_binary_reports_version(self, binary, prefix):
        if not binary.exists():
            self.skipTest(f"{binary} not built")
        out = subprocess.run([str(binary), "--version"], capture_output=True, text=True, timeout=30)
        self.assertEqual(out.returncode, 0, f"{binary} --version failed: {out.stderr}")
        self.assertEqual(out.stdout.strip(), f"{prefix} {VERSION}")

    def test_backend_reports_version(self):
        self._assert_binary_reports_version(BACKEND, "agy-desktop-backend")

    def test_cli_reports_version(self):
        self._assert_binary_reports_version(CLI, "agy-statusline")


if __name__ == "__main__":
    unittest.main()
