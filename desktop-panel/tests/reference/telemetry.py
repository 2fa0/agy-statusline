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
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator, Optional

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


def _read_gen_records(
    conn: sqlite3.Connection, limit: int = 12, schema: Optional[DbSchema] = None
) -> Iterator[GenRecord]:
    schema = schema or _detect_schema(conn)
    if not schema.has_gen_metadata:
        return
    rows = conn.execute(
        "SELECT idx, data FROM gen_metadata WHERE data IS NOT NULL ORDER BY idx DESC LIMIT ?",
        (limit,),
    )
    for idx, blob in rows:
        if isinstance(blob, memoryview):
            blob = bytes(blob)
        if not isinstance(blob, (bytes, bytearray)):
            continue
        rec = parse_gen_metadata_blob(int(idx), bytes(blob))
        if rec is not None:
            yield rec


def _usage_from_metadata(blob: Any) -> Optional[dict[str, int]]:
    """Decode the per-step usage message (metadata field 9) if it is present."""
    if isinstance(blob, memoryview):
        blob = bytes(blob)
    if not isinstance(blob, (bytes, bytearray)):
        return None
    fields = decode_proto_fields(bytes(blob))
    usage_raw = _last_bytes(fields, 9)
    if not usage_raw:
        return None
    u = decode_proto_fields(usage_raw)
    inp = _last_int(u, 2)
    out_t = _last_int(u, 3)
    cw = _last_int(u, 4)
    cr = _last_int(u, 5)
    if not any(v is not None for v in (inp, out_t, cw, cr)):
        return None
    return {
        "inputTokens": inp or 0,
        "outputTokens": out_t or 0,
        "cacheWriteTokens": cw or 0,
        "cacheReadTokens": cr or 0,
    }


def _read_latest_steps_usage(
    conn: sqlite3.Connection, limit: int = 40, schema: Optional[DbSchema] = None
) -> Optional[dict[str, int]]:
    schema = schema or _detect_schema(conn)
    blob_col = schema.steps_blob_col
    if not blob_col:
        return None
    order_col = schema.steps_order_col or "rowid"
    rows = conn.execute(
        f"SELECT {blob_col} FROM steps WHERE {blob_col} IS NOT NULL ORDER BY {order_col} DESC LIMIT ?",
        (limit,),
    ).fetchall()
    for (blob,) in rows:
        usage = _usage_from_metadata(blob)
        if usage is not None:
            return usage
    return None


# --- live (streaming) metrics ----------------------------------------------
# While the desktop agent replies, AGY writes the in-flight step row before the
# generation finishes: status stays in a non-final state and ``step_payload``
# grows as text streams in (field 20 -> field 1 is the response text). That is
# enough to derive a live output rate; token counts only become available when
# the step completes, so live rates are character based and calibrated against
# completed steps from the same conversation.

STEP_STATUS_DONE = 3
STEP_STATUS_LIVE = (1, 2, 8)  # PENDING, RUNNING, GENERATING (CortexStepStatus)
DEFAULT_CHARS_PER_TOKEN = 1.4
LIVE_RATE_WINDOW_SEC = 4.0
LIVE_RATE_MAX_SAMPLES = 5


def _proto_text_chars(payload: Any) -> Optional[int]:
    """Characters of the streamed response text carried by a step payload."""
    if isinstance(payload, memoryview):
        payload = bytes(payload)
    if not isinstance(payload, (bytes, bytearray)):
        return None
    fields = decode_proto_fields(bytes(payload))
    message = _last_bytes(fields, 20)
    if not message:
        return None
    inner = decode_proto_fields(message)
    text = _last_bytes(inner, 1)
    if text is None:
        return None
    return len(text.decode("utf-8", errors="ignore"))


def _read_live_step(
    conn: sqlite3.Connection, schema: Optional[DbSchema] = None
) -> Optional[dict[str, Any]]:
    """Newest step row if a generation/tool step is still in flight."""
    schema = schema or _detect_schema(conn)
    if not schema.steps_status_col or not schema.steps_payload_col:
        return None
    order_col = schema.steps_order_col or "rowid"
    cols = [order_col, schema.steps_status_col, schema.steps_payload_col]
    if schema.steps_type_col:
        cols.append(schema.steps_type_col)
    try:
        row = conn.execute(
            f"SELECT {', '.join(cols)} FROM steps ORDER BY {order_col} DESC LIMIT 1"
        ).fetchone()
    except sqlite3.Error:
        return None
    if not row:
        return None
    order = row[0]
    status = row[1]
    payload = row[2]
    step_type = row[3] if len(row) > 3 else None
    if not isinstance(status, int) or status == STEP_STATUS_DONE:
        return None
    if status not in STEP_STATUS_LIVE:
        return None
    return {
        "stepIdx": int(order) if isinstance(order, int) else None,
        "status": status,
        "stepType": step_type,
        "outputChars": _proto_text_chars(payload),
    }


def _estimate_chars_per_token(
    conn: sqlite3.Connection, schema: Optional[DbSchema] = None, limit: int = 24
) -> Optional[float]:
    """Calibrate streamed characters to tokens using completed steps."""
    schema = schema or _detect_schema(conn)
    if not schema.steps_blob_col or not schema.steps_payload_col:
        return None
    order_col = schema.steps_order_col or "rowid"
    try:
        rows = conn.execute(
            f"SELECT {schema.steps_payload_col}, {schema.steps_blob_col} FROM steps "
            f"WHERE {schema.steps_blob_col} IS NOT NULL ORDER BY {order_col} DESC LIMIT ?",
            (limit,),
        ).fetchall()
    except sqlite3.Error:
        return None
    chars = 0
    tokens = 0
    for payload, meta in rows:
        usage = _usage_from_metadata(meta)
        if not usage or usage["outputTokens"] <= 0:
            continue
        count = _proto_text_chars(payload)
        if not count:
            continue
        chars += count
        tokens += usage["outputTokens"]
    if chars <= 0 or tokens <= 0:
        return None
    return min(6.0, max(0.4, float(chars) / float(tokens)))


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
    tracker = TranscriptTracker(transcript_path)
    try:
        with transcript_path.open("r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    tracker._ingest(json.loads(line))
                except ValueError:
                    continue
    except OSError:
        return {}
    return tracker.snapshot()


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


# --- quota reset windows ----------------------------------------------------
# Antigravity Desktop never exposes quota to plugins, but the CLI statusline
# payload carries it (remaining_fraction + reset_in_seconds) and main.zig caches
# that payload on every render. Reading it here turns AGY's relative
# "resets in 2d 4h" into an absolute local reset time for the sidebar panel.

QUOTA_CACHE_ENV = "AGY_STATUSLINE_QUOTA_FILE"
QUOTA_PERIOD_SEC: dict[str, int] = {"5h": 5 * 3600, "weekly": 7 * 86400}
QUOTA_POOL_ORDER = ("gemini", "argon", "claude")
QUOTA_WINDOW_ORDER = ("5h", "weekly", "other")
QUOTA_STALE_SEC = 6 * 3600
_QUOTA_ROLL_LIMIT = 10_000


def get_quota_cache_path() -> Path:
    override = os.environ.get(QUOTA_CACHE_ENV)
    if override:
        return Path(override)
    return Path.home() / ".gemini" / "agy-statusline" / "quota.json"


def _quota_pool(key: str) -> Optional[str]:
    low = key.lower()
    if "argon" in low:
        return "argon"
    if "gemini" in low or "hydrogen" in low or "flash" in low:
        return "gemini"
    if any(token in low for token in ("3p", "claude", "gpt", "anthropic")):
        return "claude"
    return None


def _quota_window(key: str) -> str:
    low = key.lower()
    if "5h" in low:
        return "5h"
    if "weekly" in low:
        return "weekly"
    return "other"


def _iso_utc(epoch: Optional[int]) -> Optional[str]:
    if epoch is None:
        return None
    try:
        return datetime.fromtimestamp(epoch, tz=timezone.utc).isoformat()
    except (OverflowError, OSError, ValueError):
        return None


def _as_epoch(raw: Any) -> Optional[int]:
    if isinstance(raw, bool) or not isinstance(raw, (int, float)):
        return None
    return int(raw)


def load_quota_snapshot(now: Optional[datetime] = None) -> Optional[dict[str, Any]]:
    """Resolve the quota cache written by the CLI statusline into reset times.

    A window that already reset while the snapshot sat unread is rolled forward
    by whole periods, so even a week-old file still yields the correct next
    reset clock time (flagged ``approx``). Returned times are epoch seconds; the
    panel formats them in the viewer's local timezone.
    """
    path = get_quota_cache_path()
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(raw, dict):
        return None
    buckets = raw.get("buckets")
    if not isinstance(buckets, list):
        return None
    observed_ts = _as_epoch(raw.get("observed_at"))
    if observed_ts is None:
        return None
    now_ts = int((now or datetime.now(timezone.utc)).timestamp())

    # One row per (pool, window); keep the most constrained bucket, matching the
    # CLI's "lowest remaining fraction wins" rule.
    best: dict[tuple[str, str], tuple[float, Optional[int], str]] = {}
    for item in buckets:
        if not isinstance(item, dict):
            continue
        key = str(item.get("key") or "")
        frac_raw = item.get("remaining_fraction")
        if isinstance(frac_raw, bool) or not isinstance(frac_raw, (int, float)):
            continue
        pool = _quota_pool(key)
        if pool is None:
            continue
        frac = min(1.0, max(0.0, float(frac_raw)))
        window = _quota_window(key)
        slot = best.get((pool, window))
        if slot is None or frac < slot[0] - 1e-9:
            best[(pool, window)] = (frac, _as_epoch(item.get("reset_at")), key)

    rows: list[dict[str, Any]] = []
    for (pool, window), (frac, reset_at, key) in best.items():
        rolled = 0
        period = QUOTA_PERIOD_SEC.get(window)
        if reset_at is not None and period:
            while reset_at <= now_ts and rolled < _QUOTA_ROLL_LIMIT:
                reset_at += period
                rolled += 1
        rows.append(
            {
                "pool": pool,
                "window": window,
                "bucket": key,
                "remainingPct": round(frac * 100.0, 1),
                "resetAt": _iso_utc(reset_at),
                "resetAtEpoch": reset_at,
                "resetInSec": (reset_at - now_ts) if reset_at is not None else None,
                "approx": rolled > 0,
            }
        )
    if not rows:
        return None
    rows.sort(
        key=lambda row: (
            QUOTA_POOL_ORDER.index(row["pool"]) if row["pool"] in QUOTA_POOL_ORDER else 99,
            QUOTA_WINDOW_ORDER.index(row["window"])
            if row["window"] in QUOTA_WINDOW_ORDER
            else 99,
        )
    )
    age = max(0, now_ts - observed_ts)
    return {
        "source": str(raw.get("source") or "agy-statusline"),
        "observedAt": _iso_utc(observed_ts),
        "observedAgeSec": age,
        "stale": age > QUOTA_STALE_SEC,
        "windows": rows,
    }


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


def _file_sig(path: Path) -> tuple[int, int, int, int]:
    """Detect changes and replacements, even when mtime and size are preserved."""
    try:
        st = path.stat()
    except OSError:
        return (0, 0, 0, 0)
    return (st.st_dev, st.st_ino, st.st_mtime_ns, st.st_size)


@dataclass
class DbSchema:
    version: int = -1
    has_gen_metadata: bool = False
    steps_blob_col: Optional[str] = None
    steps_order_col: Optional[str] = None
    steps_payload_col: Optional[str] = None
    steps_type_col: Optional[str] = None
    steps_status_col: Optional[str] = None


def _detect_schema(conn: sqlite3.Connection) -> DbSchema:
    version = conn.execute("PRAGMA schema_version").fetchone()[0]
    tables = {row[0] for row in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table'"
    ).fetchall()}
    blob_col: Optional[str] = None
    order_col: Optional[str] = None
    payload_col: Optional[str] = None
    type_col: Optional[str] = None
    status_col: Optional[str] = None
    if "steps" in tables:
        cols = [row[1] for row in conn.execute("PRAGMA table_info(steps)").fetchall()]
        blob_col = "metadata" if "metadata" in cols else ("data" if "data" in cols else None)
        order_col = "idx" if "idx" in cols else ("step_idx" if "step_idx" in cols else "rowid")
        payload_col = "step_payload" if "step_payload" in cols else blob_col
        type_col = "step_type" if "step_type" in cols else None
        status_col = "status" if "status" in cols else None
    return DbSchema(
        version=version,
        has_gen_metadata="gen_metadata" in tables,
        steps_blob_col=blob_col,
        steps_order_col=order_col,
        steps_payload_col=payload_col,
        steps_type_col=type_col,
        steps_status_col=status_col,
    )


def _token_count(value: Any) -> Optional[int]:
    return value if type(value) is int and 0 <= value <= 2**53 - 1 else None


def _model_key(value: Any) -> str:
    if not isinstance(value, str) or not value.strip():
        return "未知模型"
    # These suffixes describe effort, not different served models.
    return re.sub(r"-(minimal|low|medium|high|max)$", "", value.strip())


def _empty_usage() -> dict[str, Any]:
    return {
        "requestCount": 0,
        "recordedCount": 0,
        "inputTokens": 0,
        "cacheReadTokens": 0,
        "outputTokens": 0,
    }


def _usage_summary(usage: dict[str, Any]) -> dict[str, Any]:
    result = dict(usage)
    recorded = result["recordedCount"]
    total_input = result["inputTokens"] + result["cacheReadTokens"]
    result["totalTokens"] = total_input + result["outputTokens"] if recorded else None
    result["cacheHitPct"] = 100.0 * result["cacheReadTokens"] / total_input if total_input else None
    if not recorded:
        for key in ("inputTokens", "cacheReadTokens", "outputTokens"):
            result[key] = None
    return result


class TranscriptTracker:
    """Line-incremental reader for transcript.jsonl.

    Only bytes appended since the previous call are parsed, so a long session
    does not re-read megabytes on every poll. Aggregates match
    parse_transcript_timing() exactly.
    """

    def __init__(self, path: Path) -> None:
        self.path = path
        self._reset()

    def _reset(self) -> None:
        self._identity: Optional[tuple[int, int]] = None
        self.offset = 0
        self.first_ts: Optional[datetime] = None
        self.last_ts: Optional[datetime] = None
        self.last_user_ts: Optional[datetime] = None
        self.step_count = 0
        self.turn_count = 0
        self.last_user_preview = ""
        self.usage = _empty_usage()
        self.model_usage: dict[str, dict[str, Any]] = {}
        self.context_history: list[dict[str, Any]] = []
        self.compaction_count = 0
        self.latest_usage: Optional[dict[str, Any]] = None

    def _ingest(self, item: Any) -> None:
        if not isinstance(item, dict):
            return
        self.step_count += 1
        ts = _parse_iso_ts(item.get("created_at"))
        if ts is not None:
            if self.first_ts is None or ts < self.first_ts:
                self.first_ts = ts
            if self.last_ts is None or ts > self.last_ts:
                self.last_ts = ts
        step_type = str(item.get("type") or "")
        source = str(item.get("source") or "")
        if step_type == "USER_INPUT" or source == "USER_EXPLICIT":
            self.turn_count += 1
            if ts is not None:
                self.last_user_ts = ts
            content = str(item.get("content") or "").strip().splitlines()
            if content:
                self.last_user_preview = content[0][:60]

        if step_type not in ("PLANNER_RESPONSE", "CHECKPOINT") or item.get("status") != "DONE":
            return
        model = _model_key(item.get("model"))
        group = self.model_usage.setdefault(model, _empty_usage())
        values = [_token_count(item.get(k)) for k in ("input_tokens", "cache_read_tokens", "output_tokens")]
        for usage in (self.usage, group):
            usage["requestCount"] += 1
            if all(v is not None for v in values):
                usage["recordedCount"] += 1
                for key, val in zip(("inputTokens", "cacheReadTokens", "outputTokens"), values):
                    usage[key] += val
        checkpoint = step_type == "CHECKPOINT"
        if not checkpoint:
            self.latest_usage = {"inputTokens": values[0], "cacheReadTokens": values[1], "outputTokens": values[2]}
            inp = sum(values[:2]) if all(v is not None for v in values[:2]) else 0
            self.latest_usage["cacheHitPct"] = 100.0 * values[1] / inp if inp else None
            self.latest_usage["totalTokens"] = sum(values) if all(v is not None for v in values) else None
        if checkpoint:
            self.compaction_count += 1
        self.context_history.append({
            "request": self.usage["requestCount"],
            "stepIdx": item.get("step_index") if type(item.get("step_index")) is int else None,
            "at": ts.isoformat() if ts else None,
            "model": model,
            "contextUsed": sum(values[:2]) if not checkpoint and all(v is not None for v in values[:2]) else None,
            "compaction": checkpoint,
        })
        # Keep the panel response bounded; session totals still cover the whole log.
        self.context_history = self.context_history[-120:]

    def update(self) -> dict[str, Any]:
        with self.path.open("rb") as fh:
            st = os.fstat(fh.fileno())
            identity = (st.st_dev, st.st_ino)
            if identity != self._identity or st.st_size < self.offset:
                self._reset()
            self._identity = identity
            fh.seek(self.offset)
            chunk = fh.read()
        if chunk:
            cut = chunk.rfind(b"\n")
            if cut >= 0:
                complete = chunk[: cut + 1]
                self.offset += len(complete)
                for raw in complete.split(b"\n"):
                    raw = raw.strip()
                    if not raw:
                        continue
                    try:
                        self._ingest(json.loads(raw.decode("utf-8", errors="replace")))
                    except ValueError:
                        continue
        return self.snapshot()

    def snapshot(self) -> dict[str, Any]:
        session_sec = (
            (self.last_ts - self.first_ts).total_seconds()
            if (self.first_ts and self.last_ts)
            else None
        )
        turn_sec = (
            (self.last_ts - self.last_user_ts).total_seconds()
            if (self.last_user_ts and self.last_ts)
            else None
        )
        if session_sec is not None and session_sec < 0:
            session_sec = None
        if turn_sec is not None and turn_sec < 0:
            turn_sec = None
        return {
            "sessionDurationSec": session_sec,
            "turnDurationSec": turn_sec,
            "turnCount": self.turn_count,
            "stepCount": self.step_count,
            "lastUserPreview": self.last_user_preview,
            "lastActivityAt": self.last_ts.isoformat() if self.last_ts else None,
            "lastUserInputAt": self.last_user_ts.isoformat() if self.last_user_ts else None,
            "sessionUsage": _usage_summary(self.usage),
            "latestUsage": self.latest_usage,
            "modelUsage": [{"model": model, **_usage_summary(usage)} for model, usage in self.model_usage.items()],
            "contextHistory": list(self.context_history),
            "compactionCount": self.compaction_count,
        }


class TelemetryRuntime:
    """Warm state for the long-lived serve loop.

    Keeps SQLite connections + detected schemas, incremental transcript
    trackers and the last snapshot per conversation, so an unchanged poll
    costs a few stat() calls instead of a full rebuild.
    """

    def __init__(self, max_snapshots: int = 16) -> None:
        self._dbs: dict[str, tuple[sqlite3.Connection, DbSchema, tuple[int, int]]] = {}
        self._transcripts: dict[str, TranscriptTracker] = {}
        self._snapshots: dict[str, tuple[tuple[Any, ...], dict[str, Any]]] = {}
        self._live_samples: dict[str, list[tuple[float, int]]] = {}
        self._max_snapshots = max_snapshots

    def live_rate(
        self, key: str, step_idx: Optional[int], chars: Optional[int], now_ts: float
    ) -> Optional[float]:
        """Characters/second for the in-flight step, measured between polls.

        Keeps a short rolling window of (timestamp, characters) samples so the
        rate stays smooth across the fixed poll interval and resets whenever a
        new step starts.
        """
        if chars is None or step_idx is None:
            self._live_samples.pop(key, None)
            return None
        samples = self._live_samples.get(key)
        if samples is None or samples[0][1] > chars:
            samples = []
        samples.append((now_ts, chars))
        while len(samples) > LIVE_RATE_MAX_SAMPLES:
            samples.pop(0)
        while len(samples) > 2 and now_ts - samples[0][0] > LIVE_RATE_WINDOW_SEC:
            samples.pop(0)
        self._live_samples[key] = samples
        if len(samples) < 2:
            return None
        dt = samples[-1][0] - samples[0][0]
        dc = samples[-1][1] - samples[0][1]
        if len(self._live_samples) > 64:
            for stale in list(self._live_samples)[:32]:
                self._live_samples.pop(stale, None)
        if dt <= 0.05 or dc < 0:
            return None
        return dc / dt

    def reset_live(self, key: str) -> None:
        self._live_samples.pop(key, None)

    def connection(self, db_path: Path) -> tuple[sqlite3.Connection, DbSchema]:
        key = str(db_path)
        identity = _file_sig(db_path)[:2]
        cached = self._dbs.get(key)
        if cached is not None and cached[2] != identity:
            # An open SQLite connection keeps reading the old file after replacement.
            self._dbs.pop(key)
            cached[0].close()
            cached = None
        if cached is not None:
            conn, schema, _ = cached
            if conn.execute("PRAGMA schema_version").fetchone()[0] != schema.version:
                schema = _detect_schema(conn)
                cached = (conn, schema, identity)
                self._dbs[key] = cached
            return conn, schema
        conn = _open_sqlite_ro(db_path)
        if conn is None:
            raise sqlite3.Error(f"cannot open {db_path}")
        try:
            schema = _detect_schema(conn)
        except sqlite3.Error:
            conn.close()
            raise
        if len(self._dbs) >= self._max_snapshots:
            oldest = next(iter(self._dbs))
            old_conn, _, _ = self._dbs.pop(oldest)
            old_conn.close()
        self._dbs[key] = (conn, schema, identity)
        return conn, schema

    def transcript(self, path: Path) -> TranscriptTracker:
        key = str(path)
        tracker = self._transcripts.get(key)
        if tracker is None:
            tracker = TranscriptTracker(path)
            if len(self._transcripts) >= self._max_snapshots:
                self._transcripts.pop(next(iter(self._transcripts)))
            self._transcripts[key] = tracker
        return tracker

    def cached(self, target_id: str, fingerprint: tuple[Any, ...]) -> Optional[dict[str, Any]]:
        hit = self._snapshots.get(target_id)
        if hit is None or hit[0] != fingerprint:
            return None
        snap = dict(hit[1])
        snap["generatedAt"] = datetime.now(timezone.utc).isoformat()
        snap["cacheHit"] = True
        return snap

    def remember(self, target_id: str, fingerprint: tuple[Any, ...], snap: dict[str, Any]) -> None:
        if len(self._snapshots) >= self._max_snapshots and target_id not in self._snapshots:
            self._snapshots.pop(next(iter(self._snapshots)), None)
        self._snapshots[target_id] = (fingerprint, snap)

    def close(self) -> None:
        for conn, _, _ in self._dbs.values():
            try:
                conn.close()
            except sqlite3.Error:
                pass
        self._dbs.clear()
        self._transcripts.clear()
        self._snapshots.clear()


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
                "lastEvent": str(meta.get("lastEvent") or ""),
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
            "lastEvent": str(meta.get("lastEvent") or ""),
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


def _build_live_block(
    live_step: Optional[dict[str, Any]],
    chars_per_token: Optional[float],
    timing: dict[str, Any],
    conversation_id: str,
    runtime: Optional["TelemetryRuntime"],
) -> dict[str, Any]:
    """Assemble the streaming metrics block for the panel."""
    if not live_step:
        return {"active": False}
    now_dt = datetime.now(timezone.utc)
    elapsed: Optional[float] = None
    started = _parse_iso_ts(timing.get("lastUserInputAt"))
    if started is not None:
        elapsed = max(0.0, (now_dt - started).total_seconds())
    rate: Optional[float] = None
    if runtime is not None:
        key = f"{conversation_id}:{live_step.get('stepIdx')}"
        rate = runtime.live_rate(
            key, live_step.get("stepIdx"), live_step.get("outputChars"), now_dt.timestamp()
        )
    cpt = chars_per_token or DEFAULT_CHARS_PER_TOKEN
    return {
        "active": True,
        "stepIdx": live_step.get("stepIdx"),
        "stepType": live_step.get("stepType"),
        "status": live_step.get("status"),
        "outputChars": live_step.get("outputChars"),
        "charsPerSec": round(rate, 1) if rate is not None else None,
        "charsPerToken": round(cpt, 2),
        "estTokPerSec": round(rate / cpt, 1) if rate is not None else None,
        "elapsedSec": round(elapsed, 1) if elapsed is not None else None,
        "observedAt": now_dt.isoformat(),
    }


def build_status_snapshot(
    conversation_id: Optional[str] = None,
    data_dir: Optional[Path] = None,
    desktop_root: Optional[Path] = None,
    runtime: Optional["TelemetryRuntime"] = None,
) -> dict[str, Any]:
    """Assemble a complete read-only telemetry snapshot for the desktop UI panel.

    When ``runtime`` is supplied (the long-lived serve loop), SQLite connections,
    detected schemas, transcript offsets and the last snapshot are reused, and an
    unchanged poll returns the cached snapshot without re-parsing anything.
    """
    root = desktop_root or get_desktop_root()
    hook_state = _load_hook_state(data_dir)
    sessions_meta = hook_state.get("sessions") if isinstance(hook_state.get("sessions"), dict) else {}
    active_id = str(hook_state.get("activeConversationId") or "")

    target_id = (conversation_id or "").strip()
    if target_id in ("", "auto"):
        target_id = active_id

    recent: Optional[list[dict[str, Any]]] = None
    if not target_id:
        recent = list_recent_conversations(root, hook_state)
        if recent:
            target_id = recent[0]["conversationId"]

    if not target_id or not UUID_RE.match(target_id):
        return {
            "found": False,
            "conversationId": "",
            "recentConversations": recent if recent is not None else list_recent_conversations(root, hook_state),
            "hookConnected": bool(active_id),
            "generatedAt": datetime.now(timezone.utc).isoformat(),
            "quota": load_quota_snapshot(),
            "live": {"active": False},
            "message": "No local Antigravity Desktop conversation found yet.",
        }

    session_meta = sessions_meta.get(target_id) if isinstance(sessions_meta.get(target_id), dict) else {}
    db_path = root / "conversations" / f"{target_id}.db"
    transcript_path = _resolve_transcript_path(root, target_id, session_meta)

    hook_state_path = data_dir / "active_session.json" if data_dir is not None else None
    fingerprint: tuple[Any, ...] = (
        target_id,
        active_id,
        _file_sig(db_path),
        _file_sig(db_path.with_name(db_path.name + "-wal")),
        _file_sig(transcript_path) if transcript_path else (0, 0, 0, 0),
        _file_sig(hook_state_path) if hook_state_path else (0, 0, 0, 0),
    )
    if runtime is not None:
        cached = runtime.cached(target_id, fingerprint)
        if cached is not None:
            # The conversation list also depends on files outside this session.
            cached["recentConversations"] = list_recent_conversations(root, hook_state)
            # Quota is refreshed on every poll: its snapshot lives outside the session.
            cached["quota"] = load_quota_snapshot()
            return cached

    gen_records: list[GenRecord] = []
    speeds: dict[str, tuple[int, float, int]] = {}
    steps_usage: Optional[dict[str, int]] = None
    live_step: Optional[dict[str, Any]] = None
    chars_per_token: Optional[float] = None
    db_readable = False
    cacheable = True
    if db_path.is_file():
        conn: Optional[sqlite3.Connection] = None
        schema: Optional[DbSchema] = None
        owns_conn = runtime is None
        try:
            if runtime is not None:
                conn, schema = runtime.connection(db_path)
            else:
                conn = _open_sqlite_ro(db_path)
            if conn is not None:
                db_readable = True
                # Aggregate all samples without retaining the session's raw blobs
                # or decoded records. Only the recent chart needs individual rows.
                for rec in _read_gen_records(conn, limit=-1, schema=schema):
                    if len(gen_records) < 12:
                        gen_records.append(rec)
                    if rec.served_model and rec.speed_tok_s is not None and rec.output_tokens:
                        key = _model_key(rec.served_model)
                        tokens, seconds, count = speeds.get(key, (0, 0.0, 0))
                        speeds[key] = (tokens + rec.output_tokens, seconds + rec.output_tokens / rec.speed_tok_s, count + 1)
                steps_usage = _read_latest_steps_usage(conn, limit=40, schema=schema)
                live_step = _read_live_step(conn, schema)
                if live_step is not None:
                    chars_per_token = _estimate_chars_per_token(conn, schema)
                    # Streaming state changes every poll; never serve it from cache.
                    cacheable = False
            else:
                cacheable = False
        except sqlite3.Error:
            cacheable = False
        finally:
            if owns_conn and conn is not None:
                conn.close()

    if transcript_path:
        if runtime is not None:
            try:
                timing = runtime.transcript(transcript_path).update()
            except OSError:
                timing = {}
                cacheable = False
        else:
            timing = parse_transcript_timing(transcript_path)
    else:
        timing = {}

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
        for rec in gen_records[:12]
    ]

    model_usage = timing.get("modelUsage", [])
    model_usage = [dict(group) for group in model_usage]
    for group in model_usage:
        tokens, seconds, count = speeds.get(group["model"], (0, 0.0, 0))
        group["avgSpeedTokS"] = round(tokens / seconds, 1) if seconds else None
        group["speedSamples"] = count

    workspace_paths = session_meta.get("workspacePaths") or []
    workspace_name = ""
    if workspace_paths:
        workspace_name = Path(str(workspace_paths[0])).name
    elif session_meta.get("cwd"):
        workspace_name = Path(str(session_meta["cwd"])).name

    live_block = _build_live_block(live_step, chars_per_token, timing, target_id, runtime)

    snap = {
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
        "sessionUsage": timing.get("sessionUsage"),
        "latestUsage": timing.get("latestUsage"),
        "modelUsage": model_usage,
        "contextHistory": timing.get("contextHistory", []),
        "compactionCount": timing.get("compactionCount"),
        "history": history,
        "lastActivityAt": timing.get("lastActivityAt"),
        "recentConversations": recent if recent is not None else list_recent_conversations(root, hook_state),
        "quota": load_quota_snapshot(),
        "live": live_block,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
    }
    if runtime is not None and cacheable:
        runtime.remember(target_id, fingerprint, snap)
    return snap


def _serve(data_dir: Optional[Path], desktop_root: Optional[Path]) -> int:
    """Long-lived worker: one JSON request per stdin line, one JSON line back.

    Paying interpreter startup once instead of once per poll is the single
    biggest win for the desktop panel (40ms -> a few ms per request).
    """
    runtime = TelemetryRuntime()
    stdin = sys.stdin
    stdout = sys.stdout
    for stream in (stdin, stdout):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[attr-defined]
        except (AttributeError, ValueError):
            pass
    try:
        for raw in stdin:
            line = raw.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
            except ValueError:
                req = {}
            if not isinstance(req, dict):
                req = {}
            if str(req.get("op") or "") == "close":
                break
            conv = req.get("conversationId")
            try:
                snap: dict[str, Any] = build_status_snapshot(
                    conversation_id=conv if isinstance(conv, str) else None,
                    data_dir=data_dir,
                    desktop_root=desktop_root,
                    runtime=runtime,
                )
            except Exception as exc:  # noqa: BLE001 - never kill the worker
                snap = {
                    "error": f"{type(exc).__name__}: {exc}",
                    "generatedAt": datetime.now(timezone.utc).isoformat(),
                }
            stdout.write(json.dumps(snap, ensure_ascii=False) + "\n")
            stdout.flush()
    finally:
        runtime.close()
    return 0


def _main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description="Read-only Antigravity Desktop telemetry snapshot")
    parser.add_argument("--conversation-id", default="auto")
    parser.add_argument("--data-dir", default="")
    parser.add_argument("--desktop-root", default="")
    parser.add_argument("--serve", action="store_true", help="stay alive and answer JSON-lines requests on stdin")
    args = parser.parse_args()

    data_dir = Path(args.data_dir) if args.data_dir else None
    desktop_root = Path(args.desktop_root) if args.desktop_root else None
    if args.serve:
        return _serve(data_dir, desktop_root)

    snap = build_status_snapshot(
        conversation_id=args.conversation_id or None,
        data_dir=data_dir,
        desktop_root=desktop_root,
    )
    print(json.dumps(snap, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
