#!/bin/zsh
set -e
icon_dir="$(cd "$(dirname "$0")/.." && pwd)/MacImageConverter/Assets.xcassets/AppIcon.appiconset"
swift "$(dirname "$0")/generate_icon.swift" "$icon_dir/icon_1024.png"
for size in 16 32 64 128 256 512; do
  sips -z "$size" "$size" "$icon_dir/icon_1024.png" --out "$icon_dir/icon_$size.png" >/dev/null
done
