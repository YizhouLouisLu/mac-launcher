#!/bin/bash
# Build, install into ~/Applications, and register a LaunchAgent so the launcher starts
# at login. Re-run after any source change: it rebuilds, reinstalls and restarts.
#
#   ./install.sh              build + install + start (and load at login)
#   ./install.sh --uninstall  unload the LaunchAgent and remove the installed app
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

LABEL="com.luyizhou.maclauncher"
DEST="$HOME/Applications/MacLauncher.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

stop_running() {
  pkill -f 'MacLauncher.app/Contents/MacOS/MacLauncher' 2>/dev/null || true
  sleep 1
}

if [ "${1:-}" = "--uninstall" ]; then
  echo "==> unloading $LABEL"
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || launchctl unload "$AGENT" 2>/dev/null || true
  rm -f "$AGENT"
  stop_running
  rm -rf "$DEST"
  echo "==> removed $DEST and $AGENT"
  exit 0
fi

./build.sh

echo "==> installing to $DEST"
mkdir -p "$HOME/Applications"
stop_running
rm -rf "$DEST"
# ditto rather than cp -R: Finder/fileprovider detritus carried onto the copy makes
# codesign fail with "resource fork, Finder information, or similar detritus not allowed".
ditto build/MacLauncher.app "$DEST"
xattr -cr "$DEST"
./sign.sh "$DEST" "$LABEL"

echo "==> writing LaunchAgent $AGENT"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$DEST/Contents/MacOS/MacLauncher</string>
	</array>
	<key>RunAtLoad</key><true/>
	<!-- Always keep the launcher alive: measured failure mode was the app exiting cleanly
	     (a stray Cmd-Q) and the hotkey then doing nothing with no visible reason. The
	     deliberate quit path in the app boots this agent out first, so it stays down. -->
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>5</integer>
	<!-- Interactive keeps the hotkey responsive; the default background process type
	     lets macOS throttle the app, which makes a launcher feel sluggish. -->
	<key>ProcessType</key><string>Interactive</string>
	<key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST

echo "==> loading LaunchAgent"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || launchctl unload "$AGENT" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$AGENT" 2>/dev/null || launchctl load "$AGENT"
launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true

sleep 2
PID="$(pgrep -f "$DEST/Contents/MacOS/MacLauncher" | head -1 || true)"
if [ -n "$PID" ]; then
  echo "==> running from $DEST (pid $PID)"
  echo "    launchctl: $(launchctl list "$LABEL" 2>/dev/null | grep -E 'PID|LastExitStatus' | tr '\n' ' ')"
else
  echo "!! did not start; see ~/Library/Application Support/MacLauncher/launcher.log" >&2
  exit 1
fi
echo "==> installed. Re-run ./install.sh after changing any source file."
