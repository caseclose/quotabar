#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
VERSION="1.0.0"
ARCH="arm64"
DEST="$(pwd)/.build/releases/v$VERSION"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/quotabar-release.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$DEST"
QUOTABAR_BUILD_DIR="$STAGING" QUOTABAR_ARCH="$ARCH" ./build.sh
APP="$STAGING/QuotaBar.app"
"$APP/Contents/MacOS/QuotaBar" --self-test
"$APP/Contents/MacOS/QuotaBar" --test-login
codesign --verify --strict "$APP"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" | /usr/bin/grep -qx "$VERSION"
ZIP="QuotaBar-v$VERSION-macos-$ARCH.zip"
ditto -c -k --norsrc --keepParent "$APP" "$DEST/$ZIP"
(cd "$DEST" && shasum -a 256 "$ZIP" > SHA256SUMS.txt)
echo "Release artifacts: $DEST"
