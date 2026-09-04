#!/usr/bin/env bash
# Give AiNotetaker one private HTTPS address that works on Wi-Fi and cellular.
# This uses Tailscale Serve (tailnet-only), never the public Tailscale Funnel.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This setup script is intended for the Mac that runs AiNotetaker."
  exit 1
fi

if command -v tailscale >/dev/null 2>&1; then
  TAILSCALE_BIN="$(command -v tailscale)"
elif [[ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then
  TAILSCALE_BIN=/Applications/Tailscale.app/Contents/MacOS/Tailscale
else
  echo "Install and sign in to Tailscale on this Mac first: https://tailscale.com/download/mac"
  exit 1
fi

STATUS_JSON="$("$TAILSCALE_BIN" status --json 2>/dev/null || true)"
if [[ -z "$STATUS_JSON" ]]; then
  echo "Tailscale is installed but not connected. Open Tailscale and sign in, then run this again."
  exit 1
fi

DNS_NAME="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("Self",{}).get("DNSName") or "").rstrip("."))' <<<"$STATUS_JSON")"
BACKEND_STATE="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState", ""))' <<<"$STATUS_JSON")"
if [[ "$BACKEND_STATE" != "Running" || -z "$DNS_NAME" ]]; then
  echo "Tailscale is not ready. Open it, connect, and run this script again."
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  if [[ ! -f "$ROOT_DIR/.env.example" ]]; then
    echo "Missing .env.example. Run this script from the AiNotetaker repository."
    exit 1
  fi
  cp "$ROOT_DIR/.env.example" "$ENV_FILE"
fi

# Bind the app only to localhost. Tailscale Serve is the sole remote entry
# point, so the server is not exposed directly to the LAN or public internet.
API_TOKEN_VALUE="$(python3 - "$ENV_FILE" <<'PY'
from pathlib import Path
import secrets
import sys

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()

def current(key: str) -> str:
    for line in lines:
        stripped = line.strip()
        if stripped.startswith(key + "="):
            return stripped.split("=", 1)[1].strip().strip('"').strip("'")
    return ""

def put(key: str, value: str) -> None:
    prefix = key + "="
    for index, line in enumerate(lines):
        if line.strip().startswith(prefix):
            lines[index] = prefix + value
            return
    lines.extend(["", prefix + value])

token = current("API_TOKEN") or secrets.token_hex(24)
put("API_TOKEN", token)
put("HOST", "127.0.0.1")
path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
path.chmod(0o600)
print(token)
PY
)"

echo "Configuring private HTTPS access through Tailscale…"
"$TAILSCALE_BIN" serve --bg 8000

SERVICE_NAME="gui/$(id -u)/com.ainotetaker.server"
if launchctl print "$SERVICE_NAME" >/dev/null 2>&1; then
  launchctl kickstart -k "$SERVICE_NAME"
  SERVER_NOTE="The background server was restarted with the safer localhost-only setting."
else
  SERVER_NOTE="Start AiNotetaker with ./run.sh (or install its launchd service) after this setup."
fi

REMOTE_URL="https://$DNS_NAME"
echo
echo "AiNotetaker private remote access is ready."
echo
echo "In AiNotetaker → Settings, enter:"
echo "  Address:   $REMOTE_URL"
echo "  API token: $API_TOKEN_VALUE"
echo
echo "$SERVER_NOTE"
echo "On the iPhone, enable Tailscale VPN On Demand → Always for Wi-Fi and Cellular."
echo "This uses Tailscale Serve only. It does not make AiNotetaker public."
