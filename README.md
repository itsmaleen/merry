# cmux-companion

iPhone companion app for [cmux](https://github.com/manaflow-ai/cmux) — mirror notifications, control workspaces, and navigate surfaces from your phone.

## Architecture

```
[cmux Mac app]  ←── Unix socket ───→  [cmux-bridge]  ←── WebSocket/LAN ───→  [iOS app]
```

- **`bridge/`** — Go binary that connects to the local cmux socket and exposes a WebSocket server on the LAN
- **`ios/`** — SwiftUI iPhone app for notifications + control
- **`shared/`** — Protocol documentation and JSON schema

## Quick Start

### Bridge

```bash
cd bridge
go build -o cmux-bridge ./cmd/cmux-bridge
./cmux-bridge
```

On first run, a QR code is displayed. Scan it from the iOS app to pair.

Install as a LaunchAgent (auto-starts on login):

```bash
./scripts/install-bridge.sh
```

### iOS App

Open `ios/cmux.xcodeproj` in Xcode and run on your device.

## Requirements

- cmux with socket control enabled (Settings → Socket Control → Password mode)
- macOS 13+ (bridge host)
- iOS 17+ (companion app)
- Same local network for Phase 1 (LAN mode)

## Phases

| Phase | Feature | Status |
|-------|---------|--------|
| 1 | LAN bridge + polling notifications + iOS control | In progress |
| 2 | `notification.subscribe` push stream (requires cmux PR) | Planned |
| 3 | Tailscale embed (`tsnet`) for remote access | Planned |

## Related

- [cmux](https://github.com/manaflow-ai/cmux) — the Mac terminal multiplexer
- [cmux PR: notification.subscribe](plans/cmux-pr-subscribe.md) — upstream PR spec
