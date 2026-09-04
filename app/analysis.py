"""AI analysis of transcripts and notes, and cross-note reports (OpenRouter).

Only text is sent here — never audio. Content keeps its original language
and script.
"""
from __future__ import annotations

import asyncio
import json
import re
from typing import Any

import httpx

from .config import settings

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
REQUEST_TIMEOUT = 180.0
TRANSIENT_STATUS_CODES = {408, 409, 425, 429, 500, 502, 503, 504}
DIRECT_ANALYSIS_CHARS = 60_000
ANALYSIS_CHUNK_CHARS = 45_000


class AnalysisError(Exception):
    """Raised when analysis cannot be completed (config or upstream error)."""


def _language_instruction() -> str:
    lang = (settings.analysis_language or "auto").strip().lower()
    if lang == "auto":
        return (
            "Write your output in the same language as the content, using that "
            "language's own script. If the content mixes languages, use the one "
            "that dominates. "
        )
    return f"Write your output in the language with code '{lang}'. "


async def _chat(messages: list[dict[str, Any]], *, json_mode: bool = False,
                temperature: float = 0.2, max_tokens: int = 4000) -> str:
    if not settings.openrouter_api_key:
        raise AnalysisError("OPENROUTER_API_KEY is not set. Add it to your .env file to enable AI analysis.")

    payload: dict[str, Any] = {
        "model": settings.openrouter_text_model,
        "messages": messages,
        "temperature": temperature,
        "max_tokens": max_tokens,
    }
    if json_mode:
        payload["response_format"] = {"type": "json_object"}

    headers = {
        "Authorization": f"Bearer {settings.openrouter_api_key}",
        "Content-Type": "application/json",
        "HTTP-Referer": "https://github.com/shosseini811/AiNotetaker-iOS",
        "X-Title": "AiNotetaker",
    }
    last_error: Exception | None = None
    async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT) as client:
        for attempt in range(3):
            try:
                resp = await client.post(OPENROUTER_URL, json=payload, headers=headers)
                if resp.status_code not in TRANSIENT_STATUS_CODES or attempt == 2:
                    break
                try:
                    delay = min(8.0, max(0.0, float(resp.headers.get("Retry-After", ""))))
                except ValueError:
                    delay = float(2 ** attempt)
            except httpx.HTTPError as exc:
                last_error = exc
                if attempt == 2:
                    raise AnalysisError(f"Could not reach OpenRouter: {exc}") from exc
                delay = float(2 ** attempt)
            await asyncio.sleep(delay)
        else:  # pragma: no cover - loop always breaks or raises
            raise AnalysisError(f"Could not reach OpenRouter: {last_error}")

    if resp.status_code != 200:
        raise AnalysisError(f"OpenRouter returned HTTP {resp.status_code}: {resp.text[:400]}")
    try:
        data = resp.json()
    except json.JSONDecodeError as exc:
        raise AnalysisError("OpenRouter returned a non-JSON response.") from exc
    if isinstance(data, dict) and data.get("error"):
        raise AnalysisError(f"OpenRouter error: {json.dumps(data['error'])[:400]}")
    try:
        content = data["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as exc:
        raise AnalysisError(f"Unexpected OpenRouter response shape: {json.dumps(data)[:400]}") from exc
    if isinstance(content, list):
        content = "".join(p.get("text", "") for p in content if isinstance(p, dict))
    return (content or "").strip()


def _extract_json(text: str) -> dict[str, Any]:
    """Parse a JSON object from a model reply, tolerating code fences / prose."""
    text = text.strip()
    try:
        obj = json.loads(text)
        if isinstance(obj, dict):
            return obj
    except ValueError:
        pass
    fenced = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.DOTALL)
    candidates = [fenced.group(1)] if fenced else []
    start, end = text.find("{"), text.rfind("}")
    if start != -1 and end > start:
        candidates.append(text[start:end + 1])
    for cand in candidates:
        try:
            obj = json.loads(cand)
            if isinstance(obj, dict):
                return obj
        except ValueError:
            continue
    raise AnalysisError("The model did not return valid JSON.")


def _as_str_list(value: Any) -> list[str]:
    if isinstance(value, list):
        return [str(v).strip() for v in value if str(v).strip()]
    if isinstance(value, str) and value.strip():
        return [line.strip("-•* ").strip() for line in value.splitlines() if line.strip()]
    return []


def _analysis_system() -> str:
    return (
        "You analyze a person's private voice note transcript and return a compact, "
        "faithful analysis as JSON only. Do not invent facts. Preserve which speaker "
        "made each decision, commitment, or request when speaker labels are present. "
        + _language_instruction() +
        "Return a JSON object with exactly these keys: "
        "\"title\" (a short descriptive title, at most 8 words), "
        "\"summary\" (2 to 4 sentences), "
        "\"key_points\" (array of short strings), "
        "\"decisions\" (array of explicit decisions or agreements; empty array if none), "
        "\"action_items\" (array of concrete to-dos mentioned or clearly implied; empty array if none), "
        "\"people\" (array of people, clients, companies, or organizations explicitly named), "
        "\"open_questions\" (array of unresolved questions or follow-ups; empty array if none), "
        "\"topics\" (array of 1 to 5 short tags), "
        "\"language\" (ISO 639-1 code of the content, e.g. \"en\", \"es\", \"fa\")."
    )


def _normalize_analysis(obj: dict[str, Any], title_hint: str = "") -> dict[str, Any]:
    return {
        "title": str(obj.get("title") or title_hint or "").strip()[:120],
        "summary": str(obj.get("summary") or "").strip(),
        "key_points": _as_str_list(obj.get("key_points")),
        "decisions": _as_str_list(obj.get("decisions")),
        "action_items": _as_str_list(obj.get("action_items")),
        "people": _as_str_list(obj.get("people")),
        "open_questions": _as_str_list(obj.get("open_questions")),
        "topics": _as_str_list(obj.get("topics"))[:5],
        "language": str(obj.get("language") or "").strip()[:8],
        "model": settings.openrouter_text_model,
    }


def _chunk_transcript(text: str, limit: int = ANALYSIS_CHUNK_CHARS) -> list[str]:
    """Split long text without silently dropping the end of a meeting."""
    chunks: list[str] = []
    remaining = text
    while remaining:
        if len(remaining) <= limit:
            chunks.append(remaining)
            break
        cut = remaining.rfind("\n", 0, limit)
        if cut < limit // 2:
            cut = remaining.rfind(" ", 0, limit)
        if cut < limit // 2:
            cut = limit
        chunks.append(remaining[:cut].strip())
        remaining = remaining[cut:].strip()
    return [chunk for chunk in chunks if chunk]


async def _analyze_once(text: str, title_hint: str = "", context: str = "") -> dict[str, Any]:
    user = (f"Working title: {title_hint}\n\n" if title_hint else "")
    if context:
        user += context + "\n\n"
    user += "Transcript:\n\n" + text
    reply = await _chat(
        [{"role": "system", "content": _analysis_system()}, {"role": "user", "content": user}],
        json_mode=True,
    )
    return _normalize_analysis(_extract_json(reply), title_hint)


async def analyze_transcript(text: str, title_hint: str = "") -> dict[str, Any]:
    """Summarize one transcript/note. Returns a normalized dict."""
    text = (text or "").strip()
    if not text:
        raise AnalysisError("Nothing to analyze: the transcript is empty.")

    if len(text) <= DIRECT_ANALYSIS_CHARS:
        return await _analyze_once(text, title_hint)

    chunks = _chunk_transcript(text)
    partials = []
    for index, chunk in enumerate(chunks, 1):
        partials.append(await _analyze_once(
            chunk,
            title_hint,
            f"This is part {index} of {len(chunks)}. Extract every important fact from this part.",
        ))
    # A second pass consolidates all chunk analyses. This costs one extra text
    # call for long meetings, but ensures the end is never silently ignored.
    user = (
        "Consolidate these ordered partial analyses into one final memory. "
        "Remove duplicates, preserve speaker ownership, and do not add facts.\n\n"
        + json.dumps(partials, ensure_ascii=False)
    )
    reply = await _chat(
        [{"role": "system", "content": _analysis_system()}, {"role": "user", "content": user}],
        json_mode=True,
    )
    return _normalize_analysis(_extract_json(reply), title_hint)


async def generate_report(items: list[dict[str, Any]], instructions: str = "", title: str = "") -> str:
    """Build a Markdown report across several notes/transcripts."""
    items = [i for i in items if (i.get("text") or "").strip()]
    if not items:
        raise AnalysisError("Nothing to report on: no notes or transcripts with text were selected.")

    system = (
        "You write clear, well-organized Markdown reports from a person's private notes "
        "and voice transcripts. Be faithful to the source; do not invent facts. "
        + _language_instruction() +
        "Structure: a one-paragraph overview; main themes; highlights per item (with dates); "
        "a consolidated action-items checklist; open questions or follow-ups. Use headings "
        "and bullet lists. Keep it tight and useful."
    )
    parts = []
    budget = 90000
    for i, item in enumerate(items, 1):
        head = f"### Item {i}: {item.get('title') or 'Untitled'}  ({item.get('date') or 'no date'})\n"
        body = (item.get("text") or "").strip()
        if len(head) + len(body) > budget:
            body = body[: max(0, budget - len(head))] + "\n[...truncated]"
        parts.append(head + body)
        budget -= len(head) + len(body)
        if budget <= 0:
            break
    user = ""
    if title:
        user += f"Report title: {title}\n"
    if instructions.strip():
        user += f"Extra instructions from the author: {instructions.strip()}\n"
    user += "\nSource material:\n\n" + "\n\n".join(parts)
    return await _chat(
        [{"role": "system", "content": system}, {"role": "user", "content": user}],
        temperature=0.3,
        max_tokens=6000,
    )
