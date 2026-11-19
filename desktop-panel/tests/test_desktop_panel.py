import io
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PANEL_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PANEL_DIR))

from server import APP_URI, MIME_TYPE, McpStatusServer  # noqa: E402
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

    def test_mcp_server_protocol(self) -> None:
        server = McpStatusServer()
        init_res = server.handle_request(
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26"}}
        )
        assert init_res is not None
        self.assertEqual(init_res["result"]["protocolVersion"], "2025-03-26")

        tools_res = server.handle_request({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        assert tools_res is not None
        tools = {t["name"]: t for t in tools_res["result"]["tools"]}
        self.assertIn("open_status_panel", tools)
        self.assertIn("get_status_snapshot", tools)
        entrypoints = tools["open_status_panel"]["_meta"]["com.google.antigravity/ui"]["entrypoints"]
        self.assertEqual({e["type"] for e in entrypoints}, {"aux_pane", "global"})
        self.assertEqual(tools["get_status_snapshot"]["_meta"]["ui"]["visibility"], ["app"])

        res_read = server.handle_request(
            {"jsonrpc": "2.0", "id": 3, "method": "resources/read", "params": {"uri": APP_URI}}
        )
        assert res_read is not None
        content = res_read["result"]["contents"][0]
        self.assertEqual(content["mimeType"], MIME_TYPE)
        self.assertIn("<script>", content["text"])
        self.assertEqual(content["text"].count("<!DOCTYPE html>"), 1)
        self.assertEqual(content["text"].count("</head>"), 1)

        call_res = server.handle_request(
            {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "open_status_panel", "arguments": {}}}
        )
        assert call_res is not None
        self.assertIn("result", call_res)
        self.assertFalse(call_res["result"]["isError"])
        self.assertIn("structuredContent", call_res["result"])

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


if __name__ == "__main__":
    unittest.main()
