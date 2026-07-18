#!/bin/bash
set -euo pipefail

BINARY="/usr/local/bin/cmux-bridge"
PLIST_LABEL="com.itsmaleen.cmux-bridge"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
ENABLE_TAILSCALE="${1:---no-tailscale}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Do NOT run under sudo. This installs a *per-user* LaunchAgent and talks to the
# user's launchd domain; as root the plist lands in root's home and the daemon
# runs as root — where it can't reach your cmux socket. Only the binary copy to
# /usr/local/bin needs elevation, and that's handled selectively below.
if [ "$(id -u)" = "0" ]; then
    echo "error: run this WITHOUT sudo (as your normal user):" >&2
    echo "         ./scripts/install-bridge.sh ${ENABLE_TAILSCALE}" >&2
    exit 1
fi

# Keep logs out of world-readable /tmp — daemon stdout/stderr may carry
# diagnostic detail; ~/Library/Logs is user-owned.
LOG_DIR="$HOME/Library/Logs"
LOG_PATH="$LOG_DIR/cmux-bridge.log"
mkdir -p "$LOG_DIR"

# Build to a temp path, then install to /usr/local/bin — using sudo only if the
# destination isn't user-writable (so the rest of the script stays non-root).
echo "Building cmux-bridge..."
TMP_BIN="$(mktemp)"
bash "$SCRIPT_DIR/build.sh" "$TMP_BIN"
chmod +x "$TMP_BIN"
if [ -w "$(dirname "$BINARY")" ]; then
    mv -f "$TMP_BIN" "$BINARY"
else
    echo "Installing $BINARY (needs sudo for /usr/local/bin)..."
    sudo mv -f "$TMP_BIN" "$BINARY"
fi

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
  <string>${LOG_PATH}</string>
  <key>StandardErrorPath</key>
  <string>${LOG_PATH}</string>
</dict>
</plist>
EOF

# Stop the launchd job, then hard-kill ANY lingering bridge processes. This is
# the critical step: a previous daemon can outlive `launchctl unload` — e.g. an
# instance reparented to launchd (PPID 1) that `unload`/`kickstart -k` no longer
# track. If such a process keeps holding the port, the freshly-built binary dies
# on `lan listen: address already in use` BEFORE it ever reaches the Tailscale
# listener — so the rebuild silently has no effect and remote access breaks.
launchctl unload "$PLIST_PATH" 2>/dev/null || true
pkill -f "$BINARY" 2>/dev/null || true

# Wait for the listen port to actually free up before starting the new instance.
BRIDGE_PORT="${BRIDGE_PORT:-47821}"
for _ in 1 2 3 4 5; do
    if ! lsof -nP -iTCP:"$BRIDGE_PORT" -sTCP:LISTEN >/dev/null 2>&1; then break; fi
    sleep 1
done
if lsof -nP -iTCP:"$BRIDGE_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "warning: something is still listening on :$BRIDGE_PORT — the new bridge may fail to bind." >&2
fi

# Load and force-start the fresh binary.
launchctl load "$PLIST_PATH"
launchctl kickstart -k "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null || true

# Verify it actually came up (and, when enabled, that the tailnet listener
# started — the whole point of --tailscale). Look only at the fresh tail so old
# log history can't produce a false positive. Give tsnet a few seconds.
sleep 4
RECENT="$(tail -40 "$LOG_PATH" 2>/dev/null || true)"
if echo "$RECENT" | grep -q "ws: listening on" && \
   ! echo "$RECENT" | grep -q "address already in use"; then
    echo "Bridge is listening."
    if [ "$ENABLE_TAILSCALE" = "--tailscale" ]; then
        if echo "$RECENT" | grep -q "tailscale: listening on"; then
            echo "Tailscale listener up: $(echo "$RECENT" | grep 'tailscale: listening on' | tail -1 | sed 's/.*listening on //')"
        else
            echo "warning: Tailscale did not report a listener yet — check: tail -f $LOG_PATH" >&2
        fi
    fi
else
    echo "warning: bridge may not have started cleanly — check: tail -f $LOG_PATH" >&2
fi

echo ""
echo "cmux-bridge installed and started."
echo "Logs: tail -f $LOG_PATH"
echo ""
echo "To pair with the iOS app, run:"
if [ "$ENABLE_TAILSCALE" = "--tailscale" ]; then
    echo "  cmux-bridge --pair --tailscale   # embeds the .ts.net host for remote access"
else
    echo "  cmux-bridge --pair"
fi
