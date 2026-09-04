"""SQLite storage for notes and recordings. Uses only the Python standard library.

The database is a single file under DATA_DIR (default: data/ainotetaker.db) and is
git-ignored. Recording audio files live next to it under data/recordings/.
"""
from __future__ import annotations

import json
import sqlite3
import uuid
from datetime import datetime, timezone
from typing import Any, Iterable, Optional

from .config import settings

RECORDING_STATUSES = ("uploaded", "processing", "done", "error")

_RECORDING_UPDATABLE = {
    "title", "original_name", "original_path", "denoised_path", "mime", "duration",
    "size", "status", "error", "transcript", "analysis", "note_id", "denoise_engine",
    "transcription_provider", "transcription_model",
    "transcript_corrected",
}


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(settings.db_path, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA foreign_keys=ON;")
    return conn


def init_db() -> None:
    """Create the schema if it does not exist yet."""
    with _connect() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS notes (
                id         TEXT PRIMARY KEY,
                title      TEXT NOT NULL DEFAULT '',
                content    TEXT NOT NULL DEFAULT '',
                pinned     INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_notes_updated ON notes(pinned DESC, updated_at DESC)"
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS recordings (
                id             TEXT PRIMARY KEY,
                client_id      TEXT,
                title          TEXT NOT NULL DEFAULT '',
                original_name  TEXT NOT NULL DEFAULT '',
                original_path  TEXT NOT NULL,
                denoised_path  TEXT,
                mime           TEXT NOT NULL DEFAULT '',
                duration       REAL,
                size           INTEGER NOT NULL DEFAULT 0,
                status         TEXT NOT NULL DEFAULT 'uploaded',
                error          TEXT,
                transcript     TEXT,
                transcription_provider TEXT,
                transcription_model    TEXT,
                transcript_corrected   INTEGER NOT NULL DEFAULT 0,
                analysis       TEXT,
                note_id        TEXT,
                denoise_engine TEXT,
                created_at     TEXT NOT NULL,
                updated_at     TEXT NOT NULL
            )
            """
        )
        # Existing installations predate client_id. Keep this migration
        # additive so upgrading never rebuilds or risks the recordings table.
        columns = {row["name"] for row in conn.execute("PRAGMA table_info(recordings)")}
        if "client_id" not in columns:
            conn.execute("ALTER TABLE recordings ADD COLUMN client_id TEXT")
        if "transcription_provider" not in columns:
            conn.execute("ALTER TABLE recordings ADD COLUMN transcription_provider TEXT")
        if "transcription_model" not in columns:
            conn.execute("ALTER TABLE recordings ADD COLUMN transcription_model TEXT")
        if "transcript_corrected" not in columns:
            conn.execute("ALTER TABLE recordings ADD COLUMN transcript_corrected INTEGER NOT NULL DEFAULT 0")
        conn.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_recordings_client_id "
            "ON recordings(client_id) WHERE client_id IS NOT NULL"
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_recordings_created ON recordings(created_at DESC)"
        )
        conn.commit()


def recover_interrupted_recordings() -> int:
    """Mark processing jobs lost during a server restart as safe to retry."""
    message = "Processing was interrupted by a server restart. Re-run processing."
    with _connect() as conn:
        cur = conn.execute(
            "UPDATE recordings SET status = 'error', error = ?, updated_at = ? "
            "WHERE status = 'processing'",
            (message, _now_iso()),
        )
        conn.commit()
        return cur.rowcount


# ───────────────────────────── Notes ───────────────────────────── #
def _row_to_dict(row: sqlite3.Row) -> dict[str, Any]:
    d = dict(row)
    d["pinned"] = bool(d.get("pinned", 0))
    return d


def _make_snippet(content: str, limit: int = 120) -> str:
    """First non-empty line(s) of the body, condensed for the list view."""
    text = " ".join(content.split())
    return text[:limit]


def list_notes(query: str = "") -> list[dict[str, Any]]:
    """Return notes (newest first, pinned on top). Optional case-insensitive search."""
    query = (query or "").strip()
    with _connect() as conn:
        if query:
            like = f"%{query}%"
            rows = conn.execute(
                """
                SELECT * FROM notes
                WHERE title LIKE ? COLLATE NOCASE OR content LIKE ? COLLATE NOCASE
                ORDER BY pinned DESC, updated_at DESC
                """,
                (like, like),
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM notes ORDER BY pinned DESC, updated_at DESC"
            ).fetchall()

    notes = []
    for row in rows:
        d = _row_to_dict(row)
        notes.append(
            {
                "id": d["id"],
                "title": d["title"],
                "snippet": _make_snippet(d["content"]),
                "pinned": d["pinned"],
                "created_at": d["created_at"],
                "updated_at": d["updated_at"],
            }
        )
    return notes


def list_notes_full(ids: Optional[Iterable[str]] = None) -> list[dict[str, Any]]:
    """Full notes (with content), newest first. Optionally restricted to ids."""
    with _connect() as conn:
        if ids:
            id_list = list(ids)
            marks = ",".join("?" for _ in id_list)
            rows = conn.execute(
                f"SELECT * FROM notes WHERE id IN ({marks}) ORDER BY updated_at DESC", id_list
            ).fetchall()
        else:
            rows = conn.execute("SELECT * FROM notes ORDER BY updated_at DESC").fetchall()
    return [_row_to_dict(r) for r in rows]


def get_note(note_id: str) -> Optional[dict[str, Any]]:
    with _connect() as conn:
        row = conn.execute("SELECT * FROM notes WHERE id = ?", (note_id,)).fetchone()
    return _row_to_dict(row) if row else None


def create_note(title: str = "", content: str = "") -> dict[str, Any]:
    note_id = uuid.uuid4().hex
    now = _now_iso()
    with _connect() as conn:
        conn.execute(
            "INSERT INTO notes (id, title, content, pinned, created_at, updated_at) "
            "VALUES (?, ?, ?, 0, ?, ?)",
            (note_id, title, content, now, now),
        )
        conn.commit()
    return get_note(note_id)  # type: ignore[return-value]


def update_note(
    note_id: str,
    *,
    title: Optional[str] = None,
    content: Optional[str] = None,
    pinned: Optional[bool] = None,
) -> Optional[dict[str, Any]]:
    """Patch-update a note. Only provided fields change; updated_at bumps."""
    existing = get_note(note_id)
    if existing is None:
        return None

    new_title = existing["title"] if title is None else title
    new_content = existing["content"] if content is None else content
    new_pinned = existing["pinned"] if pinned is None else bool(pinned)

    with _connect() as conn:
        conn.execute(
            "UPDATE notes SET title = ?, content = ?, pinned = ?, updated_at = ? WHERE id = ?",
            (new_title, new_content, 1 if new_pinned else 0, _now_iso(), note_id),
        )
        conn.commit()
    return get_note(note_id)


def delete_note(note_id: str) -> bool:
    with _connect() as conn:
        cur = conn.execute("DELETE FROM notes WHERE id = ?", (note_id,))
        conn.commit()
        return cur.rowcount > 0


# ─────────────────────────── Recordings ────────────────────────── #
def _row_to_recording(row: sqlite3.Row) -> dict[str, Any]:
    d = dict(row)
    d["transcript_corrected"] = bool(d.get("transcript_corrected", 0))
    raw = d.get("analysis")
    if raw:
        try:
            d["analysis"] = json.loads(raw)
        except (TypeError, ValueError):
            d["analysis"] = None
    else:
        d["analysis"] = None
    d["has_denoised"] = bool(d.get("denoised_path"))
    return d


def create_recording(
    *, title: str, original_name: str, original_path: str, mime: str, size: int,
    client_id: Optional[str] = None,
) -> dict[str, Any]:
    rec_id = uuid.uuid4().hex
    now = _now_iso()
    with _connect() as conn:
        conn.execute(
            """
            INSERT INTO recordings
                (id, client_id, title, original_name, original_path, mime, size, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'uploaded', ?, ?)
            """,
            (rec_id, client_id, title, original_name, original_path, mime, int(size), now, now),
        )
        conn.commit()
    return get_recording(rec_id)  # type: ignore[return-value]


def get_recording(rec_id: str) -> Optional[dict[str, Any]]:
    with _connect() as conn:
        row = conn.execute("SELECT * FROM recordings WHERE id = ?", (rec_id,)).fetchone()
    return _row_to_recording(row) if row else None


def get_recording_by_client_id(client_id: str) -> Optional[dict[str, Any]]:
    """Find an upload previously accepted for a stable device-side ID."""
    with _connect() as conn:
        row = conn.execute(
            "SELECT * FROM recordings WHERE client_id = ?", (client_id,)
        ).fetchone()
    return _row_to_recording(row) if row else None


def list_recordings() -> list[dict[str, Any]]:
    """Lightweight listing for the library view (no transcript bodies)."""
    with _connect() as conn:
        rows = conn.execute(
            "SELECT * FROM recordings ORDER BY created_at DESC"
        ).fetchall()
    out = []
    for row in rows:
        d = _row_to_recording(row)
        transcript = d.get("transcript") or ""
        out.append(
            {
                "id": d["id"],
                "title": d["title"],
                "duration": d["duration"],
                "size": d["size"],
                "status": d["status"],
                "error": d["error"],
                "has_transcript": bool(transcript),
                "has_analysis": d["analysis"] is not None,
                "has_denoised": d["has_denoised"],
                "transcription_provider": d.get("transcription_provider"),
                "transcription_model": d.get("transcription_model"),
                "transcript_corrected": d["transcript_corrected"],
                "snippet": _make_snippet(transcript, 160),
                "note_id": d["note_id"],
                "created_at": d["created_at"],
                "updated_at": d["updated_at"],
            }
        )
    return out


def update_recording(rec_id: str, **fields: Any) -> Optional[dict[str, Any]]:
    """Update allowed columns on a recording. `analysis` may be a dict."""
    updates = {k: v for k, v in fields.items() if k in _RECORDING_UPDATABLE}
    if "analysis" in updates and isinstance(updates["analysis"], (dict, list)):
        updates["analysis"] = json.dumps(updates["analysis"], ensure_ascii=False)
    if not updates:
        return get_recording(rec_id)
    updates["updated_at"] = _now_iso()
    assignments = ", ".join(f"{k} = ?" for k in updates)
    with _connect() as conn:
        cur = conn.execute(
            f"UPDATE recordings SET {assignments} WHERE id = ?",
            (*updates.values(), rec_id),
        )
        conn.commit()
        if cur.rowcount == 0:
            return None
    return get_recording(rec_id)


def delete_recording(rec_id: str) -> Optional[dict[str, Any]]:
    """Delete the row and return it (so the caller can remove files)."""
    existing = get_recording(rec_id)
    if existing is None:
        return None
    with _connect() as conn:
        conn.execute("DELETE FROM recordings WHERE id = ?", (rec_id,))
        conn.commit()
    return existing
