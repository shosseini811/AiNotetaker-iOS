"""Configuration, loaded from environment variables (and an optional .env file).

Nothing here is secret by default; real secrets come from the environment or a
`.env` file that is git-ignored. See `.env.example` for documentation.
"""
from __future__ import annotations

import os
import secrets
from pathlib import Path

# Project root = the directory that contains this "app" package's parent.
BASE_DIR = Path(__file__).resolve().parent.parent
WEB_DIR = BASE_DIR / "web"


def _load_dotenv(path: Path) -> None:
    """Minimal .env loader (no external dependency).

    Supports `KEY=value` lines, `#` comments and surrounding quotes. Values
    already present in the real environment win, so `VAR=... ./run.sh` works.
    """
    if not path.is_file():
        return
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


_load_dotenv(BASE_DIR / ".env")


def _get(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def _get_int(name: str, default: int) -> int:
    try:
        return int(_get(name, str(default)) or default)
    except ValueError:
        return default


def _get_bool(name: str, default: bool = False) -> bool:
    value = _get(name)
    if not value:
        return default
    return value.lower() in ("1", "true", "yes", "on")


class Settings:
    """Runtime configuration snapshot."""

    def __init__(self) -> None:
        self.app_title: str = _get("APP_TITLE", "Notes") or "Notes"

        # ── Storage ────────────────────────────────────────────────
        data_dir = _get("DATA_DIR", "data") or "data"
        self.data_dir: Path = (BASE_DIR / data_dir) if not os.path.isabs(data_dir) else Path(data_dir)
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.db_path: Path = self.data_dir / "ainotetaker.db"
        self.recordings_dir: Path = self.data_dir / "recordings"   # originals + cleaned copies
        self.recordings_dir.mkdir(parents=True, exist_ok=True)
        self.work_dir: Path = self.data_dir / "work"               # scratch for processing
        self.work_dir.mkdir(parents=True, exist_ok=True)

        # ── Server ─────────────────────────────────────────────────
        self.host: str = _get("HOST", "0.0.0.0") or "0.0.0.0"
        self.port: int = _get_int("PORT", 8000)
        self.max_upload_mb: int = _get_int("MAX_UPLOAD_MB", 2048)
        # Optional explicit address clients should save when this server sits
        # behind a custom domain or reverse proxy. Empty means "discover it"
        # (Tailscale, then the LAN address) — see app/network.py.
        self.public_url: str = _get("PUBLIC_URL").rstrip("/")

        # ── Auth ───────────────────────────────────────────────────
        # APP_PASSWORD protects the web app (cookie login).
        # API_TOKEN is a bearer token for the iOS app. Either one also works
        # as the other (the token is accepted as the web password).
        self.app_password: str = _get("APP_PASSWORD")
        self.api_token: str = _get("API_TOKEN")
        self.auth_required: bool = bool(self.app_password or self.api_token)
        self.secret_key: str = self._resolve_secret_key()

        # ── Speech-to-text ─────────────────────────────────────────
        provider = (_get("TRANSCRIBE_PROVIDER", "openrouter") or "openrouter").lower()
        valid_providers = ("openrouter", "azure-mai", "openai")
        self.transcribe_provider: str = provider if provider in valid_providers else "openrouter"
        fallback = (_get("TRANSCRIBE_FALLBACK_PROVIDER") or "").lower()
        self.transcribe_fallback_provider: str = (
            fallback if fallback in valid_providers and fallback != self.transcribe_provider else ""
        )
        # Empty (the default) means "detect the spoken language automatically",
        # which also lets a speaker switch languages mid-recording. Set an ISO
        # 639-1 code only to bias recognition toward one known language.
        self.transcribe_language: str = _get("TRANSCRIBE_LANGUAGE")
        # Optional spellings for names, products, acronyms, and domain terms.
        # They guide recognition but never replace what was actually spoken.
        vocabulary = _get("TRANSCRIBE_VOCABULARY")
        self.transcribe_vocabulary: list[str] = [
            term.strip()[:80] for term in vocabulary.split(",") if term.strip()
        ][:100]
        self.openrouter_api_key: str = _get("OPENROUTER_API_KEY")
        self.openrouter_model: str = _get("OPENROUTER_MODEL", "google/gemini-3.8-flash") or "google/gemini-3.8-flash"
        # Long recordings are transcribed in chunks (OpenRouter takes audio inline,
        # ~20 MB per request). 10 minutes of 16 kHz mono FLAC is ~7 MB: safe.
        self.transcribe_chunk_seconds: int = max(60, _get_int("TRANSCRIBE_CHUNK_SECONDS", 600))
        fmt = (_get("TRANSCRIBE_AUDIO_FORMAT", "flac") or "flac").lower()
        self.transcribe_audio_format: str = fmt if fmt in ("flac", "wav") else "flac"

        self.openai_api_key: str = _get("OPENAI_API_KEY")
        self.openai_base_url: str = _get("OPENAI_BASE_URL", "https://api.openai.com/v1") or "https://api.openai.com/v1"
        self.openai_model: str = _get("OPENAI_MODEL", "whisper-1") or "whisper-1"

        # Microsoft MAI-Transcribe-2 is an optional hosted, speaker-aware ASR
        # provider. Leave the locale empty for automatic language detection and
        # code switching; forcing one locale is a strong hint.
        self.azure_speech_endpoint: str = _get("AZURE_SPEECH_ENDPOINT").rstrip("/")
        self.azure_speech_key: str = _get("AZURE_SPEECH_KEY")
        self.azure_speech_model: str = _get("AZURE_SPEECH_MODEL", "MAI-Transcribe-2") or "MAI-Transcribe-2"
        self.azure_speech_locale: str = _get("AZURE_SPEECH_LOCALE")
        self.azure_speech_diarization: bool = _get_bool("AZURE_SPEECH_DIARIZATION", True)
        self.azure_transcribe_chunk_seconds: int = min(
            3600, max(60, _get_int("AZURE_TRANSCRIBE_CHUNK_SECONDS", 3600))
        )

        # ── AI analysis / reports ──────────────────────────────────
        self.openrouter_text_model: str = _get("OPENROUTER_TEXT_MODEL", "google/gemini-3.8-flash") or "google/gemini-3.8-flash"
        # "auto" = answer in the language of the content; or force an ISO 639-1
        # code such as "en", "es", "fa", "ja".
        self.analysis_language: str = _get("ANALYSIS_LANGUAGE", "auto") or "auto"

        # ── Noise removal ──────────────────────────────────────────
        # auto | deepfilternet | noisereduce | off
        eng = (_get("DENOISE_ENGINE", "auto") or "auto").lower()
        valid = ("auto", "deepfilternet", "deepfilter-bin", "noisereduce", "off")
        self.denoise_engine: str = eng if eng in valid else "auto"
        # Optional explicit path to the standalone DeepFilterNet binary. When
        # empty, PATH and ~/.local/bin/deep-filter are searched.
        self.deepfilter_bin: str = _get("DEEPFILTER_BIN")
        # DeepFilterNet's optional post-filter removes more residual noise but
        # can over-attenuate very noisy speech. Keep it opt-in so the normal
        # cleaned copy prioritizes natural, intelligible voices.
        self.deepfilter_postfilter: bool = _get_bool("DEEPFILTER_POSTFILTER")
        # 0.0–1.0: how strongly the lightweight denoiser (noisereduce) attenuates
        # noise. Lower keeps the sound more natural. DeepFilterNet ignores this.
        try:
            self.denoise_strength: float = min(1.0, max(0.0, float(_get("DENOISE_STRENGTH", "0.8") or 0.8)))
        except ValueError:
            self.denoise_strength = 0.8

    def _resolve_secret_key(self) -> str:
        """Use SECRET_KEY if provided, else generate & persist one under data/."""
        provided = _get("SECRET_KEY")
        if provided:
            return provided
        key_file = self.data_dir / ".secret_key"
        if key_file.is_file():
            existing = key_file.read_text(encoding="utf-8").strip()
            if existing:
                return existing
        generated = secrets.token_urlsafe(48)
        key_file.write_text(generated, encoding="utf-8")
        try:
            key_file.chmod(0o600)
        except OSError:
            pass
        return generated

    @property
    def transcription_configured(self) -> bool:
        return self.provider_configured(self.transcribe_provider) or self.provider_configured(
            self.transcribe_fallback_provider
        )

    def provider_configured(self, provider: str) -> bool:
        if provider == "openai":
            return bool(self.openai_api_key)
        if provider == "azure-mai":
            return bool(self.azure_speech_endpoint and self.azure_speech_key)
        if provider == "openrouter":
            return bool(self.openrouter_api_key)
        return False

    @property
    def analysis_configured(self) -> bool:
        return bool(self.openrouter_api_key)


settings = Settings()
