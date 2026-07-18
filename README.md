# cmux-companion

iPhone companion app for [cmux](https://github.com/manaflow-ai/cmux) — mirror notifications, control workspaces, navigate surfaces, and send voice commands from your phone.

## Architecture

```
[cmux Mac app]  <── Unix socket ──>  [cmux-bridge]  <── WebSocket/LAN ──>  [iOS app]
```

- **`bridge/`** — Go binary that connects to the local cmux socket and exposes a WebSocket server on the LAN
- **`ios/`** — SwiftUI iPhone app (landscape, iOS 17+)
- **`shared/`** — Protocol documentation

## Prerequisites

- [cmux](https://github.com/manaflow-ai/cmux) with socket control enabled:
  **Settings > Socket Control > Password mode**
- Go 1.21+ (to build the bridge)
- Xcode 15+ (to build the iOS app)
- macOS 13+
- iOS 17+
- Mac and iPhone on the same local network

## Setup

### 1. Build the bridge

```bash
cd bridge
go build -o cmux-bridge ./cmd/cmux-bridge
sudo mv cmux-bridge /usr/local/bin/
```

Or use the install script (builds + sets up LaunchAgent for auto-start on login).
Run it **as your normal user, not with `sudo`** — it installs a per-user
LaunchAgent, and it will ask for sudo only if `/usr/local/bin` needs it:

```bash
./scripts/install-bridge.sh            # LAN only
./scripts/install-bridge.sh --tailscale  # LAN + remote access (recommended)
```

The script hard-kills any previous bridge process and waits for the port to free
before starting the freshly-built binary, then verifies it's listening (and, with
`--tailscale`, that the tailnet listener came up). This avoids a stale daemon
silently keeping the old binary alive — see [Troubleshooting](#troubleshooting).

### 2. First-time pairing

This only needs to be done once. It connects to cmux's socket, generates a token, and shows a QR code.

```bash
cmux-bridge --pair
```

You'll be prompted for the cmux socket password (if password mode is enabled in cmux Settings > Socket Control). Then a QR code appears in the terminal — keep it visible for the next step.

### 3. Build and run the iOS app

Open `ios/cmux.xcodeproj` in Xcode, select your iPhone, and run.

On first launch, tap "Scan QR Code" and scan the QR from step 2.

### 4. Start the bridge

After pairing, start the bridge (it stays running and the iOS app auto-connects):

```bash
cmux-bridge
```

If you used `install-bridge.sh`, the LaunchAgent starts it automatically on login. Otherwise, run `cmux-bridge` manually or add it to your shell startup.

### Troubleshooting

- **iOS shows "reconnecting"** — make sure `cmux-bridge` is running and cmux is open
- **Bridge shows "cannot connect to cmux socket"** — make sure cmux is running with socket control enabled, then re-pair with `cmux-bridge --pair`
- **Need to re-pair** — run `cmux-bridge --pair` again and scan the new QR code from the iOS app (Settings > Pair new device)
- **Rebuilt the bridge but nothing changed / Tailscale never starts** — a stale
  daemon may still be holding the port. The bridge binds LAN **before** starting
  the Tailscale listener and treats a LAN bind failure as fatal, so a leftover
  process on `:47821` makes the new binary exit with
  `lan listen :47821: bind: address already in use` *before* Tailscale ever
  comes up. `launchctl unload`/`kickstart -k` do **not** kill a process that has
  reparented to launchd (PPID 1). Fix it by hard-killing every instance, then
  reinstalling:

  ```bash
  pkill -f /usr/local/bin/cmux-bridge
  lsof -nP -iTCP:47821 -sTCP:LISTEN     # should print nothing
  ./scripts/install-bridge.sh --tailscale
  ```

  Confirm both listeners are up:

  ```bash
  grep -E "ws: listening|tailscale: listening" ~/Library/Logs/cmux-bridge.log | tail -2
  # ws: listening on :47821 (LAN)
  # tailscale: listening on cmux-bridge.<tailnet>.ts.net:47821
  ```

## Usage

The app is designed for landscape mode with volume button controls:

| Action | Control |
|--------|---------|
| Cycle surfaces | Volume down (single press) |
| Cycle workspaces | Volume down (double press) |
| Start/stop speech input | Volume up (single press) |
| Open quick actions | Volume up (double press) or long-press surface |
| Cycle quick action options | Volume down (while menu open) |
| Select quick action | Volume up (while menu open) |
| Close quick actions | Volume down double press or tap outside |

### Quick actions

Long-press the focused surface or double-tap volume up to open:

- **Input** — Enter, Ctrl+C, Ctrl+D, Ctrl+Z, Clear, Tab, Escape, Arrow keys
- **Terminal** — Split Right, Split Down, New Terminal, Close Surface
- **Workspace** — New Workspace

Swipe left/right to switch between action sections.

### Other controls

- Swipe left/right on focused surface to cycle surfaces
- Tap a secondary tile to promote it to focused
- Hamburger menu (top-left) for navigation to other views
- Pull to refresh surfaces

## Tailscale (remote access)

To access cmux from outside your LAN (e.g., phone on cellular), enable Tailscale:

```bash
# First time: pair with --tailscale to include tailnet hostname in QR
cmux-bridge --pair --tailscale

# Run with Tailscale enabled
cmux-bridge --tailscale

# Or install the LaunchAgent with Tailscale always on
./scripts/install-bridge.sh --tailscale
```

On first `--tailscale` run, a browser opens for Tailscale OAuth login (one-time).
The bridge joins your tailnet as `cmux-bridge.your-tailnet.ts.net` (an embedded
[`tsnet`](https://tailscale.com/kb/1244/tsnet) node, independent of the system
Tailscale app on the Mac).

**Prerequisites**: Tailscale app installed on your iPhone, logged into the same tailnet.

The iOS app tries LAN first, then falls back to the tailnet address if LAN is
unreachable — but **only if the pairing QR included the tailnet hostname**. That
hostname is embedded at pair time, so if you first paired without Tailscale (or
before enabling it), the phone has no tailnet address and can only reach the
bridge on Wi‑Fi. **Re-pair with `--tailscale` to fix remote access:**

```bash
cmux-bridge --pair --tailscale   # regenerates the QR with the .ts.net host
```

then re-scan from the iOS app (Settings > Pair new device). No other phone-side
config is needed.

You can also set `"tailscale": true` in `~/.config/cmux-bridge/config.json` to
always enable it (so `cmux-bridge` alone runs with the tailnet listener).

> Note: `cmux-bridge --pair` and the running daemon share the same tsnet state
> dir. If pairing complains the state is locked, stop the daemon first
> (`launchctl unload ~/Library/LaunchAgents/com.itsmaleen.cmux-bridge.plist`),
> pair, then reinstall with `./scripts/install-bridge.sh --tailscale`.

## Logs and debugging

```bash
# Bridge logs
tail -f ~/Library/Logs/cmux-bridge.log

# Re-pair (regenerates QR)
cmux-bridge --pair

# Restart bridge (if installed as LaunchAgent). Re-running the install script is
# the reliable way — it also clears any stale/orphaned instance holding the port:
./scripts/install-bridge.sh --tailscale

# Manual restart (note: this does NOT kill a process reparented to launchd — if
# the port stays busy, `pkill -f /usr/local/bin/cmux-bridge` first):
launchctl kickstart -k "gui/$(id -u)/com.itsmaleen.cmux-bridge"
```

## Project structure

```
bridge/
  cmd/cmux-bridge/     Entry point
  internal/
    socket/            cmux Unix socket client
    ws/                WebSocket server + auth
    poller/            Notification polling
    mdns/              Bonjour/mDNS advertisement
    pair/              QR code generation
ios/
  cmux/
    App/               App entry, state management, main navigation
    Layout/            Workspace layout view, surface cards, quick actions
    Input/             Volume button handler, speech input
    Connection/        WebSocket client, Bonjour discovery
    Pairing/           QR scan pairing flow
    Control/           Surface list, send text
    Notifications/     Notification list view
    Settings/          Settings view
shared/
  protocol.md          WebSocket message protocol spec
plans/                 Design docs and implementation plans
scripts/
  build.sh             Build bridge binary
  install-bridge.sh    Build + install as LaunchAgent
```

## Phases

| Phase | Feature | Status |
|-------|---------|--------|
| 1 | LAN bridge + polling + iOS control | Done |
| 2 | `notification.subscribe` push stream (requires cmux PR) | Planned |
| 3 | Tailscale embed (`tsnet`) for remote access | Done |

## Related

- [cmux](https://github.com/manaflow-ai/cmux) — the Mac terminal multiplexer
- [cmux PR: notification.subscribe](plans/cmux-pr-subscribe.md) — upstream PR spec
