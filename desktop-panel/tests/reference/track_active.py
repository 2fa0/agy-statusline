#!/usr/bin/env python3
"""Antigravity Desktop lifecycle hook that records the active conversation state.

Reads hook metadata from stdin and atomically writes active_session.json inside
PLUGIN_DATA so the MCP App status panel knows which conversation is active.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

MAX_STDIN_BYTES = 1024 * 1024
MAX_TRACKED_SESSIONS = 30


def resolve_data_dir() -> Path:
    env_dir = os.environ.get("PLUGIN_DATA")
    if env_dir:
        return Path(env_dir)
    return Path.home() / ".gemini" / "antigravity" / "plugin_data" / "agy-desktop-status"


def load_existing(state_path: Path) -> dict:
    try:
        data = json.loads(state_path.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            return data
    except (OSError, ValueError):
        pass
    return {"sessions": {}}


def atomic_write_json(target: Path, payload: dict) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=".active_", suffix=".tmp", dir=str(target.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=2)
        os.replace(tmp_name, target)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def main() -> int:
    event_name = ""
    try:
        raw = sys.stdin.read(MAX_STDIN_BYTES)
        payload = json.loads(raw) if raw.strip() else {}
        if not isinstance(payload, dict):
            payload = {}
        event_name = str(payload.get("hookEventName") or "")
        conv_id = str(payload.get("conversationId") or "").strip()

        if conv_id:
            data_dir = resolve_data_dir()
            state_path = data_dir / "active_session.json"
            state = load_existing(state_path)
            sessions = state.get("sessions")
            if not isinstance(sessions, dict):
                sessions = {}

            now_iso = datetime.now(timezone.utc).isoformat()
            prev = sessions.get(conv_id) if isinstance(sessions.get(conv_id), dict) else {}
            sessions[conv_id] = {
                "conversationId": conv_id,
                "modelName": payload.get("modelName") or prev.get("modelName") or "",
                "transcriptPath": payload.get("transcriptPath") or prev.get("transcriptPath") or "",
                "workspacePaths": payload.get("workspacePaths") or prev.get("workspacePaths") or [],
                "cwd": payload.get("cwd") or prev.get("cwd") or "",
                "lastEvent": event_name or prev.get("lastEvent") or "",
                "invocationNum": payload.get("invocationNum", prev.get("invocationNum")),
                "executionNum": payload.get("executionNum", prev.get("executionNum")),
                "terminationReason": payload.get("terminationReason") or prev.get("terminationReason") or "",
                "updatedAt": now_iso,
            }

            if len(sessions) > MAX_TRACKED_SESSIONS:
                ordered = sorted(
                    sessions.items(),
                    key=lambda kv: str((kv[1] or {}).get("updatedAt") or ""),
                    reverse=True,
                )
                sessions = dict(ordered[:MAX_TRACKED_SESSIONS])

            next_state = {
                "activeConversationId": conv_id,
                "updatedAt": now_iso,
                "sessions": sessions,
            }
            atomic_write_json(state_path, next_state)
    except Exception:
        # Never block or fail the agent execution loop.
        pass

    if event_name == "Stop":
        sys.stdout.write(json.dumps({"decision": "allow"}))
    else:
        sys.stdout.write("{}")
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
