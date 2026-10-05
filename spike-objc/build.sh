#!/bin/bash
# Build the Objective-C spike: LaunchSpike.app, Sink.app, keydriver.
# Objective-C is used because this machine's Command Line Tools are broken for
# Swift (duplicate swift/bridging.modulemap redefines module 'SwiftBridging').
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

# xcrun resolves the default SDK to MacOSX27.0.sdk, which this clang cannot use
# (malformed .tbd / unknown architecture), so the SDK is pinned like the Swift build.
SDK="$(xcode-select -p)/SDKs/MacOSX.sdk"
CFLAGS=(-fobjc-arc -O1 -Wall -Wno-deprecated-declarations -isysroot "$SDK")
FRAMEWORKS=(-framework AppKit -framework Carbon -framework ApplicationServices)

make_bundle() {
  local name="$1" bundle_id="$2" agent="$3"
  local app="build/$name.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  cp "build/$name" "$app/Contents/MacOS/$name"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>$name</string>
	<key>CFBundleIdentifier</key><string>$bundle_id</string>
	<key>CFBundleName</key><string>$name</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><$agent/>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
  codesign --force --sign - --identifier "$bundle_id" "$app" >/dev/null 2>&1
  echo "built $app"
}

mkdir -p build

echo "==> compiling LaunchSpike"
clang "${CFLAGS[@]}" -o build/LaunchSpike LaunchSpike.m "${FRAMEWORKS[@]}"

echo "==> compiling Sink"
clang "${CFLAGS[@]}" -o build/Sink Sink.m "${FRAMEWORKS[@]}"

echo "==> compiling keydriver"
clang "${CFLAGS[@]}" -o build/keydriver keydriver.m "${FRAMEWORKS[@]}"

make_bundle LaunchSpike com.luyizhou.launchspike true
make_bundle Sink com.luyizhou.sink false

echo "==> done"
