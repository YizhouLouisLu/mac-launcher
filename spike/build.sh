#!/bin/bash
# Build LaunchSpike, assemble a real .app bundle, and ad-hoc sign it.
# Run from anywhere:  ./build.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

echo "==> swift build (release)"
swift build -c release

BIN=".build/release/LaunchSpike"
APP="build/LaunchSpike.app"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/LaunchSpike"
cp Info.plist "$APP/Contents/Info.plist"

echo "==> ad-hoc signing"
codesign --force --sign - --identifier com.luyizhou.launchspike "$APP"
codesign -dv "$APP" 2>&1 | sed -n '1,6p'

echo "==> done: $HERE/$APP"
echo "    log file: ~/Library/Application Support/LaunchSpike/spike.log"
