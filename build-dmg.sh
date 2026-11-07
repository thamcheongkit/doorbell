#!/bin/sh
# Builds dist/Doorbell.dmg. Requires macOS with the Swift compiler and librsvg.
set -eu
cd "$(dirname "$0")"

APP=dist/Doorbell/Doorbell.app
ICONSET=dist/AppIcon.iconset

rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ICONSET"
cp Info.plist "$APP/Contents/"
swiftc -O -target arm64-apple-macos13.0 main.swift -o "$APP/Contents/MacOS/Doorbell"

for size in 16 32 128 256 512; do
    rsvg-convert -w "$size" -h "$size" icon.svg -o "$ICONSET/icon_${size}x${size}.png"
    rsvg-convert -w "$((size * 2))" -h "$((size * 2))" icon.svg -o "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
ln -s /Applications dist/Doorbell/Applications

hdiutil create -volname Doorbell -srcfolder dist/Doorbell -format UDZO dist/Doorbell.dmg
