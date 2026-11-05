#!/bin/zsh
# Builds BudsPop.app into ./build without Xcode (Command Line Tools are enough).
set -euo pipefail
cd "$(dirname "$0")"

APP=build/BudsPop.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
# Earbud photos are optional (not in the repo); the app falls back to system symbols without them.
mkdir -p "$APP/Contents/Resources"
for image in Resources/*.png(N); do cp "$image" "$APP/Contents/Resources/"; done

swiftc -O -swift-version 5 ${SWIFT_FLAGS:-} -parse-as-library \
    -target arm64-apple-macosx14.0 \
    -framework IOBluetooth -framework ServiceManagement \
    Sources/*.swift -o "$APP/Contents/MacOS/BudsPop"

codesign --force --sign - "$APP"
echo "Built $APP"
