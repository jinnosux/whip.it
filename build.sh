#!/bin/sh
# Builds whipd (daemon) and Whip.app (menu-bar GUI), ad-hoc signs both.
# No Apple Developer account required — this is all local.
set -e
cd "$(dirname "$0")"

BRIDGE="-import-objc-header notify-bridge.h"

echo "› compiling whipd (daemon)…"
swiftc -O $BRIDGE whipd.swift -o whipd

echo "› compiling WhipIt (GUI)…"
swiftc -O $BRIDGE app/main.swift -o WhipIt

if [ ! -f AppIcon.icns ]; then
    echo "› generating 💥 app icon…"
    swift make-icon.swift 💥 AppIcon.iconset
    iconutil -c icns AppIcon.iconset -o AppIcon.icns
    rm -rf AppIcon.iconset
fi

echo "› assembling WhipIt.app…"
APP=WhipIt.app
rm -rf "$APP" Whip.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp app/Info.plist            "$APP/Contents/Info.plist"
mv WhipIt                     "$APP/Contents/MacOS/WhipIt"
cp whip.mp3                  "$APP/Contents/Resources/whip.mp3"
cp whipd                     "$APP/Contents/Resources/whipd"
cp com.jinnosuke.whip.plist      "$APP/Contents/Resources/com.jinnosuke.whip.plist"
cp install-daemon.sh         "$APP/Contents/Resources/install-daemon.sh"
cp AppIcon.icns              "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/Resources/install-daemon.sh" "$APP/Contents/Resources/whipd"

echo "› ad-hoc signing…"
codesign --force --deep -s - "$APP"
codesign --force -s - whipd 2>/dev/null || true

echo "✓ built $APP"
echo "  Open it:  open $APP"
echo "  Then use the menu-bar 💥 → Install Background Service…"
