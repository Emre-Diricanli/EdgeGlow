#!/bin/bash
# Builds EdgeGlow.app into ~/Applications, links the `edgeglow` CLI and starts it at login.
set -euo pipefail
cd "$(dirname "$0")"
ID="io.github.emre-diricanli.edgeglow"
APP="$HOME/Applications/EdgeGlow.app"
BIN_DIR="$HOME/.local/bin"

command -v swiftc >/dev/null || { echo "swiftc not found: run 'xcode-select --install' first"; exit 1; }
mkdir -p "$APP/Contents/MacOS" "$BIN_DIR" "$HOME/Library/LaunchAgents"
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/EdgeGlow"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$ID</string>
<key>CFBundleName</key><string>EdgeGlow</string>
<key>CFBundleExecutable</key><string>EdgeGlow</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PL
codesign --force -s - "$APP" 2>/dev/null
ln -sf "$APP/Contents/MacOS/EdgeGlow" "$BIN_DIR/edgeglow"

PLIST="$HOME/Library/LaunchAgents/$ID.plist"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$ID</string>
<key>ProgramArguments</key><array><string>$APP/Contents/MacOS/EdgeGlow</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ProcessType</key><string>Interactive</string>
</dict></plist>
PL
if launchctl print "gui/$(id -u)/$ID" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/$ID"
else
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
fi
echo "EdgeGlow installed at $APP and running (starts at login)."
