#!/bin/bash
set -euo pipefail

BINARY="/usr/local/bin/merry-bridge"
PLIST_LABEL="com.itsmaleen.merry-bridge"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
ENABLE_TAILSCALE="${1:---no-tailscale}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# MERRY_BRIDGE_BIN=/path/to/merry-bridge installs that binary instead of
# building one, for hosts without Go (cross-compile elsewhere with
# GOOS/GOARCH and copy it over).
build_bridge() {
    if [ -n "${MERRY_BRIDGE_BIN:-}" ]; then
        echo "Using prebuilt $MERRY_BRIDGE_BIN"
        cp "$MERRY_BRIDGE_BIN" "$1"
    else
        bash "$SCRIPT_DIR/build.sh" "$1"
    fi
}

# Do NOT run under sudo. This installs a *per-user* LaunchAgent (systemd user
# unit on Linux) and talks to the user's service manager; as root the plist lands in root's home and the daemon
# runs as root — where it can't reach your cmux socket. Only the binary copy to
# /usr/local/bin needs elevation, and that's handled selectively below.
if [ "$(id -u)" = "0" ]; then
    echo "error: run this WITHOUT sudo (as your normal user):" >&2
    echo "         ./scripts/install-bridge.sh ${ENABLE_TAILSCALE}" >&2
    exit 1
fi

# Pre-rename installs kept their token, config and tailnet node state in
# ~/.config/cmux-bridge; carry it over (the bridge would still read it, but
# one directory is less confusing). Called once the old daemon is stopped, so
# it cannot write into the old path behind the move.
migrate_config() {
    if [ -d "$HOME/.config/cmux-bridge" ] && [ ! -e "$HOME/.config/merry-bridge" ]; then
        echo "Moving ~/.config/cmux-bridge to ~/.config/merry-bridge."
        mv "$HOME/.config/cmux-bridge" "$HOME/.config/merry-bridge"
    fi
}

# ── Linux: systemd --user unit ───────────────────────────────────────────────
# Same shape as the macOS path below (build, stop the old daemon, wait for the
# port, start, verify), but the binary lives in ~/.local/bin and the daemon is a
# per-user systemd unit, so nothing needs sudo except enabling lingering.
# Re-running this after `git pull` is how a Linux box (WSL included) updates.
if [ "$(uname -s)" = "Linux" ]; then
    BINARY="$HOME/.local/bin/merry-bridge"
    UNIT="merry-bridge.service"
    UNIT_PATH="$HOME/.config/systemd/user/$UNIT"
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

    if ! systemctl --user show-environment >/dev/null 2>&1; then
        echo "error: no systemd user manager. On WSL, add this to /etc/wsl.conf and run 'wsl --shutdown':" >&2
        echo "         [boot]" >&2
        echo "         systemd=true" >&2
        exit 1
    fi

    echo "Building merry-bridge..."
    mkdir -p "$(dirname "$BINARY")"
    # Build next to the destination so the swap below is an atomic rename.
    TMP_BIN="$(mktemp "$BINARY.new.XXXXXX")"
    trap 'rm -f "$TMP_BIN"' EXIT
    build_bridge "$TMP_BIN"
    chmod +x "$TMP_BIN"

    EXEC="$BINARY"
    if [ "$ENABLE_TAILSCALE" = "--tailscale" ]; then
        EXEC="$BINARY --tailscale"
        echo "Tailscale enabled."
    fi

    echo "Installing systemd user unit → $UNIT_PATH"
    mkdir -p "$(dirname "$UNIT_PATH")"
    cat > "$UNIT_PATH" <<EOF
[Unit]
Description=merry bridge
# Start after herdr when it is installed as a unit; harmless when it is not.
After=herdr.service
Wants=herdr.service

[Service]
ExecStart=${EXEC}
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

    # Swap the binary in first: renaming over a running executable is safe on
    # Linux, and it leaves nothing that can fail between stopping the old
    # daemon and starting the new one.
    mv -f "$TMP_BIN" "$BINARY"
    trap - EXIT
    systemctl --user daemon-reload

    # Stop the old daemon and anything else holding the port, for the same
    # reason as the macOS path: a leftover listener makes the new binary die on
    # bind before Tailscale ever starts. If anything below fails, start the unit
    # again rather than leave the bridge down.
    trap 'systemctl --user start "$UNIT" 2>/dev/null || true' ERR
    # Retire the pre-rename cmux-bridge unit and binary.
    if [ -e "$HOME/.config/systemd/user/cmux-bridge.service" ] || [ -e "$HOME/.local/bin/cmux-bridge" ]; then
        echo "Retiring the old cmux-bridge unit and binary."
        systemctl --user disable --now cmux-bridge.service 2>/dev/null || true
        rm -f "$HOME/.config/systemd/user/cmux-bridge.service" "$HOME/.local/bin/cmux-bridge"
        pkill -f "$HOME/.local/bin/cmux-bridge" 2>/dev/null || true
        systemctl --user daemon-reload
    fi
    systemctl --user stop "$UNIT" 2>/dev/null || true
    pkill -f "$BINARY" 2>/dev/null || true
    migrate_config
    BRIDGE_PORT="${BRIDGE_PORT:-47821}"
    for _ in 1 2 3 4 5; do
        ss -ltn "sport = :$BRIDGE_PORT" 2>/dev/null | grep -q LISTEN || break
        sleep 1
    done

    systemctl --user enable "$UNIT" >/dev/null
    SINCE="$(date '+%Y-%m-%d %H:%M:%S')"
    systemctl --user start "$UNIT"
    trap - ERR

    sleep 4
    RECENT="$(journalctl --user -u "$UNIT" --since "$SINCE" --no-pager -o cat 2>/dev/null || true)"
    if echo "$RECENT" | grep -q "ws: listening on" && ! echo "$RECENT" | grep -q "address already in use"; then
        echo "Bridge is listening."
        if [ "$ENABLE_TAILSCALE" = "--tailscale" ]; then
            if echo "$RECENT" | grep -q "tailscale: listening on"; then
                echo "Tailscale listener up: $(echo "$RECENT" | grep 'tailscale: listening on' | tail -1 | sed 's/.*listening on //')"
            else
                echo "warning: Tailscale did not report a listener yet — check: journalctl --user -u $UNIT -f" >&2
            fi
        fi
    else
        echo "warning: bridge may not have started cleanly — check: journalctl --user -u $UNIT -f" >&2
    fi

    # Without lingering the user manager, and so the bridge, stops at logout.
    if [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" != "yes" ]; then
        echo ""
        echo "warning: lingering is off, so the bridge stops when you log out. Enable it with:" >&2
        echo "         sudo loginctl enable-linger $(id -un)" >&2
    fi

    echo ""
    echo "merry-bridge installed and started ($BINARY)."
    echo "Logs: journalctl --user -u $UNIT -f"
    echo "Update later with: git pull && ./scripts/install-bridge.sh ${ENABLE_TAILSCALE}"
    echo ""
    # ~/.local/bin may not be on PATH yet in a fresh shell, so name it in full.
    PAIR_CMD="merry-bridge"
    [ "$(command -v merry-bridge 2>/dev/null)" = "$BINARY" ] || PAIR_CMD="$BINARY"
    echo "To pair with the iOS app, run:"
    if [ "$ENABLE_TAILSCALE" = "--tailscale" ]; then
        echo "  $PAIR_CMD --pair --tailscale"
    else
        echo "  $PAIR_CMD --pair"
    fi
    exit 0
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
[ -e "$TS_STATE" ] || TS_STATE="$HOME/.config/cmux-bridge/tailscale/tailscaled.state" # not migrated yet
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
build_bridge "$TMP_BIN"
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
# Retire the pre-rename cmux-bridge job and binary.
OLD_PLIST="$HOME/Library/LaunchAgents/com.itsmaleen.cmux-bridge.plist"
if [ -e "$OLD_PLIST" ] || [ -e /usr/local/bin/cmux-bridge ]; then
    echo "Retiring the old cmux-bridge LaunchAgent and binary."
    launchctl bootout "gui/$(id -u)/com.itsmaleen.cmux-bridge" 2>/dev/null || true
    rm -f "$OLD_PLIST"
    pkill -f /usr/local/bin/cmux-bridge 2>/dev/null || true
    if [ -w /usr/local/bin ]; then rm -f /usr/local/bin/cmux-bridge; else sudo rm -f /usr/local/bin/cmux-bridge; fi
fi
migrate_config

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
