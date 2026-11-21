#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app_dir="$PWD/.build/Observatory.app"
contents="$app_dir/Contents"

mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$binary_dir/Observatory" "$contents/MacOS/Observatory"
cp Packaging/Info.plist "$contents/Info.plist"
swift Packaging/make-icon.swift "$PWD/.build/Observatory.iconset"
iconutil -c icns "$PWD/.build/Observatory.iconset" -o "$contents/Resources/Observatory.icns"
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"
echo "$app_dir"
