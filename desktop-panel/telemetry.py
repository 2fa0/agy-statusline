"""Read-only local telemetry parser for Antigravity 2.0 Desktop sessions.

Strictly reads local files under ~/.gemini/antigravity (or AGY_DESKTOP_DATA_DIR):
- active_session.json (written by this plugin's lifecycle hooks in PLUGIN_DATA)
- conversations/<id>.db (gen_metadata and steps tables, read-only)
- brain/<id>/.system_generated/logs/transcript.jsonl (timestamps for turn/session duration)
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

UUID_RE = re.compile(r"^[0-9a-fA-F-]{36}$")


def get_desktop_root() -> Path:
    override = os.environ.get("AGY_DESKTOP_DATA_DIR")
    if override:
        return Path(override)
    return Path.home() / ".gemini" / "antigravity"


def _read_varint(data: bytes, pos: int) -> tuple[Optional[int], int]:
    value = 0
    shift = 0
    for _ in range(10):
        if pos >= len(data):
            return None, pos
        b = data[pos]
        pos += 1
        if shift == 63 and b > 1:
            return None, pos
        value |= (b & 0x7F) << shift
        if (b & 0x80) == 0:
            return value, pos
        if shift == 63:
            return None, pos
        shift += 7
    return None, pos


def decode_proto_fields(data: bytes) -> dict[int, list[Any]]:
    """Decode raw protobuf wire bytes into {field_number: [values]}."""
    fields: dict[int, list[Any]] = {}
    pos = 0
    n = len(data)
    while pos < n:
        key, pos = _read_varint(data, pos)
        if key is None:
            break
        field_num = key >> 3
        wire_type = key & 7
        if field_num == 0:
            break
        if wire_type == 0:
            val, pos = _read_varint(data, pos)
            if val is None:
                break
            fields.setdefault(field_num, []).append(val)
        elif wire_type == 2:
            size, pos = _read_varint(data, pos)
            if size is None or size < 0 or pos + size > n:
                break
            val_bytes = data[pos : pos + size]
            pos += size
            fields.setdefault(field_num, []).append(val_bytes)
        elif wire_type in (1, 5):
            size = 8 if wire_type == 1 else 4
            if pos + size > n:
                break
            pos += size
            fields.setdefault(field_num, []).append(0)
        else:
            break
    return fields


def _last_bytes(fields: dict[int, list[Any]], num: int) -> Optional[bytes]:
    vals = fields.get(num)
    if not vals:
        return None
    v = vals[-1]
    return v if isinstance(v, (bytes, bytearray)) else None


def _last_int(fields: dict[int, list[Any]], num: int) -> Optional[int]:
    vals = fields.get(num)
    if not vals:
        return None
    v = vals[-1]
    return v if isinstance(v, int) else None


def _parse_duration(raw: Optional[bytes]) -> Optional[float]:
    if not raw:
        return None
    f = decode_proto_fields(raw)
    secs = _last_int(f, 1) or 0
    nanos = _last_int(f, 2) or 0
    if nanos < 0 or nanos >= 1_000_000_000 or secs < 0:
        return None
    return float(secs) + float(nanos) / 1e9


@dataclass
class GenRecord:
    idx: int
    output_tokens: Optional[int]
    input_tokens: Optional[int]
    cache_read_tokens: Optional[int]
    cache_write_tokens: Optional[int]
    duration_sec: Optional[float]
    exec_duration_sec: Optional[float]
    speed_tok_s: Optional[float]
    served_model: str


def parse_gen_metadata_blob(idx: int, data: bytes) -> Optional[GenRecord]:
    """Decode one gen_metadata.data protobuf blob."""
    root = decode_proto_fields(data)
    chat_raw = _last_bytes(root, 1)
    if not chat_raw:
        return None
    chat = decode_proto_fields(chat_raw)

    usage_raw = _last_bytes(chat, 4)
    output_tokens: Optional[int] = None
    input_tokens: Optional[int] = None
    cache_read_tokens: Optional[int] = None
    cache_write_tokens: Optional[int] = None
    if usage_raw:
        usage = decode_proto_fields(usage_raw)
        output_tokens = _last_int(usage, 3)
        input_tokens = _last_int(usage, 2)
        if input_tokens is None:
            input_tokens = _last_int(usage, 1)
        cache_write_tokens = _last_int(usage, 4)
        cache_read_tokens = _last_int(usage, 5)

    exec_dur = _parse_duration(_last_bytes(chat, 11))
    gen_dur = _parse_duration(_last_bytes(chat, 12))

    # Match agy-statusline speed semantics: output tokens / duration(field 12),
    # falling back to field 11 when field 12 is absent or represents a sub-100ms
    # TTFB/first-chunk timestamp whose implied speed would exceed 1000 tok/s.
    speed: Optional[float] = None
    if output_tokens and output_tokens > 0:
        for dur in (gen_dur, exec_dur):
            if dur is not None and dur >= 0.1:
                candidate = float(output_tokens) / dur
                if 0.0 < candidate < 1000.0:
                    speed = candidate
                    break

    served_model = ""
    model_raw = _last_bytes(chat, 19)
    if model_raw:
        try:
            decoded = model_raw.decode("utf-8", errors="ignore").strip()
            if decoded and all(32 <= ord(ch) < 127 for ch in decoded):
                served_model = decoded
        except Exception:
            pass

    return GenRecord(
        idx=idx,
        output_tokens=output_tokens,
        input_tokens=input_tokens,
        cache_read_tokens=cache_read_tokens,
        cache_write_tokens=cache_write_tokens,
        duration_sec=gen_dur,
        exec_duration_sec=exec_dur,
        speed_tok_s=speed,
        served_model=served_model,
    )


def _open_sqlite_ro(db_path: Path) -> Optional[sqlite3.Connection]:
    for suffix in ("mode=ro", "mode=ro&immutable=1"):
        conn: Optional[sqlite3.Connection] = None
        try:
            conn = sqlite3.connect(f"file:{db_path}?{suffix}", uri=True, timeout=0.5)
            conn.execute("PRAGMA query_only = ON")
            conn.execute("SELECT 1 FROM sqlite_master LIMIT 1").fetchone()
            return conn
        except sqlite3.Error:
            if conn is not None:
                try:
                    conn.close()
                except sqlite3.Error:
                    pass
            continue
    return None


def _read_gen_records(conn: sqlite3.Connection, limit: int = 12) -> list[GenRecord]:
    has_table = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='gen_metadata'"
    ).fetchone()
    if not has_table:
        return []
    rows = conn.execute(
        "SELECT idx, data FROM gen_metadata WHERE data IS NOT NULL ORDER BY idx DESC LIMIT ?",
        (limit,),
    ).fetchall()
    out: list[GenRecord] = []
    for idx, blob in rows:
        if isinstance(blob, memoryview):
            blob = bytes(blob)
        if not isinstance(blob, (bytes, bytearray)):
            continue
        rec = parse_gen_metadata_blob(int(idx), bytes(blob))
        if rec is not None:
            out.append(rec)
    return out


def _read_latest_steps_usage(conn: sqlite3.Connection, limit: int = 40) -> Optional[dict[str, int]]:
    has_table = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='steps'"
    ).fetchone()
    if not has_table:
        return None
    cols = [row[1] for row in conn.execute("PRAGMA table_info(steps)").fetchall()]
    blob_col = "metadata" if "metadata" in cols else ("data" if "data" in cols else None)
    if not blob_col:
        return None
    order_col = "idx" if "idx" in cols else ("step_idx" if "step_idx" in cols else "rowid")
    rows = conn.execute(
        f"SELECT {blob_col} FROM steps WHERE {blob_col} IS NOT NULL ORDER BY {order_col} DESC LIMIT ?",
        (limit,),
    ).fetchall()
    for (blob,) in rows:
        if isinstance(blob, memoryview):
            blob = bytes(blob)
        if not isinstance(blob, (bytes, bytearray)):
            continue
        fields = decode_proto_fields(bytes(blob))
        usage_raw = _last_bytes(fields, 9)
        if not usage_raw:
            continue
        u = decode_proto_fields(usage_raw)
        inp = _last_int(u, 2)
        out_t = _last_int(u, 3)
        cw = _last_int(u, 4)
        cr = _last_int(u, 5)
        if any(v is not None for v in (inp, out_t, cw, cr)):
            return {
                "inputTokens": inp if inp is not None else 0,
                "outputTokens": out_t if out_t is not None else 0,
                "cacheWriteTokens": cw if cw is not None else 0,
                "cacheReadTokens": cr if cr is not None else 0,
            }
    return None


def _parse_iso_ts(raw: Any) -> Optional[datetime]:
    if not isinstance(raw, str) or not raw:
        return None
    text = raw.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except ValueError:
        return None


def parse_transcript_timing(transcript_path: Path) -> dict[str, Any]:
    if not transcript_path.is_file():
        return {}
    first_ts: Optional[datetime] = None
    last_ts: Optional[datetime] = None
    last_user_ts: Optional[datetime] = None
    step_count = 0
    turn_count = 0
    last_user_preview = ""
    try:
        with transcript_path.open("r", encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    item = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(item, dict):
                    continue
                step_count += 1
                ts = _parse_iso_ts(item.get("created_at"))
                if ts is not None:
                    if first_ts is None or ts < first_ts:
                        first_ts = ts
                    if last_ts is None or ts > last_ts:
                        last_ts = ts
                step_type = str(item.get("type") or "")
                source = str(item.get("source") or "")
                if step_type == "USER_INPUT" or source == "USER_EXPLICIT":
                    turn_count += 1
                    if ts is not None:
                        last_user_ts = ts
                    content = str(item.get("content") or "").strip().splitlines()
                    if content:
                        last_user_preview = content[0][:60]
    except OSError:
        return {}

    session_sec = (last_ts - first_ts).total_seconds() if (first_ts and last_ts) else None
    turn_sec = (last_ts - last_user_ts).total_seconds() if (last_user_ts and last_ts) else None
    if session_sec is not None and session_sec < 0:
        session_sec = None
    if turn_sec is not None and turn_sec < 0:
        turn_sec = None

    return {
        "sessionDurationSec": session_sec,
        "turnDurationSec": turn_sec,
        "turnCount": turn_count,
        "stepCount": step_count,
        "lastUserPreview": last_user_preview,
        "lastActivityAt": last_ts.isoformat() if last_ts else None,
    }


def infer_context_window_size(model_name: str) -> Optional[int]:
    lower = (model_name or "").lower()
    if not lower:
        return None
    if any(tok in lower for tok in ("gemini", "hydrogen", "argon", "flash")):
        return 1_048_576
    if any(tok in lower for tok in ("claude", "sonnet", "opus", "haiku")):
        if "1m" in lower:
            return 1_000_000
        return 200_000
    return None


def _db_mtime(db_path: Path) -> float:
    mtime = db_path.stat().st_mtime
    wal = db_path.with_name(db_path.name + "-wal")
    if wal.exists():
        try:
            mtime = max(mtime, wal.stat().st_mtime)
        except OSError:
            pass
    return mtime


def _load_hook_state(data_dir: Optional[Path]) -> dict[str, Any]:
    if data_dir is None:
        return {}
    state_path = data_dir / "active_session.json"
    try:
        data = json.loads(state_path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def list_recent_conversations(
    desktop_root: Path, hook_state: dict[str, Any], limit: int = 15
) -> list[dict[str, Any]]:
    conv_dir = desktop_root / "conversations"
    sessions_meta = hook_state.get("sessions") if isinstance(hook_state.get("sessions"), dict) else {}
    active_id = str(hook_state.get("activeConversationId") or "")

    items: dict[str, dict[str, Any]] = {}
    if conv_dir.is_dir():
        candidates: list[tuple[float, Path]] = []
        for entry in conv_dir.iterdir():
            if entry.suffix == ".db" and UUID_RE.match(entry.stem):
                try:
                    candidates.append((_db_mtime(entry), entry))
                except OSError:
                    continue
        candidates.sort(key=lambda pair: pair[0], reverse=True)
        for mtime, path in candidates[:limit]:
            cid = path.stem
            meta = sessions_meta.get(cid) if isinstance(sessions_meta.get(cid), dict) else {}
            items[cid] = {
                "conversationId": cid,
                "shortId": cid[:8],
                "modelName": str(meta.get("modelName") or ""),
                "workspace": Path(meta["cwd"]).name if meta.get("cwd") else "",
                "updatedAt": datetime.fromtimestamp(mtime, tz=timezone.utc).isoformat(),
                "isActive": cid == active_id,
                "_sort": mtime,
            }

    if active_id and active_id not in items:
        meta = sessions_meta.get(active_id) if isinstance(sessions_meta.get(active_id), dict) else {}
        items[active_id] = {
            "conversationId": active_id,
            "shortId": active_id[:8],
            "modelName": str(meta.get("modelName") or ""),
            "workspace": Path(meta["cwd"]).name if meta.get("cwd") else "",
            "updatedAt": str(meta.get("updatedAt") or hook_state.get("updatedAt") or ""),
            "isActive": True,
            "_sort": float("inf"),
        }

    ordered = sorted(items.values(), key=lambda x: x["_sort"], reverse=True)
    for row in ordered:
        row.pop("_sort", None)
    return ordered[:limit]


def _resolve_transcript_path(
    desktop_root: Path, conv_id: str, session_meta: dict[str, Any]
) -> Optional[Path]:
    raw = str(session_meta.get("transcriptPath") or "").strip()
    if raw:
        p = Path(raw)
        if p.is_file():
            return p
    candidate = desktop_root / "brain" / conv_id / ".system_generated" / "logs" / "transcript.jsonl"
    if candidate.is_file():
        return candidate
    return None


def build_status_snapshot(
    conversation_id: Optional[str] = None,
    data_dir: Optional[Path] = None,
    desktop_root: Optional[Path] = None,
) -> dict[str, Any]:
    """Assemble a complete read-only telemetry snapshot for the desktop UI panel."""
    root = desktop_root or get_desktop_root()
    hook_state = _load_hook_state(data_dir)
    sessions_meta = hook_state.get("sessions") if isinstance(hook_state.get("sessions"), dict) else {}
    recent = list_recent_conversations(root, hook_state)

    target_id = (conversation_id or "").strip()
    if target_id in ("", "auto"):
        target_id = str(hook_state.get("activeConversationId") or "")
        if not target_id and recent:
            target_id = recent[0]["conversationId"]

    if not target_id or not UUID_RE.match(target_id):
        return {
            "found": False,
            "conversationId": "",
            "recentConversations": recent,
            "hookConnected": bool(hook_state.get("activeConversationId")),
            "generatedAt": datetime.now(timezone.utc).isoformat(),
            "message": "No local Antigravity Desktop conversation found yet.",
        }

    session_meta = sessions_meta.get(target_id) if isinstance(sessions_meta.get(target_id), dict) else {}
    db_path = root / "conversations" / f"{target_id}.db"

    gen_records: list[GenRecord] = []
    steps_usage: Optional[dict[str, int]] = None
    db_readable = False
    if db_path.is_file():
        conn = _open_sqlite_ro(db_path)
        if conn is not None:
            db_readable = True
            try:
                gen_records = _read_gen_records(conn, limit=12)
                steps_usage = _read_latest_steps_usage(conn, limit=40)
            except sqlite3.Error:
                pass
            finally:
                conn.close()

    transcript_path = _resolve_transcript_path(root, target_id, session_meta)
    timing = parse_transcript_timing(transcript_path) if transcript_path else {}

    latest_gen = gen_records[0] if gen_records else None
    model_name = (
        (latest_gen.served_model if latest_gen and latest_gen.served_model else "")
        or str(session_meta.get("modelName") or "")
    )

    # Usage & Cache Hit calculation:
    # Prefer steps.metadata (field 9), fall back to gen_metadata usage (chat.field 4).
    input_tokens: Optional[int] = None
    output_tokens: Optional[int] = latest_gen.output_tokens if latest_gen else None
    cache_read_tokens: Optional[int] = None
    cache_write_tokens: Optional[int] = None
    usage_source = "none"

    if steps_usage is not None:
        input_tokens = steps_usage["inputTokens"]
        cache_read_tokens = steps_usage["cacheReadTokens"]
        cache_write_tokens = steps_usage["cacheWriteTokens"]
        if output_tokens is None and steps_usage["outputTokens"] > 0:
            output_tokens = steps_usage["outputTokens"]
        usage_source = "steps"
    elif latest_gen is not None and (
        latest_gen.input_tokens is not None or latest_gen.cache_read_tokens is not None
    ):
        input_tokens = latest_gen.input_tokens
        cache_read_tokens = latest_gen.cache_read_tokens
        cache_write_tokens = latest_gen.cache_write_tokens
        usage_source = "gen_metadata"

    cache_hit_pct: Optional[float] = None
    if input_tokens is not None and cache_read_tokens is not None:
        denom = input_tokens + cache_read_tokens
        if denom > 0 and (cache_write_tokens or 0) == 0:
            cache_hit_pct = 100.0 * float(cache_read_tokens) / float(denom)
        elif denom > 0 and cache_read_tokens > 0:
            cache_hit_pct = 100.0 * float(cache_read_tokens) / float(denom)

    ctx_used: Optional[int] = None
    if input_tokens is not None or cache_read_tokens is not None or cache_write_tokens is not None:
        ctx_used = (input_tokens or 0) + (cache_read_tokens or 0) + (cache_write_tokens or 0)
        if ctx_used <= 0:
            ctx_used = None

    ctx_total = infer_context_window_size(model_name)
    ctx_pct: Optional[float] = None
    if ctx_used is not None and ctx_total and ctx_total > 0:
        ctx_pct = min(100.0, 100.0 * float(ctx_used) / float(ctx_total))

    last_speed = latest_gen.speed_tok_s if latest_gen else None
    last_gen_duration = None
    if latest_gen:
        last_gen_duration = (
            latest_gen.exec_duration_sec
            if latest_gen.exec_duration_sec is not None
            else latest_gen.duration_sec
        )

    history = [
        {
            "idx": rec.idx,
            "speedTokS": round(rec.speed_tok_s, 1) if rec.speed_tok_s is not None else None,
            "outputTokens": rec.output_tokens,
            "durationSec": round(
                rec.exec_duration_sec if rec.exec_duration_sec is not None else rec.duration_sec, 2
            )
            if (rec.exec_duration_sec is not None or rec.duration_sec is not None)
            else None,
            "model": rec.served_model or model_name,
        }
        for rec in gen_records
    ]

    workspace_paths = session_meta.get("workspacePaths") or []
    workspace_name = ""
    if workspace_paths:
        workspace_name = Path(str(workspace_paths[0])).name
    elif session_meta.get("cwd"):
        workspace_name = Path(str(session_meta["cwd"])).name

    return {
        "found": db_readable or bool(timing),
        "conversationId": target_id,
        "shortId": target_id[:8],
        "isActiveSession": target_id == str(hook_state.get("activeConversationId") or ""),
        "hookConnected": bool(hook_state.get("activeConversationId")),
        "modelName": model_name,
        "workspaceName": workspace_name,
        "lastAvgSpeed": round(last_speed, 1) if last_speed is not None else None,
        "lowSpeedWarning": bool(last_speed is not None and last_speed < 50.0),
        "lastGenDurationSec": round(last_gen_duration, 2) if last_gen_duration is not None else None,
        "turnDurationSec": round(timing["turnDurationSec"], 2)
        if timing.get("turnDurationSec") is not None
        else None,
        "sessionDurationSec": round(timing["sessionDurationSec"], 2)
        if timing.get("sessionDurationSec") is not None
        else None,
        "turnCount": timing.get("turnCount"),
        "stepCount": timing.get("stepCount"),
        "contextUsed": ctx_used,
        "contextTotal": ctx_total,
        "contextPct": round(ctx_pct, 1) if ctx_pct is not None else None,
        "cacheHitPct": round(cache_hit_pct, 1) if cache_hit_pct is not None else None,
        "cacheReadTokens": cache_read_tokens,
        "cacheWriteTokens": cache_write_tokens,
        "inputTokens": input_tokens,
        "outputTokens": output_tokens,
        "usageSource": usage_source,
        "history": history,
        "recentConversations": recent,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
    }


def _main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description="Read-only Antigravity Desktop telemetry snapshot")
    parser.add_argument("--conversation-id", default="auto")
    parser.add_argument("--data-dir", default="")
    parser.add_argument("--desktop-root", default="")
    args = parser.parse_args()

    snap = build_status_snapshot(
        conversation_id=args.conversation_id or None,
        data_dir=Path(args.data_dir) if args.data_dir else None,
        desktop_root=Path(args.desktop_root) if args.desktop_root else None,
    )
    print(json.dumps(snap, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
