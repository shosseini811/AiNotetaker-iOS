"""Speech-to-text for any spoken language.

Default provider is OpenRouter: audio is sent to an audio-capable chat model
(e.g. Google Gemini Flash) which returns a verbatim transcription. Because
OpenRouter takes audio inline (~20 MB per request), long recordings are split
into chunks and the pieces are stitched back together.

Microsoft MAI-Transcribe-2 can be enabled for speaker-aware meeting transcripts,
and an "openai" provider supports compatible transcription endpoints. A second
provider can be configured as a failure-only fallback.
"""
from __future__ import annotations

import asyncio
import base64
import json
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import httpx

from . import audio as audio_tools
from .config import settings

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
REQUEST_TIMEOUT = 180.0
TRANSIENT_STATUS_CODES = {408, 409, 425, 429, 500, 502, 503, 504}
MAX_REQUEST_ATTEMPTS = 3


class TranscriptionError(Exception):
    """Raised when transcription cannot be completed (config or upstream error)."""


@dataclass(frozen=True)
class TranscriptionResult:
    text: str
    provider: str
    model: str


def _build_prompt(segment: Optional[tuple[int, int]] = None) -> str:
    lang = (settings.transcribe_language or "").strip()
    lang_line = (
        f"The speaker is primarily speaking '{lang}'. "
        if lang
        else "Detect the spoken language automatically, and follow the speaker "
             "if they switch language mid-recording. "
    )
    seg_line = ""
    if segment and segment[1] > 1:
        seg_line = (
            f"This audio is segment {segment[0]} of {segment[1]} of one continuous "
            "recording; transcribe only what is in this segment, and do not add "
            "any note about it being a segment. "
        )
    vocabulary_line = ""
    if settings.transcribe_vocabulary:
        vocabulary = ", ".join(settings.transcribe_vocabulary)
        vocabulary_line = (
            "Vocabulary hints (names, brands, acronyms, or technical terms that "
            f"may occur): {vocabulary}. Prefer these exact spellings only when "
            "they match the audio; never insert a hinted term that was not spoken. "
        )
    return (
        "You are a precise speech-to-text engine. Transcribe the audio EXACTLY "
        "as spoken, word for word. " + lang_line + seg_line + vocabulary_line +
        "Preserve the original language and script — write every language in "
        "its own native script, and keep code-switched words in theirs. Do NOT "
        "translate. Do NOT add commentary, explanations, labels, timestamps, or "
        "quotation marks. Return ONLY the raw transcription text. If the audio "
        "is empty or unintelligible, return an empty string."
    )


async def transcribe(audio_bytes: bytes, content_type: str = "audio/wav", fmt: str = "wav") -> str:
    """Transcribe a short audio blob (used by the web app's quick dictation)."""
    if not audio_bytes:
        raise TranscriptionError("No audio was received.")
    text, _, _ = await _transcribe_with_fallback(audio_bytes, content_type, fmt)
    return text


async def transcribe_file(src: Path, work_dir: Path) -> TranscriptionResult:
    """Transcribe a long file, retrying the whole job with a safe fallback.

    Providers have different upload limits. Each attempt therefore creates its
    own correctly sized chunks; an hour-long Azure chunk is never forwarded to
    OpenRouter after a failure.
    """
    failures: list[str] = []
    for provider in _provider_order():
        chunk_dir = work_dir / f"chunks-{provider}"
        chunk_seconds = (
            settings.azure_transcribe_chunk_seconds
            if provider == "azure-mai"
            else settings.transcribe_chunk_seconds
        )
        try:
            chunks = audio_tools.make_transcription_chunks(
                src, chunk_dir, chunk_seconds=chunk_seconds
            )
            fmt = "flac" if chunks[0].suffix.lower() == ".flac" else "wav"
            content_type = "audio/flac" if fmt == "flac" else "audio/wav"
            total = len(chunks)
            parts: list[str] = []
            for index, chunk in enumerate(chunks, 1):
                text = await _transcribe_provider(
                    provider, chunk.read_bytes(), content_type, fmt,
                    segment=(index, total),
                )
                if text:
                    parts.append(text)
            return TranscriptionResult(
                "\n\n".join(parts).strip(), provider, _model_for_provider(provider)
            )
        except TranscriptionError as exc:
            failures.append(f"{provider}: {exc}")
        finally:
            shutil.rmtree(chunk_dir, ignore_errors=True)
    if not failures:
        raise TranscriptionError("No configured transcription provider is available.")
    raise TranscriptionError("All transcription providers failed — " + "; ".join(failures))


def _model_for_provider(provider: str) -> str:
    if provider == "azure-mai":
        return settings.azure_speech_model
    if provider == "openai":
        return settings.openai_model
    return settings.openrouter_model


def _provider_order() -> list[str]:
    providers = [settings.transcribe_provider]
    if settings.transcribe_fallback_provider:
        providers.append(settings.transcribe_fallback_provider)
    return [provider for provider in providers if settings.provider_configured(provider)]


async def _transcribe_with_fallback(
    audio_bytes: bytes, content_type: str, fmt: str,
    segment: Optional[tuple[int, int]] = None,
) -> tuple[str, str, str]:
    failures: list[str] = []
    for provider in _provider_order():
        try:
            text = await _transcribe_provider(
                provider, audio_bytes, content_type, fmt, segment=segment
            )
            return text, provider, _model_for_provider(provider)
        except TranscriptionError as exc:
            failures.append(f"{provider}: {exc}")
    if not failures:
        raise TranscriptionError("No configured transcription provider is available.")
    raise TranscriptionError("All transcription providers failed — " + "; ".join(failures))


async def _transcribe_provider(
    provider: str, audio_bytes: bytes, content_type: str, fmt: str,
    segment: Optional[tuple[int, int]] = None,
) -> str:
    if provider == "azure-mai":
        return await _transcribe_azure_mai(audio_bytes, content_type, fmt)
    if provider == "openai":
        return await _transcribe_openai(audio_bytes, content_type, fmt)
    return await _transcribe_openrouter(audio_bytes, fmt, segment=segment)


async def _post_with_retry(url: str, operation: str, **kwargs) -> httpx.Response:
    """Retry only transient network, throttling, and server failures."""
    last_error: Optional[Exception] = None
    async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT) as client:
        for attempt in range(MAX_REQUEST_ATTEMPTS):
            try:
                response = await client.post(url, **kwargs)
                if response.status_code not in TRANSIENT_STATUS_CODES:
                    return response
                if attempt == MAX_REQUEST_ATTEMPTS - 1:
                    return response
                retry_after = response.headers.get("Retry-After", "")
                try:
                    delay = min(8.0, max(0.0, float(retry_after)))
                except ValueError:
                    delay = float(2 ** attempt)
            except httpx.HTTPError as exc:
                last_error = exc
                if attempt == MAX_REQUEST_ATTEMPTS - 1:
                    break
                delay = float(2 ** attempt)
            await asyncio.sleep(delay)
    raise TranscriptionError(f"Could not reach {operation}: {last_error}")


async def _transcribe_openrouter(audio_bytes: bytes, fmt: str = "wav",
                                 segment: Optional[tuple[int, int]] = None) -> str:
    if not settings.openrouter_api_key:
        raise TranscriptionError(
            "OPENROUTER_API_KEY is not set. Add it to your .env file to enable voice-to-text."
        )

    encoded = base64.b64encode(audio_bytes).decode()
    payload = {
        "model": settings.openrouter_model,
        "temperature": 0,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": _build_prompt(segment)},
                    {
                        "type": "input_audio",
                        "input_audio": {"data": encoded, "format": fmt},
                    },
                ],
            }
        ],
    }
    headers = {
        "Authorization": f"Bearer {settings.openrouter_api_key}",
        "Content-Type": "application/json",
        "HTTP-Referer": "https://github.com/shosseini811/AiNotetaker-iOS",
        "X-Title": "AiNotetaker",
    }

    resp = await _post_with_retry(
        OPENROUTER_URL, "OpenRouter", json=payload, headers=headers
    )

    if resp.status_code != 200:
        raise TranscriptionError(
            f"OpenRouter returned HTTP {resp.status_code}: {resp.text[:400]}"
        )

    try:
        data = resp.json()
    except json.JSONDecodeError as exc:
        raise TranscriptionError("OpenRouter returned a non-JSON response.") from exc

    if isinstance(data, dict) and data.get("error"):
        raise TranscriptionError(f"OpenRouter error: {json.dumps(data['error'])[:400]}")

    try:
        content = data["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as exc:
        raise TranscriptionError(
            f"Unexpected OpenRouter response shape: {json.dumps(data)[:400]}"
        ) from exc

    if isinstance(content, list):
        content = "".join(
            part.get("text", "") for part in content if isinstance(part, dict)
        )
    return (content or "").strip()


def _azure_definition() -> dict:
    definition: dict = {
        "enhancedMode": {
            "enabled": True,
            "model": settings.azure_speech_model,
            "modelOptions": {
                "transcribeStyle": "verbatim",
                "timestamps": "segment",
            },
        },
        # A private memory should preserve what was actually said.
        "profanityFilterMode": "None",
    }
    if settings.azure_speech_diarization:
        definition["diarization"] = {"enabled": True}
    if settings.transcribe_vocabulary:
        definition["phraseList"] = {"phrases": settings.transcribe_vocabulary}
    if settings.azure_speech_locale:
        definition["locales"] = [settings.azure_speech_locale]
    return definition


def _format_timestamp(milliseconds: object) -> str:
    try:
        seconds = max(0, int(milliseconds) // 1000)
    except (TypeError, ValueError):
        seconds = 0
    hours, remainder = divmod(seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}" if hours else f"{minutes:02d}:{seconds:02d}"


def _extract_azure_transcript(data: object) -> str:
    if not isinstance(data, dict):
        raise TranscriptionError("Azure Speech returned an unexpected response shape.")
    phrases = data.get("phrases")
    valid_phrases = [p for p in phrases if isinstance(p, dict) and str(p.get("text") or "").strip()] \
        if isinstance(phrases, list) else []
    speakers = {p.get("speaker") for p in valid_phrases if p.get("speaker") is not None}
    if len(speakers) > 1:
        lines = []
        for phrase in valid_phrases:
            speaker = phrase.get("speaker")
            label = f"Speaker {speaker + 1}" if isinstance(speaker, int) else f"Speaker {speaker}"
            stamp = _format_timestamp(phrase.get("offsetMilliseconds"))
            lines.append(f"[{stamp}] {label}: {str(phrase.get('text')).strip()}")
        return "\n".join(lines)
    combined = data.get("combinedPhrases")
    if isinstance(combined, list):
        text = "\n".join(
            str(item.get("text") or "").strip()
            for item in combined if isinstance(item, dict) and str(item.get("text") or "").strip()
        )
        if text:
            return text
    return "\n".join(str(p.get("text") or "").strip() for p in valid_phrases).strip()


async def _transcribe_azure_mai(audio_bytes: bytes, content_type: str, fmt: str = "wav") -> str:
    if not settings.azure_speech_endpoint or not settings.azure_speech_key:
        raise TranscriptionError(
            "AZURE_SPEECH_ENDPOINT and AZURE_SPEECH_KEY are required for the 'azure-mai' provider."
        )
    url = (
        settings.azure_speech_endpoint
        + "/speechtotext/transcriptions:transcribe?api-version=2025-10-15"
    )
    files = {"audio": (f"audio.{fmt}", audio_bytes, content_type or f"audio/{fmt}")}
    form = {"definition": json.dumps(_azure_definition(), ensure_ascii=False)}
    headers = {"Ocp-Apim-Subscription-Key": settings.azure_speech_key}
    resp = await _post_with_retry(url, "Azure Speech", data=form, files=files, headers=headers)
    if resp.status_code != 200:
        raise TranscriptionError(
            f"Azure Speech returned HTTP {resp.status_code}: {resp.text[:400]}"
        )
    try:
        return _extract_azure_transcript(resp.json())
    except json.JSONDecodeError as exc:
        raise TranscriptionError("Azure Speech returned a non-JSON response.") from exc


async def _transcribe_openai(audio_bytes: bytes, content_type: str, fmt: str = "wav") -> str:
    if not settings.openai_api_key:
        raise TranscriptionError("OPENAI_API_KEY is not set for the 'openai' provider.")

    url = settings.openai_base_url.rstrip("/") + "/audio/transcriptions"
    files = {"file": (f"audio.{fmt}", audio_bytes, content_type or f"audio/{fmt}")}
    data = {"model": settings.openai_model}
    if settings.transcribe_language:
        data["language"] = settings.transcribe_language
    headers = {"Authorization": f"Bearer {settings.openai_api_key}"}

    resp = await _post_with_retry(
        url, "transcription endpoint", data=data, files=files, headers=headers
    )

    if resp.status_code != 200:
        raise TranscriptionError(
            f"Transcription API returned HTTP {resp.status_code}: {resp.text[:400]}"
        )

    try:
        return (resp.json().get("text") or "").strip()
    except json.JSONDecodeError as exc:
        raise TranscriptionError("Transcription API returned a non-JSON response.") from exc
