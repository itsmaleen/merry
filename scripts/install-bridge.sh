#!/bin/bash
set -euo pipefail

BINARY="/usr/local/bin/merry-bridge"
PLIST_LABEL="com.itsmaleen.merry-bridge"
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
LOG_PATH="$LOG_DIR/merry-bridge.log"
mkdir -p "$LOG_DIR"

# Clean up ROOT-owned leftovers from a historical `sudo ./install-bridge.sh`
# (from before the guard above existed). These silently shadow the per-user
# install: a root-domain launchd job respawns the daemon as root — which cmux
# denies control-socket access to ("Access denied - only processes started
# inside cmux can connect"), so it flaps forever with 'E' parse errors — and
# root-owned files (this plist, the log, the tsnet state) make the per-user
# LaunchAgent fail to even start (launchd exits it with EX_CONFIG / 78, no
# output). We only invoke sudo when something root-owned is actually found, so a
# clean machine never gets prompted.
TS_STATE="$HOME/.config/merry-bridge/tailscale/tailscaled.state"
is_root_owned() { [ -e "$1" ] && [ "$(stat -f %u "$1" 2>/dev/null)" = "0" ]; }
NEEDS_ROOT_CLEANUP=0
[ -n "$(pgrep -u 0 -f "$BINARY" 2>/dev/null || true)" ] && NEEDS_ROOT_CLEANUP=1
for f in "$PLIST_PATH" "$LOG_PATH" "$TS_STATE"; do
    is_root_owned "$f" && NEEDS_ROOT_CLEANUP=1
done
if [ "$NEEDS_ROOT_CLEANUP" = "1" ]; then
    echo "Detected root-owned bridge leftovers from a past 'sudo' install — cleaning up (needs sudo)..."
    # Remove any root-domain launchd registration so it stops respawning as root.
    sudo launchctl bootout "gui/0/${PLIST_LABEL}" 2>/dev/null || true
    sudo launchctl bootout "system/${PLIST_LABEL}" 2>/dev/null || true
    sudo pkill -9 -f "$BINARY" 2>/dev/null || true
    # Root-owned plist/log block the per-user agent; drop them (both re-created).
    is_root_owned "$PLIST_PATH" && { echo "  removing root-owned $PLIST_PATH"; sudo rm -f "$PLIST_PATH"; }
    is_root_owned "$LOG_PATH"   && { echo "  removing root-owned $LOG_PATH";   sudo rm -f "$LOG_PATH"; }
    # Hand the tsnet state back to the user rather than deleting it, to preserve
    # the tailnet node identity (deleting would force a re-auth).
    is_root_owned "$TS_STATE"   && { echo "  reclaiming root-owned $TS_STATE"; sudo chown "$(id -u):$(id -g)" "$TS_STATE"; }
fi

# Build to a temp path, then install to /usr/local/bin — using sudo only if the
# destination isn't user-writable (so the rest of the script stays non-root).
echo "Building merry-bridge..."
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

# Migration: retire the pre-rename cmux-bridge install if it's still around, or
# its daemon keeps holding :$BRIDGE_PORT and the renamed one can't bind. Leaves
# the shared ~/.config (token, tailscale state) in place — the new binary keeps
# using it via configDir()'s legacy fallback.
LEGACY_LABEL="com.itsmaleen.cmux-bridge"
LEGACY_PLIST="$HOME/Library/LaunchAgents/${LEGACY_LABEL}.plist"
launchctl bootout "gui/$(id -u)/${LEGACY_LABEL}" 2>/dev/null || true
launchctl unload "$LEGACY_PLIST" 2>/dev/null || true
pkill -f "/usr/local/bin/cmux-bridge" 2>/dev/null || true
rm -f "$LEGACY_PLIST" 2>/dev/null || true

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
echo "merry-bridge installed and started."
echo "Logs: tail -f $LOG_PATH"
echo ""
echo "To pair with the iOS app, run:"
if [ "$ENABLE_TAILSCALE" = "--tailscale" ]; then
    echo "  merry-bridge --pair --tailscale   # embeds the .ts.net host for remote access"
else
    echo "  merry-bridge --pair"
fi
