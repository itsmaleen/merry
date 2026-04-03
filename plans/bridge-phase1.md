# Bridge Phase 1 — LAN + Polling

## Overview

A Go binary (`cmux-bridge`) that:
1. Authenticates with the local cmux Unix socket (password mode)
2. Polls `notification.list` every 1s and pushes new notifications to connected iOS clients over WebSocket
3. Proxies any v2 JSON-RPC command from iOS clients to the cmux socket and streams the response back
4. Advertises itself via Bonjour/mDNS for zero-config LAN discovery
5. Generates a pairing token and displays a QR code for secure first-time pairing

## Directory Structure

```
bridge/
├── cmd/
│   └── cmux-bridge/
│       └── main.go          # entry point, flags, config
├── internal/
│   ├── socket/
│   │   ├── client.go        # Unix socket connection + v2 JSON-RPC
│   │   └── auth.go          # password challenge-response
│   ├── poller/
│   │   └── poller.go        # notification.list polling + diff
│   ├── ws/
│   │   ├── server.go        # WebSocket server
│   │   ├── handler.go       # per-client handler (push + proxy)
│   │   └── auth.go          # Bearer token validation
│   ├── mdns/
│   │   └── advertise.go     # Bonjour _cmux-bridge._tcp advertisement
│   └── pair/
│       └── qr.go            # token generation + QR code display
├── go.mod
└── go.sum
```

## Dependencies

```
github.com/nhooyr.io/websocket    # WebSocket server (stdlib-style)
github.com/grandcat/zeroconf      # Bonjour/mDNS
github.com/skip2/go-qrcode        # QR code terminal output
```

No CGO. Single static binary.

## Configuration

Config file: `~/.config/cmux-bridge/config.json`

```json
{
  "socket_path": "",          // auto-detected from CMUX_SOCKET_PATH or last-socket-path file
  "socket_password": "",      // cmux socket password (SocketControlMode.password)
  "bridge_port": 47821,       // WebSocket server port
  "poll_interval_ms": 1000    // notification poll interval
}
```

Token file: `~/.config/cmux-bridge/token` (600 permissions, generated on first run)

## Socket Authentication

The cmux socket in password mode uses a challenge-response protocol. The bridge must:
1. Connect to Unix socket
2. Read challenge line
3. Respond with HMAC-SHA256(challenge, password)

Reference: `Sources/SocketControlSettings.swift` and the CLI relay auth in `daemon/remote/cmd/cmuxd-remote/cli.go`.

## Notification Polling

```
every 1000ms:
  send: {"id":"poll-N","method":"notification.list","params":{}}
  recv: {"id":"poll-N","ok":true,"result":{"notifications":[...]}}
  diff against last-seen IDs
  for each new notification:
    push to all connected WebSocket clients:
    {"type":"notification.created","data":{...notification...}}
```

## WebSocket Message Protocol

See `shared/protocol.md` for the full schema.

**Server → Client (push):**
```json
{"type":"notification.created","data":{"id":"...","title":"...","body":"...","tab_id":"...","panel_id":"..."}}
{"type":"notification.cleared","data":{}}
{"type":"connected","data":{"bridge_version":"0.1.0","cmux_connected":true}}
```

**Client → Server (commands):**
```json
{"id":"1","method":"workspace.list","params":{}}
{"id":"2","method":"workspace.select","params":{"workspace_id":"..."}}
{"id":"3","method":"surface.send_text","params":{"surface_id":"...","text":"ls\n"}}
{"id":"4","method":"notification.clear","params":{}}
```

**Server → Client (command responses):**
```json
{"id":"1","ok":true,"result":{...}}
{"id":"2","ok":false,"error":{"code":"not_found","message":"workspace not found"}}
```

## QR Pairing Flow

```bash
cmux-bridge --pair
```

Output:
```
┌─────────────────────────────────┐
│  Scan to pair cmux companion    │
│                                 │
│  [QR CODE]                      │
│                                 │
│  cmux-bridge://pair?            │
│    host=192.168.1.5             │
│    port=47821                   │
│    token=<base64url-256bit>     │
└─────────────────────────────────┘
```

QR URL scheme: `cmux-bridge://pair?host=HOST&port=PORT&token=TOKEN`

iOS app registers the `cmux-bridge://` URL scheme and handles pairing on open.

## Bonjour Advertisement

Service type: `_cmux-bridge._tcp`
TXT records:
- `version=1`
- `host=HOSTNAME` (for display in iOS app)

## LaunchAgent

`scripts/install-bridge.sh` writes:

```xml
<!-- ~/Library/LaunchAgents/com.itsmaleen.cmux-bridge.plist -->
<plist version="1.0">
<dict>
  <key>Label</key><string>com.itsmaleen.cmux-bridge</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/cmux-bridge</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/cmux-bridge.log</string>
  <key>StandardErrorPath</key><string>/tmp/cmux-bridge.log</string>
</dict>
</plist>
```

## Error Handling

- If cmux socket is not available: retry with exponential backoff (1s, 2s, 4s, max 30s). Push `{"type":"cmux.disconnected"}` to clients.
- If cmux socket reconnects: push `{"type":"cmux.connected"}` to clients.
- WebSocket client disconnect: remove from client list, no action needed.
