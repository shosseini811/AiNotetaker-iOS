"""End-to-end server tests: synthetic ALAC recording → upload → denoise →
chunked transcription → analysis → note/report, with OpenRouter mocked."""
from __future__ import annotations

import asyncio
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

TMP = Path(tempfile.mkdtemp(prefix="ainotetaker-test-"))
os.environ.update({
    "DATA_DIR": str(TMP / "data"),
    "API_TOKEN": "test-token-123",
    "APP_PASSWORD": "",
    "OPENROUTER_API_KEY": "dummy-key",
    "DENOISE_ENGINE": "noisereduce",
    "TRANSCRIBE_CHUNK_SECONDS": "60",
})
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from fastapi.testclient import TestClient  # noqa: E402

from app import analysis, db, main as main_module, network, transcription  # noqa: E402
from app import audio as audio_tools  # noqa: E402
from app.main import app  # noqa: E402

AUTH = {"Authorization": "Bearer test-token-123"}
STATE: dict = {}


@pytest.fixture(scope="module")
def client():
    with TestClient(app) as c:
        yield c


@pytest.fixture(scope="module")
def sample_m4a() -> Path:
    """130 s of tone + noise, encoded as Apple Lossless (what the iPhone sends)."""
    sr, seconds = 48_000, 130
    t = np.arange(sr * seconds) / sr
    rng = np.random.default_rng(0)
    signal = 0.3 * np.sin(2 * np.pi * 220 * t) * (0.5 + 0.5 * np.sin(2 * np.pi * 0.5 * t))
    signal += 0.05 * rng.standard_normal(t.size)
    wav = TMP / "sample.wav"
    sf.write(str(wav), signal.astype(np.float32), sr, subtype="PCM_16")
    m4a = TMP / "sample.m4a"
    subprocess.run(
        [audio_tools.ffmpeg_exe(), "-y", "-loglevel", "error", "-i", str(wav), "-c:a", "alac", str(m4a)],
        check=True,
    )
    return m4a


@pytest.fixture(autouse=True)
def mock_openrouter(monkeypatch):
    async def fake_transcribe(audio_bytes, fmt="wav", segment=None):
        assert audio_bytes[:4] in (b"fLaC", b"RIFF"), "chunk must be FLAC or WAV"
        n = segment[0] if segment else 1
        return f"segment {n} text"

    async def fake_chat(messages, *, json_mode=False, temperature=0.2, max_tokens=4000):
        if json_mode:
            return json.dumps({
                "title": "Test Title", "summary": "A summary.", "key_points": ["p1", "p2"],
                "decisions": ["use Gemini"], "action_items": ["do x"],
                "people": ["Ada"], "open_questions": ["when?"], "topics": ["t"],
                "language": "en",
            })
        return "# Report\n\nThis is a report."

    monkeypatch.setattr(transcription, "_transcribe_openrouter", fake_transcribe)
    monkeypatch.setattr(analysis, "_chat", fake_chat)


def test_config_is_public(client):
    r = client.get("/api/config")
    assert r.status_code == 200
    cfg = r.json()
    assert cfg["auth_required"] is True and cfg["authenticated"] is False
    assert cfg["transcription_configured"] and cfg["analysis_configured"]
    assert cfg["transcription_provider"] == "openrouter"
    assert cfg["transcription_model"] == "google/gemini-3.8-flash"
    assert cfg["denoise_engine"] == "noisereduce"


# ── Reachable from anywhere ─────────────────────────────────────── #
SERVE_STATUS = {
    "TCP": {"443": {"HTTPS": True}},
    "Web": {
        "mac-mini.tail1234.ts.net:443": {
            "Handlers": {"/": {"Proxy": "http://127.0.0.1:8000"}}
        }
    },
}
NODE_STATUS = {
    "BackendState": "Running",
    "Self": {"DNSName": "mac-mini.tail1234.ts.net.", "TailscaleIPs": ["100.101.102.103"]},
}


@pytest.fixture
def tailscale(monkeypatch):
    """Fake the Tailscale CLI. `state` decides what each command answers."""
    state: dict = {"status": {}, "serve": {}}

    def fake_json(*args):
        return state["serve"] if args[0] == "serve" else state["status"]

    monkeypatch.setattr(network, "_tailscale_json", fake_json)
    network.reset_cache()
    yield state
    network.reset_cache()


def test_endpoints_are_only_shown_to_an_authenticated_client(client, tailscale):
    tailscale["status"] = NODE_STATUS
    tailscale["serve"] = SERVE_STATUS

    # A stranger on the same café Wi-Fi must not learn the tailnet name.
    assert "endpoints" not in client.get("/api/config").json()

    endpoints = client.get("/api/config", headers=AUTH).json()["endpoints"]
    assert endpoints["remote_url"] == "https://mac-mini.tail1234.ts.net"
    assert endpoints["remote_source"] == "tailscale-serve"
    assert endpoints["reachable_anywhere"] is True
    assert endpoints["setup_hint"] == ""


def test_tailnet_name_is_advertised_without_tailscale_serve(tailscale, monkeypatch):
    tailscale["status"] = NODE_STATUS
    monkeypatch.setattr(main_module.settings, "host", "0.0.0.0")

    endpoints = network.advertised_endpoints(refresh=True)
    assert endpoints["remote_url"] == "http://mac-mini.tail1234.ts.net:8000"
    assert endpoints["remote_source"] == "tailscale"


def test_tailnet_ip_is_offered_even_without_magicdns(tailscale, monkeypatch):
    tailscale["status"] = {"BackendState": "Running", "Self": {"TailscaleIPs": ["100.101.102.103"]}}
    monkeypatch.setattr(main_module.settings, "host", "0.0.0.0")
    monkeypatch.setattr(network, "lan_address", lambda: "192.168.1.24")

    endpoints = network.advertised_endpoints(refresh=True)
    assert endpoints["remote_url"] == ""  # no MagicDNS name to advertise
    # The tailnet address still reaches the Mac from cellular, so the app is
    # not told to go and set up remote access.
    assert endpoints["direct_urls"] == ["http://100.101.102.103:8000", "http://192.168.1.24:8000"]
    assert endpoints["reachable_anywhere"] is True
    assert endpoints["setup_hint"] == ""


def test_localhost_only_server_advertises_no_direct_address(tailscale, monkeypatch):
    """setup-remote-access.sh binds to 127.0.0.1; only the proxy gets in."""
    tailscale["status"] = NODE_STATUS
    monkeypatch.setattr(main_module.settings, "host", "127.0.0.1")

    endpoints = network.advertised_endpoints(refresh=True)
    assert endpoints["direct_urls"] == []
    assert endpoints["remote_url"] == ""  # no Serve configured either


def test_public_url_overrides_discovery(tailscale, monkeypatch):
    tailscale["status"] = NODE_STATUS
    tailscale["serve"] = SERVE_STATUS
    monkeypatch.setattr(main_module.settings, "public_url", "https://notes.example.com")

    endpoints = network.advertised_endpoints(refresh=True)
    assert endpoints["remote_url"] == "https://notes.example.com"
    assert endpoints["remote_source"] == "public_url"


def test_lan_only_server_says_how_to_fix_it(tailscale, monkeypatch):
    monkeypatch.setattr(main_module.settings, "host", "0.0.0.0")
    monkeypatch.setattr(network, "lan_address", lambda: "192.168.1.24")

    endpoints = network.advertised_endpoints(refresh=True)
    assert endpoints["remote_url"] == ""
    assert endpoints["reachable_anywhere"] is False
    assert "setup-remote-access.sh" in endpoints["setup_hint"]
    assert endpoints["direct_urls"] == ["http://192.168.1.24:8000"]


def test_serve_status_only_matches_this_app(tailscale):
    tailscale["serve"] = {
        "Web": {
            "mac-mini.tail1234.ts.net:443": {
                "Handlers": {"/": {"Proxy": "http://127.0.0.1:9999"}}
            }
        }
    }
    assert network.tailscale_serve_url(8000) == ""

    tailscale["serve"] = SERVE_STATUS
    assert network.tailscale_serve_url(8000) == "https://mac-mini.tail1234.ts.net"


def test_offline_tailscale_is_not_advertised(tailscale):
    tailscale["status"] = {"BackendState": "Stopped", "Self": NODE_STATUS["Self"]}
    assert network.tailscale_dns_name() == ""


def test_deepfilter_postfilter_is_explicitly_opt_in():
    ordinary = audio_tools._deepfilter_command("deep-filter", "/tmp/out", Path("voice.wav"), False)
    maximum = audio_tools._deepfilter_command("deep-filter", "/tmp/out", Path("voice.wav"), True)
    assert "--pf" not in ordinary
    assert "--pf" in maximum
    assert ordinary[-3:] == ["--output-dir", "/tmp/out", "voice.wav"]


def test_transcription_prompt_uses_vocabulary_without_forcing_it(monkeypatch):
    monkeypatch.setattr(
        transcription.settings,
        "transcribe_vocabulary",
        ["Ada", "Grace", "AiNotetaker"],
    )
    prompt = transcription._build_prompt()
    assert "Ada, Grace, AiNotetaker" in prompt
    assert "never insert a hinted term that was not spoken" in prompt


def test_azure_mai_request_and_speaker_transcript(monkeypatch):
    monkeypatch.setattr(transcription.settings, "transcribe_vocabulary", ["Ada", "AiNotetaker"])
    monkeypatch.setattr(transcription.settings, "azure_speech_locale", "")
    definition = transcription._azure_definition()
    assert definition["enhancedMode"]["model"] == "MAI-Transcribe-2"
    assert definition["enhancedMode"]["modelOptions"]["transcribeStyle"] == "verbatim"
    assert definition["phraseList"]["phrases"] == ["Ada", "AiNotetaker"]
    assert "locales" not in definition  # preserve automatic multi-language switching

    text = transcription._extract_azure_transcript({
        "combinedPhrases": [{"text": "combined"}],
        "phrases": [
            {"speaker": 0, "offsetMilliseconds": 0, "text": "سلام"},
            {"speaker": 1, "offsetMilliseconds": 65_000, "text": "Hello"},
        ],
    })
    assert text == "[00:00] Speaker 1: سلام\n[01:05] Speaker 2: Hello"


def test_transcription_falls_back_without_losing_the_recording(monkeypatch):
    monkeypatch.setattr(transcription.settings, "transcribe_provider", "azure-mai")
    monkeypatch.setattr(transcription.settings, "transcribe_fallback_provider", "openrouter")
    monkeypatch.setattr(transcription.settings, "azure_speech_endpoint", "https://example.invalid")
    monkeypatch.setattr(transcription.settings, "azure_speech_key", "test")

    async def fail_azure(*args, **kwargs):
        raise transcription.TranscriptionError("temporary outage")

    async def good_openrouter(*args, **kwargs):
        return "fallback transcript"

    monkeypatch.setattr(transcription, "_transcribe_azure_mai", fail_azure)
    monkeypatch.setattr(transcription, "_transcribe_openrouter", good_openrouter)
    text, provider, model = asyncio.run(
        transcription._transcribe_with_fallback(b"audio", "audio/wav", "wav")
    )
    assert text == "fallback transcript"
    assert provider == "openrouter" and model == "google/gemini-3.8-flash"


def test_long_recording_fallback_rechunks_for_provider_limits(monkeypatch, tmp_path):
    monkeypatch.setattr(transcription.settings, "transcribe_provider", "azure-mai")
    monkeypatch.setattr(transcription.settings, "transcribe_fallback_provider", "openrouter")
    monkeypatch.setattr(transcription.settings, "azure_speech_endpoint", "https://example.invalid")
    monkeypatch.setattr(transcription.settings, "azure_speech_key", "test")
    monkeypatch.setattr(transcription.settings, "azure_transcribe_chunk_seconds", 3600)
    monkeypatch.setattr(transcription.settings, "transcribe_chunk_seconds", 600)
    chunk_sizes = []

    def fake_chunks(src, out_dir, chunk_seconds=None, fmt=None):
        chunk_sizes.append(chunk_seconds)
        out_dir.mkdir(parents=True, exist_ok=True)
        chunk = out_dir / "chunk_000.flac"
        chunk.write_bytes(b"audio")
        return [chunk]

    async def fake_provider(provider, *args, **kwargs):
        if provider == "azure-mai":
            raise transcription.TranscriptionError("temporary outage")
        return "safe fallback"

    monkeypatch.setattr(transcription.audio_tools, "make_transcription_chunks", fake_chunks)
    monkeypatch.setattr(transcription, "_transcribe_provider", fake_provider)
    result = asyncio.run(transcription.transcribe_file(tmp_path / "source.wav", tmp_path))
    assert chunk_sizes == [3600, 600]
    assert result.text == "safe fallback" and result.provider == "openrouter"


def test_long_analysis_includes_the_end_instead_of_truncating(monkeypatch):
    calls = []

    async def fake_chat(messages, **kwargs):
        calls.append(messages[-1]["content"])
        return json.dumps({
            "title": "Complete", "summary": "All parts.", "key_points": [],
            "decisions": [], "action_items": [], "people": [],
            "open_questions": [], "topics": [], "language": "en",
        })

    monkeypatch.setattr(analysis, "_chat", fake_chat)
    marker = "IMPORTANT END-OF-MEETING DECISION"
    result = asyncio.run(analysis.analyze_transcript("start " + ("x" * 70_000) + marker))
    assert result["title"] == "Complete"
    assert len(calls) >= 3  # at least two extraction calls plus consolidation
    assert any(marker in call for call in calls)


def test_bearer_auth(client):
    assert client.get("/api/recordings").status_code == 401
    assert client.get("/api/recordings", headers={"Authorization": "Bearer nope"}).status_code == 401
    assert client.get("/api/recordings", headers=AUTH).status_code == 200
    # the token also works as the web password
    assert client.post("/api/login", json={"password": "test-token-123"}).status_code == 200
    assert client.post("/api/login", json={"password": "wrong"}).status_code == 401


def test_interrupted_processing_becomes_retryable(client):
    source = TMP / "interrupted.m4a"
    source.write_bytes(b"partial recording")
    rec = db.create_recording(
        title="Interrupted",
        original_name=source.name,
        original_path=str(source),
        mime="audio/mp4",
        size=source.stat().st_size,
    )
    db.update_recording(rec["id"], status="processing")
    assert db.recover_interrupted_recordings() == 1
    recovered = db.get_recording(rec["id"])
    assert recovered["status"] == "error"
    assert "server restart" in recovered["error"]
    db.delete_recording(rec["id"])
    source.unlink()


def test_upload_retry_is_idempotent(client):
    client_id = "device-recording-123"
    first = client.post(
        "/api/recordings",
        headers=AUTH,
        files={"audio": ("first.wav", b"first audio", "audio/wav")},
        data={"title": "First", "process": "0", "client_id": client_id},
    )
    second = client.post(
        "/api/recordings",
        headers=AUTH,
        files={"audio": ("retry.wav", b"different retry body", "audio/wav")},
        data={"title": "Retry", "process": "0", "client_id": client_id},
    )
    assert first.status_code == 200 and second.status_code == 200
    assert second.json()["id"] == first.json()["id"]
    assert second.json()["title"] == "First"
    assert second.json()["size"] == len(b"first audio")

    rec = client.get(f"/api/recordings/{first.json()['id']}", headers=AUTH).json()
    original = Path(rec["original_path"])
    assert original.read_bytes() == b"first audio"
    assert client.delete(f"/api/recordings/{rec['id']}", headers=AUTH).status_code == 200
    assert not original.exists()


def test_upload_and_full_pipeline(client, sample_m4a):
    with sample_m4a.open("rb") as fh:
        r = client.post(
            "/api/recordings", headers=AUTH,
            files={"audio": ("sample.m4a", fh, "audio/mp4")},
            data={"title": "Recording 2026-09-02", "process": "1"},
        )
    assert r.status_code == 200, r.text
    rid = r.json()["id"]
    STATE["rid"] = rid

    rec = client.get(f"/api/recordings/{rid}", headers=AUTH).json()
    assert rec["status"] == "done", rec.get("error")
    assert abs(rec["duration"] - 130) < 1.5
    assert rec["has_denoised"] is True and rec["denoise_engine"] == "noisereduce"
    assert Path(rec["denoised_path"]).suffix == ".flac" and Path(rec["denoised_path"]).is_file()
    assert sf.info(rec["denoised_path"]).subtype == "PCM_24"   # cleaned copy keeps 24-bit depth
    assert rec["transcript"].count("segment") == 3          # 130 s in 60 s chunks
    assert rec["transcription_provider"] == "openrouter"
    assert rec["transcription_model"] == "google/gemini-3.8-flash"
    assert rec["analysis"]["title"] == "Test Title"
    assert rec["analysis"]["decisions"] == ["use Gemini"]
    assert rec["analysis"]["action_items"] == ["do x"]
    assert rec["analysis"]["people"] == ["Ada"]
    assert rec["analysis"]["open_questions"] == ["when?"]
    assert rec["title"] == "Test Title"                      # auto-titled from analysis
    assert rec["error"] is None

    listing = client.get("/api/recordings", headers=AUTH).json()
    assert listing[0]["id"] == rid and listing[0]["has_transcript"] and listing[0]["has_analysis"]


def test_audio_streaming(client):
    rid = STATE["rid"]
    r = client.get(f"/api/recordings/{rid}/audio", headers=AUTH)
    assert r.status_code == 200 and r.headers["content-type"].startswith("audio/mp4")
    assert len(r.content) > 10_000
    r = client.get(f"/api/recordings/{rid}/audio", headers=AUTH, params={"variant": "denoised"})
    assert r.status_code == 200 and r.headers["content-type"].startswith("audio/flac")
    assert r.content[:4] == b"fLaC"


def test_upload_without_processing_then_process(client, sample_m4a):
    with sample_m4a.open("rb") as fh:
        r = client.post("/api/recordings", headers=AUTH,
                        files={"audio": ("second.m4a", fh, "audio/mp4")}, data={"process": "0"})
    rec = r.json()
    assert rec["status"] == "uploaded" and rec["title"] == "second"
    r = client.post(f"/api/recordings/{rec['id']}/process", headers=AUTH,
                    json={"denoise": False, "transcribe": True, "analyze": False})
    assert r.status_code == 202
    rec = client.get(f"/api/recordings/{rec['id']}", headers=AUTH).json()
    assert rec["status"] == "done" and rec["has_denoised"] is False
    assert rec["analysis"] is None and "segment 1 text" in rec["transcript"]
    STATE["rid2"] = rec["id"]


def test_note_from_recording_and_rename(client):
    rid = STATE["rid"]
    note = client.post(f"/api/recordings/{rid}/note", headers=AUTH).json()
    assert note["title"] == "Test Title" and "segment 1 text" in note["content"]
    assert client.get(f"/api/recordings/{rid}", headers=AUTH).json()["note_id"] == note["id"]
    r = client.put(f"/api/recordings/{rid}", headers=AUTH, json={"title": "Renamed"})
    assert r.json()["title"] == "Renamed"


def test_report(client):
    r = client.post("/api/reports", headers=AUTH,
                    json={"instructions": "focus on actions", "title": "Weekly", "save_as_note": True})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["report"].startswith("# Report") and body["item_count"] >= 2
    assert body["note"]["title"] == "Weekly"


def test_owner_can_correct_transcript_and_refresh_memory_atomically(client):
    rid = STATE["rid"]
    corrected = "Ada confirmed the final client decision."
    r = client.put(
        f"/api/recordings/{rid}", headers=AUTH,
        json={"transcript": corrected, "refresh_analysis": True},
    )
    assert r.status_code == 200, r.text
    rec = r.json()
    assert rec["transcript"] == corrected
    assert rec["transcription_provider"] == "openrouter"
    assert rec["transcription_model"] == "google/gemini-3.8-flash"
    assert rec["transcript_corrected"] is True
    assert rec["analysis"]["summary"] == "A summary."


def test_failed_memory_refresh_preserves_previous_transcript(client, monkeypatch):
    rid = STATE["rid"]
    before = client.get(f"/api/recordings/{rid}", headers=AUTH).json()

    async def fail_analysis(*args, **kwargs):
        raise analysis.AnalysisError("temporary model failure")

    monkeypatch.setattr(analysis, "analyze_transcript", fail_analysis)
    r = client.put(
        f"/api/recordings/{rid}", headers=AUTH,
        json={"transcript": "This must not replace the saved transcript.", "refresh_analysis": True},
    )
    assert r.status_code == 502
    after = client.get(f"/api/recordings/{rid}", headers=AUTH).json()
    assert after["transcript"] == before["transcript"]
    assert after["analysis"] == before["analysis"]



def test_quick_dictation_rejects_oversized_upload(client, monkeypatch):
    monkeypatch.setattr(main_module, "MAX_QUICK_AUDIO_BYTES", 4)
    r = client.post(
        "/api/transcribe",
        headers=AUTH,
        files={"audio": ("too-large.wav", b"12345", "audio/wav")},
    )
    assert r.status_code == 413
    assert r.json()["detail"] == "Audio file too large"

def test_quick_dictation_endpoint_still_works(client):
    sr = 16_000
    tone = (0.2 * np.sin(2 * np.pi * 440 * np.arange(sr) / sr)).astype(np.float32)
    wav = TMP / "quick.wav"
    sf.write(str(wav), tone, sr, subtype="PCM_16")
    r = client.post("/api/transcribe", headers=AUTH, files={"audio": ("q.wav", wav.read_bytes(), "audio/wav")})
    assert r.status_code == 200 and r.json()["text"] == "segment 1 text"


def test_delete_recording_removes_files(client):
    rid = STATE["rid"]
    rec = client.get(f"/api/recordings/{rid}", headers=AUTH).json()
    original, denoised = Path(rec["original_path"]), Path(rec["denoised_path"])
    assert original.is_file() and denoised.is_file()
    assert client.delete(f"/api/recordings/{rid}", headers=AUTH).status_code == 200
    assert client.get(f"/api/recordings/{rid}", headers=AUTH).status_code == 404
    assert not original.exists() and not denoised.exists()


def test_notes_crud_unchanged(client):
    n = client.post("/api/notes", headers=AUTH, json={"title": "سلام", "content": "یادداشت"}).json()
    assert client.get("/api/notes", headers=AUTH, params={"q": "سلام"}).json()[0]["id"] == n["id"]
    assert client.put(f"/api/notes/{n['id']}", headers=AUTH, json={"pinned": True}).json()["pinned"] is True
    assert client.delete(f"/api/notes/{n['id']}", headers=AUTH).json() == {"ok": True}
