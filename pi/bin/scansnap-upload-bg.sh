#!/usr/bin/env bash
# Upload PDFs to WebDAV in the background.
# Aufruf: scansnap-upload-bg.sh <pfad-zur-pdf>
set -uo pipefail

status_led() {
  if [[ -n "${SCANSNAP_LED_JOB_ID:-}" && -x "$HOME/bin/scansnap-led.sh" ]]; then
    "$HOME/bin/scansnap-led.sh" "$1" "$SCANSNAP_LED_JOB_ID" || true
  fi
}
finish_upload() {
  local rc=$?
  trap - EXIT
  if (( rc == 0 )); then status_led end; else status_led fail; fi
  exit "$rc"
}
trap finish_upload EXIT

PDF="${1:?Pfad zur PDF fehlt}"
[[ -f "$PDF" ]] || { echo "PDF nicht gefunden: $PDF" >&2; exit 1; }

SCANSNAP_CONFIG="${SCANSNAP_CONFIG:-${HOME}/.config/scansnap/scansnap.env}"
LOG="${HOME}/scansnap.log"
FAILED_DIR="${HOME}/scansnap-failed"
RETRIES=3
RETRY_WAIT=10

[[ -r "$SCANSNAP_CONFIG" ]] || { echo "ERROR: $SCANSNAP_CONFIG is not readable" >&2; exit 2; }
source "$(dirname "$0")/scansnap-config.sh" || exit 2
: "${WEBDAV_URL:?WEBDAV_URL is not set}"
: "${WEBDAV_USER:?WEBDAV_USER is not set}"
: "${WEBDAV_PASSWORD:?WEBDAV_PASSWORD is not set}"

mkdir -p "$FAILED_DIR"
log() { echo "$(date -Iseconds) [bg-$$] $*" >> "$LOG"; }

BASENAME=$(basename "$PDF")
REMOTE_URL="${WEBDAV_URL%/}/$BASENAME"
AUTH_HEADER="Basic $(printf '%s:%s' "$WEBDAV_USER" "$WEBDAV_PASSWORD" | base64)"

log "==> BG-WebDAV-Upload Start: $BASENAME → $REMOTE_URL"

HTTP_CODE=000
for attempt in $(seq 1 "$RETRIES"); do
  HTTP_CODE=$(curl -sS -m 600 -o /tmp/webdav_resp.txt -w "%{http_code}" \
    -X PUT \
    -H "Authorization: $AUTH_HEADER" \
    -H "Content-Type: application/pdf" \
    --data-binary @"$PDF" \
    "$REMOTE_URL" || echo "000")
  if [[ "$HTTP_CODE" =~ ^(2[0-9]{2}|204)$ ]]; then
    log "==> BG-WebDAV-Upload OK (Versuch $attempt), HTTP=$HTTP_CODE"
    rm -f "$PDF"
    exit 0
  fi
  log "WARN: BG-WebDAV-Versuch $attempt → HTTP=$HTTP_CODE, Antwort: $(head -c 200 /tmp/webdav_resp.txt)"
  [[ "$attempt" -lt "$RETRIES" ]] && sleep "$RETRY_WAIT"
done

RESCUE="$FAILED_DIR/$BASENAME"
mv "$PDF" "$RESCUE"
log "ERROR: BG-WebDAV-Upload nach $RETRIES Versuchen gescheitert. Gerettet: $RESCUE"
exit 6
