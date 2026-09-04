#!/usr/bin/env bash
# Convenience launcher for AiNotetaker.
#   ./run.sh
# Uses ./.venv if present, otherwise the system python3 (override with $PYTHON).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if [ -x ".venv/bin/python" ]; then
  PY=".venv/bin/python"
else
  PY="${PYTHON:-python3}"
fi

exec "$PY" run.py
