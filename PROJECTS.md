# Projects

## P-001: Bridge Phase 1 — LAN + Polling

**Goal:** Working Go bridge that connects to the cmux socket, polls for notifications, and exposes a WebSocket server on the local network with QR-code pairing.

**Deliverables:**
- `merry-bridge` binary (single static binary, no dependencies)
- LaunchAgent plist + install script
- QR pairing flow in terminal

**Success criteria:**
- Bridge connects to cmux using password socket mode
- New cmux notifications appear on the WebSocket within 2 seconds
- QR scan from iOS pairs successfully with no manual config

**Status:** Not started

---

## P-002: iOS App Phase 1

**Goal:** SwiftUI iPhone app that pairs via QR, auto-discovers bridge on LAN, mirrors notifications, and can control workspaces/surfaces.

**Deliverables:**
- Xcode project in `ios/`
- QR scan pairing
- Notification panel
- Workspace + surface control

**Success criteria:**
- Scans QR code and connects without manual IP entry
- Notifications from `cmux notify` appear on phone within 2 seconds
- Can switch workspaces and send text from phone

**Status:** Not started

---

## P-003: notification.subscribe (cmux PR)

**Goal:** Add `notification.subscribe` to the cmux v2 socket API so the bridge can receive push events instead of polling.

**Deliverables:**
- PR to manaflow-ai/cmux
- Bridge updated to use subscribe stream

**Success criteria:**
- Notification latency drops from ~1s (polling) to <100ms (push)
- No regression in existing socket API behavior

**Status:** Not started — open after P-001 is working

---

## P-004: Bridge Phase 2 — notification.subscribe

**Goal:** Replace polling in the bridge with the new subscribe stream once the cmux PR lands.

**Status:** Blocked on P-003

---

## P-005: Bridge Phase 3 — Tailscale

**Goal:** Embed `tsnet` in the bridge so users can connect from anywhere without port forwarding.

**Deliverables:**
- `--tailscale` flag in bridge
- Tailscale hostname in QR code
- Updated README

**Status:** Not started — after P-001 + P-002 stabilize
