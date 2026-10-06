#!/bin/bash
# Build MacLauncher.app with direct swiftc.
#
# Two environment constraints on this machine shape this script:
#   1. `xcrun` resolves the default SDK to MacOSX27.0.sdk, which was built by Swift
#      6.4 and is rejected by the installed Swift 6.3.3 compiler. The versioned
#      symlink $(xcode-select -p)/SDKs/MacOSX.sdk points at MacOSX26.5.sdk, which
#      works, so the SDK is pinned explicitly.
#   2. SwiftPM is unusable (swift-package dies on a dyld symbol mismatch against its
#      own BuildServerProtocol framework), so the bundle is assembled by hand.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

SDK="$(xcode-select -p)/SDKs/MacOSX.sdk"
if [ ! -d "$SDK" ]; then
  echo "error: no SDK at $SDK — run: sudo xcode-select --install" >&2
  exit 1
fi

SOURCES=$(find Sources -name '*.swift' | sort)

mkdir -p build

# Without an explicit -target the binary's minimum OS becomes the SDK's own version
# (measured: minos 26.0), so it would refuse to launch on any older macOS. 13.0 is the
# floor the code is gated for.
TARGET_ARCH="${TARGET_ARCH:-arm64}"
MIN_MACOS="${MIN_MACOS:-13.0}"

echo "==> swiftc  ($TARGET_ARCH, min macOS $MIN_MACOS, SDK $(readlink "$SDK" 2>/dev/null | xargs basename 2>/dev/null || basename "$SDK"))"
xcrun swiftc -swift-version 5 -O -sdk "$SDK" -target "$TARGET_ARCH-apple-macos$MIN_MACOS" \
  -o build/MacLauncher $SOURCES \
  -framework AppKit -framework Carbon -framework ApplicationServices

echo "==> generating app icon"
xcrun swiftc -swift-version 5 -sdk "$SDK" -o build/make-icon tools/make-icon.swift -framework AppKit
rm -rf build/AppIcon.iconset
./build/make-icon build/AppIcon.iconset >/dev/null
iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns

APP=build/MacLauncher.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/MacLauncher "$APP/Contents/MacOS/MacLauncher"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Prefer the machine's real config when present (it is git-ignored); otherwise fall back to
# the sanitized example that ships with the repository.
BUNDLED_DEFAULTS=""
if [ -f default-config.json ]; then
  BUNDLED_DEFAULTS="default-config.json"
elif [ -f default-config.example.json ]; then
  BUNDLED_DEFAULTS="default-config.example.json"
fi
if [ -n "$BUNDLED_DEFAULTS" ]; then
  cp "$BUNDLED_DEFAULTS" "$APP/Contents/Resources/default-config.json"
  echo "==> bundled $BUNDLED_DEFAULTS as the default config for fresh installs"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>MacLauncher</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIconName</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>com.luyizhou.maclauncher</string>
	<key>CFBundleName</key><string>MacLauncher</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.2</string>
	<key>CFBundleVersion</key><string>2</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

./sign.sh "$APP" com.luyizhou.maclauncher

echo "==> built $APP"
echo "    plain binary (for --selftest): $HERE/build/MacLauncher"
echo "    log: ~/Library/Application Support/MacLauncher/launcher.log"
