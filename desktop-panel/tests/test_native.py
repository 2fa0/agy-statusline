"""Native runtime regressions. Python is a test driver, never a plugin dependency."""
import json
import os
import secrets
import socket
import sqlite3
import shutil
import shlex
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

PANEL = Path(__file__).resolve().parent.parent
BINARY = Path(os.environ.get('AGY_DESKTOP_BACKEND', str(PANEL / 'sidecars' / 'status' / ('agy-desktop-backend.exe' if os.name == 'nt' else 'agy-desktop-backend')))).resolve()
CID = '12345678-1234-1234-1234-123456789abc'


def encode_varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            break
    return bytes(out)


def field_varint(num, val):
    return encode_varint((num << 3) | 0) + encode_varint(val)


def field_bytes(num, payload):
    return encode_varint((num << 3) | 2) + encode_varint(len(payload)) + payload


def blob(tokens=100, seconds=2, model=b'gemini-demo', duration11=None, nanos=None):
    chat = field_bytes(4, field_varint(2, 20) + field_varint(3, tokens) + field_varint(5, 80))
    if seconds is not None or nanos is not None:
        dur = b''
        if seconds is not None:
            dur += field_varint(1, seconds)
        if nanos is not None:
            dur += field_varint(2, nanos)
        chat += field_bytes(12, dur)
    if duration11 is not None:
        chat += field_bytes(11, field_varint(1, duration11))
    return field_bytes(1, chat + field_bytes(19, model))


class NativeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not BINARY.is_file():
            raise RuntimeError(f'Build the Zig backend first: {BINARY}')

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='agy-native-test-')
        self.root = Path(self.tmp.name)
        self.data = self.root / 'plugin_data' / 'agy-desktop-status'
        self.data.mkdir(parents=True)
        (self.root / 'conversations').mkdir()
        self.path = self.root / 'conversations' / f'{CID}.db'
        self.log = self.root / 'brain' / CID / '.system_generated' / 'logs' / 'transcript.jsonl'
        self.env = dict(os.environ, AGY_NO_NOTCH='1', AGY_STATUSLINE_SETTINGS=str(self.root / 'config.json'),
                        AGY_STATUSLINE_QUOTA_FILE=str(self.root / 'quota.json'))
        self.processes = []

    def tearDown(self):
        for proc in self.processes:
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=5)
            for stream in (proc.stdin, proc.stdout, proc.stderr):
                if stream:
                    stream.close()
        self.tmp.cleanup()

    def args(self):
        return ['--desktop-root', str(self.root), '--data-dir', str(self.data)]

    def snapshot(self, cid=CID):
        p = subprocess.run([str(BINARY), 'status', '--conversation-id', cid, *self.args()], env=self.env, text=True, capture_output=True, check=True)
        return json.loads(p.stdout)

    def worker(self):
        p = subprocess.Popen([str(BINARY), '--serve', *self.args()], env=self.env, text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.processes.append(p)
        return p

    def query(self, proc, cid=CID):
        proc.stdin.write(json.dumps({'conversationId': cid}) + '\n')
        proc.stdin.flush()
        return json.loads(proc.stdout.readline())

    def transcript(self, rows):
        self.log.parent.mkdir(parents=True, exist_ok=True)
        self.log.write_text(''.join(json.dumps(row) + '\n' for row in rows))

    def database(self, entries=(None,), wal=False):
        db = sqlite3.connect(self.path)
        if wal:
            db.execute('PRAGMA journal_mode=WAL')
        db.execute('CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY,data BLOB)')
        for idx, entry in enumerate(entries):
            db.execute('INSERT INTO gen_metadata VALUES(?,?)', (idx, blob() if entry is None else entry))
        db.commit()
        return db

    def test_runtime_configuration_is_native_only(self):
        manifest = json.loads((PANEL / 'sidecars' / 'status' / 'sidecar.json').read_text())
        self.assertEqual(manifest['command'], './agy-desktop-backend')
        self.assertEqual(manifest['args'], ['serve'])
        self.assertTrue(manifest.get('has_web_ui'))
        self.assertEqual(manifest.get('restart_policy'), 'always')
        views = manifest.get('ui_config', {}).get('views', [])
        self.assertEqual(len(views), 1)
        self.assertEqual(views[0].get('entrypoint'), 'SIDECAR_UI_ENTRYPOINT_AUX_PANE')
        self.assertEqual(views[0].get('path'), '/')
        hooks = (PANEL / 'hooks.json').read_text()
        self.assertNotIn('python', hooks)
        self.assertIn('agy-desktop-backend hook', hooks)
        self.assertFalse((PANEL / 'telemetry.py').exists())
        self.assertFalse((PANEL / 'sidecars' / 'status' / 'main.mjs').exists())

    def test_resolves_host_sidecar_data_environment(self):
        (self.data / 'active_session.json').write_text(json.dumps({'activeConversationId': CID, 'sessions': {}}))
        env = dict(self.env, ANTIGRAVITY_EXECUTABLE_DATA_DIR=str(self.root / 'sidecar_data' / 'agy-desktop-status' / 'status' / 'data'))
        env.pop('AGY_DESKTOP_DATA_DIR', None)
        env.pop('PLUGIN_DATA', None)
        proc = subprocess.run([str(BINARY), 'status'], env=env, capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(proc.stdout)['conversationId'], CID)

    def test_data_directory_resolves_custom_cli_root_without_environment(self):
        self.database().close()
        (self.data / 'active_session.json').write_text(json.dumps({'activeConversationId': CID, 'sessions': {}}))
        env = dict(self.env)
        for key in ('AGY_DESKTOP_DATA_DIR', 'ANTIGRAVITY_EXECUTABLE_DATA_DIR'):
            env.pop(key, None)
        proc = subprocess.run([str(BINARY), 'status-brief', '--data-dir', str(self.data)],
                              env=env, capture_output=True, text=True, check=True)
        self.assertTrue(json.loads(proc.stdout)['found'])

    def test_cli_status_preserves_per_session_terminal_identity(self):
        other = '22222222-2222-2222-2222-222222222222'
        for cid, terminal in ((CID, 'ghostty'), (other, 'iTerm.app')):
            subprocess.run([str(BINARY), 'cli-status', '--desktop-root', str(self.root), '--conversation-id', cid],
                           env=dict(self.env, TERM_PROGRAM=terminal), cwd=self.root, check=True)
        state = json.loads((self.data / 'active_session.json').read_text())
        self.assertEqual(state['clientKind'], 'cli')
        self.assertEqual(state['sessions'][CID]['terminalEnv']['TERM_PROGRAM'], 'ghostty')
        self.assertEqual(state['sessions'][other]['terminalEnv']['TERM_PROGRAM'], 'iTerm.app')
        self.assertEqual(Path(state['sessions'][CID]['cwd']).resolve(), self.root.resolve())
        snap = self.snapshot(CID)
        self.assertEqual(snap['terminalEnv']['TERM_PROGRAM'], 'ghostty')
        recent = {item['conversationId']: item for item in snap['recentConversations']}
        self.assertEqual(recent[other]['terminalEnv']['TERM_PROGRAM'], 'iTerm.app')

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS CLI menu bar')
    def test_cli_statusline_starts_notch_with_explicit_root_and_cli_mode(self):
        cli_binary = os.environ.get('AGY_STATUSLINE_BINARY')
        if not cli_binary:
            self.skipTest('Set AGY_STATUSLINE_BINARY to exercise the CLI startup chain')
        cli = self.root / 'custom-cli'
        sidecars = cli / 'sidecars/status'
        sidecars.mkdir(parents=True)
        shutil.copy2(cli_binary, cli / 'agy-statusline')
        shutil.copy2(BINARY, sidecars / 'agy-desktop-backend')
        captured = self.root / 'notch-args'
        notch = sidecars / 'agy-notch'
        notch.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > ' + shlex.quote(str(captured)) + '\n')
        notch.chmod(0o755)
        env = dict(self.env, AGY_CLI_DIR=str(cli), TERM_PROGRAM='ghostty')
        env.pop('AGY_NO_NOTCH', None)
        result = subprocess.run([str(cli / 'agy-statusline')], input=json.dumps({'conversation_id': CID}),
                                env=env, capture_output=True, text=True, check=True, timeout=3)
        self.assertIn('Ctx:', result.stdout)
        deadline = time.time() + 3
        while not captured.exists() and time.time() < deadline:
            time.sleep(.01)
        self.assertTrue(captured.exists())
        args = captured.read_text().splitlines()
        self.assertIn('--cli', args)
        self.assertEqual(args[args.index('--desktop-root') + 1], str(cli))
        self.assertEqual(args[args.index('--data-dir') + 1], str(cli / 'plugin_data/agy-desktop-status'))
        state = json.loads((cli / 'plugin_data/agy-desktop-status/active_session.json').read_text())
        self.assertEqual(state['activeConversationId'], CID)

    def install_release_backend(self):
        source = (PANEL / 'install.sh').read_text()

        def function_block(name):
            start = source.index(f'{name}() {{')
            return source[start:source.index('\n}\n', start) + 3]

        prepare = '\n'.join(function_block(name) for name in
                            ('detect_platform', 'resolve_native_source', 'prepare_backend'))
        import platform
        target = {
            ('Darwin', 'arm64'): 'macos-arm64',
            ('Linux', 'x86_64'): 'linux-x64',
            ('Linux', 'aarch64'): 'linux-arm64',
            ('Linux', 'arm64'): 'linux-arm64',
        }.get((platform.system(), platform.machine()), 'local')
        (self.root / 'bin' / target).mkdir(parents=True)
        (self.root / 'sidecars' / 'status').mkdir(parents=True)
        import shutil
        shutil.copyfile(BINARY, self.root / 'bin' / target / 'agy-desktop-backend')
        proc = subprocess.run(['bash', '-c', prepare + '\nprepare_backend "$1"', '_', str(self.root)], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        installed = self.root / 'sidecars' / 'status' / 'agy-desktop-backend'
        self.assertTrue(os.access(installed, os.X_OK))
        self.assertEqual(installed.read_bytes(), BINARY.read_bytes())

    @unittest.skipIf(os.name == 'nt', 'Unix installer')
    def test_release_installer_selects_native_binary(self):
        self.install_release_backend()

    def test_empty_and_invalid_conversations(self):
        self.assertFalse(self.snapshot('auto')['found'])
        self.assertEqual(self.snapshot('../../etc/passwd')['conversationId'], '')
        self.assertFalse(self.snapshot()['found'])
        self.assertIsNone(self.snapshot()['sessionUsage'])

    @unittest.skipIf(os.name == 'nt', 'Unix installer')
    def test_release_installer_replaces_running_backend(self):
        self.install_release_backend()
        installed = self.root / 'sidecars' / 'status' / 'agy-desktop-backend'
        before = installed.stat().st_ino
        p = subprocess.Popen([str(installed), '--serve', *self.args()], env=self.env, text=True,
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.processes.append(p)
        self.assertFalse(self.query(p)['found'])
        source = (PANEL / 'install.sh').read_text()

        def function_block(name):
            start = source.index(f'{name}() {{')
            return source[start:source.index('\n}\n', start) + 3]

        prepare = '\n'.join(function_block(name) for name in
                            ('detect_platform', 'resolve_native_source', 'prepare_backend'))
        subprocess.run(['bash', '-c', prepare + '\nprepare_backend "$1"', '_', str(self.root)], check=True)
        self.assertNotEqual(installed.stat().st_ino, before)
        self.assertFalse(self.query(p)['found'])

    def test_snapshot_stats_and_model_usage(self):
        db = self.database([blob(100, 2), blob(600, 3, b'claude-demo')]); db.close()
        self.transcript([
            {'type': 'USER_INPUT', 'created_at': '2026-11-20T01:00:00.123456Z'},
            {'type': 'PLANNER_RESPONSE', 'status': 'DONE', 'created_at': '2026-11-20T01:00:04.123456Z', 'model': 'gemini-demo-high', 'input_tokens': 10, 'cache_read_tokens': 90, 'output_tokens': 100},
            {'type': 'CHECKPOINT', 'status': 'DONE', 'created_at': '2026-11-20T01:00:05Z', 'input_tokens': 50, 'cache_read_tokens': 0, 'output_tokens': 5},
            {'type': 'PLANNER_RESPONSE', 'status': 'DONE', 'created_at': '2026-11-20T01:00:08Z', 'model': 'claude-demo', 'input_tokens': 100, 'cache_read_tokens': 0, 'output_tokens': 600},
            {'type': 'PLANNER_RESPONSE', 'status': 'DONE', 'input_tokens': False, 'cache_read_tokens': 0, 'output_tokens': 4},
        ])
        snap = self.snapshot()
        self.assertTrue(snap['found'])
        self.assertEqual(snap['conversationId'], CID)
        self.assertEqual(snap['outputTokens'], 600)
        self.assertEqual(snap['inputTokens'], 20)
        self.assertEqual(snap['cacheReadTokens'], 80)
        self.assertEqual(snap['lastGenSpeed'], 200.0)
        self.assertEqual(snap['lastAvgSpeed'], 200.0)
        self.assertEqual(snap['lastGenDurationSec'], 3.0)
        self.assertEqual(snap['stepCount'], 5)
        self.assertEqual(snap['compactionCount'], 1)
        self.assertEqual(snap['turnDurationSec'], 7.88)
        self.assertEqual(snap['sessionDurationSec'], 7.88)
        self.assertEqual(snap['sessionUsage']['requestCount'], 4)
        self.assertEqual(snap['sessionUsage']['inputTokens'], 160)
        self.assertEqual(snap['sessionUsage']['cacheReadTokens'], 90)
        self.assertEqual(snap['sessionUsage']['outputTokens'], 705)
        self.assertEqual(snap['sessionUsage']['totalTokens'], 955)
        self.assertEqual(len(snap['history']), 2)
        models = {m['model']: m for m in snap['modelUsage']}
        self.assertEqual(models['gemini-demo']['speedSamples'], 1)
        self.assertEqual(models['gemini-demo']['avgSpeedTokS'], 50.0)
        self.assertEqual(models['claude-demo']['speedSamples'], 1)
        self.assertEqual(models['claude-demo']['avgSpeedTokS'], 200.0)

    def test_speed_filters_sub_100ms_and_unrealistic_bursts(self):
        # Sub-100ms field 12 must not fall back to field 11, and >= 1000 tok/s bursts are ignored.
        db = self.database([
            blob(200, seconds=None, nanos=50_000_000, duration11=5),
            blob(1000, seconds=None, nanos=500_000_000),
        ]); db.close()
        snap = self.snapshot()
        self.assertIsNone(snap['lastAvgSpeed'])
        self.assertEqual([h['speedTokS'] for h in snap['history']], [None, None])

    def test_duration_uses_field12_not_ttft_and_speed_scopes_to_current_model(self):
        db = self.database([
            blob(10000, seconds=100, model=b'gemini-4-neon', duration11=5),
            blob(2455, seconds=8, nanos=880_000_000, model=b'gemini-4-hydrogen', duration11=4),
        ]); db.close()
        snap = self.snapshot()
        self.assertEqual(snap['lastGenDurationSec'], 8.88)
        self.assertEqual(snap['lastGenTtftSec'], 4.0)
        self.assertEqual(snap['lastGenSpeed'], 276.5)
        self.assertEqual(snap['lastAvgSpeed'], 276.5)
        self.assertEqual(snap['history'][0]['durationSec'], 8.88)
        self.assertEqual(snap['history'][0]['ttftSec'], 4.0)
        self.assertEqual(snap['history'][1]['durationSec'], 100.0)
        self.assertEqual(snap['history'][1]['ttftSec'], 5.0)

        # Missing field 12 must leave durationSec/lastGenDurationSec as None instead of falling back to field 11.
        self.path.unlink()
        db2 = self.database([blob(200, seconds=None, duration11=5)]); db2.close()
        snap2 = self.snapshot()
        self.assertIsNone(snap2['lastGenDurationSec'])
        self.assertEqual(snap2['lastGenTtftSec'], 5.0)
        self.assertIsNone(snap2['history'][0]['durationSec'])
        self.assertEqual(snap2['history'][0]['ttftSec'], 5.0)

    def test_last_avg_speed_prefers_steady_samples_and_falls_back_to_short(self):
        # idx 0..1: older than recent 12 (excluded from lastAvgSpeed)
        # idx 2..11: steady 200 tok / 1.0s = 200 tok/s
        # idx 12: short burst 160 tok / 0.2s = 800 tok/s (ignored because steady samples exist)
        # idx 13: corrupt burst 1000 tok / 0.5s = 2000 tok/s (>= 1000, filtered out)
        entries = [
            blob(50, 1),
            blob(50, 1),
            *[blob(200, 1) for _ in range(10)],
            blob(160, seconds=None, nanos=200_000_000),
            blob(1000, seconds=None, nanos=500_000_000),
        ]
        db = self.database(entries); db.close()
        self.assertAlmostEqual(self.snapshot()['lastAvgSpeed'], 200.0)

        # When only short (0.1s..0.3s, < 1000 tok/s) samples exist, fall back instead of returning None.
        self.path.unlink()
        db2 = self.database([blob(100, seconds=None, nanos=200_000_000)]); db2.close()
        self.assertAlmostEqual(self.snapshot()['lastAvgSpeed'], 500.0)

    def test_schema_variants_and_partial_protobuf(self):
        for col, idx in [('metadata', 'idx'), ('data', 'step_idx')]:
            with self.subTest(col=col):
                self.path.unlink(missing_ok=True)
                db = self.database([blob(seconds=None, duration11=5) + b'\xff'])
                db.execute(f'CREATE TABLE steps({idx} INTEGER PRIMARY KEY,{col} BLOB)')
                usage = field_bytes(9, field_varint(2, 200) + field_varint(5, 800) + field_varint(3, 50))
                db.execute(f'INSERT INTO steps VALUES(1,?)', (usage,)); db.commit(); db.close()
                snap = self.snapshot()
                self.assertTrue(snap['found'])
                self.assertEqual(snap['inputTokens'], 200)
                self.assertEqual(snap['cacheReadTokens'], 800)
                self.assertEqual(snap['contextUsed'], 1000)
                self.assertEqual(snap['outputTokens'], 100)
                self.assertIsNone(snap['lastAvgSpeed'])

    def test_invalid_counts_empty_metadata_and_unknown_payloads(self):
        db = self.database([field_bytes(1, b'')]); db.close()
        for invalid in (None, -1, True, "100", 1.5, 2**53, 2**53 - 1):
            with self.subTest(invalid=invalid):
                self.transcript([{'type': 'PLANNER_RESPONSE', 'status': 'DONE', 'input_tokens': invalid, 'cache_read_tokens': 0, 'output_tokens': 2, 'content': 'x' * (256 * 1024)}])
                snap = self.snapshot()
                self.assertIsNone(snap['outputTokens'])
                self.assertIsNone(snap['lastAvgSpeed'])
                expected_input = 2**53 - 1 if invalid == 2**53 - 1 else None
                expected_output = 2 if invalid == 2**53 - 1 else None
                self.assertEqual(snap['sessionUsage']['inputTokens'], expected_input)
                self.assertEqual(snap['sessionUsage']['outputTokens'], expected_output)

    def test_all_speed_samples_and_bounded_context(self):
        db = self.database([blob(100 if i < 13 else 600, 2 if i < 13 else 3) for i in range(14)]); db.close()
        self.transcript([{'type': 'PLANNER_RESPONSE', 'status': 'DONE', 'model': 'gemini-demo-low', 'input_tokens': 0, 'cache_read_tokens': 0, 'output_tokens': 1}] * 130)
        snap = self.snapshot()
        self.assertEqual(len(snap['contextHistory']), 120)
        self.assertEqual(len(snap['history']), 12)
        self.assertEqual(snap['modelUsage'][0]['speedSamples'], 14)
        self.assertEqual(snap['modelUsage'][0]['avgSpeedTokS'], round(1900 / 29, 1))
        self.assertEqual(snap['lastAvgSpeed'], round(1700 / 25, 1))

    def test_incremental_partial_lines_truncate_regrow_and_switch(self):
        first = {'type': 'PLANNER_RESPONSE', 'status': 'DONE', 'input_tokens': 1, 'cache_read_tokens': 0, 'output_tokens': 2}
        self.transcript([first]); p = self.worker()
        self.assertEqual(self.query(p)['sessionUsage']['totalTokens'], 3)
        extra = json.dumps({'type': 'CHECKPOINT', 'status': 'DONE'})
        with self.log.open('a') as f:
            f.write(extra[:12])
        self.assertEqual(self.query(p)['compactionCount'], 0)
        with self.log.open('a') as f:
            f.write(extra[12:] + '\n')
        self.assertEqual(self.query(p)['compactionCount'], 1)
        self.assertEqual(self.query(p)['sessionUsage']['requestCount'], 2)
        self.transcript([first] * 8)
        self.assertEqual(self.query(p)['sessionUsage']['requestCount'], 8)
        replacement = self.log.with_suffix('.next')
        old = self.log.stat()
        replacement.write_text(json.dumps({'type': 'USER_INPUT'}) + '\n')
        os.utime(replacement, ns=(old.st_atime_ns, old.st_mtime_ns)); replacement.replace(self.log)
        self.assertEqual(self.query(p)['stepCount'], 1)
        other = '00000000-0000-0000-0000-000000000000'
        self.assertFalse(self.query(p, other)['found'])
        self.assertEqual(self.query(p)['stepCount'], 1)

    def test_incremental_detects_middle_rewrite_with_unchanged_boundaries(self):
        def row(tokens):
            return {'type': 'PLANNER_RESPONSE', 'status': 'DONE', 'input_tokens': tokens,
                    'cache_read_tokens': 0, 'output_tokens': 1, 'content': 'x' * 400}
        self.transcript([row(1), row(2), row(3)])
        p = self.worker()
        self.assertEqual(self.query(p)['sessionUsage']['inputTokens'], 6)
        self.transcript([row(1), row(9), row(3), row(4)])
        self.assertEqual(self.query(p)['sessionUsage']['inputTokens'], 17)
        with self.log.open('a') as f:
            f.write(json.dumps(row(5)) + '\n')
        self.assertEqual(self.query(p)['sessionUsage']['inputTokens'], 22)

    def test_wal_schema_changes_locks_and_database_replacement(self):
        db = self.database(wal=True); p = self.worker()
        self.assertEqual(self.query(p)['outputTokens'], 100)
        db.execute('UPDATE gen_metadata SET data=? WHERE idx=0', (blob(200),)); db.commit()
        self.assertEqual(self.query(p)['outputTokens'], 200)
        db.execute('CREATE TABLE steps(idx INTEGER PRIMARY KEY,metadata BLOB)')
        db.execute('INSERT INTO steps VALUES(1,?)', (field_bytes(9, field_varint(2, 300)),)); db.commit()
        self.assertEqual(self.query(p)['inputTokens'], 300)
        db.close()
        new_path = self.path.with_suffix('.next')
        new_db = sqlite3.connect(new_path); new_db.execute('CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY,data BLOB)')
        new_db.execute('INSERT INTO gen_metadata VALUES(0,?)', (blob(900),)); new_db.commit(); new_db.close()
        new_path.replace(self.path)
        self.assertEqual(self.query(p)['outputTokens'], 900)
        writer = sqlite3.connect(self.path)
        writer.execute('BEGIN EXCLUSIVE')
        # An invalidated snapshot must retry after a temporary lock.
        self.transcript([{'type': 'USER_INPUT'}])
        self.path.touch()
        self.assertIsNone(self.query(p)['outputTokens'])
        writer.rollback(); writer.close()
        self.assertEqual(self.query(p)['outputTokens'], 900)

    def test_closed_wal_database_falls_back_to_immutable(self):
        db = self.database(wal=True)
        db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        db.close()
        for ext in ('-wal', '-shm'):
            Path(str(self.path) + ext).unlink(missing_ok=True)
        before_ns = self.path.stat().st_mtime_ns
        snap = self.snapshot()
        after_ns = self.path.stat().st_mtime_ns
        self.assertEqual(before_ns, after_ns, f'snapshot changed mtime: {before_ns} -> {after_ns}')
        self.assertEqual(snap['outputTokens'], 100)
        self.assertEqual(snap['lastAvgSpeed'], 50.0)
        snap_ts = datetime.fromisoformat(snap['recentConversations'][0]['updatedAt'].replace('Z', '+00:00')).timestamp()
        self.assertAlmostEqual(snap_ts, before_ns / 1e9, places=5)
        self.assertEqual([c['conversationId'] for c in snap['recentConversations']], [CID])

    def test_cli_reads_closed_wal_database(self):
        cli = PANEL.parent / ('agy-statusline.exe' if os.name == 'nt' else 'agy-statusline')
        if not cli.is_file():
            self.skipTest(f'{cli} not built')
        conv = self.root / '.gemini' / 'antigravity-cli' / 'conversations'
        conv.mkdir(parents=True)
        db_path = conv / f'{CID}.db'
        db = sqlite3.connect(db_path)
        db.execute('PRAGMA journal_mode=WAL')
        db.execute('CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY,data BLOB)')
        db.execute('INSERT INTO gen_metadata VALUES(0,?)', (blob(120, 2),))
        db.commit()
        db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        db.close()
        for ext in ('-wal', '-shm'):
            Path(str(db_path) + ext).unlink(missing_ok=True)
        env = dict(os.environ, HOME=str(self.root), USERPROFILE=str(self.root), AGY_STATUSLINE_QUOTA_FILE=str(self.root / 'quota.json'))
        out = subprocess.run([str(cli)], input=json.dumps({'conversation_id': CID}), env=env, text=True, capture_output=True, check=True)
        self.assertIn('Last avg speed: 60 token/s', out.stdout)

    def test_live_unicode_rate_and_step_reset(self):
        db = self.database()
        db.execute('CREATE TABLE steps(idx INTEGER PRIMARY KEY,status INTEGER,step_type INTEGER,step_payload BLOB,metadata BLOB)')
        payload = lambda text: field_bytes(20, field_bytes(1, text.encode()))
        db.execute('INSERT INTO steps VALUES(1,8,1,?,NULL)', (payload('你好'),)); db.commit()
        self.transcript([{'type': 'USER_INPUT', 'created_at': datetime.now(timezone.utc).isoformat()}])
        p = self.worker(); snap = self.query(p)
        self.assertTrue(snap['live']['active']); self.assertEqual(snap['live']['outputChars'], 2)
        self.assertIsNone(snap['live']['charsPerSec']); time.sleep(.08)
        db.execute('UPDATE steps SET step_payload=?', (payload('你好世界'),)); db.commit()
        self.assertGreater(self.query(p)['live']['charsPerSec'], 0)
        # Live snapshots must bypass the DB stat cache even if file sigs are unchanged.
        blocker = sqlite3.connect(self.path)
        blocker.execute('BEGIN EXCLUSIVE')
        self.assertFalse(self.query(p)['live']['active'])
        blocker.rollback(); blocker.close()
        db.execute('UPDATE steps SET idx=2'); db.commit()
        self.assertIsNone(self.query(p)['live']['charsPerSec'])
        db.execute('UPDATE steps SET status=3'); db.commit(); db.close()
        self.assertFalse(self.query(p)['live']['active'])

    def test_quota_roll_forward_and_most_constrained_bucket(self):
        now = int(time.time())
        content = {'source': 'agy-statusline', 'observed_at': now - 10 * 86400, 'buckets': [
            {'key': 'gemini-weekly', 'remaining_fraction': .8, 'reset_at': now - 604200},
            {'key': 'gemini-flash-weekly', 'remaining_fraction': .2, 'reset_at': now - 604200},
            {'key': 'claude-5h', 'remaining_fraction': .5},
            {'key': 'argon-weekly', 'remaining_fraction': False},
        ]}
        (self.root / 'quota.json').write_text(json.dumps(content))
        quota = self.snapshot()['quota']
        self.assertTrue(quota['stale'])
        self.assertEqual([(w['pool'], w['window']) for w in quota['windows']], [('gemini', 'weekly'), ('claude', '5h')])
        self.assertTrue(quota['windows'][0]['approx'])
        self.assertEqual(quota['windows'][0]['remainingPct'], 20)
        self.assertEqual(quota['windows'][0]['bucket'], 'gemini-flash-weekly')
        self.assertGreater(quota['windows'][0]['resetInSec'], 0)
        self.assertEqual(quota['windows'][1]['remainingPct'], 50)
        self.assertIsNone(quota['windows'][1]['resetAtEpoch'])
        self.assertIsNone(quota['windows'][1]['resetInSec'])

    def test_hook_preserves_metadata_limits_sessions_and_allows_stop(self):
        def invoke(data):
            p = subprocess.run([str(BINARY), 'hook', *self.args()], env=self.env, input=json.dumps(data), text=True, capture_output=True, check=True)
            return json.loads(p.stdout)
        invoke({'conversationId': CID, 'hookEventName': 'SessionStart', 'modelName': 'demo', 'cwd': '/project'})
        self.assertEqual(invoke({'conversationId': CID, 'hookEventName': 'Stop'}), {'decision': 'allow'})
        state = json.loads((self.data / 'active_session.json').read_text())
        self.assertEqual(state['sessions'][CID]['modelName'], 'demo')
        self.assertEqual(state['sessions'][CID]['cwd'], '/project')
        for i in range(32):
            invoke({'conversationId': f'00000000-0000-0000-0000-{i:012d}'})
        self.assertEqual(len(json.loads((self.data / 'active_session.json').read_text())['sessions']), 30)
        self.assertEqual(invoke({'hookEventName': 'Stop', 'conversationId': '../../invalid'}), {'decision': 'allow'})
        self.assertEqual(self.snapshot('auto')['conversationId'], '00000000-0000-0000-0000-000000000031')

    def test_settings_patches_preserve_other_fields_across_processes(self):
        settings = self.root / 'config.json'
        settings.write_text(json.dumps({'debug': True, 'custom': {'keep': 1}, 'pollSec': 7}))
        patches = [
            {'layout': 'detailed'}, {'modules': {'quota': False}},
            {'modules': {'history': False}}, {'thresholds': {'stallSec': 90}},
            {'thresholds': {'waitSec': 45}}, {'notch': {'hideWhenIdle': True}},
            {'notch': {'screenMode': 'allScreens'}}, {'lowSpeedWarnTokS': 80},
        ]
        procs = []
        for patch in patches:
            proc = subprocess.Popen([str(BINARY), 'settings-patch', *self.args()], env=self.env,
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.processes.append(proc)
            proc.stdin.write(json.dumps(patch)); proc.stdin.close(); proc.stdin = None
            procs.append(proc)
        for proc in procs:
            out, err = proc.communicate(timeout=10)
            self.assertEqual(proc.returncode, 0, err)
            self.assertEqual(json.loads(out)['pollSec'], 7)
        actual = json.loads(settings.read_text())
        self.assertTrue(actual['debug']); self.assertEqual(actual['custom'], {'keep': 1})
        for patch in patches:
            for key, value in patch.items():
                if isinstance(value, dict):
                    for nested, expected in value.items():
                        self.assertEqual(actual[key][nested], expected)
                else:
                    self.assertEqual(actual[key], value)

    def test_brief_queries_skip_full_transcript_and_preserve_nine_live_sessions(self):
        self.database().close()
        self.log.parent.mkdir(parents=True)
        self.log.write_bytes(b'x' * (17 * 1024 * 1024))
        ids = [f'12345678-1234-1234-1234-{i:012d}' for i in range(9)]
        for cid in ids:
            db = sqlite3.connect(self.root / 'conversations' / f'{cid}.db')
            db.execute('CREATE TABLE steps(idx INTEGER PRIMARY KEY,status INTEGER,step_type INTEGER,step_payload BLOB,metadata BLOB)')
            db.execute('INSERT INTO steps VALUES(1,8,1,?,NULL)', (field_bytes(20, field_bytes(1, b'hello')),))
            db.commit(); db.close()
        (self.root / 'config.json').write_text(json.dumps({'debug': True, 'thresholds': {'stallSec': 1}}))
        proc = self.worker()
        def brief(cid):
            proc.stdin.write(json.dumps({'op': 'brief', 'conversationId': cid}) + '\n'); proc.stdin.flush()
            return json.loads(proc.stdout.readline())
        snap = brief(CID)
        self.assertTrue(snap['found'])
        self.assertEqual(snap['transcriptPath'], str(self.log))
        self.assertIsNone(snap['sessionUsage'])
        for cid in ids:
            self.assertIsNone(brief(cid)['live']['charsPerSec'])
        time.sleep(1.05)
        for cid in ids:
            brief(CID)  # Idle queries must not evict an active sample.
            snap = brief(cid)
            self.assertEqual(snap['live']['charsPerSec'], 0)
            self.assertEqual(snap['session']['code'], 'stalled')

    def test_brief_can_omit_shared_fields_without_changing_session(self):
        self.database().close()
        proc = self.worker()

        def brief(cid=CID, **options):
            proc.stdin.write(json.dumps({'op': 'brief', 'conversationId': cid, **options}) + '\n')
            proc.stdin.flush()
            return json.loads(proc.stdout.readline())

        full = brief()
        lean = brief(includeShared=False)
        for key in ('config', 'quota', 'recentConversations'):
            self.assertIn(key, full)
            self.assertNotIn(key, lean)
            self.assertIn(key, brief())  # The option must reset on each request.
        for key in ('found', 'conversationId', 'modelName', 'workspaceName', 'transcriptPath', 'contextPct', 'session'):
            self.assertEqual(lean[key], full[key])
        self.assertIn('recentConversations', brief('auto', includeShared=False))
        proc.stdin.write(json.dumps({'conversationId': CID, 'includeShared': False}) + '\n')
        proc.stdin.flush()
        self.assertIn('recentConversations', json.loads(proc.stdout.readline()))

    def test_brief_database_cache_does_not_truncate_full_statistics(self):
        self.database(entries=[blob()] * 60).close()
        self.transcript([{'type': 'PLANNER_RESPONSE', 'status': 'DONE', 'model': 'gemini-demo',
                          'input_tokens': 20, 'cache_read_tokens': 80, 'output_tokens': 100}])
        proc = self.worker()
        proc.stdin.write(json.dumps({'op': 'brief', 'conversationId': CID}) + '\n'); proc.stdin.flush()
        self.assertIsNone(json.loads(proc.stdout.readline())['sessionUsage'])
        full = self.query(proc)
        self.assertEqual(full['modelUsage'][0]['speedSamples'], 60)
        self.assertEqual(full['sessionUsage']['requestCount'], 1)

    def test_http_contract_auth_embedded_assets_and_methods(self):
        # Reserve a port only for choosing its number; the backend owns binding.
        with socket.socket() as s:
            s.bind(('127.0.0.1', 0)); port = s.getsockname()[1]
        token = secrets.token_hex(8)
        env = dict(self.env, ANTIGRAVITY_SIDECAR_UI_TOKEN=token)
        p = subprocess.Popen([str(BINARY), 'serve', '--port', str(port), *self.args()], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.processes.append(p)
        self.assertIn('listening on 127.0.0.1:', p.stderr.readline())
        url = f'http://127.0.0.1:{port}'
        def request(path, **kwargs):
            return urllib.request.urlopen(urllib.request.Request(url + path, **kwargs), timeout=5)
        with request('/') as r:
            html = r.read().decode(); self.assertIn('/preload.js', html); self.assertIn('context-section', html)
            # The binary embeds dist/index.html at compile time; if the file was
            # rebuilt without rebuilding the backend it silently serves the old UI.
            served = html.replace('<script src="/preload.js"></script>', '', 1)
            self.assertEqual(served, (PANEL / 'dist' / 'index.html').read_text(),
                             'the backend embeds a stale bundle: run desktop-panel/build.sh')
        with request('/preload.js') as r:
            self.assertIn('X-Sidecar-Token', r.read().decode())
        with self.assertRaises(urllib.error.HTTPError) as e:
            request('/api/status')
        self.assertEqual(e.exception.code, 401); e.exception.close()
        with request('/api/status?conversationId=auto', headers={'X-Sidecar-Token': token}) as r:
            self.assertFalse(json.load(r)['found'])
        with self.assertRaises(urllib.error.HTTPError) as e:
            request('/api/settings', data=b'{"layout":"detailed"}', method='POST')
        self.assertEqual(e.exception.code, 401); e.exception.close()
        with request('/api/settings', data=b'{"layout":"detailed","pollSec":7}', method='POST',
                     headers={'X-Sidecar-Token': token, 'Content-Type': 'application/json'}) as r:
            self.assertEqual(json.load(r)['layout'], 'detailed')
        with request('/api/settings', data=b'{"modules":{"quota":false}}', method='POST',
                     headers={'X-Sidecar-Token': token}) as r:
            saved = json.load(r)
            self.assertEqual(saved['pollSec'], 7)
            self.assertFalse(saved['modules']['quota'])
        for path, method, status in [('/api/status', 'POST', 405), ('/../backend.zig', 'GET', 404), ('/api/status?token=%GG', 'GET', 400)]:
            with self.subTest(path=path), self.assertRaises(urllib.error.HTTPError) as e:
                request(path, method=method)
            self.assertEqual(e.exception.code, status); e.exception.close()

    def test_brief_falls_back_to_cli_transcript_when_db_missing(self):
        cli_log = self.root / 'cli-brain' / CID / 'transcript_full.jsonl'
        cli_log.parent.mkdir(parents=True)
        cli_log.write_text('\n'.join([
            json.dumps({'type': 'USER_INPUT', 'status': 'DONE', 'source': 'USER_EXPLICIT', 'created_at': '2026-11-24T05:00:00Z'}),
            json.dumps({'type': 'PLANNER_RESPONSE', 'status': 'DONE', 'model': 'gemini-4-hydrogen-medium',
                        'input_tokens': 4000, 'cache_read_tokens': 60000, 'output_tokens': 500, 'created_at': '2026-11-24T05:00:10Z'}),
        ]) + '\n')
        other_cid = '87654321-4321-4321-4321-210987654321'
        (self.data / 'active_session.json').write_text(json.dumps({
            'activeConversationId': CID,
            'updatedAt': '2026-11-24T05:00:12+00:00',
            'sessions': {
                CID: {
                    'conversationId': CID,
                    'updatedAt': '2026-11-24T05:00:12+00:00',
                    'modelName': 'gemini-4-hydrogen-medium',
                    'cwd': '/tmp/cli-repo',
                    'transcriptPath': str(cli_log),
                    'lastEvent': 'PreInvocation',
                },
                other_cid: {
                    'conversationId': other_cid,
                    'updatedAt': '2026-11-24T04:59:00+00:00',
                    'modelName': 'gemini-4-hydrogen-medium',
                    'cwd': '/tmp/other-cli',
                    'lastEvent': 'Stop',
                },
            },
        }))
        proc = self.worker()
        proc.stdin.write(json.dumps({'op': 'brief', 'conversationId': 'auto', 'includeShared': True}) + '\n')
        proc.stdin.flush()
        snap = json.loads(proc.stdout.readline())
        self.assertTrue(snap['found'])
        self.assertEqual(snap['usageSource'], 'transcript')
        self.assertEqual(snap['contextUsed'], 64000)
        self.assertEqual(snap['contextTotal'], 1048576)
        self.assertAlmostEqual(snap['contextPct'], 6.1, places=1)
        self.assertEqual(snap['modelName'], 'gemini-4-hydrogen-medium')
        self.assertEqual(snap['workspaceName'], 'cli-repo')
        recent_ids = [item['conversationId'] for item in snap['recentConversations']]
        self.assertIn(CID, recent_ids)
        self.assertIn(other_cid, recent_ids)

    def test_config_only_op_hot_reloads(self):
        cfg_path = self.root / 'config.json'
        cfg_path.write_text(json.dumps({'notch': {'enabled': False, 'screenMode': 'allScreens'}}))
        proc = self.worker()
        proc.stdin.write(json.dumps({'op': 'config'}) + '\n')
        proc.stdin.flush()
        resp = json.loads(proc.stdout.readline())
        self.assertTrue(resp['configOnly'])
        self.assertFalse(resp['config']['notch']['enabled'])
        self.assertEqual(resp['config']['notch']['screenMode'], 'allScreens')
        cfg_path.write_text(json.dumps({'notch': {'enabled': True, 'screenMode': 'notchOrMain'}}))
        proc.stdin.write(json.dumps({'op': 'config'}) + '\n')
        proc.stdin.flush()
        resp2 = json.loads(proc.stdout.readline())
        self.assertTrue(resp2['config']['notch']['enabled'])
        self.assertEqual(resp2['config']['notch']['screenMode'], 'notchOrMain')

    def test_cli_transcripts_remain_independent_across_nine_sessions(self):
        ids = [f'12345678-1234-1234-1234-{i:012d}' for i in range(9)]
        logs = []
        for i, cid in enumerate(ids):
            path = self.root / 'brain' / cid / '.system_generated' / 'logs' / 'transcript.jsonl'
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps({'type': 'PLANNER_RESPONSE', 'status': 'DONE', 'model': 'gemini-demo',
                                        'input_tokens': i + 1, 'cache_read_tokens': 0, 'output_tokens': 10}) + '\n')
            logs.append(path)
        proc = self.worker()
        def brief(cid):
            proc.stdin.write(json.dumps({'op': 'brief', 'conversationId': cid, 'includeShared': False}) + '\n')
            proc.stdin.flush()
            return json.loads(proc.stdout.readline())
        for _ in range(2):
            for i, cid in enumerate(ids):
                snap = brief(cid)
                self.assertEqual(snap['contextUsed'], i + 1)
                self.assertEqual(snap['sessionUsage']['requestCount'], 1)
        with logs[0].open('a') as log:
            log.write(json.dumps({'type': 'PLANNER_RESPONSE', 'status': 'DONE', 'model': 'claude-demo',
                                  'input_tokens': 100, 'cache_read_tokens': 0, 'output_tokens': 10}) + '\n')
        self.assertEqual(brief(ids[0])['contextUsed'], 100)
        self.assertEqual(brief(ids[1])['contextUsed'], 2)
        logs[0].write_text(json.dumps({'type': 'PLANNER_RESPONSE', 'status': 'DONE', 'model': 'claude-demo',
                                      'input_tokens': 7, 'cache_read_tokens': 0, 'output_tokens': 10}) + '\n')
        snap = brief(ids[0])
        self.assertEqual(snap['contextUsed'], 7)
        self.assertEqual(snap['sessionUsage']['requestCount'], 1)

    def test_recent_cache_keeps_both_newly_updated_hook_databases(self):
        ids = [f'12345678-1234-1234-1234-{i:012d}' for i in range(26)]
        base = int(time.time()) - 1000
        for i, cid in enumerate(ids):
            path = self.root / 'conversations' / f'{cid}.db'
            sqlite3.connect(path).close()
            os.utime(path, (base + i, base + i))
        proc = self.worker()
        self.query(proc)
        # These two DBs were outside the top-24 cache. Updating contents does
        # not change the directory signature, so the incremental path is used.
        for i, cid in enumerate(ids[:2]):
            os.utime(self.root / 'conversations' / f'{cid}.db', (base + 100 - i, base + 100 - i))
        (self.data / 'active_session.json').write_text(json.dumps({'sessions': {
            cid: {'updatedAt': '2020-01-01T00:00:00Z'} for cid in ids[:2]
        }}))
        recent_ids = [item['conversationId'] for item in self.query(proc)['recentConversations']]
        self.assertEqual(recent_ids[:2], ids[:2])

    def test_multi_slot_db_cache_and_recent_dir_cache(self):
        cid_a = '11111111-1111-1111-1111-111111111111'
        cid_b = '22222222-2222-2222-2222-222222222222'
        cid_c = '33333333-3333-3333-3333-333333333333'
        for cid, tok in [(cid_a, 100), (cid_b, 200)]:
            db = sqlite3.connect(self.root / 'conversations' / f'{cid}.db')
            db.execute('CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY,data BLOB)')
            db.execute('INSERT INTO gen_metadata VALUES(0,?)', (blob(tok, 2),))
            db.commit(); db.close()
        proc = self.worker()
        self.assertEqual(self.query(proc, cid_a)['outputTokens'], 100)
        self.assertEqual(self.query(proc, cid_b)['outputTokens'], 200)
        self.assertEqual(self.query(proc, cid_a)['outputTokens'], 100)
        # Adding a new DB file must invalidate the directory cache and appear in recentConversations.
        db_c = sqlite3.connect(self.root / 'conversations' / f'{cid_c}.db')
        db_c.execute('CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY,data BLOB)')
        db_c.execute('INSERT INTO gen_metadata VALUES(0,?)', (blob(300, 2),))
        db_c.commit(); db_c.close()
        snap = self.query(proc, cid_c)
        self.assertEqual(snap['outputTokens'], 300)
        recent_ids = [item['conversationId'] for item in snap['recentConversations']]
        self.assertIn(cid_c, recent_ids)

    def test_concurrent_hooks_and_turn_scoped_termination_reason(self):
        def run_hook(data):
            return subprocess.run([str(BINARY), 'hook', *self.args()], env=self.env,
                                  input=json.dumps(data), text=True, capture_output=True, check=True)
        run_hook({'conversationId': CID, 'hookEventName': 'Stop', 'terminationReason': 'MODEL_ERROR'})
        state = json.loads((self.data / 'active_session.json').read_text())
        self.assertEqual(state['sessions'][CID]['terminationReason'], 'MODEL_ERROR')
        # Next turn PreInvocation and Stop without terminationReason must not inherit MODEL_ERROR.
        run_hook({'conversationId': CID, 'hookEventName': 'PreInvocation'})
        state = json.loads((self.data / 'active_session.json').read_text())
        self.assertEqual(state['sessions'][CID]['terminationReason'], '')
        run_hook({'conversationId': CID, 'hookEventName': 'Stop'})
        state = json.loads((self.data / 'active_session.json').read_text())
        self.assertEqual(state['sessions'][CID]['lastEvent'], 'Stop')
        self.assertEqual(state['sessions'][CID]['terminationReason'], '')
        # Concurrent PreInvocation + Stop must not drop Stop due to lock contention.
        p1 = subprocess.Popen([str(BINARY), 'hook', *self.args()], env=self.env,
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        p2 = subprocess.Popen([str(BINARY), 'hook', *self.args()], env=self.env,
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        p1.stdin.write(json.dumps({'conversationId': CID, 'hookEventName': 'PreInvocation'})); p1.stdin.close()
        time.sleep(0.005)
        p2.stdin.write(json.dumps({'conversationId': CID, 'hookEventName': 'Stop'})); p2.stdin.close()
        self.assertEqual(p1.wait(timeout=5), 0)
        self.assertEqual(p2.wait(timeout=5), 0)
        for p in (p1, p2):
            p.stdout.close(); p.stderr.close()
        state = json.loads((self.data / 'active_session.json').read_text())
        self.assertEqual(state['sessions'][CID]['lastEvent'], 'Stop')

    def test_speed_history_and_usage_do_not_mix_models_splice_or_fake_zero(self):
        # Issue #5: Gemini 200 tok/s + modelless 10 tok/s must not leak into Claude's lastAvgSpeed,
        # and modelless history items must keep model == ''.
        db = self.database([blob(400, 2, b'gemini-demo'), blob(20, 2, b'')])
        db.close()
        (self.data / 'active_session.json').write_text(json.dumps({
            'activeConversationId': CID,
            'sessions': {CID: {'conversationId': CID, 'modelName': 'claude-demo', 'lastEvent': 'Stop'}},
        }))
        snap = self.snapshot()
        self.assertIsNone(snap['lastAvgSpeed'])
        self.assertEqual(snap['history'][0]['model'], '')

        # Issue #6 & #7: gen_metadata missing output with duration=2.0 must not splice steps output=888,
        # steps with only input=300 must not fake cacheHitPct=0.0, and readable empty DB falls back to transcript.
        self.path.unlink()
        no_output_meta = field_bytes(
            1,
            field_bytes(4, field_varint(2, 20))
            + field_bytes(12, field_varint(1, 2))
            + field_bytes(19, b'claude-demo'),
        )
        db = self.database([no_output_meta])
        db.execute('CREATE TABLE steps(idx INTEGER PRIMARY KEY,metadata BLOB)')
        db.execute('INSERT INTO steps VALUES(1,?)', (field_bytes(9, field_varint(2, 300) + field_varint(3, 888)),))
        db.commit(); db.close()
        snap2 = self.snapshot()
        self.assertIsNone(snap2['outputTokens'])
        self.assertEqual(snap2['lastGenDurationSec'], 2.0)
        self.assertIsNone(snap2['cacheReadTokens'])
        self.assertIsNone(snap2['cacheHitPct'])

        self.path.unlink()
        db = self.database([]); db.close()
        self.transcript([{'type': 'PLANNER_RESPONSE', 'status': 'DONE', 'model': 'claude-demo',
                          'input_tokens': 100, 'cache_read_tokens': 900, 'output_tokens': 50}])
        snap3 = self.snapshot()
        self.assertEqual(snap3['usageSource'], 'transcript')
        self.assertEqual(snap3['cacheHitPct'], 90.0)

    def test_large_transcript_append_and_middle_rewrite_detection(self):
        row = json.dumps({'type': 'PLANNER_RESPONSE', 'status': 'DONE', 'input_tokens': 10,
                          'cache_read_tokens': 90, 'output_tokens': 5, 'content': 'x' * 512}) + '\n'
        count = 2000  # > 1 MiB (exceeds full_verify_limit 512 KiB)
        self.log.parent.mkdir(parents=True, exist_ok=True)
        self.log.write_bytes((row * count).encode())
        p = self.worker()
        self.assertEqual(self.query(p)['sessionUsage']['requestCount'], count)
        with self.log.open('a') as f:
            f.write(row)
        self.assertEqual(self.query(p)['sessionUsage']['requestCount'], count + 1)
        # Rewriting the middle (while keeping length larger) must be detected by chunked verification.
        data = bytearray(self.log.read_bytes())
        mid_start = len(data) // 2
        idx = data.find(b'"input_tokens": 10', mid_start)
        self.assertGreater(idx, 0)
        data[idx:idx + len(b'"input_tokens": 10')] = b'"input_tokens": 99'
        data.extend(row.encode())
        self.log.write_bytes(bytes(data))
        self.assertEqual(self.query(p)['sessionUsage']['inputTokens'], (count + 1) * 10 + 99)


    def test_step_usage_is_completed_from_the_same_logged_step_only(self):
        # SQLite often knows the input of a step but not its cache reads; the
        # transcript row for the same step index has both. Mixing them is only
        # allowed within one request.
        db = self.database([blob(50, 2, b'gemini-demo')])
        db.execute('CREATE TABLE steps(idx INTEGER PRIMARY KEY,status INTEGER,metadata BLOB)')
        db.execute('INSERT INTO steps VALUES(4,3,?)',
                   (field_bytes(9, field_varint(2, 100) + field_varint(3, 50)),))
        db.commit(); db.close()
        self.transcript([
            {'type': 'USER_INPUT', 'created_at': '2026-11-24T05:00:00Z'},
            {'type': 'PLANNER_RESPONSE', 'status': 'DONE', 'step_index': 4, 'model': 'gemini-demo',
             'input_tokens': 100, 'cache_read_tokens': 900, 'output_tokens': 50,
             'created_at': '2026-11-24T05:00:10Z'},
        ])
        snap = self.snapshot()
        self.assertEqual(snap['usageSource'], 'steps')
        self.assertEqual(snap['inputTokens'], 100)
        self.assertEqual(snap['cacheReadTokens'], 900)
        self.assertEqual(snap['contextUsed'], 1000)
        self.assertAlmostEqual(snap['cacheHitPct'], 90.0, places=3)
        # The speed card keeps reading the one completed generation row.
        self.assertEqual(snap['outputTokens'], 50)
        self.assertEqual(snap['lastGenDurationSec'], 2.0)
        self.assertEqual(snap['lastGenSpeed'], 25.0)

        # A log row for a different step must not be spliced onto this request.
        self.transcript([
            {'type': 'PLANNER_RESPONSE', 'status': 'DONE', 'step_index': 7, 'model': 'gemini-demo',
             'input_tokens': 100, 'cache_read_tokens': 900, 'output_tokens': 50},
        ])
        snap = self.snapshot()
        self.assertEqual(snap['inputTokens'], 100)
        self.assertIsNone(snap['cacheReadTokens'])
        self.assertIsNone(snap['cacheHitPct'])
        self.assertEqual(snap['contextUsed'], 100)

        # A real zero stays a zero; "unknown" and "nothing cached" differ.
        self.transcript([
            {'type': 'PLANNER_RESPONSE', 'status': 'DONE', 'step_index': 4, 'model': 'gemini-demo',
             'input_tokens': 100, 'cache_read_tokens': 0, 'output_tokens': 50},
        ])
        snap = self.snapshot()
        self.assertEqual(snap['cacheReadTokens'], 0)
        self.assertEqual(snap['cacheHitPct'], 0.0)
        self.assertEqual(snap['contextUsed'], 100)

    def test_idle_transcript_still_corrects_a_block_edited_before_the_last_append(self):
        # ~1.2 MiB in 64 KiB chunks: past the exhaustive 512 KiB window, so the
        # edited block is only reached by the rotating scrub.
        def row(tokens):
            return json.dumps({'type': 'PLANNER_RESPONSE', 'status': 'DONE', 'input_tokens': tokens,
                               'cache_read_tokens': 90, 'output_tokens': 5, 'content': 'x' * 800}) + '\n'
        data = ''.join(row(10) for _ in range(1300))
        self.log.parent.mkdir(parents=True, exist_ok=True)
        self.log.write_text(data)
        proc = self.worker()
        base = self.query(proc)['sessionUsage']
        needle = '"input_tokens": 10'
        start = data.index(needle, 64 * 1024)
        self.assertLess(start, 128 * 1024, 'the edited row must live in the second 64 KiB block')
        patched = data[:start] + '"input_tokens": 99' + data[start + len(needle):] + row(10)
        self.log.write_bytes(patched.encode())
        # The append is picked up, but the in-place edit has not been re-read yet.
        stale = self.query(proc)['sessionUsage']
        self.assertEqual(stale['inputTokens'], base['inputTokens'] + 10)
        self.assertEqual(stale['requestCount'], base['requestCount'] + 1)
        # Nothing changes on disk any more; the scrub alone must find it.
        recovered = None
        for _ in range(12):
            recovered = self.query(proc)['sessionUsage']
            if recovered['inputTokens'] == base['inputTokens'] + 10 + 89:
                break
        self.assertEqual(recovered['inputTokens'], base['inputTokens'] + 10 + 89)
        self.assertEqual(recovered['requestCount'], base['requestCount'] + 1)


    def test_average_speed_is_labelled_with_the_model_that_produced_it(self):
        # Previous reply: Gemini. The hook already reports the newly chosen
        # Claude for this turn, so the average must not be sold as Claude's.
        from datetime import datetime, timezone
        db = self.database([blob(200, 2, b'gemini-4-hydrogen'), blob(400, 1, b'gemini-4-hydrogen')])
        db.close()
        hook_at = datetime.fromtimestamp(time.time() - 2, timezone.utc).isoformat()
        (self.data / 'active_session.json').write_text(json.dumps({
            'activeConversationId': CID,
            'sessions': {CID: {'conversationId': CID, 'updatedAt': hook_at,
                               'modelName': 'claude-sonnet-4', 'lastEvent': 'PreInvocation'}},
        }))
        snap = self.snapshot()
        self.assertEqual(snap['modelName'], 'gemini-4-hydrogen')
        self.assertEqual(snap['turnModel'], 'claude-sonnet-4')
        self.assertEqual(snap['lastAvgSpeedModel'], 'gemini-4-hydrogen')
        self.assertEqual(snap['lastAvgSpeed'], 200.0)

        # Unknown-model samples keep an empty name instead of borrowing a known one.
        self.path.unlink()
        db = self.database([blob(100, 2, b'')])
        db.close()
        (self.data / 'active_session.json').write_text(json.dumps({
            'activeConversationId': CID,
            'sessions': {CID: {'conversationId': CID, 'updatedAt': hook_at,
                               'modelName': '', 'lastEvent': 'PreInvocation'}},
        }))
        snap = self.snapshot()
        self.assertEqual(snap['lastAvgSpeed'], 50.0)
        self.assertEqual(snap['lastAvgSpeedModel'], '')

    def test_shared_notch_merges_desktop_and_cli_peer_sessions(self):
        desktop_root = self.root / 'shared' / 'antigravity'
        cli_root = self.root / 'shared' / 'antigravity-cli'
        desktop_data = desktop_root / 'plugin_data' / 'agy-desktop-status'
        cli_data = cli_root / 'plugin_data' / 'agy-desktop-status'
        desktop_data.mkdir(parents=True)
        cli_data.mkdir(parents=True)
        (desktop_root / 'conversations').mkdir(parents=True)
        cli_cid = '33333333-3333-3333-3333-333333333333'
        db = sqlite3.connect(desktop_root / 'conversations' / f'{CID}.db')
        db.execute('CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY,data BLOB)')
        db.execute('INSERT INTO gen_metadata VALUES(?,?)', (0, blob(150, 2, b'gemini-desktop')))
        db.commit()
        db.close()

        t_desktop = datetime.fromtimestamp(time.time() - 10, timezone.utc).isoformat()
        t_cli = datetime.fromtimestamp(time.time() - 2, timezone.utc).isoformat()
        (desktop_data / 'active_session.json').write_text(json.dumps({
            'activeConversationId': CID,
            'updatedAt': t_desktop,
            'sessions': {
                CID: {
                    'conversationId': CID,
                    'updatedAt': t_desktop,
                    'modelName': 'gemini-desktop',
                    'lastEvent': 'Stop',
                },
            },
        }))
        (cli_data / 'active_session.json').write_text(json.dumps({
            'activeConversationId': cli_cid,
            'updatedAt': t_cli,
            'clientKind': 'cli',
            'sessions': {
                cli_cid: {
                    'conversationId': cli_cid,
                    'updatedAt': t_cli,
                    'modelName': 'gemini-cli',
                    'lastEvent': 'PreInvocation',
                    'terminalEnv': {'TERM_PROGRAM': 'ghostty'},
                },
            },
        }))

        # Querying from Desktop side merges CLI peer and picks the newer CLI session as active.
        proc = subprocess.run(
            [str(BINARY), 'status', '--conversation-id', 'auto',
             '--desktop-root', str(desktop_root), '--data-dir', str(desktop_data)],
            env=self.env, text=True, capture_output=True, check=True,
        )
        snap = json.loads(proc.stdout)
        self.assertEqual(snap['conversationId'], cli_cid)
        self.assertEqual(snap['clientKind'], 'cli')
        self.assertEqual(snap['terminalEnv']['TERM_PROGRAM'], 'ghostty')
        recent = {item['conversationId']: item for item in snap['recentConversations']}
        self.assertEqual(recent[cli_cid]['clientKind'], 'cli')
        self.assertEqual(recent[CID]['clientKind'], 'desktop')

        # Querying Desktop's conversation from CLI side still resolves Desktop's .db via peer root.
        proc_cli = subprocess.run(
            [str(BINARY), 'status', '--conversation-id', CID,
             '--desktop-root', str(cli_root), '--data-dir', str(cli_data)],
            env=self.env, text=True, capture_output=True, check=True,
        )
        snap_cli = json.loads(proc_cli.stdout)
        self.assertTrue(snap_cli['found'])
        self.assertEqual(snap_cli['clientKind'], 'desktop')
        self.assertEqual(snap_cli['modelName'], 'gemini-desktop')

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS shared notch lock')
    def test_shared_notch_lock_prevents_duplicate_launch_across_data_dirs(self):
        import fcntl
        sidecars = self.root / 'sidecars' / 'status'
        sidecars.mkdir(parents=True)
        backend_copy = sidecars / 'agy-desktop-backend'
        shutil.copy2(BINARY, backend_copy)
        marker = self.root / 'spawned'
        notch = sidecars / 'agy-notch'
        notch.write_text('#!/bin/sh\necho spawned > ' + shlex.quote(str(marker)) + '\n')
        notch.chmod(0o755)
        lock_file = self.root / 'agy-notch.lock'
        with open(lock_file, 'a+') as lf:
            fcntl.flock(lf.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            env = dict(self.env)
            env.pop('AGY_NO_NOTCH', None)
            subprocess.run(
                [str(backend_copy), 'cli-status', '--desktop-root', str(self.root / 'other-cli'), '--conversation-id', CID],
                env=env, check=True,
            )
            time.sleep(0.15)
            self.assertFalse(marker.exists())


if __name__ == '__main__':
    unittest.main()
