#!/bin/sh
# Packages the service into dist/macos-notifier.dmg. Requires macOS.
set -eu
cd "$(dirname "$0")"

rm -rf dist
mkdir -p dist/macos-notifier
cp notifier.pl README.md dist/macos-notifier/
cp install.sh dist/macos-notifier/Install.command
cp uninstall.sh dist/macos-notifier/Uninstall.command

hdiutil create -volname macos-notifier -srcfolder dist/macos-notifier -format UDZO dist/macos-notifier.dmg
