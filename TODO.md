# TODO

## Bridge — Phase 1 (LAN + Polling)

- [ ] Go module init (`go mod init github.com/manaflow-ai/cmux-companion`)
- [ ] cmux socket client (`bridge/internal/socket/`) — connect, authenticate (password mode), send v2 JSON-RPC, read responses
- [ ] Notification poller (`bridge/internal/poller/`) — poll `notification.list` every 1s, diff, emit new events
- [ ] WebSocket server (`bridge/internal/ws/`) — serve clients, push notification events, proxy control commands to socket
- [ ] Token auth — generate 256-bit token on first run, store in `~/.config/cmux-bridge/token`, validate `Authorization: Bearer` header
- [ ] QR code pairing — encode `cmux-bridge://pair?host=HOST&port=PORT&token=TOKEN`, display in terminal on `--pair` flag
- [ ] Bonjour/mDNS advertisement — advertise `_cmux-bridge._tcp` service on LAN
- [ ] LaunchAgent install script (`scripts/install-bridge.sh`)
- [ ] `scripts/build.sh` — build bridge binary

## iOS App — Phase 1

- [ ] Xcode project scaffold (SwiftUI, iOS 17+)
- [ ] Bonjour discovery (`NetServiceBrowser` for `_cmux-bridge._tcp`)
- [ ] QR scan pairing flow (AVFoundation, store token in Keychain)
- [ ] Manual IP/port fallback in Settings
- [ ] WebSocket client (URLSessionWebSocketTask)
- [ ] Notification panel — real-time list, badge count, clear action
- [ ] Workspace list — fetch `workspace.list`, display, tap to select (`workspace.select`)
- [ ] Surface/pane navigation — `surface.list`, `surface.focus`
- [ ] Send text command — `surface.send_text`
- [ ] Connection status indicator (connected / reconnecting / offline)

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

- [ ] `shared/protocol.md` — document full WebSocket message schema
- [ ] Add setup instructions to README
- [ ] Add screenshots to README once iOS app is functional
