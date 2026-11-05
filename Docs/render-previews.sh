#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
PREVIEW_DIR="$(pwd)/.build/previews"
PREVIEW_APP="$PREVIEW_DIR/QuotaBarPreview.app"
mkdir -p "$PREVIEW_APP/Contents/MacOS" "$PREVIEW_APP/Contents/Resources" Docs/images
cp Assets/QuotaBar.icns "$PREVIEW_APP/Contents/Resources/"
cp Assets/*.png "$PREVIEW_APP/Contents/Resources/"
python3 - "$PREVIEW_DIR/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/main.swift').read_text().split('if CommandLine.arguments.contains("--test-login")')[0]
# Offscreen export has no desktop backdrop; use a static dark material approximation.
source = source.replace('FrostedBackground().overlay(Color(red:0.075,green:0.09,blue:0.12).opacity(0.22))', 'LinearGradient(colors:[Color(red:0.12,green:0.14,blue:0.17),Color(red:0.065,green:0.08,blue:0.10)],startPoint:.topLeading,endPoint:.bottomTrailing)')
Path(sys.argv[1]).write_text(source + '\n' + Path('Docs/Preview.swift').read_text())
PY
swiftc -swift-version 5 "$PREVIEW_DIR/main.swift" -o "$PREVIEW_APP/Contents/MacOS/Preview" -framework Cocoa -framework SwiftUI -framework Security -framework ServiceManagement
"$PREVIEW_APP/Contents/MacOS/Preview" "$(pwd)/Docs/images"
