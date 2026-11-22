"""Session state machine and hot-reloaded panel settings.

The state machine exists so the panel can explain a slow or failed turn instead
of only colouring a dot. These tests pin the branches that would otherwise
regress silently: cancel is not an error, a model switch explains the wait, a
stalled stream is not reported as progress, and a stale Stop event expires.
"""
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime, timezone
from pathlib import Path

PANEL = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PANEL / 'tests' / 'reference'))
from test_native import BINARY, CID, blob, field_bytes

CONFIG = 'config.json'


def iso(seconds_ago=0.0):
    return datetime.fromtimestamp(time.time() - seconds_ago, timezone.utc).isoformat()


def payload(text):
    return field_bytes(20, field_bytes(1, text.encode()))


class PanelFixture(unittest.TestCase):
    """Shared temp panel data directory: hooks, database, transcript, config."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='agy-session-test-')
        self.root = Path(self.tmp.name)
        self.data = self.root / 'plugin_data' / 'agy-desktop-status'
        self.data.mkdir(parents=True)
        (self.root / 'conversations').mkdir()
        self.db_path = self.root / 'conversations' / f'{CID}.db'
        self.log = self.root / 'brain' / CID / '.system_generated' / 'logs' / 'transcript.jsonl'
        self.config_path = self.root / CONFIG
        self.env = dict(
            os.environ,
            AGY_STATUSLINE_QUOTA_FILE=str(self.root / 'quota.json'),
            AGY_STATUSLINE_SETTINGS=str(self.config_path),
        )
        self.processes = []
        self.db = None

    def tearDown(self):
        for proc in self.processes:
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=5)
            for stream in (proc.stdin, proc.stdout, proc.stderr):
                if stream:
                    stream.close()
        if self.db is not None:
            self.db.close()
        self.tmp.cleanup()

    # ---------------------------------------------------------------- fixtures
    def hooks(self, event='PreInvocation', age=0.0, model='gemini-demo', termination='', active=True):
        session = {
            'conversationId': CID,
            'updatedAt': iso(age),
            'modelName': model,
            'lastEvent': event,
            'terminationReason': termination,
        }
        state = {'updatedAt': iso(age), 'sessions': {CID: session}}
        if active:
            state['activeConversationId'] = CID
        (self.data / 'active_session.json').write_text(json.dumps(state))

    def config(self, **overrides):
        self.config_path.write_text(json.dumps(overrides))

    def database(self, models=('gemini-demo',)):
        self.db = sqlite3.connect(self.db_path)
        self.db.execute('CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY,data BLOB)')
        for idx, model in enumerate(models):
            self.db.execute('INSERT INTO gen_metadata VALUES(?,?)', (idx, blob(120, 2, model.encode())))
        self.db.commit()
        return self.db

    def live_step(self, text='你好', idx=1, status=2):
        if not self.db:
            self.database()
        exists = self.db.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='steps'"
        ).fetchone()
        if not exists:
            self.db.execute(
                'CREATE TABLE steps(idx INTEGER PRIMARY KEY,status INTEGER,step_type INTEGER,step_payload BLOB,metadata BLOB)'
            )
        self.db.execute('DELETE FROM steps')
        self.db.execute('INSERT INTO steps VALUES(?,?,2,?,?)', (idx, status, payload(text), blob(120, 2)))
        self.db.commit()

    def transcript(self, rows=()):
        self.log.parent.mkdir(parents=True, exist_ok=True)
        rows = list(rows) or [{'type': 'USER_INPUT', 'created_at': iso(30)}]
        self.log.write_text(''.join(json.dumps(row) + '\n' for row in rows))

    # ------------------------------------------------------------------ drivers
    def snapshot(self):
        proc = subprocess.run(
            [str(BINARY), 'status', '--conversation-id', CID,
             '--desktop-root', str(self.root), '--data-dir', str(self.data)],
            env=self.env, text=True, capture_output=True, check=True,
        )
        return json.loads(proc.stdout)

    def worker(self):
        proc = subprocess.Popen(
            [str(BINARY), '--serve', '--desktop-root', str(self.root), '--data-dir', str(self.data)],
            env=self.env, text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.processes.append(proc)
        return proc

    def query(self, proc):
        proc.stdin.write(json.dumps({'conversationId': CID}) + '\n')
        proc.stdin.flush()
        return json.loads(proc.stdout.readline())

class SessionTests(PanelFixture):
    # -------------------------------------------------------------------- cases
    def test_preparing_turns_into_explained_first_token_wait(self):
        self.config(thresholds={'waitSec': 20})
        self.database()
        self.transcript()
        self.hooks('PreInvocation', age=3)
        snap = self.snapshot()['session']
        self.assertEqual((snap['state'], snap['code']), ('running', 'preparing'))
        self.assertNotIn('首字', snap['detail'])

        self.hooks('PreInvocation', age=45)
        snap = self.snapshot()['session']
        self.assertEqual((snap['state'], snap['code']), ('waiting', 'first_token_wait'))
        self.assertIn('首字', snap['detail'])
        self.assertGreaterEqual(snap['waitSec'], 44)

    def test_slight_negative_clock_skew_still_reads_as_preparing(self):
        self.database()
        self.transcript()
        self.hooks('PreInvocation', age=-1.5)
        snap = self.snapshot()['session']
        self.assertEqual((snap['state'], snap['code']), ('running', 'preparing'))
        # A far-future timestamp is corrupt and must not fake a live turn.
        self.hooks('PreInvocation', age=-300)
        snap = self.snapshot()['session']
        self.assertEqual((snap['state'], snap['code']), ('idle', 'idle'))

    def test_unreadable_database_does_not_fake_a_first_token_wait(self):
        """A missing/locked DB is not evidence that the model never started."""
        self.config(thresholds={'waitSec': 5})
        self.hooks('PreInvocation', age=30)
        snap = self.snapshot()['session']
        self.assertEqual((snap['state'], snap['code']), ('running', 'preparing'))
        # Long after the fact, admit that we cannot tell rather than guess.
        self.hooks('PreInvocation', age=600)
        snap = self.snapshot()['session']
        self.assertEqual((snap['state'], snap['code']), ('idle', 'evidence_missing'))
        self.assertIn('无法确认', snap['detail'])
        # With a readable database the same wait is real and gets explained.
        self.database()
        self.hooks('PreInvocation', age=30)
        self.assertEqual(self.snapshot()['session']['code'], 'first_token_wait')

    def test_model_switch_is_explained_with_both_models(self):
        self.database(models=('gemini-demo',))
        self.transcript()
        self.hooks('PreInvocation', age=30, model='claude-sonnet-4')
        snap = self.snapshot()['session']
        self.assertEqual(snap['code'], 'model_switch_prefill')
        self.assertEqual(snap['state'], 'waiting')
        self.assertIn('claude-sonnet-4', snap['detail'])
        self.assertIn('gemini-demo', snap['detail'])
        self.assertIn('切换', snap['detail'])

    def test_user_cancel_is_idle_not_error(self):
        self.config()
        self.database()
        self.transcript()
        for reason in ('CANCELLED', 'cancelled by user', 'Aborted'):
            self.hooks('Stop', age=5, termination=reason)
            snap = self.snapshot()['session']
            self.assertEqual((snap['state'], snap['code']), ('idle', 'user_cancelled'), reason)
            snapshot = self.snapshot()
            self.assertFalse(snapshot['live']['active'])
        self.hooks('Stop', age=5, termination='CANCELLED')
        self.assertIn('不是错误', self.snapshot()['session']['detail'])

    def test_real_termination_error_is_surfaced(self):
        self.database()
        self.transcript()
        self.hooks('Stop', age=5, termination='MODEL_ERROR: upstream 503')
        snap = self.snapshot()['session']
        self.assertEqual((snap['state'], snap['code']), ('error', 'terminated_error'))
        self.assertIn('MODEL_ERROR', snap['detail'])

    def test_long_multibyte_reason_is_truncated_safely(self):
        """A truncated UTF-8 sequence would break the whole JSON payload."""
        self.database()
        self.transcript()
        self.hooks('Stop', age=3, termination='执行失败：上游服务不可用，请稍后重试。' * 8)
        snap = self.snapshot()['session']
        self.assertEqual(snap['code'], 'terminated_error')
        self.assertLess(len(snap['detail']), 200)
        self.assertIn('执行失败', snap['detail'])

    def test_stop_chip_expires_after_ttl(self):
        self.database()
        self.transcript()
        self.hooks('Stop', age=600, termination='MODEL_ERROR')
        snap = self.snapshot()['session']
        self.assertEqual((snap['state'], snap['code']), ('idle', 'idle'))

    def test_post_invocation_without_next_step_reads_as_tool_work(self):
        self.database()
        self.transcript()
        self.hooks('PostInvocation', age=20)
        snap = self.snapshot()['session']
        self.assertEqual((snap['state'], snap['code']), ('running', 'tool_step'))
        self.hooks('PostInvocation', age=400)
        self.assertEqual(self.snapshot()['session']['code'], 'idle')

    def test_missing_hooks_says_so_instead_of_pretending(self):
        self.database()
        self.transcript()
        snap = self.snapshot()['session']
        self.assertEqual((snap['state'], snap['code']), ('idle', 'hook_missing'))
        self.assertIn('Hook', snap['detail'])

    def test_stalled_stream_is_reported_then_recovers(self):
        self.config(thresholds={'stallSec': 1})
        self.database()
        self.live_step('你好')
        self.transcript()
        self.hooks('PreInvocation', age=2)
        proc = self.worker()
        first = self.query(proc)['session']
        self.assertEqual((first['state'], first['code']), ('running', 'streaming'))
        time.sleep(1.4)
        stalled = self.query(proc)['session']
        self.assertEqual((stalled['state'], stalled['code']), ('waiting', 'stalled'))
        self.assertGreaterEqual(stalled['waitSec'], 1)
        self.live_step('你好，世界，继续输出')
        recovered = self.query(proc)['session']
        self.assertEqual((recovered['state'], recovered['code']), ('running', 'streaming'))
        self.assertLess(recovered['waitSec'], 1)

    def test_debug_evidence_is_opt_in(self):
        self.database()
        self.transcript()
        self.hooks('PreInvocation', age=3)
        self.assertNotIn('evidence', self.snapshot()['session'])
        self.config(debug=True)
        evidence = self.snapshot()['session']['evidence']
        self.assertEqual(evidence['hookEvent'], 'PreInvocation')
        self.assertFalse(evidence['liveStep'])

    # ----------------------------------------------------------------- settings
    def test_defaults_apply_without_a_config_file(self):
        self.database()
        self.transcript()
        self.hooks()
        config = self.snapshot()['config']
        self.assertTrue(config['enabled'])
        self.assertEqual(config['layout'], 'compact')
        self.assertEqual(config['lowSpeedWarnTokS'], 50)
        self.assertEqual(config['modules'], {
            'session': True, 'quota': True, 'history': True, 'models': True, 'context': True,
        })

    def test_settings_are_clamped_and_modules_take_effect(self):
        self.database()
        self.transcript()
        self.hooks()
        self.config(layout='detailed', pollSec=999, lowSpeedWarnTokS=10 ** 9,
                    modules={'models': False, 'history': False, 'session': False})
        snap = self.snapshot()
        self.assertEqual(snap['config']['pollSec'], 60)
        self.assertEqual(snap['config']['layout'], 'detailed')
        self.assertEqual(snap['config']['lowSpeedWarnTokS'], 10000)
        self.assertNotIn('session', snap)
        self.assertEqual(snap['modelUsage'], [])
        self.assertEqual(snap['history'], [])

    def test_disabled_panel_returns_a_quiet_payload(self):
        self.database()
        self.transcript()
        self.hooks()
        self.config(enabled=False)
        snap = self.snapshot()
        self.assertTrue(snap['disabled'])
        self.assertFalse(snap['found'])
        self.assertFalse(snap['config']['enabled'])
        self.assertNotIn('session', snap)
        self.assertIn('enabled', snap['message'])

    def test_config_reloads_without_restarting_the_sidecar(self):
        self.database()
        self.transcript([
            {'type': 'USER_INPUT', 'created_at': iso(30)},
            {'type': 'PLANNER_RESPONSE', 'status': 'DONE', 'created_at': iso(20),
             'model': 'gemini-demo', 'input_tokens': 100, 'cache_read_tokens': 50, 'output_tokens': 20},
        ])
        self.hooks()
        self.config(modules={'models': False})
        proc = self.worker()
        self.assertEqual(self.query(proc)['modelUsage'], [])
        self.config(modules={'models': True}, lowSpeedWarnTokS=42)
        reloaded = self.query(proc)
        self.assertEqual(len(reloaded['modelUsage']), 1)
        self.assertEqual(reloaded['config']['lowSpeedWarnTokS'], 42)

    def test_quota_module_switch_skips_quota_reads(self):
        self.database()
        self.transcript()
        self.hooks()
        now = int(time.time())
        (self.root / 'quota.json').write_text(json.dumps({
            'source': 'agy-statusline', 'observed_at': now - 30,
            'buckets': [{'key': 'gemini-5h', 'remaining_fraction': .5, 'reset_at': now + 3600}],
        }))
        self.assertIsNotNone(self.snapshot()['quota'])
        self.config(modules={'quota': False})
        self.assertIsNone(self.snapshot()['quota'])


if __name__ == '__main__':
    unittest.main()
