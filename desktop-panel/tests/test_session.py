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
sys.path.insert(0, str(PANEL / 'tests'))
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
            # Without this every status/hook call would launch a real macOS notch
            # bound to this throwaway data dir, and it would outlive the test.
            AGY_NO_NOTCH='1',
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

    def test_stop_suppresses_stale_live_step_and_zero_chars_is_preparing(self):
        self.database()
        self.live_step('你好')
        self.transcript()
        for reason in ('CANCELLED', 'MODEL_ERROR', ''):
            self.hooks('Stop', age=2, termination=reason)
            snap = self.snapshot()
            self.assertFalse(snap['live']['active'], reason)
            self.assertNotEqual(snap['session']['code'], 'streaming', reason)

        # An active step before the first streamed character is preparing/waiting, not streaming.
        self.live_step('')
        self.hooks('PreInvocation', age=3)
        snap = self.snapshot()
        self.assertFalse(snap['live']['active'])
        self.assertEqual((snap['session']['state'], snap['session']['code']), ('running', 'preparing'))

    def test_normal_termination_is_idle_not_error(self):
        self.database()
        self.transcript()
        for reason in ('NO_TOOL_CALL', 'end_turn', 'COMPLETED', 'done'):
            self.hooks('Stop', age=5, termination=reason)
            snap = self.snapshot()['session']
            self.assertEqual((snap['state'], snap['code']), ('idle', 'idle'), reason)

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


    def test_locked_database_does_not_claim_a_confirmed_first_token_wait(self):
        self.config(thresholds={'waitSec': 5})
        self.database()
        self.transcript()
        self.hooks('PreInvocation', age=30)
        blocker = sqlite3.connect(self.db_path)
        blocker.execute('BEGIN EXCLUSIVE')
        try:
            snap = self.snapshot()['session']
        finally:
            blocker.rollback()
            blocker.close()
        self.assertEqual((snap['state'], snap['code']), ('running', 'preparing'))
        self.assertNotIn('首字', snap['detail'])

    def test_older_stop_does_not_suppress_a_newer_step_without_preinvocation(self):
        self.config(thresholds={'stallSec': 30})
        self.database()
        self.transcript()
        self.hooks('PreInvocation', age=2)
        self.live_step('第一轮残留文本', idx=1)
        proc = self.worker()
        self.assertEqual(self.query(proc)['live']['stepIdx'], 1)
        # A Stop for that same step keeps suppressing the leftover row.
        self.hooks('Stop', age=30, termination='MODEL_ERROR')
        same_round = self.query(proc)
        self.assertFalse(same_round['live']['active'])
        self.assertEqual(same_round['session']['code'], 'terminated_error')
        # A new step starts without any PreInvocation event: the older Stop must
        # not paint a finished turn over a live one.
        self.live_step('新一轮正在输出', idx=2)
        newer = self.query(proc)
        self.assertTrue(newer['live']['active'])
        self.assertEqual(newer['live']['stepIdx'], 2)
        self.assertEqual(newer['session']['code'], 'streaming')
        self.assertNotEqual(newer['session']['code'], 'terminated_error')

    def test_finished_step_does_not_mask_a_still_growing_older_step(self):
        self.config(thresholds={'stallSec': 1})
        self.database()
        self.transcript()
        self.hooks('PreInvocation', age=2)
        self.db.execute('CREATE TABLE steps(idx INTEGER PRIMARY KEY,status INTEGER,step_type INTEGER,step_payload BLOB,metadata BLOB)')
        self.db.execute('INSERT INTO steps VALUES(1,2,2,?,?)', (payload('你好'), blob(120, 2)))
        self.db.execute('INSERT INTO steps VALUES(2,3,1,?,?)', (payload('已完成'), blob(120, 2)))
        self.db.commit()
        proc = self.worker()
        growing = self.query(proc)
        self.assertTrue(growing['live']['active'])
        self.assertEqual(growing['live']['stepIdx'], 1)
        self.assertEqual(growing['session']['code'], 'streaming')
        # The same row stops growing: it is a leftover from an older round and
        # must not keep pretending to be a new stream.
        time.sleep(1.2)
        residue = self.query(proc)
        self.assertFalse(residue['live']['active'])
        self.assertNotEqual(residue['session']['code'], 'streaming')
        # Real growth brings it back.
        self.db.execute('UPDATE steps SET step_payload=? WHERE idx=1', (payload('你好，世界，继续'),))
        self.db.commit()
        revived = self.query(proc)
        self.assertTrue(revived['live']['active'])
        self.assertEqual(revived['session']['code'], 'streaming')


    def test_behind_step_recovers_when_its_text_grows_again(self):
        self.config(thresholds={'stallSec': 1})
        self.database()
        self.transcript()
        self.hooks('PreInvocation', age=2)
        self.db.execute('CREATE TABLE steps(idx INTEGER PRIMARY KEY,status INTEGER,step_type INTEGER,step_payload BLOB,metadata BLOB)')
        self.db.execute('INSERT INTO steps VALUES(3,8,1,?,NULL)', (payload('活跃的中段'),))
        self.db.execute('INSERT INTO steps VALUES(4,3,2,NULL,NULL)', ())
        self.db.commit()
        proc = self.worker()
        self.assertTrue(self.query(proc)['live']['active'])
        # Long enough to look like leftovers; the row is behind a finished step.
        time.sleep(1.2)
        self.assertFalse(self.query(proc)['live']['active'])
        # New text proves it is a live stream again, not residue.
        self.db.execute('UPDATE steps SET step_payload=? WHERE idx=3', (payload('活跃的中段，继续输出'),))
        self.db.commit()
        revived = self.query(proc)
        self.assertTrue(revived['live']['active'])
        self.assertEqual(revived['live']['stepIdx'], 3)
        self.assertEqual(revived['session']['code'], 'streaming')

    def test_stop_verdict_outlives_the_badge_ttl(self):
        # The chip may expire after stop_ttl_sec, but an unchanged active row
        # must not reappear as a live stream just because the badge timed out.
        self.database()
        self.transcript([{'type': 'USER_INPUT', 'created_at': iso(600)}])
        self.live_step('残留的最终文本', idx=1, status=8)
        old = time.time() - 300
        os.utime(self.db_path, (old, old))
        self.hooks('Stop', age=250)
        snap = self.snapshot()
        self.assertFalse(snap['live']['active'])
        self.assertNotEqual(snap['session']['code'], 'streaming')
        self.assertNotEqual(snap['session']['code'], 'terminated_error')


    def test_stop_still_applies_when_a_completed_step_is_newer(self):
        # The finished step above the stream ended before the Stop; it must not
        # be mistaken for a new round and resurrect the stream.
        self.config(thresholds={'stallSec': 30})
        self.database()
        self.transcript()
        self.hooks('PreInvocation', age=2)
        self.db.execute('CREATE TABLE steps(idx INTEGER PRIMARY KEY,status INTEGER,step_type INTEGER,step_payload BLOB,metadata BLOB)')
        self.db.execute('INSERT INTO steps VALUES(3,8,1,?,NULL)', (payload('活跃的中段'),))
        self.db.execute('INSERT INTO steps VALUES(4,3,2,NULL,NULL)', ())
        self.db.commit()
        proc = self.worker()
        self.assertTrue(self.query(proc)['live']['active'])
        self.hooks('Stop', age=1, termination='USER_CANCELLED')
        stopped = self.query(proc)
        self.assertFalse(stopped['live']['active'])
        self.assertEqual(stopped['session']['code'], 'user_cancelled')


    def test_residual_write_after_stop_does_not_resume_the_stream(self):
        # A finished step sits above the streaming one; the final flush after the
        # Stop must be read as that same step ending, not as a new round.
        self.config(thresholds={'stallSec': 30})
        self.database()
        self.transcript()
        self.hooks('PreInvocation', age=2)
        self.db.execute('CREATE TABLE steps(idx INTEGER PRIMARY KEY,status INTEGER,step_type INTEGER,step_payload BLOB,metadata BLOB)')
        self.db.execute('INSERT INTO steps VALUES(3,8,1,?,NULL)', (payload('流式中段'),))
        self.db.execute('INSERT INTO steps VALUES(4,3,2,NULL,NULL)', ())
        self.db.commit()
        proc = self.worker()
        self.assertTrue(self.query(proc)['live']['active'])
        self.db.execute('UPDATE steps SET step_payload=? WHERE idx=3', (payload('流式中段，继续'),))
        self.db.commit()
        self.assertTrue(self.query(proc)['live']['active'])
        self.hooks('Stop', age=0, termination='USER_CANCELLED')
        self.db.execute('UPDATE steps SET step_payload=? WHERE idx=3', (payload('流式中段，继续，收尾写入'),))
        self.db.commit()
        stopped = self.query(proc)
        self.assertFalse(stopped['live']['active'])
        self.assertEqual(stopped['session']['code'], 'user_cancelled')

    def test_fresh_panel_reads_a_stop_with_a_finished_step_above_as_current(self):
        self.database()
        self.transcript()
        self.db.execute('CREATE TABLE steps(idx INTEGER PRIMARY KEY,status INTEGER,step_type INTEGER,step_payload BLOB,metadata BLOB)')
        self.db.execute('INSERT INTO steps VALUES(3,8,1,?,NULL)', (payload('已停止前的流式文本'),))
        self.db.execute('INSERT INTO steps VALUES(4,3,2,NULL,NULL)', ())
        self.db.commit()
        self.hooks('Stop', age=1, termination='USER_CANCELLED')
        snap = self.snapshot()
        self.assertFalse(snap['live']['active'])
        self.assertEqual(snap['session']['code'], 'user_cancelled')


    def test_stop_explanation_survives_a_database_write_with_no_live_step(self):
        # A generation row written after the Stop (same round) must not erase the
        # reason while nothing is live: the mtime fallback is only for deciding
        # whether a *live* row is a new round.
        self.database()
        self.transcript()
        for termination, code in (('CANCELLED', 'user_cancelled'), ('MODEL_ERROR', 'terminated_error')):
            self.hooks('Stop', age=5, termination=termination)
            os.utime(self.db_path, None)
            snap = self.snapshot()
            self.assertEqual(snap['session']['code'], code, termination)
            self.assertFalse(snap['live']['active'])


    def test_cold_start_residue_survives_a_database_write_after_the_stop(self):
        # A WAL checkpoint or final flush can bump the file mtime long after the
        # Stop; a cold start must still read the leftover row as finished.
        self.database()
        self.transcript([{'type': 'USER_INPUT', 'created_at': iso(600)}])
        self.hooks('Stop', age=5, termination='USER_CANCELLED')
        self.live_step('残留文本', idx=1, status=8)
        os.utime(self.db_path, None)
        snap = self.snapshot()
        self.assertFalse(snap['live']['active'])
        self.assertEqual(snap['session']['code'], 'user_cancelled')

        self.hooks('Stop', age=250, termination='USER_CANCELLED')
        os.utime(self.db_path, None)
        self.assertFalse(self.snapshot()['live']['active'])

    def test_late_flush_after_a_cold_start_stays_hidden(self):
        # The panel starts a couple of seconds after the Stop; AGY writes its
        # final flush afterwards. That is text growth without a user turn, so it
        # must not be sold as a new stream.
        self.config(thresholds={'stallSec': 30})
        self.database()
        self.transcript([{'type': 'USER_INPUT', 'created_at': iso(600)}])
        self.live_step('残留文本', idx=1, status=8)
        self.hooks('Stop', age=3, termination='USER_CANCELLED')
        proc = self.worker()
        self.assertFalse(self.query(proc)['live']['active'])
        self.db.execute('UPDATE steps SET step_payload=? WHERE idx=1', (payload('残留文本，收尾写入'),))
        self.db.commit()
        after = self.query(proc)
        self.assertFalse(after['live']['active'])
        self.assertNotEqual(after['session']['code'], 'streaming')

    def test_cold_start_stop_yields_to_a_new_user_turn(self):
        # A user turn logged after the Stop is the one thing that proves a new
        # round began when the step history is unknown.
        self.config(thresholds={'stallSec': 30})
        self.database()
        self.transcript([{'type': 'USER_INPUT', 'created_at': iso(1)}])
        self.live_step('新回合的第一段', idx=1, status=8)
        self.hooks('Stop', age=5, termination='USER_CANCELLED')
        snap = self.snapshot()
        self.assertTrue(snap['live']['active'])
        self.assertEqual(snap['session']['code'], 'streaming')

    def test_cold_start_without_a_log_yields_to_observed_growth(self):
        # No transcript to consult: only text that grows after the panel starts
        # watching can prove the row is a stream, and residue never grows.
        self.config(thresholds={'stallSec': 30})
        self.database()
        self.live_step('第一段文本', idx=1, status=8)
        self.hooks('Stop', age=5, termination='USER_CANCELLED')
        proc = self.worker()
        self.assertFalse(self.query(proc)['live']['active'])
        self.db.execute('UPDATE steps SET step_payload=? WHERE idx=1', (payload('第一段文本，后来继续输出了一大段'),))
        self.db.commit()
        resumed = self.query(proc)
        self.assertTrue(resumed['live']['active'])
        self.assertEqual(resumed['session']['code'], 'streaming')


    def test_cold_start_new_step_is_not_held_back_by_the_stopped_row_length(self):
        # The stopped row is long; a brand-new (shorter) active row must be read
        # as a new stream immediately, because a different row cannot be the one
        # the Stop ended. The baseline remembers which row it belongs to.
        self.config(thresholds={'stallSec': 30})
        self.database()
        self.transcript([{'type': 'USER_INPUT', 'created_at': iso(600)}])
        self.live_step('残' * 3000, idx=1, status=8)
        self.hooks('Stop', age=5, termination='USER_CANCELLED')
        proc = self.worker()
        self.assertFalse(self.query(proc)['live']['active'])
        self.db.execute('INSERT INTO steps VALUES(2,2,1,?,?)', (payload('新款回复'), blob(120, 2)))
        self.db.commit()
        resumed = self.query(proc)
        self.assertTrue(resumed['live']['active'])
        self.assertEqual(resumed['live']['stepIdx'], 2)
        self.assertEqual(resumed['session']['code'], 'streaming')


if __name__ == '__main__':
    unittest.main()
