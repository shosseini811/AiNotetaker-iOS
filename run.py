#!/usr/bin/env python3
"""Start AiNotetaker.

Reads configuration from the environment / .env (via app.config) and launches
uvicorn. If a TLS certificate exists under ./certs, it serves HTTPS
automatically (required for the iPhone microphone). Otherwise it serves plain
HTTP, which is fine for localhost or behind a TLS proxy such as Tailscale.
"""
from __future__ import annotations

import sys

import uvicorn

from app.config import BASE_DIR, settings


def main() -> None:
    # Under launchd (or nohup), stdout isn't a terminal, so Python fully buffers
    # it instead of flushing per line. Since uvicorn.run() below blocks forever,
    # the banner would otherwise never reach the log file at all.
    sys.stdout.reconfigure(line_buffering=True)

    cert = BASE_DIR / "certs" / "cert.pem"
    key = BASE_DIR / "certs" / "key.pem"

    ssl_kwargs = {}
    scheme = "http"
    if cert.is_file() and key.is_file():
        ssl_kwargs = {"ssl_certfile": str(cert), "ssl_keyfile": str(key)}
        scheme = "https"

    host_display = "localhost" if settings.host in ("0.0.0.0", "127.0.0.1") else settings.host
    print("\n  AiNotetaker")
    print(f"  → {scheme}://{host_display}:{settings.port}   (Ctrl+C to stop)\n")
    print(f"  • Web login:    {'password protected' if settings.app_password else ('token accepted as password' if settings.api_token else 'OPEN — set APP_PASSWORD in .env')}")
    print(f"  • iOS app token: {'set (API_TOKEN)' if settings.api_token else 'NOT set — add API_TOKEN to .env for the iPhone app'}")
    voice_status = (
        f"ready ({settings.transcribe_provider})"
        if settings.transcription_configured
        else "NOT set up — configure a transcription provider in .env"
    )
    print(f"  • Voice-to-text: {voice_status}")
    from app import audio as audio_tools
    print(f"  • Noise removal: {audio_tools.available_denoise_engine()}")
    print(f"  • AI analysis:  {'ready' if settings.analysis_configured else 'NOT set up — add OPENROUTER_API_KEY to .env'}")

    from app import network
    endpoints = network.advertised_endpoints(refresh=True)
    if endpoints["remote_url"]:
        print(f"  • Away from Wi-Fi: {endpoints['remote_url']}")
        print("                  (the iPhone app picks this up automatically)")
    else:
        print("  • Away from Wi-Fi: no address yet — this server only answers on")
        print("                  the local network. Run scripts/setup-remote-access.sh.")
    if scheme == "http":
        print("  • HTTPS:        off — fine for the iPhone app. The *web* app's microphone")
        print("                  needs HTTPS: run scripts/gen_cert.sh or use Tailscale (see README).")
    print()

    uvicorn.run(
        "app.main:app",
        host=settings.host,
        port=settings.port,
        log_level="info",
        **ssl_kwargs,
    )


if __name__ == "__main__":
    main()
