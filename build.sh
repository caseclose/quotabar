#!/bin/zsh
set -eu
cd "$(dirname "$0")"
OUTPUT_DIR="${QUOTABAR_BUILD_DIR:-$(pwd)}"
APP="$OUTPUT_DIR/QuotaBar.app"
ARCH="${QUOTABAR_ARCH:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; esac
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Assets/QuotaBar.icns "$APP/Contents/Resources/"
cp Assets/*.png "$APP/Contents/Resources/"
cp LICENSE LICENSE.lobe-icons THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
swiftc -swift-version 5 -O -target "$ARCH-apple-macosx13.0" -file-prefix-map "$(pwd)=." -debug-prefix-map "$(pwd)=." Sources/main.swift Tests/LoginTests.swift -o "$APP/Contents/MacOS/QuotaBar" -framework Cocoa -framework SwiftUI -framework Security -framework ServiceManagement
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>QuotaBar</string><key>CFBundleIdentifier</key><string>local.QuotaBar</string><key>CFBundleIconFile</key><string>QuotaBar</string><key>CFBundleName</key><string>QuotaBar</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>1.0.0</string><key>LSUIElement</key><true/><key>LSMinimumSystemVersion</key><string>13.0</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
