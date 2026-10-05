#!/bin/bash
# MacLauncher 安装器：装到 ~/Applications，注册开机自启，并引导完成唯一的手动步骤。
#
# 为什么不是 .pkg：本 App 没有 Developer ID 签名，.pkg 会因为「未识别的开发者」被 Gatekeeper
# 直接拒绝；而这个脚本方案只依赖一个本地拷贝 + 一次辅助功能授权。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$HERE/MacLauncher.app"
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/MacLauncher.app"
LABEL="com.luyizhou.maclauncher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

say() { printf '%s\n' "$*"; }

if [ ! -d "$APP_SRC" ]; then
  say "找不到 MacLauncher.app —— 它应与本安装器在同一个文件夹里。"
  read -n 1 -s -r -p "按任意键关闭…"
  exit 1
fi

say "==> 安装到 $DEST"
mkdir -p "$DEST_DIR"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -rf "$DEST"
# ditto 保留代码签名与扩展属性；cp -R 可能破坏签名。
ditto "$APP_SRC" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

say "==> 注册开机自启（LaunchAgent）"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array><string>$DEST/Contents/MacOS/MacLauncher</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>ThrottleInterval</key><integer>5</integer>
	<key>ProcessType</key><string>Interactive</string>
	<key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST
if ! launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
  launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || true
fi

sleep 2
say "==> 首次启动（会请求辅助功能权限）"
open "$DEST" || true
sleep 1
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true

HOTKEY="option+space"
CONFIG="$HOME/Library/Application Support/MacLauncher/config.json"
if [ -f "$CONFIG" ]; then
  parsed=$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8")).get("hotKey","option+space"))' "$CONFIG" 2>/dev/null || true)
  [ -n "${parsed:-}" ] && HOTKEY="$parsed"
fi

say ""
say "──────── 还需要你手动做两件事 ────────"
say "1) 在刚打开的「辅助功能」里勾选 MacLauncher（用于把片段粘贴进其他 App）。"
say "   列表里若没有，用左下角 ＋ 选择：$DEST"
say "2) 试按热键 ${HOTKEY}（默认 ⌥Space）唤出面板。想换键：面板里输入「设置」→ 通用。"
say ""
say "配置与片段：~/Library/Application Support/MacLauncher/config.json"
say "若 iCloud Drive 里已有 MacLauncher/config.json，首次启动会采用较新的那一份，多台 Mac 共用。"
say ""
read -n 1 -s -r -p "按任意键关闭本窗口…"
