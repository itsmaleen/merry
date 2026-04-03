#!/bin/bash
set -euo pipefail

BINARY="/usr/local/bin/cmux-bridge"
PLIST_LABEL="com.itsmaleen.cmux-bridge"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
ENABLE_TAILSCALE="${1:---no-tailscale}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Build and install binary
echo "Building cmux-bridge..."
bash "$SCRIPT_DIR/build.sh" "$BINARY"

# Build ProgramArguments
ARGS="    <string>${BINARY}</string>"
if [ "$ENABLE_TAILSCALE" = "--tailscale" ]; then
    ARGS="${ARGS}
    <string>--tailscale</string>"
    echo "Tailscale enabled."
fi

# Write LaunchAgent plist
echo "Installing LaunchAgent → $PLIST_PATH"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
${ARGS}
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
  </dict>
  <key>StandardOutPath</key>
  <string>/tmp/cmux-bridge.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/cmux-bridge.log</string>
</dict>
</plist>
EOF

# Unload if already loaded, then load
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo ""
echo "cmux-bridge installed and started."
echo "Logs: tail -f /tmp/cmux-bridge.log"
echo ""
echo "To pair with the iOS app, run:"
echo "  cmux-bridge --pair"
