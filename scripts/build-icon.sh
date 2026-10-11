#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

icon_work=$(mktemp -d -t chessarena-icon)
trap 'rm -rf "$icon_work"' EXIT
icon_set="$icon_work/AppIcon.iconset"
mkdir -p "$icon_set"

# macOS uses the matching representation for Finder, Dock and Retina displays.
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/AppIcon.png --out "$icon_set/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" Assets/AppIcon.png --out "$icon_set/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$icon_set" -o Assets/AppIcon.icns
