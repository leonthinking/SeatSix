#!/bin/bash
# Build both Finder and Retina representations from the committed 1024px artwork.
set -euo pipefail
source_png="$1"
iconset="$2/SeatSix.iconset"
output="$3"
mkdir "$iconset"
for points in 16 32 128 256 512; do
  for scale in 1 2; do
    pixels=$((points * scale))
    suffix=""
    if [[ "$scale" == 2 ]]; then suffix="@2x"; fi
    /usr/bin/sips -z "$pixels" "$pixels" "$source_png" --out "$iconset/icon_${points}x${points}${suffix}.png" >/dev/null
  done
done
/usr/bin/iconutil -c icns "$iconset" -o "$output"
