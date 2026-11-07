#!/bin/sh
# Run from the OrbStack Linux machine. Copies the service to the Mac because
# macOS blocks launchd and Mac processes from reading files under ~/OrbStack.
set -eu
cd "$(dirname "$0")"

LABEL=local.macos-notifier
MAC_HOME=$(mac sh -c 'printf %s "$HOME"')
MAC_UID=$(mac id -u)
APP_DIR="$MAC_HOME/Library/Application Support/macos-notifier"
PLIST="$MAC_HOME/Library/LaunchAgents/$LABEL.plist"

mac mkdir -p "$APP_DIR" "$MAC_HOME/Library/LaunchAgents" "$MAC_HOME/Library/Logs"
mac sh -c 'cat > "$1"' sh "$APP_DIR/notifier.pl" < notifier.pl

mac sh -c 'cat > "$1"' sh "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/perl</string>
        <string>$APP_DIR/notifier.pl</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>LANG</key><string>en_US.UTF-8</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardErrorPath</key><string>$MAC_HOME/Library/Logs/macos-notifier.log</string>
</dict>
</plist>
EOF

# launchd rejects world-writable plists, and `mac` creates files as 0666.
mac chmod 755 "$APP_DIR" "$MAC_HOME/Library/LaunchAgents"
mac chmod 644 "$APP_DIR/notifier.pl" "$PLIST"

mac launchctl bootout "gui/$MAC_UID/$LABEL" 2>/dev/null || true
sleep 1
mac launchctl bootstrap "gui/$MAC_UID" "$PLIST"
echo "installed: http://127.0.0.1:8765 on the Mac"
