#!/bin/bash
# Build AwakeMode.app from AwakeMode.swift.
#   build.sh [destination .app]     default: ~/Applications/AwakeMode.app
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-$HOME/Applications/AwakeMode.app}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$SOURCE_DIR/Info.plist" "$APP/Contents/Info.plist"

# -parse-as-library: handed a single file, swiftc treats it as a script and
# rejects @main. Warnings are errors so a release never ships one.
xcrun swiftc -O -parse-as-library \
  -o "$APP/Contents/MacOS/AwakeMode" "$SOURCE_DIR/AwakeMode.swift"

plutil -lint "$APP/Contents/Info.plist" >/dev/null
# Ad-hoc signature: unsigned menu bar apps are killed on launch on Apple silicon.
codesign --force --sign - "$APP"
codesign --verify --verbose=1 "$APP"
echo "built: $APP"
