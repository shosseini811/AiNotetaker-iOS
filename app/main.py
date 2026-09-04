"""AiNotetaker FastAPI application.

Serves the web app (PWA) plus a JSON API used by both the web app and the
native iOS app: notes CRUD, recordings (upload → noise removal → chunked
multilingual transcription → AI analysis), and cross-note reports.
"""
from __future__ import annotations

import asyncio
import logging
import shutil
import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, Optional

from fastapi import (BackgroundTasks, Depends, FastAPI, File, Form, HTTPException,
                     Request, Response, UploadFile)
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from . import __version__, analysis, auth, db, network, transcription
from . import audio as audio_tools
from .config import WEB_DIR, settings

log = logging.getLogger("ainotetaker")

MAX_QUICK_AUDIO_BYTES = 25 * 1024 * 1024  # web quick-dictation blobs
ALLOWED_AUDIO_EXT = {".m4a", ".mp4", ".caf", ".wav", ".flac", ".mp3", ".aac",
                     ".ogg", ".opus", ".webm", ".aiff", ".aif"}
MIME_BY_EXT = {
    ".m4a": "audio/mp4", ".mp4": "audio/mp4", ".caf": "audio/x-caf", ".wav": "audio/wav",
    ".flac": "audio/flac", ".mp3": "audio/mpeg", ".aac": "audio/aac", ".ogg": "audio/ogg",
    ".opus": "audio/opus", ".webm": "audio/webm", ".aiff": "audio/aiff", ".aif": "audio/aiff",
}
EXT_BY_MIME = {
    "audio/mp4": ".m4a", "audio/x-m4a": ".m4a", "audio/m4a": ".m4a", "audio/aac": ".aac",
    "audio/wav": ".wav", "audio/x-wav": ".wav", "audio/wave": ".wav", "audio/flac": ".flac",
    "audio/x-flac": ".flac", "audio/mpeg": ".mp3", "audio/ogg": ".ogg", "audio/webm": ".webm",
    "audio/x-caf": ".caf",
}

@asynccontextmanager
async def _lifespan(_app: FastAPI):
    db.init_db()
    recovered = db.recover_interrupted_recordings()
    if recovered:
        log.warning("marked %d interrupted recording job(s) ready to retry", recovered)
    yield


app = FastAPI(title="AiNotetaker", version=__version__, docs_url=None, redoc_url=None,
              openapi_url=None, lifespan=_lifespan)


# ──────────────────────────── Schemas ──────────────────────────── #
class NoteCreate(BaseModel):
    title: str = ""
    content: str = ""


class NoteUpdate(BaseModel):
    title: Optional[str] = None
    content: Optional[str] = None
    pinned: Optional[bool] = None


class LoginBody(BaseModel):
    password: str = ""


class RecordingUpdate(BaseModel):
    title: Optional[str] = None
    transcript: Optional[str] = None
    refresh_analysis: bool = False


class ProcessBody(BaseModel):
    denoise: bool = True
    transcribe: bool = True
    analyze: bool = True


class ReportBody(BaseModel):
    note_ids: list[str] = []
    recording_ids: list[str] = []
    instructions: str = ""
    title: str = ""
    save_as_note: bool = False


# ──────────────────────────── Auth ─────────────────────────────── #
def _is_authenticated(request: Request) -> bool:
    if not settings.auth_required:
        return True
    header = request.headers.get("authorization", "")
    if header.lower().startswith("bearer ") and auth.check_bearer(header[7:]):
        return True
    return auth.verify_token(request.cookies.get(auth.COOKIE_NAME, ""))


def require_auth(request: Request) -> None:
    """Dependency: allow the request through, or raise 401."""
    if not _is_authenticated(request):
        raise HTTPException(status_code=401, detail="Authentication required")


def _set_session_cookie(response: Response, request: Request) -> None:
    response.set_cookie(
        key=auth.COOKIE_NAME,
        value=auth.create_session_token(),
        max_age=auth.MAX_AGE_SECONDS,
        httponly=True,
        samesite="lax",
        secure=(request.url.scheme == "https"),
        path="/",
    )


@app.get("/api/config")
def api_config(request: Request) -> dict:
    """Public: what the clients need to render (no secrets)."""
    authenticated = _is_authenticated(request)
    payload = {
        "app_title": settings.app_title,
        "auth_required": settings.auth_required,
        "authenticated": authenticated,
        "transcription_configured": settings.transcription_configured,
        "transcription_provider": settings.transcribe_provider,
        "transcription_model": transcription._model_for_provider(settings.transcribe_provider),
        "analysis_configured": settings.analysis_configured,
        "denoise_engine": audio_tools.available_denoise_engine(),
        "language": settings.transcribe_language,
        "version": __version__,
    }
    if authenticated:
        # Only a client that already holds the token learns where else this
        # Mac answers, so the tailnet name is never handed to a stranger on
        # the same coffee-shop Wi-Fi. The iPhone app saves the permanent
        # address from here and keeps working when it leaves this network.
        payload["endpoints"] = network.advertised_endpoints()
    return payload


@app.post("/api/login")
async def api_login(body: LoginBody, request: Request) -> JSONResponse:
    if settings.auth_required and not auth.check_password(body.password):
        await asyncio.sleep(0.6)  # slow down brute-force attempts
        raise HTTPException(status_code=401, detail="Incorrect password")
    resp = JSONResponse({"ok": True})
    _set_session_cookie(resp, request)
    return resp


@app.post("/api/logout")
def api_logout() -> JSONResponse:
    resp = JSONResponse({"ok": True})
    resp.delete_cookie(auth.COOKIE_NAME, path="/")
    return resp


# ──────────────────────────── Notes ────────────────────────────── #
@app.get("/api/notes", dependencies=[Depends(require_auth)])
def api_list_notes(q: str = "") -> list[dict]:
    return db.list_notes(q)


@app.post("/api/notes", dependencies=[Depends(require_auth)])
def api_create_note(body: NoteCreate) -> dict:
    return db.create_note(title=body.title, content=body.content)


@app.get("/api/notes/{note_id}", dependencies=[Depends(require_auth)])
def api_get_note(note_id: str) -> dict:
    note = db.get_note(note_id)
    if note is None:
        raise HTTPException(status_code=404, detail="Note not found")
    return note


@app.put("/api/notes/{note_id}", dependencies=[Depends(require_auth)])
def api_update_note(note_id: str, body: NoteUpdate) -> dict:
    note = db.update_note(note_id, title=body.title, content=body.content, pinned=body.pinned)
    if note is None:
        raise HTTPException(status_code=404, detail="Note not found")
    return note


@app.delete("/api/notes/{note_id}", dependencies=[Depends(require_auth)])
def api_delete_note(note_id: str) -> dict:
    if not db.delete_note(note_id):
        raise HTTPException(status_code=404, detail="Note not found")
    return {"ok": True}


# ─────────────────── Quick dictation (web app) ─────────────────── #
@app.post("/api/transcribe", dependencies=[Depends(require_auth)])
async def api_transcribe(audio: UploadFile = File(...)) -> dict:
    if not settings.transcription_configured:
        raise HTTPException(
            status_code=503,
            detail="Voice-to-text is not configured. Configure a transcription provider in .env.",
        )
    # Read at most one byte beyond the limit so an oversized request is rejected
    # without loading the entire upload into server memory.
    data = await audio.read(MAX_QUICK_AUDIO_BYTES + 1)
    if not data:
        raise HTTPException(status_code=400, detail="Empty audio upload")
    if len(data) > MAX_QUICK_AUDIO_BYTES:
        raise HTTPException(status_code=413, detail="Audio file too large")
    ctype = (audio.content_type or "audio/wav").lower()
    fmt = "flac" if "flac" in ctype else "wav"
    try:
        text = await transcription.transcribe(data, ctype, fmt)
    except transcription.TranscriptionError as exc:
        raise HTTPException(status_code=502, detail=str(exc))
    return {"text": text}


# ──────────────────────────── Recordings ───────────────────────── #
def _ext_for_upload(upload: UploadFile) -> str:
    suffix = Path(upload.filename or "").suffix.lower()
    if suffix in ALLOWED_AUDIO_EXT:
        return suffix
    ctype = (upload.content_type or "").split(";")[0].strip().lower()
    return EXT_BY_MIME.get(ctype, ".m4a")


def _require_recording(rec_id: str) -> dict:
    rec = db.get_recording(rec_id)
    if rec is None:
        raise HTTPException(status_code=404, detail="Recording not found")
    return rec


def _remove_recording_files(rec: dict) -> None:
    for key in ("original_path", "denoised_path"):
        path = rec.get(key)
        if path:
            Path(path).unlink(missing_ok=True)
    shutil.rmtree(settings.work_dir / rec["id"], ignore_errors=True)


async def _process_recording(rec_id: str, do_denoise: bool, do_transcribe: bool, do_analyze: bool) -> None:
    """Background pipeline: decode → (denoise) → (transcribe) → (analyze)."""
    rec = db.get_recording(rec_id)
    if rec is None:
        return
    work = settings.work_dir / rec_id
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True, exist_ok=True)
    original = Path(rec["original_path"])
    notes: list[str] = []
    try:
        wav = work / "audio48.wav"
        await asyncio.to_thread(audio_tools.decode_to_wav, original, wav)
        duration = await asyncio.to_thread(audio_tools.wav_duration, wav)
        db.update_recording(rec_id, duration=round(duration, 2))

        if do_denoise:
            try:
                clean_dst = settings.recordings_dir / f"{original.stem}.clean.flac"
                path, engine = await asyncio.to_thread(audio_tools.denoise_wav, wav, clean_dst)
                db.update_recording(
                    rec_id, denoised_path=str(path) if path else None, denoise_engine=engine
                )
            except audio_tools.AudioError as exc:
                notes.append(f"noise removal skipped: {exc}")

        if do_transcribe:
            result = await transcription.transcribe_file(wav, work)
            db.update_recording(
                rec_id,
                transcript=result.text,
                transcription_provider=result.provider,
                transcription_model=result.model,
                transcript_corrected=False,
            )

        if do_analyze:
            rec = db.get_recording(rec_id) or rec
            transcript = rec.get("transcript") or ""
            if transcript.strip():
                result = await analysis.analyze_transcript(transcript, rec.get("title") or "")
                fields: dict[str, Any] = {"analysis": result}
                current_title = (rec.get("title") or "").strip()
                if result.get("title") and (not current_title or current_title.startswith("Recording")):
                    fields["title"] = result["title"]
                db.update_recording(rec_id, **fields)
            else:
                notes.append("analysis skipped: no transcript")

        db.update_recording(rec_id, status="done", error=("; ".join(notes) or None))
    except (audio_tools.AudioError, transcription.TranscriptionError, analysis.AnalysisError) as exc:
        db.update_recording(rec_id, status="error", error=str(exc))
    except Exception as exc:  # noqa: BLE001 - never leave a recording stuck in "processing"
        log.exception("processing %s failed", rec_id)
        db.update_recording(rec_id, status="error", error=f"unexpected error: {exc}")
    finally:
        shutil.rmtree(work, ignore_errors=True)


@app.post("/api/recordings", dependencies=[Depends(require_auth)])
async def api_upload_recording(
    background: BackgroundTasks,
    audio: UploadFile = File(...),
    title: str = Form(""),
    process: str = Form("1"),
    client_id: str = Form(""),
) -> dict:
    """Upload a recording (streamed to disk). `process=1` starts the pipeline.

    A stable client_id makes retries idempotent: if the response is lost after
    the server accepted a file, the iPhone can retry without creating a duplicate.
    """
    client_key = client_id.strip()[:128]
    if client_key:
        existing = db.get_recording_by_client_id(client_key)
        if existing is not None:
            return existing

    ext = _ext_for_upload(audio)
    dest = settings.recordings_dir / f"{uuid.uuid4().hex}{ext}"
    limit = settings.max_upload_mb * 1024 * 1024
    size = 0
    try:
        with dest.open("wb") as fh:
            while True:
                chunk = await audio.read(1024 * 1024)
                if not chunk:
                    break
                size += len(chunk)
                if size > limit:
                    raise HTTPException(status_code=413, detail=f"Recording larger than {settings.max_upload_mb} MB")
                fh.write(chunk)
    except HTTPException:
        dest.unlink(missing_ok=True)
        raise
    if size == 0:
        dest.unlink(missing_ok=True)
        raise HTTPException(status_code=400, detail="Empty upload")

    rec_title = title.strip() or Path(audio.filename or "").stem or "Recording"
    rec = db.create_recording(
        title=rec_title,
        original_name=audio.filename or dest.name,
        original_path=str(dest),
        mime=MIME_BY_EXT.get(ext, audio.content_type or "application/octet-stream"),
        size=size,
        client_id=client_key or None,
    )
    if process.strip().lower() in ("1", "true", "yes", "on"):
        db.update_recording(rec["id"], status="processing", error=None)
        background.add_task(_process_recording, rec["id"], True, True, True)
        rec = db.get_recording(rec["id"]) or rec
    return rec


@app.get("/api/recordings", dependencies=[Depends(require_auth)])
def api_list_recordings() -> list[dict]:
    return db.list_recordings()


@app.get("/api/recordings/{rec_id}", dependencies=[Depends(require_auth)])
def api_get_recording(rec_id: str) -> dict:
    return _require_recording(rec_id)


@app.put("/api/recordings/{rec_id}", dependencies=[Depends(require_auth)])
async def api_update_recording(rec_id: str, body: RecordingUpdate) -> dict:
    rec = _require_recording(rec_id)
    fields: dict[str, Any] = {}
    if body.title is not None:
        fields["title"] = body.title.strip()
    if body.transcript is not None:
        corrected = body.transcript.strip()
        if len(corrected) > 1_000_000:
            raise HTTPException(status_code=413, detail="Transcript is too large")
        if body.refresh_analysis and corrected:
            try:
                # Analyze before writing so a model failure never replaces a
                # good transcript/analysis pair with a half-updated state.
                fields["analysis"] = await analysis.analyze_transcript(
                    corrected, fields.get("title") or rec.get("title") or ""
                )
            except analysis.AnalysisError as exc:
                raise HTTPException(status_code=502, detail=str(exc))
        else:
            # Never present an old summary as if it describes corrected text.
            fields["analysis"] = None
        fields["transcript"] = corrected
        fields["transcript_corrected"] = True
    return db.update_recording(rec_id, **fields) or _require_recording(rec_id)


@app.delete("/api/recordings/{rec_id}", dependencies=[Depends(require_auth)])
def api_delete_recording(rec_id: str) -> dict:
    rec = db.delete_recording(rec_id)
    if rec is None:
        raise HTTPException(status_code=404, detail="Recording not found")
    _remove_recording_files(rec)
    return {"ok": True}


@app.get("/api/recordings/{rec_id}/audio", dependencies=[Depends(require_auth)])
def api_recording_audio(rec_id: str, variant: str = "original") -> FileResponse:
    rec = _require_recording(rec_id)
    if variant == "denoised":
        path = rec.get("denoised_path")
        if not path:
            raise HTTPException(status_code=404, detail="No noise-removed copy for this recording")
        media_type = "audio/flac"
    else:
        path = rec["original_path"]
        media_type = rec.get("mime") or "application/octet-stream"
    file_path = Path(path)
    if not file_path.is_file():
        raise HTTPException(status_code=404, detail="Audio file is missing on disk")
    return FileResponse(file_path, media_type=media_type, filename=file_path.name)


@app.post("/api/recordings/{rec_id}/process", dependencies=[Depends(require_auth)], status_code=202)
def api_process_recording(rec_id: str, body: ProcessBody, background: BackgroundTasks) -> dict:
    rec = _require_recording(rec_id)
    if rec["status"] == "processing":
        raise HTTPException(status_code=409, detail="This recording is already being processed")
    if body.transcribe and not settings.transcription_configured:
        raise HTTPException(status_code=503, detail="Voice-to-text is not configured. Configure a provider in .env.")
    db.update_recording(rec_id, status="processing", error=None)
    background.add_task(_process_recording, rec_id, body.denoise, body.transcribe, body.analyze)
    return {"ok": True, "status": "processing"}


@app.post("/api/recordings/{rec_id}/analyze", dependencies=[Depends(require_auth)])
async def api_analyze_recording(rec_id: str) -> dict:
    rec = _require_recording(rec_id)
    transcript = (rec.get("transcript") or "").strip()
    if not transcript:
        raise HTTPException(status_code=400, detail="Transcribe the recording first")
    try:
        result = await analysis.analyze_transcript(transcript, rec.get("title") or "")
    except analysis.AnalysisError as exc:
        raise HTTPException(status_code=502, detail=str(exc))
    return db.update_recording(rec_id, analysis=result) or rec


@app.post("/api/recordings/{rec_id}/note", dependencies=[Depends(require_auth)])
def api_note_from_recording(rec_id: str) -> dict:
    rec = _require_recording(rec_id)
    transcript = (rec.get("transcript") or "").strip()
    if not transcript:
        raise HTTPException(status_code=400, detail="Transcribe the recording first")
    ana = rec.get("analysis") or {}
    title = (ana.get("title") if isinstance(ana, dict) else None) or rec.get("title") or "Recording"
    note = db.create_note(title=title, content=transcript)
    db.update_recording(rec_id, note_id=note["id"])
    return note


# ──────────────────────────── Reports ──────────────────────────── #
@app.post("/api/reports", dependencies=[Depends(require_auth)])
async def api_report(body: ReportBody) -> dict:
    if not settings.analysis_configured:
        raise HTTPException(status_code=503, detail="AI analysis is not configured. Set OPENROUTER_API_KEY.")
    items: list[dict[str, Any]] = []
    select_all = not body.note_ids and not body.recording_ids

    for note in db.list_notes_full(body.note_ids or None) if (body.note_ids or select_all) else []:
        items.append({"title": note["title"] or "Untitled note", "date": note["updated_at"][:10], "text": note["content"]})

    if body.recording_ids or select_all:
        recs = [db.get_recording(r) for r in body.recording_ids] if body.recording_ids else [
            db.get_recording(r["id"]) for r in db.list_recordings() if r["has_transcript"]
        ]
        for rec in recs:
            if rec and (rec.get("transcript") or "").strip():
                items.append({"title": rec["title"] or "Recording", "date": rec["created_at"][:10],
                              "text": rec["transcript"]})

    try:
        report = await analysis.generate_report(items, body.instructions, body.title)
    except analysis.AnalysisError as exc:
        raise HTTPException(status_code=502, detail=str(exc))

    note = None
    if body.save_as_note:
        note = db.create_note(title=body.title.strip() or "Report", content=report)
    return {"report": report, "item_count": len(items), "note": note}


# ──────────────────────── Static / PWA shell ───────────────────── #
@app.get("/")
def index() -> FileResponse:
    return FileResponse(WEB_DIR / "index.html", headers={"Cache-Control": "no-cache"})


@app.get("/sw.js")
def service_worker() -> FileResponse:
    return FileResponse(
        WEB_DIR / "sw.js",
        media_type="text/javascript",
        headers={"Cache-Control": "no-cache", "Service-Worker-Allowed": "/"},
    )


@app.get("/manifest.webmanifest")
def manifest() -> FileResponse:
    return FileResponse(WEB_DIR / "manifest.webmanifest", media_type="application/manifest+json")


app.mount("/", StaticFiles(directory=WEB_DIR, html=True), name="static")
