#!/usr/bin/env bash
# Optional indicator; never prevent scanning if the LED is unavailable.
set -uo pipefail
HELPER=/usr/local/libexec/scansnap-status-led
[[ -x "$HELPER" ]] || exit 0
if ! sudo -n "$HELPER" "$@"; then
  echo "WARN: ScanSnap LED status could not be updated" >&2
fi
