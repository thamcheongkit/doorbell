#!/bin/sh
# Run from the OrbStack Linux machine.
set -eu

LABEL=local.macos-notifier
MAC_HOME=$(mac sh -c 'printf %s "$HOME"')
MAC_UID=$(mac id -u)

mac launchctl bootout "gui/$MAC_UID/$LABEL" 2>/dev/null || true
mac rm -rf "$MAC_HOME/Library/Application Support/macos-notifier"
mac rm -f "$MAC_HOME/Library/LaunchAgents/$LABEL.plist" "$MAC_HOME/Library/Logs/macos-notifier.log"
echo "uninstalled"
