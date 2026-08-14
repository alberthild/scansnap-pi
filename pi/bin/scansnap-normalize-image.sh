#!/usr/bin/env bash
# Normalize a scanned page by deskewing it and trimming the white border.
set -euo pipefail

FORCE_RECEIPT=false
if [[ "${1:-}" == "--receipt" ]]; then
  FORCE_RECEIPT=true
  shift
fi

IMAGE="${1:?Pfad zum JPEG fehlt}"
[[ -f "$IMAGE" ]] || { echo "Bild nicht gefunden: $IMAGE" >&2; exit 1; }

read -r ORIGINAL_WIDTH ORIGINAL_HEIGHT < <(identify -format '%w %h\n' "$IMAGE")
TMP="${IMAGE%.jpg}.normalized.jpg"
trap 'rm -f "$TMP"' EXIT

convert "$IMAGE" \
  -bordercolor white -border 20 \
  -fuzz 10% -trim +repage \
  -background white -deskew 40% \
  -bordercolor white -border 20 \
  -fuzz 10% -trim +repage \
  -bordercolor white -border 20 \
  -strip "$TMP"

read -r NORMALIZED_WIDTH NORMALIZED_HEIGHT < <(identify -format '%w %h\n' "$TMP")
if (( NORMALIZED_WIDTH < 100 || NORMALIZED_HEIGHT < 100 )); then
  echo "Normalisierung verworfen: Ergebnis ${NORMALIZED_WIDTH}x${NORMALIZED_HEIGHT} unplausibel" >&2
  exit 0
fi

mv "$TMP" "$IMAGE"

# Schmale, lange Seiten sind Kassenbons. Den hellen Durchdruck entfernen,
# A4-Dokumente dagegen unverändert in Farbe lassen.
if [[ "$FORCE_RECEIPT" == true ]] || (( NORMALIZED_WIDTH * 100 < NORMALIZED_HEIGHT * 55 )); then
  CLEANED="${IMAGE%.jpg}.cleaned.jpg"
  CROPPED="${IMAGE%.jpg}.cropped.jpg"
  trap 'rm -f "$CLEANED" "$CROPPED"' EXIT
  convert "$IMAGE" \
    -colorspace Gray \
    -white-threshold 75% \
    -contrast-stretch 1%x1% \
    -strip "$CLEANED"

  convert "$CLEANED" \
    -bordercolor white -border 20 \
    -fuzz 5% -trim +repage \
    -bordercolor white -border 20 \
    -strip "$CROPPED"
  read -r CROPPED_WIDTH CROPPED_HEIGHT < <(identify -format '%w %h\n' "$CROPPED")
  if (( CROPPED_WIDTH >= 100 && CROPPED_HEIGHT >= 100 )); then
    mv "$CROPPED" "$IMAGE"
    rm -f "$CLEANED"
  else
    mv "$CLEANED" "$IMAGE"
    rm -f "$CROPPED"
  fi
  echo "Normalisiert: ${ORIGINAL_WIDTH}x${ORIGINAL_HEIGHT} -> ${NORMALIZED_WIDTH}x${NORMALIZED_HEIGHT}; Belegkontrast angewandt"
else
  echo "Normalisiert: ${ORIGINAL_WIDTH}x${ORIGINAL_HEIGHT} -> ${NORMALIZED_WIDTH}x${NORMALIZED_HEIGHT}"
fi
trap - EXIT
