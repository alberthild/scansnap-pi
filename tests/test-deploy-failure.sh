#!/usr/bin/env bash
# The deploy must fail when any remote installation command fails.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_BIN="$ROOT/tests/fixtures/deploy"
REMOTE_BIN="$LOCAL_BIN/remote"

set +e
TEST_REMOTE_BIN="$REMOTE_BIN" PATH="$LOCAL_BIN:$PATH" \
  "$ROOT/scripts/deploy-to-pi.sh" admin@pi-host >/dev/null 2>&1
DEPLOY_RC=$?
set -e

if [[ "$DEPLOY_RC" -eq 0 ]]; then
  printf '%s\n' 'FAIL: deploy reported success after remote install failed' >&2
  exit 1
fi

printf '%s\n' 'PASS: deploy propagates remote installation failures'
