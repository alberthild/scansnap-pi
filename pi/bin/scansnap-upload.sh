#!/usr/bin/env bash
# Button action: capture durably, queue, and release the scanner immediately.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if ! source "$SCRIPT_DIR/scansnap-config.sh"; then
  if [[ -x "$HOME/bin/scansnap-led.sh" ]]; then
    JOB="${SCANSNAP_LED_JOB_ID:-config-$$}"
    "$HOME/bin/scansnap-led.sh" begin "$JOB" || true
    "$HOME/bin/scansnap-led.sh" fail "$JOB" || true
  fi
  exit 2
fi
exec python3 "$SCRIPT_DIR/scansnap-queue.py" capture
