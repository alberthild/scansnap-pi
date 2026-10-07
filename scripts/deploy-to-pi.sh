#!/usr/bin/env bash
set -euo pipefail
TARGET="${1:-pi-host}"
SCAN_USER="${2:-scansnap}"
[[ "$SCAN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo 'Invalid scan user' >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REMOTE_TMP="/tmp/scansnap-pi-deploy"
ssh "$TARGET" "id '$SCAN_USER' >/dev/null && mkdir -p '$REMOTE_TMP'"
scp -r pi scripts/install-on-pi.sh "$TARGET:$REMOTE_TMP/"
ssh "$TARGET" "sudo bash '$REMOTE_TMP/install-on-pi.sh' '$SCAN_USER' '$REMOTE_TMP'"
echo "Deploy complete for $SCAN_USER on $TARGET."
