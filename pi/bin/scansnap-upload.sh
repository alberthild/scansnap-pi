#!/usr/bin/env bash
# ScanSnap iX500 → PDF → WebDAV upload
set -euo pipefail

SCANSNAP_CONFIG="${SCANSNAP_CONFIG:-${HOME}/.config/scansnap/scansnap.env}"
[[ -r "$SCANSNAP_CONFIG" ]] || { echo "ERROR: $SCANSNAP_CONFIG is not readable" >&2; exit 2; }
set -a; source "$SCANSNAP_CONFIG"; set +a

: "${SCANNER_DEVICE:?SCANNER_DEVICE is not set}"
: "${WEBDAV_URL:?WEBDAV_URL is not set}"
: "${WEBDAV_USER:?WEBDAV_USER is not set}"
: "${WEBDAV_PASSWORD:?WEBDAV_PASSWORD is not set}"

# --- Dependency checks ---
for cmd in scanimage identify convert djpeg cjpeg img2pdf curl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: required command '$cmd' not found" >&2; exit 1; }
done

RESOLUTION="${RESOLUTION:-200}"
MODE="${MODE:-Color}"
SOURCE="${SOURCE:-ADF Duplex}"
PAGE_WIDTH="${PAGE_WIDTH:-210}"
PAGE_HEIGHT="${PAGE_HEIGHT:-297}"
BLANK_THRESHOLD="${BLANK_THRESHOLD:-0.96}"
JPEG_QUALITY="${JPEG_QUALITY:-60}"
SCANSNAP_TMPDIR="${SCANSNAP_TMPDIR:-/dev/shm}"
LOG="${HOME}/scansnap.log"
PENDING_DIR="${HOME}/scansnap-pending"
BG_UPLOADER="${HOME}/bin/scansnap-upload-bg.sh"
IMAGE_NORMALIZER="${HOME}/bin/scansnap-normalize-image.sh"

[[ -x "$BG_UPLOADER" ]] || { echo "ERROR: $BG_UPLOADER is missing or not executable" >&2; exit 2; }
[[ -x "$IMAGE_NORMALIZER" ]] || { echo "ERROR: $IMAGE_NORMALIZER is missing or not executable" >&2; exit 2; }
[[ -d "$SCANSNAP_TMPDIR" && -w "$SCANSNAP_TMPDIR" ]] || { echo "ERROR: $SCANSNAP_TMPDIR is not a writable directory" >&2; exit 2; }

if [[ ! "$WEBDAV_URL" =~ ^https?:// ]]; then
  echo "ERROR: WEBDAV_URL must start with http:// or https://" >&2; exit 2
fi

mkdir -p "$PENDING_DIR"
log() { echo "$(date -Iseconds) $*" | tee -a "$LOG"; }

WORK="$(mktemp -d -p "$SCANSNAP_TMPDIR" scansnap.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
log "==> Start, workdir=$WORK"

# --- Scan ---
SCAN_STDERR="$WORK/scan-stderr.log"
set +e
scanimage \
    --device-name "$SCANNER_DEVICE" \
    --source "$SOURCE" --mode "$MODE" --resolution "$RESOLUTION" \
    --page-width "$PAGE_WIDTH" --page-height "$PAGE_HEIGHT" \
    --format=jpeg --batch="$WORK/page-%03d.jpg" 2>"$SCAN_STDERR"
SCAN_RC=$?
set -e
cat "$SCAN_STDERR" >> "$LOG"

PAGES=$(find "$WORK" -maxdepth 1 -type f -name 'page-*.jpg' | wc -l)
if [[ "$PAGES" -eq 0 ]]; then
  if grep -q "out of documents" "$SCAN_STDERR"; then
    log "==> ADF leer."
    logger -t scansnap "ADF leer, kein Scan"
    exit 0
  fi
  log "ERROR: scanimage fehlgeschlagen (rc=$SCAN_RC): $(tail -1 "$SCAN_STDERR")"
  exit 3
fi
log "==> $PAGES Seiten gescannt"

# --- Leere Rückseiten entfernen ---
KEPT=0; DROPPED=0
for jpg in "$WORK"/page-*.jpg; do
  mean=$(identify -define jpeg:size=200x200 -format "%[fx:mean]" "$jpg" 2>/dev/null || echo "0")
  # Korrigierte Logik: sehr helle Seiten = blank (mean > threshold)
  blank=$(awk -v m="$mean" -v t="$BLANK_THRESHOLD" 'BEGIN {print (m > t) ? "yes" : "no"}')
  if [[ "$blank" == "yes" ]]; then
    log "    Leere Seite entfernt: $(basename "$jpg") (mean=$mean)"
    rm -f "$jpg"; DROPPED=$((DROPPED+1))
  else
    log "    Seite behalten:    $(basename "$jpg") (mean=$mean)"
    KEPT=$((KEPT+1))
  fi
done
log "==> Filter: $KEPT behalten, $DROPPED entfernt"

if [[ "$KEPT" -eq 0 ]]; then
  log "==> Alle Seiten leer. Nichts hochzuladen."
  exit 0
fi

# --- Belege begradigen und auf Inhalt zuschneiden ---
PAGE_FILES=("$WORK"/page-*.jpg)
for jpg in "${PAGE_FILES[@]}"; do
  if NORMALIZE_RESULT=$("$IMAGE_NORMALIZER" "$jpg" 2>&1); then
    log "    $NORMALIZE_RESULT"
  else
    log "WARN: Normalisierung fehlgeschlagen für $(basename "$jpg"); Original bleibt erhalten: $NORMALIZE_RESULT"
  fi
done

# Der Scanner liefert bei Duplex-Scans Vorder- und Rückseite direkt
# hintereinander. Erkennt eine Seite einen Beleg, die zugehörige Seite
# ebenfalls als Beleg bereinigen - auch wenn deren heller Durchdruck den
# Zuschnitt zunächst wie A4 aussehen lässt.
if [[ "$SOURCE" == "ADF Duplex" ]]; then
  for (( index=0; index < ${#PAGE_FILES[@]}; index+=2 )); do
    first="${PAGE_FILES[index]}"
    second="${PAGE_FILES[index + 1]:-}"
    [[ -n "$second" && -f "$second" ]] || continue

    read -r first_width first_height < <(identify -format '%w %h\n' "$first")
    read -r second_width second_height < <(identify -format '%w %h\n' "$second")
    first_receipt=false
    second_receipt=false
    (( first_width * 100 < first_height * 55 )) && first_receipt=true
    (( second_width * 100 < second_height * 55 )) && second_receipt=true

    if [[ "$first_receipt" == true && "$second_receipt" == false ]]; then
      NORMALIZE_RESULT=$("$IMAGE_NORMALIZER" --receipt "$second" 2>&1)
      log "    Rückseite als Belegpaar bereinigt: $NORMALIZE_RESULT"
    elif [[ "$second_receipt" == true && "$first_receipt" == false ]]; then
      NORMALIZE_RESULT=$("$IMAGE_NORMALIZER" --receipt "$first" 2>&1)
      log "    Rückseite als Belegpaar bereinigt: $NORMALIZE_RESULT"
    fi
  done
fi

# --- Kompression: JPEG re-encode mit cjpeg (forced) ---
log "==> Komprimiere JPEGs (Quality $JPEG_QUALITY)..."
SIZE_BEFORE=$(du -sb "$WORK" | cut -f1)
for jpg in "$WORK"/page-*.jpg; do
  tmp="$jpg.tmp"
  if djpeg "$jpg" 2>/dev/null | cjpeg -quality "$JPEG_QUALITY" -optimize -progressive > "$tmp"; then
    mv "$tmp" "$jpg"
  else
    rm -f "$tmp"
    log "WARN: JPEG-Kompression fehlgeschlagen für $(basename "$jpg")"
  fi
done
SIZE_AFTER=$(du -sb "$WORK" | cut -f1)
log "==> JPEGs: $((SIZE_BEFORE/1024)) KB -> $((SIZE_AFTER/1024)) KB (Quality $JPEG_QUALITY)"

# --- JPEG → PDF ---
PDF_NAME="scan-$(date +%Y%m%d-%H%M%S).pdf"
PDF_LOCAL="${WORK}/${PDF_NAME}"
if ! img2pdf "$WORK"/page-*.jpg -o "$PDF_LOCAL" 2>>"$LOG"; then
  log "ERROR: img2pdf fehlgeschlagen"; exit 5
fi
log "==> PDF: $PDF_NAME ($(du -h "$PDF_LOCAL" | cut -f1))"

# --- PDF persistent machen bevor WORK gelöscht wird ---
PDF_PERSISTENT="${PENDING_DIR}/${PDF_NAME}"
cp -p "$PDF_LOCAL" "$PDF_PERSISTENT"
log "==> PDF persistent kopiert nach $PDF_PERSISTENT"

# --- Async-WebDAV Upload anstoßen ---
setsid nohup "$BG_UPLOADER" "$PDF_PERSISTENT" >/dev/null 2>&1 < /dev/null &
BG_PID=$!
log "==> Async-WebDAV-Upload PID $BG_PID gestartet für $PDF_NAME"
log "==> Scanner ist frei. Trigger-Skript exit."
