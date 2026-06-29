#!/bin/sh
# Installs whipd as a root LaunchDaemon. Run with administrator privileges.
# Usage: install-daemon.sh <path-to-WhipIt.app>
set -e

APP="$1"
RES="$APP/Contents/Resources"

mkdir -p /usr/local/bin
install -m 755 "$RES/whipd" /usr/local/bin/whipd

cp "$RES/com.jinnosuke.whip.plist" /Library/LaunchDaemons/com.jinnosuke.whip.plist
chown root:wheel /Library/LaunchDaemons/com.jinnosuke.whip.plist
chmod 644 /Library/LaunchDaemons/com.jinnosuke.whip.plist

# reload if already present, then start
launchctl bootout system/com.jinnosuke.whip 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.jinnosuke.whip.plist
launchctl enable system/com.jinnosuke.whip
echo "whipd installed and started"
