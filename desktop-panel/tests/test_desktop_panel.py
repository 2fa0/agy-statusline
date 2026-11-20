import io
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

PANEL_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PANEL_DIR))

from telemetry import (  # noqa: E402
    build_status_snapshot,
    decode_proto_fields,
    infer_context_window_size,
    parse_gen_metadata_blob,
    parse_transcript_timing,
)


def encode_varint(n: int) -> bytes:
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


def field_varint(num: int, val: int) -> bytes:
    return encode_varint((num << 3) | 0) + encode_varint(val)


def field_bytes(num: int, payload: bytes) -> bytes:
    return encode_varint((num << 3) | 2) + encode_varint(len(payload)) + payload


class DesktopPanelTests(unittest.TestCase):
    def test_gen_metadata_speed_and_model(self) -> None:
        # Matches main.zig test fixture + served model field 19
        usage = field_varint(3, 100)
        dur12 = field_varint(1, 2)
        chat = (
            field_bytes(4, usage)
            + field_bytes(12, dur12)
            + field_bytes(19, b"gemini-4-hydrogen")
        )
        blob = field_bytes(1, chat)
        rec = parse_gen_metadata_blob(7, blob)
        self.assertIsNotNone(rec)
        assert rec is not None
        self.assertEqual(rec.idx, 7)
        self.assertEqual(rec.output_tokens, 100)
        self.assertAlmostEqual(rec.speed_tok_s or 0.0, 50.0, places=3)
        self.assertEqual(rec.served_model, "gemini-4-hydrogen")

    def test_gen_metadata_falls_back_to_field_11_when_field_12_is_subsecond_ttfb(self) -> None:
        # When field 12 is ~0.05s (TTFB) and field 11 is 5.0s total duration
        usage = field_varint(3, 200)
        dur11 = field_varint(1, 5)
        dur12 = field_varint(2, 50_000_000)  # 0.05s
        chat = field_bytes(4, usage) + field_bytes(11, dur11) + field_bytes(12, dur12)
        rec = parse_gen_metadata_blob(8, field_bytes(1, chat))
        assert rec is not None
        self.assertAlmostEqual(rec.speed_tok_s or 0.0, 40.0, places=2)

    def test_decode_proto_fields_ignores_truncated_tail(self) -> None:
        fields = decode_proto_fields(b"\x08\x2a\x12\xff")
        self.assertEqual(fields.get(1), [42])

    def test_infer_context_window(self) -> None:
        self.assertEqual(infer_context_window_size("Gemini 4 Hydrogen"), 1_048_576)
        self.assertEqual(infer_context_window_size("claude-sonnet-4"), 200_000)
        self.assertIsNone(infer_context_window_size("unknown-model"))

    def test_transcript_timing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tpath = Path(tmp) / "transcript.jsonl"
            lines = [
                {
                    "step_index": 0,
                    "type": "USER_INPUT",
                    "source": "USER_EXPLICIT",
                    "created_at": "2026-11-19T07:00:00Z",
                    "content": "hello",
                },
                {
                    "step_index": 1,
                    "type": "PLANNER_RESPONSE",
                    "source": "MODEL",
                    "created_at": "2026-11-19T07:00:12Z",
                },
                {
                    "step_index": 2,
                    "type": "USER_INPUT",
                    "source": "USER_EXPLICIT",
                    "created_at": "2026-11-19T07:01:00Z",
                    "content": "second turn",
                },
                {
                    "step_index": 3,
                    "type": "PLANNER_RESPONSE",
                    "source": "MODEL",
                    "created_at": "2026-11-19T07:01:05Z",
                },
            ]
            tpath.write_text("\n".join(json.dumps(x) for x in lines), encoding="utf-8")
            timing = parse_transcript_timing(tpath)
            self.assertEqual(timing["turnCount"], 2)
            self.assertEqual(timing["stepCount"], 4)
            self.assertAlmostEqual(timing["sessionDurationSec"], 65.0, places=2)
            self.assertAlmostEqual(timing["turnDurationSec"], 5.0, places=2)

    def test_build_snapshot_with_steps_cache_and_hook(self) -> None:
        cid = "11111111-2222-3333-4444-555555555555"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "desktop"
            data_dir = Path(tmp) / "plugin_data"
            (root / "conversations").mkdir(parents=True)
            tpath = root / "brain" / cid / ".system_generated" / "logs" / "transcript.jsonl"
            tpath.parent.mkdir(parents=True)
            tpath.write_text(
                "\n".join(
                    [
                        json.dumps(
                            {
                                "type": "USER_INPUT",
                                "created_at": "2026-11-19T07:00:00Z",
                                "content": "hi",
                            }
                        ),
                        json.dumps(
                            {
                                "type": "PLANNER_RESPONSE",
                                "created_at": "2026-11-19T07:00:08Z",
                            }
                        ),
                    ]
                ),
                encoding="utf-8",
            )

            db_path = root / "conversations" / f"{cid}.db"
            conn = sqlite3.connect(str(db_path))
            conn.execute("CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB)")
            conn.execute("CREATE TABLE steps (idx INTEGER PRIMARY KEY, metadata BLOB)")
            # output=80 in 2.0s => 40 tok/s (triggers lowSpeedWarning < 50)
            gen_blob = field_bytes(
                1,
                field_bytes(4, field_varint(3, 80))
                + field_bytes(12, field_varint(1, 2))
                + field_bytes(19, b"gemini-4-hydrogen"),
            )
            conn.execute("INSERT INTO gen_metadata VALUES (1, ?)", (gen_blob,))
            # steps.metadata field 9: input=200, output=80, cache_write=0, cache_read=800
            step_usage = (
                field_varint(2, 200)
                + field_varint(3, 80)
                + field_varint(4, 0)
                + field_varint(5, 800)
            )
            conn.execute("INSERT INTO steps VALUES (1, ?)", (field_bytes(9, step_usage),))
            conn.commit()
            conn.close()

            # Simulate hook execution writing active_session.json
            hook_proc = subprocess.run(
                [sys.executable, str(PANEL_DIR / "hooks" / "track_active.py")],
                input=json.dumps(
                    {
                        "conversationId": cid,
                        "modelName": "Gemini 4 Hydrogen",
                        "transcriptPath": str(tpath),
                        "cwd": "/tmp/demo-repo",
                        "hookEventName": "Stop",
                    }
                ),
                text=True,
                capture_output=True,
                env={**os.environ, "PLUGIN_DATA": str(data_dir)},
                check=True,
            )
            self.assertEqual(json.loads(hook_proc.stdout), {"decision": "allow"})

            snap = build_status_snapshot(data_dir=data_dir, desktop_root=root)
            self.assertTrue(snap["found"])
            self.assertTrue(snap["hookConnected"])
            self.assertEqual(snap["conversationId"], cid)
            self.assertAlmostEqual(snap["lastAvgSpeed"], 40.0, places=1)
            self.assertTrue(snap["lowSpeedWarning"])
            self.assertAlmostEqual(snap["turnDurationSec"], 8.0, places=1)
            self.assertAlmostEqual(snap["sessionDurationSec"], 8.0, places=1)
            self.assertEqual(snap["contextUsed"], 1000)
            self.assertEqual(snap["contextTotal"], 1_048_576)
            self.assertAlmostEqual(snap["cacheHitPct"], 80.0, places=1)
            self.assertEqual(snap["cacheReadTokens"], 800)

    def test_dist_html_bundle_is_valid_single_document(self) -> None:
        html_path = PANEL_DIR / "dist" / "index.html"
        self.assertTrue(html_path.is_file())
        text = html_path.read_text(encoding="utf-8")
        self.assertIn("<script>", text)
        self.assertEqual(text.count("<!DOCTYPE html>"), 1)
        self.assertEqual(text.count("</head>"), 1)
        self.assertFalse((PANEL_DIR / "mcp_config.json").exists())
        self.assertFalse((PANEL_DIR / "server.py").exists())

    def test_sidecar_manifest_and_telemetry_cli(self) -> None:
        sidecar_cfg_path = PANEL_DIR / "sidecars" / "status" / "sidecar.json"
        self.assertTrue(sidecar_cfg_path.is_file())
        cfg = json.loads(sidecar_cfg_path.read_text(encoding="utf-8"))
        self.assertTrue(cfg.get("has_web_ui"))
        self.assertEqual(cfg.get("restart_policy"), "always")
        views = cfg.get("ui_config", {}).get("views", [])
        self.assertEqual(len(views), 1)
        self.assertEqual(views[0].get("entrypoint"), "SIDECAR_UI_ENTRYPOINT_AUX_PANE")
        self.assertEqual(views[0].get("path"), "/")

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "antigravity"
            data_dir = root / "plugin_data" / "agy-desktop-status"
            (root / "conversations").mkdir(parents=True)
            proc = subprocess.run(
                [
                    sys.executable,
                    str(PANEL_DIR / "telemetry.py"),
                    "--conversation-id",
                    "auto",
                    "--data-dir",
                    str(data_dir),
                    "--desktop-root",
                    str(root),
                ],
                text=True,
                capture_output=True,
                check=True,
            )
            payload = json.loads(proc.stdout)
            self.assertFalse(payload["found"])
            self.assertEqual(payload["conversationId"], "")

    # ------------------------------------------------------------------ #
    # Incremental parsing / warm-runtime caching / JSON-lines serve mode
    # ------------------------------------------------------------------ #

    def _write_transcript(self, path: Path, rows: list[dict[str, object]]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8")

    def test_incremental_tracker_matches_full_parse(self) -> None:
        from telemetry import TranscriptTracker

        rows = [
            {"type": "USER_INPUT", "source": "USER_EXPLICIT", "created_at": "2026-11-19T07:00:00Z", "content": "first"},
            {"type": "PLANNER_RESPONSE", "source": "MODEL", "created_at": "2026-11-19T07:00:30Z"},
        ]
        with tempfile.TemporaryDirectory() as tmp:
            tpath = Path(tmp) / "transcript.jsonl"
            self._write_transcript(tpath, rows)
            tracker = TranscriptTracker(tpath)
            first = tracker.update()
            self.assertEqual(first, parse_transcript_timing(tpath))

            # Append a new turn, half-written line first to prove partial lines are held.
            extra = json.dumps(
                {"type": "USER_INPUT", "source": "USER_EXPLICIT", "created_at": "2026-11-19T07:01:00Z", "content": "second"}
            )
            with tpath.open("a", encoding="utf-8") as fh:
                fh.write(extra[:20])
            partial = tracker.update()
            self.assertEqual(partial, first)
            with tpath.open("a", encoding="utf-8") as fh:
                fh.write(extra[20:] + "\n" + json.dumps(
                    {"type": "PLANNER_RESPONSE", "created_at": "2026-11-19T07:01:09Z"}
                ) + "\n")
            increment = tracker.update()
            # Full re-parse must agree with the incremental aggregate.
            self.assertEqual(increment, parse_transcript_timing(tpath))
            self.assertEqual(increment["turnCount"], 2)
            self.assertEqual(increment["stepCount"], 4)
            self.assertAlmostEqual(increment["turnDurationSec"], 9.0, places=2)

            # Truncation resets cleanly instead of returning stale aggregates.
            self._write_transcript(tpath, rows[:1])
            after_reset = tracker.update()
            self.assertEqual(after_reset, parse_transcript_timing(tpath))
            self.assertEqual(after_reset["stepCount"], 1)

    def test_runtime_cache_hits_and_invalidates(self) -> None:
        from telemetry import TelemetryRuntime

        cid = "99999999-8888-7777-6666-555555555555"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "desktop"
            data_dir = Path(tmp) / "plugin_data"
            (root / "conversations").mkdir(parents=True)
            tpath = root / "brain" / cid / ".system_generated" / "logs" / "transcript.jsonl"
            self._write_transcript(tpath, [{"type": "PLANNER_RESPONSE", "created_at": "2026-11-19T07:00:00Z"}])
            db_path = root / "conversations" / f"{cid}.db"
            conn = sqlite3.connect(str(db_path))
            conn.execute("CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB)")
            conn.execute(
                "INSERT INTO gen_metadata VALUES (1, ?)",
                (field_bytes(1, field_bytes(4, field_varint(3, 40)) + field_bytes(12, field_varint(1, 2))),),
            )
            conn.commit()
            conn.close()
            (data_dir).mkdir(parents=True, exist_ok=True)
            (data_dir / "active_session.json").write_text(
                json.dumps({"activeConversationId": cid, "sessions": {cid: {"transcriptPath": str(tpath)}}}),
                encoding="utf-8",
            )

            runtime = TelemetryRuntime()
            try:
                cold = build_status_snapshot(data_dir=data_dir, desktop_root=root, runtime=runtime)
                self.assertFalse(cold.get("cacheHit", False))
                self.assertAlmostEqual(cold["turnDurationSec"] or 0.0, 0.0, places=2)

                warm = build_status_snapshot(data_dir=data_dir, desktop_root=root, runtime=runtime)
                self.assertTrue(warm["cacheHit"])
                self.assertEqual(warm["conversationId"], cold["conversationId"])
                self.assertEqual(warm["stepCount"], cold["stepCount"])

                # Appending to the transcript must invalidate the cache and update timing.
                with tpath.open("a", encoding="utf-8") as fh:
                    fh.write(json.dumps({"type": "PLANNER_RESPONSE", "created_at": "2026-11-19T07:00:05Z"}) + "\n")
                fresh = build_status_snapshot(data_dir=data_dir, desktop_root=root, runtime=runtime)
                self.assertFalse(fresh.get("cacheHit", False))
                self.assertAlmostEqual(fresh["sessionDurationSec"], 5.0, places=2)
                self.assertEqual(fresh["stepCount"], 2)
            finally:
                runtime.close()

    def test_cached_snapshot_refreshes_recent_conversations(self) -> None:
        from telemetry import TelemetryRuntime

        cid = "11111111-1111-1111-1111-111111111111"
        other = "22222222-2222-2222-2222-222222222222"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            conv_dir = root / "conversations"
            conv_dir.mkdir()
            conn = sqlite3.connect(conv_dir / f"{cid}.db")
            conn.execute("CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB)")
            conn.close()
            runtime = TelemetryRuntime()
            try:
                build_status_snapshot(cid, desktop_root=root, runtime=runtime)
                other_path = conv_dir / f"{other}.db"
                conn = sqlite3.connect(other_path)
                conn.execute("CREATE TABLE steps (idx INTEGER PRIMARY KEY, data BLOB)")
                conn.close()
                for expected in (2, 1):
                    warm = build_status_snapshot(cid, desktop_root=root, runtime=runtime)
                    fresh = build_status_snapshot(cid, desktop_root=root)
                    self.assertTrue(warm["cacheHit"])
                    self.assertEqual(warm["recentConversations"], fresh["recentConversations"])
                    self.assertEqual(len(warm["recentConversations"]), expected)
                    other_path.unlink(missing_ok=True)
            finally:
                runtime.close()

    def test_runtime_retries_after_temporary_database_lock(self) -> None:
        from telemetry import TelemetryRuntime

        cid = "11111111-1111-1111-1111-111111111111"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "conversations").mkdir()
            db_path = root / "conversations" / f"{cid}.db"
            writer = sqlite3.connect(db_path)
            writer.execute("CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB)")
            blob = field_bytes(1, field_bytes(4, field_varint(3, 100)) + field_bytes(12, field_varint(1, 2)))
            writer.execute("INSERT INTO gen_metadata VALUES (1, ?)", (blob,))
            writer.commit()
            runtime = TelemetryRuntime()
            try:
                cold = build_status_snapshot(cid, desktop_root=root, runtime=runtime)
                self.assertEqual(cold["lastAvgSpeed"], 50.0)
                # A transcript append invalidates the snapshot before SQLite is locked.
                tpath = root / "brain" / cid / ".system_generated" / "logs" / "transcript.jsonl"
                self._write_transcript(tpath, [{"type": "USER_INPUT", "content": "next"}])
                writer.execute("BEGIN EXCLUSIVE")
                blocked = build_status_snapshot(cid, desktop_root=root, runtime=runtime)
                self.assertIsNone(blocked["lastAvgSpeed"])
                writer.rollback()
                recovered = build_status_snapshot(cid, desktop_root=root, runtime=runtime)
                self.assertEqual(recovered["lastAvgSpeed"], 50.0)
                warm = build_status_snapshot(cid, desktop_root=root, runtime=runtime)
                self.assertTrue(warm["cacheHit"])
            finally:
                writer.close()
                runtime.close()

    def test_runtime_refreshes_schema_when_tables_are_added(self) -> None:
        from telemetry import TelemetryRuntime

        cid = "11111111-1111-1111-1111-111111111111"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "conversations").mkdir()
            writer = sqlite3.connect(root / "conversations" / f"{cid}.db")
            runtime = TelemetryRuntime()
            try:
                build_status_snapshot(cid, desktop_root=root, runtime=runtime)
                writer.execute("CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB)")
                blob = field_bytes(1, field_bytes(4, field_varint(3, 100)) + field_bytes(12, field_varint(1, 2)))
                writer.execute("INSERT INTO gen_metadata VALUES (1, ?)", (blob,))
                writer.commit()
                snap = build_status_snapshot(cid, desktop_root=root, runtime=runtime)
                self.assertEqual(snap["lastAvgSpeed"], 50.0)

                writer.execute("CREATE TABLE steps (idx INTEGER PRIMARY KEY, metadata BLOB)")
                writer.execute("INSERT INTO steps VALUES (1, ?)", (field_bytes(9, field_varint(2, 200)),))
                writer.commit()
                snap = build_status_snapshot(cid, desktop_root=root, runtime=runtime)
                self.assertEqual(snap["usageSource"], "steps")
                self.assertEqual(snap["inputTokens"], 200)
            finally:
                writer.close()
                runtime.close()

    def test_runtime_reopens_database_when_file_is_replaced(self) -> None:
        from telemetry import TelemetryRuntime

        cid = "11111111-1111-1111-1111-111111111111"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "conversations").mkdir()
            db_path = root / "conversations" / f"{cid}.db"
            replacement = db_path.with_suffix(".next")
            for path, tokens in ((db_path, 40), (replacement, 200)):
                with sqlite3.connect(path) as writer:
                    writer.execute("CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB)")
                    blob = field_bytes(1, field_bytes(4, field_varint(3, tokens)))
                    writer.execute("INSERT INTO gen_metadata VALUES (1, ?)", (blob,))
                writer.close()

            runtime = TelemetryRuntime()
            try:
                snap = build_status_snapshot(cid, desktop_root=root, runtime=runtime)
                self.assertEqual(snap["outputTokens"], 40)
                old_conn = runtime.connection(db_path)[0]
                old_stat = db_path.stat()
                self.assertEqual(replacement.stat().st_size, old_stat.st_size)
                os.utime(replacement, ns=(old_stat.st_atime_ns, old_stat.st_mtime_ns))
                replacement.replace(db_path)

                snap = build_status_snapshot(cid, desktop_root=root, runtime=runtime)
                self.assertEqual(snap["outputTokens"], 200)
                with self.assertRaises(sqlite3.ProgrammingError):
                    old_conn.execute("SELECT 1")
                warm = build_status_snapshot(cid, desktop_root=root, runtime=runtime)
                self.assertTrue(warm["cacheHit"])
                self.assertEqual(warm["outputTokens"], 200)
            finally:
                runtime.close()

    def test_runtime_resets_transcript_when_file_is_replaced(self) -> None:
        from telemetry import TelemetryRuntime

        cid = "11111111-1111-1111-1111-111111111111"
        for extra in ([], [{"type": "PLANNER_RESPONSE", "created_at": "2026-11-20T07:00:10Z"}]):
            with self.subTest(larger=bool(extra)), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                tpath = root / "brain" / cid / ".system_generated" / "logs" / "transcript.jsonl"
                self._write_transcript(tpath, [{"type": "USER_INPUT", "content": "old", "created_at": "2026-11-19T07:00:00Z"}])
                runtime = TelemetryRuntime()
                try:
                    build_status_snapshot(cid, desktop_root=root, runtime=runtime)
                    old_stat = tpath.stat()
                    replacement = tpath.with_suffix(".next")
                    self._write_transcript(replacement, [{"type": "USER_INPUT", "content": "new", "created_at": "2026-11-20T07:00:00Z"}] + extra)
                    # Even preserving mtime and size must not hide a replacement.
                    os.utime(replacement, ns=(old_stat.st_atime_ns, old_stat.st_mtime_ns))
                    replacement.replace(tpath)
                    snap = build_status_snapshot(cid, desktop_root=root, runtime=runtime)
                    full = build_status_snapshot(cid, desktop_root=root)
                    self.assertEqual(snap["stepCount"], full["stepCount"])
                    self.assertEqual(snap["lastActivityAt"], full["lastActivityAt"])
                    self.assertEqual(runtime.transcript(tpath).update(), parse_transcript_timing(tpath))
                finally:
                    runtime.close()

    def test_runtime_retries_after_temporary_transcript_read_error(self) -> None:
        from telemetry import TelemetryRuntime

        cid = "11111111-1111-1111-1111-111111111111"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tpath = root / "brain" / cid / ".system_generated" / "logs" / "transcript.jsonl"
            rows = [{"type": "USER_INPUT", "created_at": "2026-11-20T07:00:00Z"}]
            self._write_transcript(tpath, rows)
            runtime = TelemetryRuntime()
            original_open = Path.open

            def temporarily_unreadable(path, *args, **kwargs):
                if path == tpath:
                    raise PermissionError("temporarily unreadable")
                return original_open(path, *args, **kwargs)

            try:
                build_status_snapshot(cid, desktop_root=root, runtime=runtime)
                rows.append({"type": "PLANNER_RESPONSE", "created_at": "2026-11-20T07:00:05Z"})
                self._write_transcript(tpath, rows)
                with patch.object(Path, "open", temporarily_unreadable):
                    blocked = build_status_snapshot(cid, desktop_root=root, runtime=runtime)
                self.assertIsNone(blocked["stepCount"])
                recovered = build_status_snapshot(cid, desktop_root=root, runtime=runtime)
                self.assertEqual(recovered["stepCount"], 2)
                self.assertEqual(recovered["sessionDurationSec"], 5.0)
            finally:
                runtime.close()

    def test_runtime_bounds_connections_and_transcript_trackers(self) -> None:
        from telemetry import TelemetryRuntime

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "conversations").mkdir()
            runtime = TelemetryRuntime(max_snapshots=2)
            first_conn = None
            try:
                for i in range(3):
                    cid = f"00000000-0000-0000-0000-{i:012d}"
                    db_path = root / "conversations" / f"{cid}.db"
                    conn = sqlite3.connect(db_path)
                    conn.execute("CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB)")
                    conn.close()
                    tpath = root / "brain" / cid / ".system_generated" / "logs" / "transcript.jsonl"
                    self._write_transcript(tpath, [{"type": "USER_INPUT", "content": str(i)}])
                    snap = build_status_snapshot(cid, desktop_root=root, runtime=runtime)
                    self.assertEqual(snap["stepCount"], 1)
                    if i == 0:
                        first_conn = runtime.connection(db_path)[0]
                self.assertEqual(len(runtime._snapshots), 2)
                self.assertEqual(len(runtime._dbs), 2)
                self.assertEqual(len(runtime._transcripts), 2)
                assert first_conn is not None
                with self.assertRaises(sqlite3.ProgrammingError):
                    first_conn.execute("SELECT 1")
                # Revisiting an evicted session reopens and reparses it correctly.
                first_id = "00000000-0000-0000-0000-000000000000"
                snap = build_status_snapshot(first_id, desktop_root=root, runtime=runtime)
                self.assertEqual(snap["stepCount"], 1)
                self.assertEqual(len(runtime._dbs), 2)
                self.assertEqual(len(runtime._transcripts), 2)
            finally:
                runtime.close()

    def test_serve_mode_answers_json_lines(self) -> None:
        cid = "77777777-6666-5555-4444-333333333333"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "antigravity"
            data_dir = root / "plugin_data" / "agy-desktop-status"
            (root / "conversations").mkdir(parents=True)
            data_dir.mkdir(parents=True, exist_ok=True)
            (data_dir / "active_session.json").write_text(
                json.dumps({"activeConversationId": cid, "sessions": {}}), encoding="utf-8"
            )
            proc = subprocess.Popen(
                [
                    sys.executable,
                    str(PANEL_DIR / "telemetry.py"),
                    "--serve",
                    "--data-dir",
                    str(data_dir),
                    "--desktop-root",
                    str(root),
                ],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                text=True,
                bufsize=1,
            )
            try:
                assert proc.stdin is not None and proc.stdout is not None
                proc.stdin.write(json.dumps({"conversationId": "auto"}) + "\n")
                proc.stdin.flush()
                first = json.loads(proc.stdout.readline())
                self.assertEqual(first["conversationId"], cid)
                proc.stdin.write(json.dumps({"conversationId": "auto"}) + "\n")
                proc.stdin.flush()
                second = json.loads(proc.stdout.readline())
                self.assertTrue(second.get("cacheHit"))
                proc.stdin.write(json.dumps({"op": "close"}) + "\n")
                proc.stdin.flush()
                self.assertEqual(proc.wait(timeout=10), 0)
            finally:
                if proc.poll() is None:
                    proc.kill()
                for stream in (proc.stdin, proc.stdout):
                    try:
                        if stream is not None:
                            stream.close()
                    except OSError:
                        pass


    # ------------------------------------------------------------------ #
    # Quota snapshot bridge: agy CLI statusline -> absolute reset times
    # ------------------------------------------------------------------ #

    def _write_quota_cache(self, path: Path, observed_at: int, buckets: list) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(
                {"schema": 1, "source": "agy-statusline", "observed_at": observed_at, "buckets": buckets}
            ),
            encoding="utf-8",
        )

    def test_quota_snapshot_resolves_absolute_reset_times(self) -> None:
        from telemetry import load_quota_snapshot

        now = datetime(2026, 11, 20, 9, 0, tzinfo=timezone.utc)
        observed = int(now.timestamp()) - 30
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp) / "quota.json"
            self._write_quota_cache(
                cache,
                observed,
                [
                    {"key": "gemini-weekly", "remaining_fraction": 0.88, "reset_at": observed + 266400},
                    {"key": "gemini-5h", "remaining_fraction": 0.96, "reset_at": observed + 7200},
                    {"key": "3p-weekly", "remaining_fraction": 0.42},
                ],
            )
            with patch.dict(os.environ, {"AGY_STATUSLINE_QUOTA_FILE": str(cache)}):
                snap = load_quota_snapshot(now)

        self.assertIsNotNone(snap)
        assert snap is not None
        self.assertFalse(snap["stale"])
        self.assertEqual(
            [(w["pool"], w["window"]) for w in snap["windows"]],
            [("gemini", "5h"), ("gemini", "weekly"), ("claude", "weekly")],
        )
        weekly = snap["windows"][1]
        self.assertAlmostEqual(weekly["remainingPct"], 88.0)
        self.assertEqual(weekly["resetAtEpoch"], observed + 266400)
        self.assertEqual(weekly["resetInSec"], 266370)
        self.assertFalse(weekly["approx"])
        # A bucket without reset_in_seconds still reports usage, just no time.
        self.assertIsNone(snap["windows"][2]["resetAtEpoch"])
        self.assertIsNone(snap["windows"][2]["resetInSec"])

    def test_quota_snapshot_rolls_forward_after_a_missed_window(self) -> None:
        from telemetry import load_quota_snapshot

        now = datetime(2026, 11, 20, 9, 0, tzinfo=timezone.utc)
        now_ts = int(now.timestamp())
        observed = now_ts - 10 * 86400
        reset_at = observed + 3 * 86400 + 600  # already reset 7 days before "now"
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp) / "quota.json"
            self._write_quota_cache(
                cache, observed, [{"key": "gemini-weekly", "remaining_fraction": 0.5, "reset_at": reset_at}]
            )
            with patch.dict(os.environ, {"AGY_STATUSLINE_QUOTA_FILE": str(cache)}):
                snap = load_quota_snapshot(now)

        assert snap is not None
        window = snap["windows"][0]
        self.assertEqual(window["resetAtEpoch"], reset_at + 7 * 86400)
        self.assertEqual(window["resetInSec"], 600)
        self.assertTrue(window["approx"])
        self.assertTrue(snap["stale"])
        self.assertEqual(snap["observedAgeSec"], 10 * 86400)

    def test_quota_snapshot_keeps_most_constrained_bucket_per_window(self) -> None:
        from telemetry import load_quota_snapshot

        now = datetime(2026, 11, 20, 9, 0, tzinfo=timezone.utc)
        now_ts = int(now.timestamp())
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp) / "quota.json"
            self._write_quota_cache(
                cache,
                now_ts,
                [
                    {"key": "gemini-weekly", "remaining_fraction": 0.9, "reset_at": now_ts + 3600},
                    {"key": "gemini-flash-weekly", "remaining_fraction": 0.25, "reset_at": now_ts + 7200},
                    {"key": "gemini-argon-wtu-weekly", "remaining_fraction": 1.0, "reset_at": now_ts + 3600},
                ],
            )
            with patch.dict(os.environ, {"AGY_STATUSLINE_QUOTA_FILE": str(cache)}):
                snap = load_quota_snapshot(now)

        assert snap is not None
        weekly = snap["windows"][0]
        self.assertEqual(weekly["pool"], "gemini")
        self.assertAlmostEqual(weekly["remainingPct"], 25.0)
        self.assertEqual(weekly["bucket"], "gemini-flash-weekly")
        self.assertEqual(weekly["resetAtEpoch"], now_ts + 7200)
        self.assertEqual(len(snap["windows"]), 2)
        self.assertEqual(snap["windows"][1]["pool"], "argon")

    def test_quota_snapshot_ignores_unusable_cache(self) -> None:
        from telemetry import load_quota_snapshot

        now = datetime(2026, 11, 20, 9, 0, tzinfo=timezone.utc)
        now_ts = int(now.timestamp())
        with tempfile.TemporaryDirectory() as tmp:
            missing = Path(tmp) / "missing.json"
            with patch.dict(os.environ, {"AGY_STATUSLINE_QUOTA_FILE": str(missing)}):
                self.assertIsNone(load_quota_snapshot(now))

            unknown_pool = Path(tmp) / "unknown.json"
            self._write_quota_cache(
                unknown_pool, now_ts, [{"key": "codeium-weekly", "remaining_fraction": 0.4}]
            )
            with patch.dict(os.environ, {"AGY_STATUSLINE_QUOTA_FILE": str(unknown_pool)}):
                self.assertIsNone(load_quota_snapshot(now))

            broken = Path(tmp) / "broken.json"
            broken.write_text("{not json", encoding="utf-8")
            with patch.dict(os.environ, {"AGY_STATUSLINE_QUOTA_FILE": str(broken)}):
                self.assertIsNone(load_quota_snapshot(now))

    def test_snapshot_attaches_quota_block(self) -> None:
        from telemetry import build_status_snapshot

        now_ts = int(datetime.now(timezone.utc).timestamp())
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "antigravity"
            (root / "conversations").mkdir(parents=True)
            cache = Path(tmp) / "quota.json"
            self._write_quota_cache(
                cache, now_ts, [{"key": "gemini-weekly", "remaining_fraction": 0.7, "reset_at": now_ts + 86400}]
            )
            with patch.dict(os.environ, {"AGY_STATUSLINE_QUOTA_FILE": str(cache)}):
                snap = build_status_snapshot(desktop_root=root, data_dir=Path(tmp) / "data")
            self.assertFalse(snap["found"])
            self.assertEqual(snap["quota"]["windows"][0]["pool"], "gemini")

            with patch.dict(os.environ, {"AGY_STATUSLINE_QUOTA_FILE": str(Path(tmp) / "nope.json")}):
                snap_without = build_status_snapshot(desktop_root=root, data_dir=Path(tmp) / "data")
            self.assertIsNone(snap_without["quota"])


    # ------------------------------------------------------------------ #
    # Live (streaming) metrics: in-flight step row -> live chars/tok-s
    # ------------------------------------------------------------------ #

    @staticmethod
    def _live_payload(text: str) -> bytes:
        body = field_bytes(1, text.encode("utf-8")) + field_bytes(8, text.encode("utf-8"))
        return field_varint(1, 15) + field_varint(4, 8) + field_bytes(20, body)

    def test_proto_text_chars_counts_streamed_text(self) -> None:
        from telemetry import _proto_text_chars

        text = "2147年，地球日已陷入永寂的极夜。" * 4
        self.assertEqual(_proto_text_chars(self._live_payload(text)), len(text))
        self.assertIsNone(_proto_text_chars(field_varint(1, 15)))
        self.assertIsNone(_proto_text_chars(None))

    def test_read_live_step_detects_only_in_flight_rows(self) -> None:
        from telemetry import _read_live_step

        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "conv.db"
            conn = sqlite3.connect(db)
            conn.execute(
                "CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER, status INTEGER,"
                " metadata BLOB, step_payload BLOB)"
            )
            conn.execute("INSERT INTO steps VALUES (0, 14, 3, NULL, NULL)")
            conn.execute("INSERT INTO steps VALUES (1, 15, 8, NULL, ?)", (self._live_payload("流式中..."),))
            conn.commit()
            ro = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
            try:
                live = _read_live_step(ro)
                self.assertIsNotNone(live)
                assert live is not None
                self.assertEqual(live["stepIdx"], 1)
                self.assertEqual(live["status"], 8)
                self.assertGreater(live["outputChars"] or 0, 0)

                # Finished / failed rows must not look like an active generation.
                for status in (3, 4):
                    conn.execute("UPDATE steps SET status=? WHERE idx=1", (status,))
                    conn.commit()
                    self.assertIsNone(_read_live_step(ro))
            finally:
                ro.close()
                conn.close()

    def test_estimate_chars_per_token_uses_completed_steps(self) -> None:
        from telemetry import _estimate_chars_per_token

        text = "字" * 200
        payload = self._live_payload(text)
        usage = field_varint(2, 1000) + field_varint(3, 100)  # 100 output tokens
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "conv.db"
            conn = sqlite3.connect(db)
            conn.execute(
                "CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER, status INTEGER,"
                " metadata BLOB, step_payload BLOB)"
            )
            conn.execute("INSERT INTO steps VALUES (1, 15, 3, ?, ?)", (field_bytes(9, usage), payload))
            conn.commit()
            ratio = _estimate_chars_per_token(conn)
            conn.close()
        self.assertIsNotNone(ratio)
        assert ratio is not None
        self.assertAlmostEqual(ratio, 2.0, places=2)

    def test_live_rate_needs_two_samples_and_resets(self) -> None:
        from telemetry import TelemetryRuntime

        runtime = TelemetryRuntime()
        try:
            self.assertIsNone(runtime.live_rate("c:1", 1, 100, 100.0))
            self.assertAlmostEqual(runtime.live_rate("c:1", 1, 160, 101.0) or 0.0, 60.0, places=3)
            self.assertAlmostEqual(runtime.live_rate("c:1", 1, 220, 102.0) or 0.0, 60.0, places=3)
            # Text shrinking means a new step/window started: no bogus rate.
            self.assertIsNone(runtime.live_rate("c:1", 1, 10, 103.0))
            self.assertIsNone(runtime.live_rate("c:1", 1, None, 104.0))
        finally:
            runtime.close()

    def test_build_snapshot_reports_live_progress(self) -> None:
        cid = "33333333-3333-3333-3333-333333333333"
        text = "正在生成一段较长的回复。" * 5
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "desktop"
            (root / "conversations").mkdir(parents=True)
            db_path = root / "conversations" / f"{cid}.db"
            conn = sqlite3.connect(db_path)
            conn.execute(
                "CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER, status INTEGER,"
                " metadata BLOB, step_payload BLOB)"
            )
            conn.execute("CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB)")
            conn.execute("INSERT INTO steps VALUES (0, 14, 3, NULL, NULL)")
            conn.execute("INSERT INTO steps VALUES (1, 15, 8, NULL, ?)", (self._live_payload(text),))
            conn.commit()
            conn.close()
            started = datetime.now(timezone.utc) - timedelta(seconds=3)
            tpath = root / "brain" / cid / ".system_generated" / "logs" / "transcript.jsonl"
            self._write_transcript(
                tpath, [{"type": "USER_INPUT", "created_at": started.strftime("%Y-%m-%dT%H:%M:%SZ")}]
            )

            live_snap = build_status_snapshot(cid, desktop_root=root)
            self.assertTrue(live_snap["live"]["active"])
            self.assertEqual(live_snap["live"]["stepIdx"], 1)
            self.assertEqual(live_snap["live"]["outputChars"], len(text))
            self.assertGreater(live_snap["live"]["elapsedSec"] or 0, 2.0)
            self.assertGreater(live_snap["live"]["charsPerToken"] or 0, 0)

            # Once the row is finalized the panel goes back to idle metrics.
            conn = sqlite3.connect(db_path)
            conn.execute("UPDATE steps SET status=3 WHERE idx=1")
            conn.commit()
            conn.close()
            idle_snap = build_status_snapshot(cid, desktop_root=root)
            self.assertFalse(idle_snap["live"]["active"])


if __name__ == "__main__":
    unittest.main()
