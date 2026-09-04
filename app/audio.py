"""Audio processing: decoding, chunking and noise removal.

ffmpeg comes bundled through the `imageio-ffmpeg` package (no system install
needed); a system `ffmpeg` on PATH is used as a fallback. Noise removal uses
the standalone DeepFilterNet binary when installed (best quality, no PyTorch)
and otherwise falls back to `noisereduce` (lightweight spectral gating).
"""
from __future__ import annotations

import importlib
import importlib.util
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Optional

import numpy as np
import soundfile as sf

from .config import settings

WORK_SAMPLE_RATE = 48_000          # DeepFilterNet operates at 48 kHz
TRANSCRIBE_SAMPLE_RATE = 16_000    # plenty for speech; keeps chunks small
_DFN_CHUNK_SECONDS = 600           # bound memory on very long recordings


class AudioError(Exception):
    """Raised when ffmpeg or a denoiser fails."""


# ───────────────────────────── ffmpeg ──────────────────────────── #
def ffmpeg_exe() -> str:
    try:
        import imageio_ffmpeg  # type: ignore

        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:  # noqa: BLE001 - any failure → try PATH
        exe = shutil.which("ffmpeg")
        if exe:
            return exe
        raise AudioError(
            "ffmpeg not found. Run `pip install imageio-ffmpeg` (bundled binary) "
            "or install ffmpeg on the system."
        )


def _run_ffmpeg(args: list[str], timeout: float = 3600) -> None:
    cmd = [ffmpeg_exe(), "-hide_banner", "-loglevel", "error", "-nostdin", *args]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        raise AudioError("ffmpeg timed out") from exc
    if proc.returncode != 0:
        raise AudioError(f"ffmpeg failed: {proc.stderr.strip()[-600:]}")


def decode_to_wav(src: Path, dst: Path, sample_rate: int = WORK_SAMPLE_RATE, channels: int = 1) -> Path:
    """Decode any audio (ALAC/AAC .m4a, WAV, FLAC, ...) to 24-bit PCM WAV."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    _run_ffmpeg([
        "-y", "-i", str(src), "-vn",
        "-ac", str(channels), "-ar", str(sample_rate),
        "-c:a", "pcm_s24le", str(dst),
    ])
    return dst


def wav_duration(path: Path) -> float:
    info = sf.info(str(path))
    return float(info.frames) / float(info.samplerate)


def make_transcription_chunks(
    src: Path, out_dir: Path, chunk_seconds: Optional[int] = None, fmt: Optional[str] = None
) -> list[Path]:
    """Split audio into ≤chunk_seconds pieces as 16 kHz mono FLAC (or WAV)."""
    chunk_seconds = chunk_seconds or settings.transcribe_chunk_seconds
    fmt = (fmt or settings.transcribe_audio_format).lower()
    codec = "flac" if fmt == "flac" else "pcm_s16le"
    ext = "flac" if fmt == "flac" else "wav"
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob(f"chunk_*.{ext}"):
        old.unlink()
    pattern = out_dir / f"chunk_%03d.{ext}"
    _run_ffmpeg([
        "-y", "-i", str(src), "-vn",
        "-ac", "1", "-ar", str(TRANSCRIBE_SAMPLE_RATE), "-c:a", codec, "-sample_fmt", "s16",
        "-f", "segment", "-segment_time", str(int(chunk_seconds)),
        "-reset_timestamps", "1", str(pattern),
    ])
    chunks = sorted(out_dir.glob(f"chunk_*.{ext}"))
    if not chunks:
        raise AudioError("chunking produced no output")
    return chunks


# ─────────────────────────── Noise removal ─────────────────────── #
def _has_module(name: str) -> bool:
    try:
        return importlib.util.find_spec(name) is not None
    except (ImportError, ValueError):
        return False


def deepfilter_binary() -> Optional[str]:
    """Locate the standalone DeepFilterNet binary (no PyTorch required).

    Grab it from https://github.com/Rikorose/DeepFilterNet/releases (asset
    `deep-filter-<ver>-<arch>`), chmod +x, and put it on PATH or in
    ~/.local/bin — or point DEEPFILTER_BIN at it.
    """
    configured = settings.deepfilter_bin
    if configured:
        return configured if os.path.isfile(configured) and os.access(configured, os.X_OK) else None
    found = shutil.which("deep-filter")
    if found:
        return found
    fallback = Path.home() / ".local" / "bin" / "deep-filter"
    if fallback.is_file() and os.access(fallback, os.X_OK):
        return str(fallback)
    return None


def _deepfilternet_python_ok() -> bool:
    """The pip package needs torch AND a torchaudio old enough to still have
    torchaudio.backend (removed in torchaudio >= 2.1), so verify it imports."""
    if not (_has_module("df") and _has_module("torch")):
        return False
    try:
        importlib.import_module("df.enhance")
        return True
    except Exception:  # noqa: BLE001 - broken install is as good as absent
        return False


def available_denoise_engine() -> str:
    """Resolve DENOISE_ENGINE ('auto' picks the best installed engine)."""
    pref = settings.denoise_engine
    if pref == "off":
        return "off"
    if pref in ("deepfilternet", "deepfilter-bin"):
        if deepfilter_binary():
            return "deepfilter-bin"
        return "deepfilternet" if _deepfilternet_python_ok() else "off"
    if pref == "noisereduce":
        return "noisereduce" if _has_module("noisereduce") else "off"
    # auto — best quality first
    if deepfilter_binary():
        return "deepfilter-bin"
    if _deepfilternet_python_ok():
        return "deepfilternet"
    if _has_module("noisereduce"):
        return "noisereduce"
    return "off"


_dfn_cache: dict = {}


def _dfn_model():
    if "model" not in _dfn_cache:
        from df import init_df  # type: ignore

        model, df_state, _ = init_df()
        _dfn_cache["model"] = model
        _dfn_cache["state"] = df_state
    return _dfn_cache["model"], _dfn_cache["state"]


def _resample(x: np.ndarray, src_sr: int, dst_sr: int) -> np.ndarray:
    if src_sr == dst_sr:
        return x
    from math import gcd

    from scipy.signal import resample_poly

    g = gcd(src_sr, dst_sr)
    return resample_poly(x, dst_sr // g, src_sr // g).astype(np.float32)


def _denoise_deepfilternet(mono: np.ndarray, sr: int) -> np.ndarray:
    import torch  # type: ignore
    from df import enhance  # type: ignore

    model, df_state = _dfn_model()
    target_sr = int(df_state.sr())
    x = _resample(mono, sr, target_sr)
    step = _DFN_CHUNK_SECONDS * target_sr
    pieces = []
    for start in range(0, len(x), step):
        seg = torch.from_numpy(np.ascontiguousarray(x[start:start + step], dtype=np.float32)).unsqueeze(0)
        with torch.no_grad():
            out = enhance(model, df_state, seg)
        pieces.append(out.squeeze(0).detach().cpu().numpy().astype(np.float32))
    y = np.concatenate(pieces) if pieces else x
    return _resample(y, target_sr, sr)


def _deepfilter_command(binary: str, output_dir: str, src_wav: Path, postfilter: bool) -> list[str]:
    command = [binary, "-D"]
    if postfilter:
        command.append("--pf")
    return [*command, "--output-dir", output_dir, str(src_wav)]


def _denoise_deepfilter_bin(src_wav: Path, binary: str) -> tuple[np.ndarray, int]:
    """Run the native DeepFilterNet binary on a 48 kHz WAV and read the result.

    -D compensates the STFT/lookahead delay so the cleaned copy stays sample
    aligned with the original.
    """
    with tempfile.TemporaryDirectory() as tmp:
        # The Rust WAV reader rejects >16-bit samples ("TooWide"), and our work
        # file is 24-bit, so hand it a 16-bit copy. No practical loss: 16-bit
        # already exceeds any phone mic's dynamic range, the pristine 24-bit
        # original is never touched, and this copy exists only for listening.
        staged = Path(tmp) / "in16.wav"
        _run_ffmpeg([
            "-y", "-i", str(src_wav), "-vn",
            "-ac", "1", "-ar", str(WORK_SAMPLE_RATE),
            "-c:a", "pcm_s16le", str(staged),
        ])
        src_wav = staged
        cmd = _deepfilter_command(binary, tmp, src_wav, settings.deepfilter_postfilter)
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
        if proc.returncode != 0:
            raise AudioError(f"deep-filter failed: {proc.stderr.strip()[-400:]}")
        out = Path(tmp) / src_wav.name
        if out.resolve() == src_wav.resolve() or not out.is_file():
            produced = list(Path(tmp).glob("*.wav"))
            if not produced:
                raise AudioError("deep-filter produced no output")
            out = produced[0]
        data, sr = sf.read(str(out), dtype="float32", always_2d=True)
    mono = data.mean(axis=1).astype(np.float32) if data.shape[1] > 1 else data[:, 0]
    return mono, sr


def _denoise_noisereduce(mono: np.ndarray, sr: int) -> np.ndarray:
    import noisereduce as nr  # type: ignore

    y = nr.reduce_noise(y=mono, sr=sr, stationary=False, prop_decrease=settings.denoise_strength)
    return np.asarray(y, dtype=np.float32)


def denoise_wav(src_wav: Path, dst: Path, engine: Optional[str] = None) -> tuple[Optional[Path], str]:
    """Denoise a WAV file. Writes a 24-bit FLAC/WAV copy to `dst`.

    Returns (path or None if skipped, engine used). The original is never touched.
    """
    engine = engine or available_denoise_engine()
    if engine == "off":
        return None, "off"

    data, sr = sf.read(str(src_wav), dtype="float32", always_2d=True)
    mono = data.mean(axis=1).astype(np.float32) if data.shape[1] > 1 else data[:, 0]
    if mono.size == 0:
        raise AudioError("empty audio")

    try:
        if engine == "deepfilter-bin":
            binary = deepfilter_binary()
            if not binary:
                raise AudioError("deep-filter binary not found")
            # The binary needs 48 kHz; decode_to_wav already produces that.
            cleaned, sr = _denoise_deepfilter_bin(src_wav, binary)
        elif engine == "deepfilternet":
            cleaned = _denoise_deepfilternet(mono, sr)
        elif engine == "noisereduce":
            cleaned = _denoise_noisereduce(mono, sr)
        else:
            return None, "off"
    except AudioError:
        raise
    except Exception as exc:  # noqa: BLE001 - surface any engine failure
        raise AudioError(f"{engine} failed: {exc}") from exc

    cleaned = np.clip(cleaned, -1.0, 1.0).astype(np.float32)
    dst.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(dst), cleaned, sr, subtype="PCM_24")
    return dst, engine
