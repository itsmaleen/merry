# iOS App Phase 1

## Overview

SwiftUI iPhone app that:
1. Pairs with `cmux-bridge` via QR scan
2. Auto-discovers bridge on LAN via Bonjour
3. Mirrors cmux notifications in real time
4. Controls workspaces, surfaces, and sends text/key commands

## Requirements

- iOS 17+
- Xcode 16+
- Same LAN as the Mac running cmux-bridge (Phase 1)

## Project Structure

```
ios/
├── cmux.xcodeproj
└── cmux/
    ├── App/
    │   ├── cmuxApp.swift           # @main, URL scheme handler (cmux-bridge://)
    │   └── AppState.swift          # ObservableObject: connection, workspaces, notifications
    ├── Connection/
    │   ├── BridgeClient.swift      # URLSessionWebSocketTask wrapper
    │   ├── BridgeDiscovery.swift   # NetServiceBrowser for _cmux-bridge._tcp
    │   └── PairingStore.swift      # Keychain storage for host/port/token
    ├── Pairing/
    │   ├── PairingView.swift       # QR scan + manual entry
    │   └── QRScannerView.swift     # AVFoundation camera view
    ├── Notifications/
    │   ├── NotificationsView.swift  # list of notifications, clear button
    │   └── NotificationRow.swift
    ├── Control/
    │   ├── ControlView.swift        # tab: Workspaces | Surfaces | Send
    │   ├── WorkspaceListView.swift  # workspace.list + tap to select
    │   ├── SurfaceListView.swift    # surface.list + tap to focus
    │   └── SendTextView.swift       # text field + send button
    └── Settings/
        └── SettingsView.swift       # manual IP/port override, unpair
```

## URL Scheme

Register `cmux-bridge` in Info.plist. On open:
```
cmux-bridge://pair?host=192.168.1.5&port=47821&token=TOKEN
```

Parse parameters → store in Keychain via `PairingStore` → connect.

## WebSocket Message Handling

`BridgeClient` decodes incoming messages:

```swift
enum BridgeMessage: Decodable {
    case notificationCreated(NotificationPayload)  // type: "notification.created"
    case notificationCleared                        // type: "notification.cleared"
    case cmuxConnected                              // type: "cmux.connected"
    case cmuxDisconnected                           // type: "cmux.disconnected"
    case commandResponse(CommandResponse)           // id + ok + result/error
}
```

Outgoing commands use the v2 JSON-RPC envelope:
```swift
struct Command: Encodable {
    let id: String
    let method: String
    let params: [String: Any]
}
```

## Reconnect Strategy

- On disconnect: retry with backoff (1s, 2s, 4s, 8s, max 30s)
- Show connection status bar (green dot / spinner / red dot)
- Bonjour re-discovery if stored host becomes unreachable

## UI Structure

**Tab bar:**
1. **Notifications** — badge count, list, swipe-to-clear
2. **Workspaces** — list with current indicator, tap to switch
3. **Surfaces** — list in current workspace, tap to focus
4. **Send** — text field + send button (sends to focused surface)
5. **Settings** — connection info, manual override, unpair

## Keychain Storage

```swift
// PairingStore
struct PairingCredentials: Codable {
    let host: String
    let port: Int
    let token: String
}
// stored under key: "dev.itsmaleen.cmux-bridge.credentials"
```

## Bonjour Discovery

```swift
// BridgeDiscovery
let browser = NetServiceBrowser()
browser.searchForServices(ofType: "_cmux-bridge._tcp", inDomain: "local.")
// On discovery: extract host+port from TXT records, offer to user
```

If multiple bridges are found (multiple Macs), show a picker.
