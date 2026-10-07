#!/usr/bin/env bash
# Process a copied job; originals remain in JOB/raw until confirmed upload.
set -euo pipefail
JOB="${1:?job directory required}"
WORK="$JOB/work"
SOURCE="${SOURCE:-ADF Duplex}"
BLANK_THRESHOLD="${BLANK_THRESHOLD:-0.96}"
JPEG_QUALITY="${JPEG_QUALITY:-60}"
IMAGE_NORMALIZER="${HOME}/bin/scansnap-normalize-image.sh"
LOG="$JOB/process.log"
log() { echo "$(date -Iseconds) $*"; }
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
  touch "$JOB/empty"
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
  for first in "${PAGE_FILES[@]}"; do
    number="${first##*/page-}"
    number="${number%.jpg}"
    number=$((10#$number))
    (( number % 2 == 1 )) || continue
    printf -v second '%s/page-%03d.jpg' "$WORK" "$((number + 1))"
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
PDF_NAME="result.pdf"
PDF_LOCAL="$JOB/result.part.pdf"
if ! img2pdf "$WORK"/page-*.jpg -o "$PDF_LOCAL" 2>>"$LOG"; then
  log "ERROR: img2pdf fehlgeschlagen"; exit 5
fi
log "==> PDF: $PDF_NAME ($(du -h "$PDF_LOCAL" | cut -f1))"

# The worker fsyncs, renames, and records the checksum before upload.
