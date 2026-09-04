#!/usr/bin/env bash
# Build AiNotetaker and install it straight onto your paired iPhone.
#
#   cd ios && ./deploy_to_device.sh
#
# Meant to run on the same Mac you already use for AiNotetaker in Xcode, so it
# reuses your existing wireless device pairing and free-tier signing.
#
# One-time prerequisites: the iPhone paired for wireless debugging in Xcode,
# and ios/Config/Local.xcconfig holding your DEVELOPMENT_TEAM (created by
# ./generate.sh — see Config/Local.xcconfig.example).
#
# Optional environment variables:
#   IOS_DEVELOPMENT_TEAM   Apple Developer Team ID. If set, overwrites
#                          Config/Local.xcconfig with this value (leave it
#                          unset to keep whatever generate.sh made).
#   IOS_DEVICE_UDID        Install target device UDID. If unset, this script
#                          tries to auto-detect a single connected iPhone and
#                          prints every paired device it saw either way —
#                          copy the UDID from that list and export
#                          IOS_DEVICE_UDID if auto-detection picks wrong (or
#                          you have more than one iPhone paired).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

BUNDLE_ID="com.example.ainotetaker"
DERIVED_DATA="build"
APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/AiNotetaker.app"

if [ -n "${IOS_DEVELOPMENT_TEAM:-}" ]; then
  echo "DEVELOPMENT_TEAM = $IOS_DEVELOPMENT_TEAM" > Config/Local.xcconfig
  echo "Wrote Config/Local.xcconfig from \$IOS_DEVELOPMENT_TEAM."
fi

./generate.sh

# Config/Local.xcconfig is git-ignored, so a fresh clone only has the blank
# example that generate.sh copies into place. Catch that clearly here instead
# of failing deep inside xcodebuild with a cryptic signing error.
if ! grep -qE '^DEVELOPMENT_TEAM\s*=\s*\S+' Config/Local.xcconfig 2>/dev/null; then
  echo "error: DEVELOPMENT_TEAM is not set in ios/Config/Local.xcconfig." >&2
  echo "  Edit that file directly (see Config/Local.xcconfig.example), or" >&2
  echo "  export IOS_DEVELOPMENT_TEAM and re-run — this script then writes it" >&2
  echo "  into Config/Local.xcconfig for you." >&2
  exit 1
fi

echo "==> Building (Release, automatic signing)…"
# Optional: unlock the login keychain explicitly. Leave KEYCHAIN_PASSWORD unset
# unless signing fails with errSecInternalComponent, and prefer the one-time
# partition-list fix printed below (it stores no password).
if [ -n "${KEYCHAIN_PASSWORD:-}" ]; then
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$HOME/Library/Keychains/login.keychain-db"
fi
set -o pipefail
BUILD_LOG="$(mktemp)"
if ! xcodebuild \
  -project AiNotetaker.xcodeproj -scheme AiNotetaker -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  build 2>&1 | tee "$BUILD_LOG" | tail -n 200; then
  if grep -q "errSecInternalComponent" "$BUILD_LOG"; then
    cat >&2 <<'MSG'

error: codesign could not use the signing key (errSecInternalComponent).
  This happens when the build runs in a security session that cannot reach
  the login keychain (a background service, an ssh session, a CI agent),
  even though the same build works in Terminal. Grant codesign access to
  the key once — it asks for your login password and stores nothing:

    security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
      ~/Library/Keychains/login.keychain-db

  Then run this script again.
MSG
  fi
  rm -f "$BUILD_LOG"
  exit 65
fi
rm -f "$BUILD_LOG"

if [ ! -d "$APP_PATH" ]; then
  echo "error: build did not produce $APP_PATH" >&2
  exit 1
fi

echo "==> Looking for a paired iPhone…"
DEVICES_JSON="$(mktemp)"
xcrun devicectl list devices --json-output "$DEVICES_JSON" >/dev/null
python3 - "$DEVICES_JSON" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for d in data.get("result", {}).get("devices", []):
    name = d.get("deviceProperties", {}).get("name", "?")
    udid = d.get("hardwareProperties", {}).get("udid", "?")
    state = d.get("connectionProperties", {}).get("tunnelState", "?")
    kind = d.get("hardwareProperties", {}).get("deviceType", "?")
    print(f"  {name}  udid={udid}  type={kind}  state={state}")
PY

DEVICE_UDID="${IOS_DEVICE_UDID:-}"
if [ -z "$DEVICE_UDID" ]; then
  DEVICE_UDID="$(python3 - "$DEVICES_JSON" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
devices = data.get("result", {}).get("devices", [])
connected = [
    d for d in devices
    if d.get("hardwareProperties", {}).get("deviceType") == "iPhone"
    and d.get("connectionProperties", {}).get("tunnelState") == "connected"
]
pool = connected or [d for d in devices if d.get("hardwareProperties", {}).get("deviceType") == "iPhone"]
if len(pool) == 1:
    print(pool[0]["hardwareProperties"]["udid"])
PY
)"
fi
rm -f "$DEVICES_JSON"

if [ -z "$DEVICE_UDID" ]; then
  echo "error: couldn't auto-detect exactly one iPhone. Set IOS_DEVICE_UDID to" >&2
  echo "  one of the udid values printed above (as a GitHub Actions secret for" >&2
  echo "  the deploy workflow, or exported in your shell to run this manually)." >&2
  exit 1
fi

echo "==> Installing to device ${DEVICE_UDID}…"
xcrun devicectl device install app --device "$DEVICE_UDID" "$APP_PATH"

echo "==> Launching…"
xcrun devicectl device process launch --terminate-existing --device "$DEVICE_UDID" "$BUNDLE_ID" || true

echo "Done — AiNotetaker installed and launched."
