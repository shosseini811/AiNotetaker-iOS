#!/usr/bin/env bash
# Generate a self-signed TLS certificate so the iPhone microphone works over LAN.
#
#   ./scripts/gen_cert.sh [extra-hostname-or-ip ...]
#
# It auto-detects this machine's LAN IPs. Pass extra hostnames/IPs as arguments
# if needed. After generating, ./run.sh will serve HTTPS automatically.
#
# NOTE: a self-signed cert must be trusted on the iPhone the first time
# (Settings → General → About → Certificate Trust Settings). For a smoother
# experience with a valid certificate, use Tailscale instead — see the README.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

mkdir -p certs

SANS="DNS:localhost,IP:127.0.0.1"

add_san() {
  local v="$1"
  if [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    SANS="$SANS,IP:$v"
  else
    SANS="$SANS,DNS:$v"
  fi
}

# Extra hostnames/IPs from arguments.
for arg in "$@"; do add_san "$arg"; done

# Auto-detect this host's LAN IPv4 addresses (macOS and Linux).
detect_ips() {
  if command -v ipconfig >/dev/null 2>&1; then          # macOS
    for iface in $(networksetup -listallhardwareports 2>/dev/null \
                     | awk '/Device:/{print $2}'); do
      ipconfig getifaddr "$iface" 2>/dev/null || true
    done
  fi
  if command -v ifconfig >/dev/null 2>&1; then          # macOS + BSD fallback
    ifconfig 2>/dev/null | awk '/inet /{print $2}'
  elif command -v hostname >/dev/null 2>&1; then        # Linux
    hostname -I 2>/dev/null || true
  fi
}

for ip in $(detect_ips | sort -u); do
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
  [[ "$ip" == "127.0.0.1" ]] && continue
  add_san "$ip"
done

echo "Generating self-signed certificate"
echo "  Subject Alternative Names: $SANS"

openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 825 \
  -keyout certs/key.pem -out certs/cert.pem \
  -subj "/CN=AiNotetaker" \
  -addext "subjectAltName=$SANS" >/dev/null 2>&1

chmod 600 certs/key.pem
echo "Wrote certs/cert.pem and certs/key.pem"
echo "Now start the app with ./run.sh — it will serve HTTPS."
