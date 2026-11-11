#!/bin/zsh
# Skapar/uppdaterar Python-miljön som Transkribering använder för lokal transkribering.
# Miljön hamnar i ~/Library/Application Support/Transkribering/venv
#
# Användning: scripts/setup_backend.sh [sökväg/till/requirements.txt]
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REQ="${1:-$SCRIPT_DIR/../backend/requirements.txt}"
SUPPORT="$HOME/Library/Application Support/Transkribering"
VENV="$SUPPORT/venv"

# Välj en Python >= 3.10 (MLX kräver Apple silicon och en nyare Python)
PY=""
for cand in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3 python3; do
  if command -v "$cand" >/dev/null 2>&1; then
    if "$cand" -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
      PY="$cand"; break
    fi
  fi
done
if [[ -z "$PY" ]]; then
  echo "Hittade ingen Python 3.10+. Installera t.ex. med: brew install python" >&2
  exit 1
fi

echo "Använder $PY ($($PY --version))"
mkdir -p "$SUPPORT"
if [[ ! -x "$VENV/bin/python" ]]; then
  echo "Skapar virtuell miljö i $VENV"
  "$PY" -m venv "$VENV"
fi

"$VENV/bin/python" -m pip install --upgrade pip --quiet
echo "Installerar beroenden från $REQ"
"$VENV/bin/python" -m pip install -r "$REQ"
echo "Klart. Backend-miljön finns i $VENV"
