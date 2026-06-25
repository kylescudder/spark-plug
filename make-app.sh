#!/usr/bin/env bash
set -euo pipefail

APP_NAME="SparkPlug"          # Swift product / executable / icon base — no spaces
DISPLAY_NAME="Spark Plug"     # User-facing name: bundle, Spotlight, dock
BUNDLE_ID="co.uk.kylescudder.spark-plug"
VERSION="1.5.0"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/$DISPLAY_NAME.app"

echo "▸ Building release…"
swift build -c release --package-path "$ROOT"

BIN="$ROOT/.build/release/$APP_NAME"
[[ -x "$BIN" ]] || { echo "✗ binary missing at $BIN"; exit 1; }

ICNS="$ROOT/Tools/$APP_NAME.icns"
ICONSET="$ROOT/Tools/$APP_NAME.iconset"
if [[ ! -f "$ICNS" || "$ROOT/Tools/make-icon.swift" -nt "$ICNS" ]]; then
    echo "▸ Generating icon…"
    swift "$ROOT/Tools/make-icon.swift" "$ICONSET" >/dev/null
    iconutil -c icns "$ICONSET" -o "$ICNS"
fi

echo "▸ Assembling $APP"
rm -rf "$APP" "$ROOT/$APP_NAME.app"   # drop old one-word bundle so Spotlight doesn't keep both
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ICNS" "$APP/Contents/Resources/$APP_NAME.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>      <string>en</string>
    <key>CFBundleDisplayName</key>            <string>$DISPLAY_NAME</string>
    <key>CFBundleExecutable</key>             <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>               <string>$APP_NAME</string>
    <key>CFBundleIconName</key>               <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>             <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>  <string>6.0</string>
    <key>CFBundleName</key>                   <string>$DISPLAY_NAME</string>
    <key>CFBundlePackageType</key>            <string>APPL</string>
    <key>CFBundleShortVersionString</key>     <string>$VERSION</string>
    <key>CFBundleVersion</key>                <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>         <string>14.0</string>
    <key>LSUIElement</key>                    <true/>
    <key>NSHighResolutionCapable</key>        <true/>
    <key>NSPrincipalClass</key>               <string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key>  <string>Spark Plug uses Apple Events to open Terminal in your selected worktree.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "✓ Built $APP"
echo "  Run:    open \"$APP\""
echo "  Install: mv \"$APP\" /Applications/"
