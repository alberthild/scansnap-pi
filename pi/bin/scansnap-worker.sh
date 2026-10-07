#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/scansnap-config.sh"
exec python3 "$SCRIPT_DIR/scansnap-queue.py" "${@:-worker}"
