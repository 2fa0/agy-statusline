"""Data-source visibility: "no data" must never look like "could not read".

Every number in the panel comes from the conversation database, the transcript
log, the hook state file or the quota snapshot. When one of them is unavailable
the panel still renders — which is exactly why it has to say so.
"""
import sqlite3
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_session import PanelFixture


class SourceTests(PanelFixture):
    def sources(self):
        return self.snapshot()['sources']

    def test_healthy_conversation_lists_every_source(self):
        self.database()
        self.transcript()
        self.hooks()
        sources = self.sources()
        self.assertFalse(sources['degraded'])
        self.assertEqual(sources['notes'], [])
        self.assertEqual(sources['db'], 'ok')
        self.assertEqual(sources['transcript'], 'ok')
        self.assertEqual(sources['hooks'], 'ok')

    def test_new_conversation_is_not_degraded(self):
        """No rows yet is normal; it must not raise a warning."""
        self.database()
        self.hooks()
        sources = self.sources()
        self.assertFalse(sources['degraded'])
        self.assertEqual(sources['transcript'], 'missing')
        self.assertIn(sources['db'], ('empty', 'ok'))

    def test_locked_database_is_explained_instead_of_looking_empty(self):
        self.database()
        self.transcript()
        self.hooks()
        blocker = sqlite3.connect(self.db_path)
        blocker.execute('BEGIN EXCLUSIVE')
        try:
            sources = self.sources()
        finally:
            blocker.rollback()
            blocker.close()
        self.assertTrue(sources['degraded'])
        self.assertEqual(sources['db'], 'locked')
        self.assertEqual([n['code'] for n in sources['notes']], ['db_locked'])
        note = sources['notes'][0]
        self.assertEqual(note['label'], '数据库被占用')
        self.assertIn('重试', note['text'])

    def test_missing_database_with_a_transcript_is_reported(self):
        self.transcript()
        self.hooks()
        sources = self.sources()
        self.assertEqual(sources['db'], 'missing')
        self.assertEqual(sources['transcript'], 'ok')
        self.assertIn('db_missing', [n['code'] for n in sources['notes']])

    def test_unreadable_transcript_is_reported(self):
        self.database()
        self.hooks()
        # A directory where the log should be: exists, but cannot be parsed.
        self.log.mkdir(parents=True)
        sources = self.sources()
        self.assertEqual(sources['transcript'], 'error')
        self.assertIn('transcript_error', [n['code'] for n in sources['notes']])
        self.assertTrue(sources['degraded'])

    def test_absent_quota_is_reported_but_does_not_warn(self):
        """The CLI not having run yet is not a panel problem."""
        self.database()
        self.transcript()
        self.hooks()
        sources = self.sources()
        self.assertEqual(sources['quota'], 'missing')
        self.assertFalse(sources['degraded'])

    def test_quota_staleness_is_visible(self):
        import json
        import time
        self.database()
        self.transcript()
        self.hooks()
        (self.root / 'quota.json').write_text(json.dumps({
            'source': 'agy-statusline', 'observed_at': int(time.time()) - 7 * 86400,
            'buckets': [{'key': 'gemini-5h', 'remaining_fraction': .5, 'reset_at': int(time.time()) + 3600}],
        }))
        self.assertEqual(self.sources()['quota'], 'stale')

    def test_disabled_quota_module_reports_disabled(self):
        self.database()
        self.transcript()
        self.hooks()
        self.config(modules={'quota': False})
        self.assertEqual(self.sources()['quota'], 'disabled')

    def test_missing_hooks_are_visible(self):
        self.database()
        self.transcript()
        self.assertEqual(self.sources()['hooks'], 'missing')


if __name__ == '__main__':
    unittest.main()
