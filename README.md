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

### 1. Build and install the bridge

**Option A — LaunchAgent (recommended, auto-starts on login):**

```bash
./scripts/install-bridge.sh
```

This builds the binary to `/usr/local/bin/cmux-bridge`, installs a LaunchAgent, and starts it.

**Option B — Manual build and run:**

```bash
cd bridge
go build -o cmux-bridge ./cmd/cmux-bridge
./cmux-bridge
```

### 2. Pair with the iOS app

```bash
cmux-bridge --pair
```

This displays a QR code in the terminal. Scan it from the iOS app's pairing screen.

### 3. Build and run the iOS app

Open `ios/cmux.xcodeproj` in Xcode, select your iPhone, and run.

On first launch, tap "Scan QR Code" and scan the QR displayed by `cmux-bridge --pair`.

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

## Logs and debugging

```bash
# Bridge logs
tail -f /tmp/cmux-bridge.log

# Re-pair (regenerates QR)
cmux-bridge --pair

# Restart bridge (if installed as LaunchAgent)
launchctl unload ~/Library/LaunchAgents/com.itsmaleen.cmux-bridge.plist
launchctl load ~/Library/LaunchAgents/com.itsmaleen.cmux-bridge.plist
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
| 3 | Tailscale embed (`tsnet`) for remote access | Planned |

## Related

- [cmux](https://github.com/manaflow-ai/cmux) — the Mac terminal multiplexer
- [cmux PR: notification.subscribe](plans/cmux-pr-subscribe.md) — upstream PR spec
