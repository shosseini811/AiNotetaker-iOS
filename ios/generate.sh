#!/usr/bin/env bash
# Regenerate AiNotetaker.xcodeproj from project.yml.
#   cd ios && ./generate.sh
#
# Safe to re-run any time the Swift sources or project.yml change — your
# signing team (Config/Local.xcconfig) is preserved across regenerations.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found on PATH." >&2
  echo "  brew install xcodegen" >&2
  echo "  (or build from source: https://github.com/yonaskolb/XcodeGen)" >&2
  exit 1
fi

if [ ! -f Config/Local.xcconfig ]; then
  cp Config/Local.xcconfig.example Config/Local.xcconfig
  echo "Created Config/Local.xcconfig (git-ignored)."
  echo "  Set DEVELOPMENT_TEAM there, or pick your Team once in Xcode's"
  echo "  Signing & Capabilities UI and copy the ID it resolves to back in."
fi

xcodegen generate
echo "Generated AiNotetaker.xcodeproj — open it with: open AiNotetaker.xcodeproj"
