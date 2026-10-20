#!/usr/bin/env bash
# Renders the app icon set in the asset catalog from Brand/cluvia-app-icon.svg.
# Requires rsvg-convert (brew install librsvg).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
source_svg="$root/Brand/cluvia-app-icon.svg"
icon_set="$root/Cluvia/Assets.xcassets/AppIcon.appiconset"

command -v rsvg-convert >/dev/null || { echo "rsvg-convert not found (brew install librsvg)" >&2; exit 1; }
mkdir -p "$icon_set"

images=""
separator=""
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    pixels=$((size * scale))
    name="icon_${size}x${size}@${scale}x.png"
    rsvg-convert -w "$pixels" -h "$pixels" "$source_svg" -o "$icon_set/$name"
    images+="$separator    { \"filename\" : \"$name\", \"idiom\" : \"mac\", \"scale\" : \"${scale}x\", \"size\" : \"${size}x${size}\" }"
    separator=$',\n'
  done
done

cat > "$icon_set/Contents.json" <<JSON
{
  "images" : [
$images
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
echo "Rendered $(ls "$icon_set"/*.png | wc -l | tr -d ' ') icons into $icon_set"
