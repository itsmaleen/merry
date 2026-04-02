# TODO

## Bridge — Phase 1 (LAN + Polling) ✅

- [x] Go module init (`go mod init github.com/manaflow-ai/cmux-companion`)
- [x] cmux socket client (`bridge/internal/socket/`) — connect, authenticate (password mode), send v2 JSON-RPC, read responses
- [x] Notification poller (`bridge/internal/poller/`) — poll `notification.list` every 1s, diff, emit new events
- [x] WebSocket server (`bridge/internal/ws/`) — serve clients, push notification events, proxy control commands to socket
- [x] Token auth — generate 256-bit token on first run, store in `~/.config/cmux-bridge/token`, validate `Authorization: Bearer` header
- [x] QR code pairing — encode `cmux-bridge://pair?host=HOST&port=PORT&token=TOKEN`, display in terminal on `--pair` flag
- [x] Bonjour/mDNS advertisement — advertise `_cmux-bridge._tcp` service on LAN
- [x] LaunchAgent install script (`scripts/install-bridge.sh`)
- [x] `scripts/build.sh` — build bridge binary

## iOS App — Phase 1 ✅

- [x] Xcode project scaffold (SwiftUI, iOS 17+)
- [x] Bonjour discovery (`NetServiceBrowser` for `_cmux-bridge._tcp`)
- [x] QR scan pairing flow (AVFoundation, store token in Keychain)
- [x] Manual IP/port fallback in Settings
- [x] WebSocket client (URLSessionWebSocketTask)
- [x] Notification panel — real-time list, badge count, clear action
- [x] Workspace list — fetch `workspace.list`, display, tap to select (`workspace.select`)
- [x] Surface/pane navigation — `surface.list`, `surface.focus`
- [x] Send text command — `surface.send_text`
- [x] Connection status indicator (connected / reconnecting / offline)

## iOS App — Layout View

- [x] NavigationStack-based layout (replaced broken ZStack root)
- [x] Surface grid with cards, tap to focus
- [x] Workspace pills with auto-scroll to active workspace
- [x] Friendly workspace labels (fallback for raw IDs)
- [x] Volume-down single press to cycle surfaces
- [x] Volume-down double press to cycle workspaces
- [x] Volume-up hold for speech input
- [x] Notification sound + vibration on new notifications
- [x] Orange ring on surface cards with notifications
- [x] Orange ring on current workspace pill when it has notifications
- [ ] Pane spatial layout (GeometryReader approach broken inside NavigationStack — needs rework)
- [ ] Gear/settings button overlay

## Cross-Workspace Notifications

See `plans/cross-workspace-notifications.md` for full design.

- [ ] Bridge: build surface→workspace lookup table on cmux connect
- [ ] Bridge: enrich `notification.created` with `workspace_id` and `surface_title`
- [ ] Protocol: add `workspace_id`, `surface_title` to `notification.created` schema
- [ ] iOS: update `BridgeNotification` model with new fields
- [ ] iOS: workspace pill notification indicator using `workspace_id` (no surface loading needed)

## Bridge — Phase 2 (notification.subscribe)

- [ ] Wait for cmux `notification.subscribe` PR to land
- [ ] Swap poller for subscribe stream in bridge
- [ ] Remove polling interval config (no longer needed)

## Bridge — Phase 3 (Tailscale)

- [ ] Add `tsnet` dependency
- [ ] `--tailscale` flag: embed Tailscale node, advertise on tailnet
- [ ] Update QR code URL with Tailscale hostname
- [ ] Update README with Tailscale setup instructions

## cmux PR

- [ ] Implement `notification.subscribe` in cmux Mac app (see `plans/cmux-pr-subscribe.md`)
- [ ] Open PR to manaflow-ai/cmux

## Docs

- [x] `shared/protocol.md` — document full WebSocket message schema
- [ ] Add setup instructions to README
- [ ] Add screenshots to README once iOS app is functional
