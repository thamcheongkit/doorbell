#!/bin/sh
# Builds dist/macos-notifier.dmg. Requires macOS with the Swift compiler.
set -eu
cd "$(dirname "$0")"

APP=dist/macos-notifier/macos-notifier.app

rm -rf dist
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
swiftc -O -target arm64-apple-macos13.0 main.swift -o "$APP/Contents/MacOS/macos-notifier"
codesign --force --sign - "$APP"
ln -s /Applications dist/macos-notifier/Applications

hdiutil create -volname macos-notifier -srcfolder dist/macos-notifier -format UDZO dist/macos-notifier.dmg
