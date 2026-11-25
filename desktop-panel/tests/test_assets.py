"""Build-output drift guards for the single-file panel UI.

The whole panel is one HTML file compiled into the native binary, so two silent
failures are possible: editing `ui/src` without rebuilding `dist/index.html`, and
rebuilding `dist` without rebuilding the binary. Neither shows up at runtime —
the panel just keeps rendering the old UI. Both are asserted here.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PANEL = Path(__file__).resolve().parent.parent
ROOT = PANEL.parent
MANIFEST = PANEL / 'manifest.json'


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def node_binary():
    found = shutil.which('node')
    if found:
        return found
    for candidate in sorted(Path(os.path.expanduser('~/.nvm/versions/node')).glob('*/bin/node'), reverse=True):
        if candidate.is_file():
            return str(candidate)
    return None


class AssetDriftTests(unittest.TestCase):
    def test_manifest_covers_bundle_and_sources(self):
        """Editing ui/src without rebuilding breaks the source hashes here."""
        manifest = json.loads(MANIFEST.read_text())
        self.assertEqual(manifest['version'], (ROOT / 'VERSION').read_text().strip())
        bundle = manifest['bundle']
        self.assertEqual(sha256(PANEL / bundle['path']), bundle['sha256'])
        self.assertEqual((PANEL / bundle['path']).stat().st_size, bundle['bytes'])
        self.assertGreaterEqual(len(manifest['sources']), 3)
        for rel, entry in manifest['sources'].items():
            with self.subTest(source=rel):
                self.assertEqual(sha256(PANEL / rel), entry['sha256'])
                self.assertEqual((PANEL / rel).stat().st_size, entry['bytes'])

    def test_committed_bundle_is_exactly_rebuilt_from_sources(self):
        node = node_binary()
        if not node:
            self.skipTest('node is not available')
        build = PANEL / 'ui' / 'build.mjs'
        if not (PANEL / 'ui' / 'node_modules' / 'esbuild').is_dir():
            self.skipTest('run npm install in desktop-panel/ui first')
        with tempfile.TemporaryDirectory(prefix='agy-ui-build-') as tmp:
            out = Path(tmp) / 'index.html'
            env = dict(os.environ, AGY_UI_OUT=str(out))
            proc = subprocess.run([node, str(build)], env=env, cwd=str(PANEL / 'ui'),
                                  text=True, capture_output=True, timeout=180)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(sha256(out), sha256(PANEL / 'dist' / 'index.html'),
                             'dist/index.html is stale: run `npm run build` in desktop-panel/ui')

    def test_bundle_has_no_external_asset_references(self):
        """The panel must stay a self-contained file the binary can embed."""
        html = (PANEL / 'dist' / 'index.html').read_text()
        for bad in ('<link rel="stylesheet"', ' src="http', ' src="//', 'url(http'):
            self.assertNotIn(bad, html)
        self.assertIn('<script>', html)
        self.assertEqual(html.count('<!DOCTYPE html>'), 1)
        self.assertEqual(html.count('</head>'), 1)
        self.assertFalse((PANEL / 'mcp_config.json').exists())
        self.assertFalse((PANEL / 'server.py').exists())


if __name__ == '__main__':
    unittest.main()
