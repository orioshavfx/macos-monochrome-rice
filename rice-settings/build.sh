#!/bin/sh
# Builds rice-settings in release mode and packs it into ~/Applications/rice-settings.app
set -e
cd "$(dirname "$0")"
# The commit this copy was installed from: install.sh writes BUILD_COMMIT next to the sources.
COMMIT="$(cat BUILD_COMMIT 2>/dev/null || echo unknown)"
BUILT="$(date '+%Y-%m-%d %H:%M')"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/rice-settings"
APP="$HOME/Applications/rice-settings.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/rice-settings"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>rice-settings</string>
  <key>CFBundleDisplayName</key><string>Rice Settings</string>
  <key>CFBundleIdentifier</key><string>com.oriosha.rice-settings</string>
  <key>CFBundleExecutable</key><string>rice-settings</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>RiceBuildCommit</key><string>$COMMIT</string>
  <key>RiceBuildDate</key><string>$BUILT</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
