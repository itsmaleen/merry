# TODO

## Bridge — Phase 1 (LAN + Polling) ✅

- [x] Go module init
- [x] cmux socket client with auth
- [x] Notification poller (1s poll, ID-based dedup)
- [x] WebSocket server with Bearer token auth
- [x] QR code pairing
- [x] Bonjour/mDNS advertisement
- [x] LaunchAgent install script
- [x] Build script

## iOS App — Phase 1 ✅

- [x] Xcode project scaffold (SwiftUI, iOS 17+)
- [x] Bonjour discovery + QR scan pairing
- [x] WebSocket client + connection status indicator
- [x] Notification panel with badge count
- [x] Workspace list + surface/pane navigation
- [x] Send text + send key commands

## iOS App — Layout & Controls ✅

- [x] Landscape-only, split layout (65/35 focused + tiles)
- [x] Glass material cards with terminal title bar
- [x] Workspace pills with auto-scroll + notification indicators
- [x] Volume-down: single = cycle surfaces, double = cycle workspaces
- [x] Volume-up: single = toggle STT, double = quick actions menu
- [x] Quick actions: tabbed sections (Input/Terminal/Workspace), swipe to switch
- [x] Terminal actions via cmux RPC: surface.split, surface.create, surface.close
- [x] Speech-to-text with auto-submit toggle
- [x] Notification sound/vibration + local push notifications (foreground + background)
- [x] Surface + workspace notification indicators (orange ring)
- [x] Auto-clear notifications on focused surface
- [x] Auto-select first surface on workspace load
- [x] Volume handler recovery from audio interruptions
- [x] Slide-out sidebar menu
- [x] Swipe gestures + spring animations
- [x] README with full setup + usage docs

## iOS App — UX Improvements ✅

- [x] Cancel speech/recording via volume down with haptic feedback
- [x] Swipe-to-edit transcript with keyboard mode (TranscriptEditorView)
- [x] Zoom quick action (Terminal) — sends cmd+shift+enter to toggle pane zoom
- [x] Fullscreen quick action (Workspace) — hides sidebar + workspace bar
- [x] Close Workspace quick action
- [x] Remember last focused surface per workspace across switches
- [x] Live terminal content viewing via surface.read_text (3s polling)
- [x] Browser surface detection — globe icon + URL display
- [x] Loading spinner for terminal cards before content arrives
- [x] Command dictionary with autocomplete suggestions in transcript editor

## Polish & Improvements

- [ ] Better STT model (replace Apple Speech with Whisper or similar)
- [ ] Haptic feedback on surface/workspace cycling
- [ ] Pane spatial layout (GeometryReader needs rework for current structure)
- [ ] Screenshots in README
- [ ] Browser surface screenshots (browser.screenshot polling)

## Bridge — Phase 2 (notification.subscribe)

- [ ] Wait for cmux `notification.subscribe` PR to land
- [ ] Swap poller for subscribe stream in bridge
- [ ] Remove polling interval config

## Bridge — Phase 3 (Tailscale)

- [ ] Add `tsnet` dependency
- [ ] `--tailscale` flag: embed Tailscale node, advertise on tailnet
- [ ] Update QR code URL with Tailscale hostname
- [ ] Update README with Tailscale setup instructions

## cmux PR

- [ ] Implement `notification.subscribe` in cmux Mac app (see `plans/cmux-pr-subscribe.md`)
- [ ] Open PR to manaflow-ai/cmux
