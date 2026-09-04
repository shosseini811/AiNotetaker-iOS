#!/usr/bin/env bash
# Install DeepFilterNet's standalone binary — high-quality neural noise removal
# that runs in real time on CPU (18x realtime on an M1), no PyTorch needed.
#
#   ./scripts/install-deepfilter.sh
#
# Downloads the right build for this machine into ~/.local/bin/deep-filter.
# The server picks it up automatically (DENOISE_ENGINE=auto). Set
# DEEPFILTER_BIN in .env to use a different location.
set -euo pipefail

VER="${DEEPFILTER_VERSION:-0.5.6}"
DEST="${DEEPFILTER_DEST:-$HOME/.local/bin/deep-filter}"

os="$(uname -s)"; arch="$(uname -m)"
case "$os/$arch" in
  Darwin/arm64)   asset="deep-filter-${VER}-aarch64-apple-darwin" ;;
  Darwin/x86_64)  asset="deep-filter-${VER}-x86_64-apple-darwin" ;;
  Linux/aarch64)  asset="deep-filter-${VER}-aarch64-unknown-linux-gnu" ;;
  Linux/x86_64)   asset="deep-filter-${VER}-x86_64-unknown-linux-musl" ;;
  Linux/armv7l)   asset="deep-filter-${VER}-armv7-unknown-linux-gnueabihf" ;;
  *) echo "error: no prebuilt deep-filter for $os/$arch" >&2; exit 1 ;;
esac

url="https://github.com/Rikorose/DeepFilterNet/releases/download/v${VER}/${asset}"
mkdir -p "$(dirname "$DEST")"
echo "Downloading $asset …"
curl -fsSL "$url" -o "$DEST"
chmod +x "$DEST"
# macOS quarantines downloaded executables; clear it so launchd can run it.
[ "$os" = "Darwin" ] && xattr -d com.apple.quarantine "$DEST" 2>/dev/null || true

"$DEST" --help >/dev/null 2>&1 && echo "Installed: $DEST" || { echo "error: binary did not run" >&2; exit 1; }
echo "Restart the server to switch to it:"
echo "  launchctl kickstart -k gui/\$(id -u)/com.ainotetaker.server"
