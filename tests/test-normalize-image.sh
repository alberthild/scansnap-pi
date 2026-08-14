#!/usr/bin/env bash
# Integration test for the Pi-only ImageMagick normalizer.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NORMALIZER="${NORMALIZER:-$ROOT/pi/bin/scansnap-normalize-image.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

INPUT="$WORK/receipt.jpg"
convert -size 413x584 xc:white \
  -fill '#444444' -draw 'rectangle 152,63 263,530' \
  -fill white -draw 'rectangle 156,68 259,525' \
  -fill '#e0e0e0' -draw 'rectangle 160,75 255,520' \
  -fill '#222222' -draw 'rectangle 165,85 250,105' \
  -rotate 2 \
  "$INPUT"

"$NORMALIZER" "$INPUT"

if find "$WORK" -maxdepth 1 \( -name '*.cleaned.jpg' -o -name '*.cropped.jpg' -o -name '*.normalized.jpg' \) -print -quit | grep -q .; then
  echo "FAIL: normalizer left an intermediate image that would be added to the PDF" >&2
  exit 1
fi

read -r width height < <(identify -format '%w %h\n' "$INPUT")
if (( width >= 300 )); then
  echo "FAIL: receipt was not cropped tightly enough (width=$width)" >&2
  exit 1
fi
if (( height < 350 )); then
  echo "FAIL: receipt was cropped implausibly short (height=$height)" >&2
  exit 1
fi

corner_intensity=$(convert "$INPUT" -crop 1x1+0+0 -format '%[fx:intensity]' info:)
if ! awk -v value="$corner_intensity" 'BEGIN { exit !(value > 0.90) }'; then
  echo "FAIL: normalizer did not retain a white safety border (corner=$corner_intensity)" >&2
  exit 1
fi

receipt_colorspace=$(identify -format '%[colorspace]' "$INPUT")
if [[ "$receipt_colorspace" != "Gray" ]]; then
  echo "FAIL: receipt was not converted to grayscale (colorspace=$receipt_colorspace)" >&2
  exit 1
fi
receipt_mean=$(identify -format '%[fx:mean]' "$INPUT")
if ! awk -v value="$receipt_mean" 'BEGIN { exit !(value > 0.91) }'; then
  echo "FAIL: receipt background was not cleaned sufficiently (mean=$receipt_mean)" >&2
  exit 1
fi

DOCUMENT="$WORK/document.jpg"
convert -size 413x584 xc:white \
  -fill '#ce0000' -draw 'rectangle 25,25 388,559' \
  -fill white -draw 'rectangle 45,45 368,539' \
  "$DOCUMENT"
"$NORMALIZER" "$DOCUMENT"

document_colorspace=$(identify -format '%[colorspace]' "$DOCUMENT")
if [[ "$document_colorspace" != "sRGB" ]]; then
  echo "FAIL: document should retain color (colorspace=$document_colorspace)" >&2
  exit 1
fi

BACKSIDE="$WORK/receipt-backside.jpg"
convert -size 413x584 xc:white \
  -fill '#f5dcdc' -draw 'rectangle 0,0 20,583' \
  -fill '#f5dcdc' -draw 'rectangle 392,0 412,583' \
  -fill '#e0e0e0' -draw 'rectangle 80,80 332,510' \
  -fill '#222222' -draw 'rectangle 105,120 307,145' \
  "$BACKSIDE"
"$NORMALIZER" --receipt "$BACKSIDE"

backside_colorspace=$(identify -format '%[colorspace]' "$BACKSIDE")
if [[ "$backside_colorspace" != "Gray" ]]; then
  echo "FAIL: forced receipt backside was not converted to grayscale (colorspace=$backside_colorspace)" >&2
  exit 1
fi
backside_mean=$(identify -format '%[fx:mean]' "$BACKSIDE")
if ! awk -v value="$backside_mean" 'BEGIN { exit !(value > 0.91) }'; then
  echo "FAIL: forced receipt backside was not cleaned sufficiently (mean=$backside_mean)" >&2
  exit 1
fi

echo "PASS: receipt is ${width}x${height} in grayscale; document remains color; receipt backside is cleaned"
