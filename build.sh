#!/bin/zsh
# Builds BudsPop.app into ./build without Xcode (Command Line Tools are enough).
set -euo pipefail
cd "$(dirname "$0")"

APP=build/BudsPop.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -O -swift-version 5 ${SWIFT_FLAGS:-} -parse-as-library \
    -target arm64-apple-macosx14.0 \
    -framework IOBluetooth -framework ServiceManagement \
    Sources/*.swift -o "$APP/Contents/MacOS/BudsPop"

codesign --force --sign - "$APP"
echo "Built $APP"
