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

Or use the install script (builds + sets up LaunchAgent for auto-start on login):

```bash
sudo ./scripts/install-bridge.sh
```

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
