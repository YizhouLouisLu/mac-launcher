#!/bin/bash
# Builds the distributable disk image: a universal-free (arm64) app plus the installer.
#
#   dist/MacLauncher-<version>.dmg   <- copy this to another Mac, open, double-click the installer
#
# The app carries app/default-config.json in its Resources, so a fresh machine starts with
# the snippets, engines and search scope configured here.
set -euo pipefail

VERSION="${VERSION:-0.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/app"
DIST="$ROOT/dist"
STAGE="$DIST/stage"
DMG="$DIST/MacLauncher-$VERSION.dmg"

echo "==> 构建 app（部署目标 macOS 13，arm64）"
(cd "$APP" && ./build.sh)

echo "==> 组装安装包内容"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP/build/MacLauncher.app" "$STAGE/MacLauncher.app"
cp "$DIST/payload/安装 MacLauncher.command" "$STAGE/"
cp "$DIST/payload/安装说明.txt" "$STAGE/"
chmod +x "$STAGE/安装 MacLauncher.command"

echo "==> 自检"
BIN="$STAGE/MacLauncher.app/Contents/MacOS/MacLauncher"
lipo -info "$BIN"
otool -l "$BIN" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print "    min macOS: "$2; f=0}'
if [ -f "$STAGE/MacLauncher.app/Contents/Resources/default-config.json" ]; then
  python3 - "$STAGE/MacLauncher.app/Contents/Resources/default-config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
print(f"    内置默认配置: {len(cfg.get('snippets', []))} 个片段, "
      f"{len(cfg.get('engines', []))} 个引擎, hotKey={cfg.get('hotKey')}")
PY
else
  echo "    ⚠️ 缺少内置默认配置（default-config.json）"
fi

echo "==> 生成 DMG"
rm -f "$DMG"
hdiutil create -volname "MacLauncher $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null && echo "    dmg 校验通过"
rm -rf "$STAGE"

echo "==> 完成"
ls -lh "$DMG" | awk '{print "    "$9" ("$5")"}'
shasum -a 256 "$DMG" | awk '{print "    sha256 "$1}'
