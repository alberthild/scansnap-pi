#!/usr/bin/env bash
# Verifies that a deployment-specific scanner identifier comes from config.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASE_DIR="$(mktemp -d)"
trap 'rm -rf "$CASE_DIR"' EXIT

FAKE_BIN="$CASE_DIR/fake-bin"
TEST_HOME="$CASE_DIR/home"
mkdir -p "$FAKE_BIN" "$TEST_HOME/.config/scansnap" "$TEST_HOME/bin"

ln -s "$ROOT/tests/fixtures/scanimage" "$FAKE_BIN/scanimage"
for command_name in identify convert djpeg cjpeg img2pdf curl; do
  ln -s /usr/bin/true "$FAKE_BIN/$command_name"
done

printf '%s\n' \
  'SCANNER_DEVICE="fujitsu:ScanSnap iX500:community-device"' \
  'WEBDAV_URL=https://cloud.example.com/remote.php/dav/files/scanner/Scans/' \
  'WEBDAV_USER=scanner' \
  'WEBDAV_PASSWORD=example-app-password' \
  "SCANSNAP_TMPDIR=$CASE_DIR" \
  > "$TEST_HOME/.config/scansnap/scansnap.env"

printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$TEST_HOME/bin/scansnap-normalize-image.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$TEST_HOME/bin/scansnap-upload-bg.sh"
chmod +x "$TEST_HOME/bin/scansnap-normalize-image.sh" "$TEST_HOME/bin/scansnap-upload-bg.sh"

TEST_SCAN_ARGS="$CASE_DIR/scan-args" \
HOME="$TEST_HOME" \
PATH="$FAKE_BIN:$PATH" \
  "$ROOT/pi/bin/scansnap-upload.sh"

grep -F -- '--device-name fujitsu:ScanSnap iX500:community-device' "$CASE_DIR/scan-args" >/dev/null

printf '%s\n' 'PASS: scanner device is loaded from the community configuration'
