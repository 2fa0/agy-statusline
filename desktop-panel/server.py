#!/usr/bin/env python3
"""Zero-dependency MCP App server for AGY Desktop Status right-pane panel.

Speaks newline-delimited JSON-RPC 2.0 over stdio and exposes:
- open_status_panel (aux_pane & global UI entrypoints via com.google.antigravity/ui)
- get_status_snapshot (app-only live refresh tool, hidden from the model)
- ui://agy-desktop-status/panel.html (single-file MCP App HTML resource)
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any, Optional

from telemetry import build_status_snapshot

PLUGIN_ROOT = Path(__file__).resolve().parent
APP_URI = "ui://agy-desktop-status/panel.html"
MIME_TYPE = "text/html;profile=mcp-app"
SUPPORTED_PROTOCOL_VERSION = "2025-03-26"


def load_html_bundle() -> str:
    override = os.environ.get("AGY_DESKTOP_STATUS_HTML")
    html_path = Path(override) if override else (PLUGIN_ROOT / "dist" / "index.html")
    if html_path.is_file():
        return html_path.read_text(encoding="utf-8")
    return (
        "<!doctype html><html><body style='font-family:sans-serif;padding:16px'>"
        "<h3>AGY Desktop Status</h3>"
        "<p>UI bundle missing. Run <code>npm run build</code> inside <code>desktop-panel/ui</code>.</p>"
        "</body></html>"
    )


def format_summary_text(snapshot: dict[str, Any]) -> str:
    if not snapshot.get("found"):
        return "AGY Desktop Status: waiting for an active conversation."
    speed = snapshot.get("lastAvgSpeed")
    speed_str = f"{speed:.0f} tok/s" if speed is not None else "--"
    turn_s = snapshot.get("turnDurationSec")
    turn_str = f"{turn_s:.1f}s" if turn_s is not None else "--"
    ctx_used = snapshot.get("contextUsed")
    ctx_total = snapshot.get("contextTotal")
    ctx_str = f"{ctx_used}/{ctx_total}" if (ctx_used is not None and ctx_total) else "--"
    hit = snapshot.get("cacheHitPct")
    hit_str = f"{hit:.1f}%" if hit is not None else "--"
    return (
        f"AGY Desktop Status [{snapshot.get('shortId', '')}] "
        f"Speed: {speed_str} | Turn: {turn_str} | Ctx: {ctx_str} | Cache: {hit_str}"
    )


TOOLS = [
    {
        "name": "open_status_panel",
        "title": "AGY Status",
        "description": "Open the AGY Desktop telemetry panel showing speed, turn/session duration, context usage, and cache hit rate.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "conversationId": {
                    "type": "string",
                    "description": "Optional conversation UUID (defaults to active conversation).",
                }
            },
        },
        "_meta": {
            "ui": {"resourceUri": APP_URI},
            "com.google.antigravity/ui": {
                "entrypoints": [
                    {"type": "aux_pane", "title": "AGY Status"},
                    {"type": "global", "title": "AGY Status"},
                ]
            },
        },
    },
    {
        "name": "get_status_snapshot",
        "title": "Refresh AGY Status Snapshot",
        "description": "Fetch live read-only telemetry snapshot for the AGY Status UI.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "conversationId": {
                    "type": "string",
                    "description": "Optional conversation UUID or 'auto'.",
                }
            },
        },
        "_meta": {
            "ui": {"visibility": ["app"]},
        },
    },
]


class McpStatusServer:
    def __init__(self, data_dir: Optional[Path] = None) -> None:
        self.data_dir = data_dir

    def handle_request(self, msg: dict[str, Any]) -> Optional[dict[str, Any]]:
        method = msg.get("method")
        req_id = msg.get("id")
        params = msg.get("params") or {}

        # Notifications have no id and expect no reply.
        if req_id is None:
            return None

        try:
            if method == "initialize":
                client_proto = str(params.get("protocolVersion") or SUPPORTED_PROTOCOL_VERSION)
                return self._ok(
                    req_id,
                    {
                        "protocolVersion": client_proto,
                        "capabilities": {
                            "tools": {"listChanged": False},
                            "resources": {"subscribe": False, "listChanged": False},
                        },
                        "serverInfo": {"name": "agy-desktop-status", "version": "0.3.1"},
                    },
                )

            if method == "ping":
                return self._ok(req_id, {})

            if method == "tools/list":
                return self._ok(req_id, {"tools": TOOLS})

            if method == "tools/call":
                name = params.get("name")
                args = params.get("arguments") or {}
                if name not in ("open_status_panel", "get_status_snapshot"):
                    return self._err(req_id, -32602, f"Unknown tool: {name}")
                conv_id = args.get("conversationId") if isinstance(args, dict) else None
                snapshot = build_status_snapshot(conversation_id=conv_id, data_dir=self.data_dir)
                return self._ok(
                    req_id,
                    {
                        "content": [{"type": "text", "text": format_summary_text(snapshot)}],
                        "structuredContent": snapshot,
                        "isError": False,
                    },
                )

            if method == "resources/list":
                return self._ok(
                    req_id,
                    {
                        "resources": [
                            {
                                "uri": APP_URI,
                                "name": "AGY Status Panel",
                                "description": "Read-only telemetry view for Antigravity Desktop.",
                                "mimeType": MIME_TYPE,
                                "_meta": {"ui": {"prefersBorder": False}},
                            }
                        ]
                    },
                )

            if method == "resources/read":
                uri = params.get("uri")
                if uri != APP_URI:
                    return self._err(req_id, -32002, f"Resource not found: {uri}")
                return self._ok(
                    req_id,
                    {
                        "contents": [
                            {
                                "uri": APP_URI,
                                "mimeType": MIME_TYPE,
                                "text": load_html_bundle(),
                                "_meta": {"ui": {"prefersBorder": False}},
                            }
                        ]
                    },
                )

            return self._err(req_id, -32601, f"Method not found: {method}")
        except Exception as exc:
            return self._err(req_id, -32603, f"Internal error: {exc}")

    @staticmethod
    def _ok(req_id: Any, result: dict[str, Any]) -> dict[str, Any]:
        return {"jsonrpc": "2.0", "id": req_id, "result": result}

    @staticmethod
    def _err(req_id: Any, code: int, message: str) -> dict[str, Any]:
        return {"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}}


def main() -> int:
    parser = argparse.ArgumentParser(description="AGY Desktop Status MCP App Server")
    parser.add_argument("--data-dir", default=os.environ.get("PLUGIN_DATA", ""))
    args = parser.parse_args()
    data_dir = Path(args.data_dir) if args.data_dir else None

    server = McpStatusServer(data_dir=data_dir)
    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if not isinstance(msg, dict):
            continue
        reply = server.handle_request(msg)
        if reply is not None:
            sys.stdout.write(json.dumps(reply, ensure_ascii=False) + "\n")
            sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
