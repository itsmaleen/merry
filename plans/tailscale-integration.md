# Tailscale Integration Plan (Phase 3)

## Goal

Allow the iOS app to connect to the bridge from anywhere (not just LAN) via
Tailscale, using `tsnet` embedded directly in the bridge binary.

## How tsnet works

`tsnet` embeds a Tailscale node inside a Go binary. No separate Tailscale client
install needed on the Mac. The bridge joins the user's tailnet and gets a stable
hostname like `cmux-bridge.tailnet-name.ts.net`. The iOS device (with Tailscale
installed) can then connect to that hostname from anywhere.

Key properties:
- Provides `ts.Listen("tcp", ":47821")` → listener on the tailnet
- Automatic TLS via Tailscale's `tsnet.Server.TLS()` if wanted
- State stored in a local directory (persists identity across restarts)
- No extra ports opened on the Mac's public IP

## Architecture

```
[cmux Mac]  ←── Unix socket ──→  [cmux-bridge]  ←── WS/LAN ──→  [iOS on LAN]
                                       │
                                       ├── WS/Tailscale ──→  [iOS on tailnet]
                                       │
                                    [tsnet node]
                                  (embedded Tailscale)
```

Dual listeners: the bridge serves WebSocket on **both** LAN (existing) and tailnet
(new). Same token auth, same handler, same protocol.

## Implementation

### 1. Add tsnet dependency

```bash
cd bridge
go get tailscale.com/tsnet@latest
```

### 2. Config changes

```go
type config struct {
    // ... existing fields ...
    Tailscale        bool   `json:"tailscale"`          // enable tailnet listener
    TailscaleHostname string `json:"tailscale_hostname"` // e.g. "cmux-bridge"
}
```

Default: `tailscale: false` (opt-in). Enable with `--tailscale` flag or config.

### 3. Bridge changes — dual listener in server.go

Current `ListenAndServe` creates one TCP listener. Change to accept multiple
listeners so the same HTTP handler serves both:

```go
func (s *Server) ListenAndServe(ctx context.Context, listeners ...net.Listener) error {
    // Serve each listener in its own goroutine
    for _, ln := range listeners {
        go s.httpServer.Serve(ln)
    }
    <-ctx.Done()
    return s.httpServer.Shutdown(context.Background())
}
```

### 4. Bridge changes — main.go tsnet setup

```go
if cfg.Tailscale {
    ts := &tsnet.Server{
        Hostname: cfg.TailscaleHostname, // defaults to "cmux-bridge"
        Dir:      filepath.Join(configDir, "tailscale"),
    }
    defer ts.Close()

    tsLn, err := ts.Listen("tcp", fmt.Sprintf(":%d", cfg.BridgePort))
    if err != nil {
        log.Fatalf("tailscale listen: %v", err)
    }
    listeners = append(listeners, tsLn)

    // Get tailnet IP for QR code
    status, _ := ts.Up(ctx)
    log.Printf("tailscale: %s (%s)", status.Self.DNSName, status.TailscaleIPs[0])
}
```

On first run with `--tailscale`, tsnet opens a browser for Tailscale OAuth login.
After that, the node identity is cached in `~/.config/cmux-bridge/tailscale/`.

### 5. QR pairing changes

The QR code currently encodes:
```
cmux-bridge://pair?host=192.168.1.x&port=47821&token=...
```

With Tailscale, also include the tailnet hostname:
```
cmux-bridge://pair?host=192.168.1.x&port=47821&token=...&tailscale_host=cmux-bridge.tailnet.ts.net
```

The iOS app stores both addresses and tries tailnet when LAN is unreachable.

### 6. iOS changes

**PairingCredentials** — add optional tailscale host:

```swift
struct PairingCredentials: Codable {
    let host: String           // LAN IP
    let port: Int
    let token: String
    let tailscaleHost: String? // e.g. "cmux-bridge.tailnet.ts.net"
}
```

**BridgeClient** — connection strategy:

1. Try LAN first (`host:port`) — fast path, sub-50ms
2. If LAN fails and `tailscaleHost` is set, try `tailscaleHost:port`
3. On reconnect, alternate between LAN and tailnet

The iOS device needs Tailscale installed and connected to the same tailnet.

**Bonjour discovery** — keep as-is for LAN. For tailnet, the stored hostname
is sufficient (no discovery needed since Tailscale provides DNS).

### 7. Flag and CLI

```
cmux-bridge                    # LAN only (default)
cmux-bridge --tailscale        # LAN + tailnet
cmux-bridge --pair             # Pair (includes tailnet info if enabled)
cmux-bridge --pair --tailscale # Pair with tailnet hostname in QR
```

## Rollout order

1. Add `tsnet` dependency and `--tailscale` flag
2. Create dual listener in server.go
3. Wire up tsnet node in main.go (behind flag)
4. Update QR code to include tailnet hostname
5. Update iOS PairingCredentials + BridgeClient connection strategy
6. Test: LAN-only still works, tailnet connects when LAN unavailable
7. Update README

## Considerations

- **First-time auth**: `tsnet` opens a browser for Tailscale login on first run.
  This is a one-time interactive step. Document it clearly.
- **Binary size**: `tsnet` adds ~15-20MB to the binary. Acceptable for a daemon.
- **State directory**: `~/.config/cmux-bridge/tailscale/` persists the node identity.
  Deleting it requires re-authenticating.
- **TLS**: tsnet can provide automatic TLS. Our Bearer token auth is sufficient
  for authorization, but TLS encrypts the WebSocket traffic on the tailnet.
  Consider using `ts.TLS()` for the tailnet listener.
- **iOS Tailscale**: the user must have Tailscale installed on the iPhone and be
  logged into the same tailnet. This is a prerequisite, not something we control.
- **Fallback**: if tailnet is down, LAN still works. If LAN is unavailable
  (e.g., phone on cellular), tailnet is the only path.

## Files to change

| File | Change |
|------|--------|
| `bridge/go.mod` | Add `tailscale.com/tsnet` |
| `bridge/cmd/cmux-bridge/main.go` | `--tailscale` flag, tsnet setup, dual listener |
| `bridge/internal/ws/server.go` | Accept multiple listeners |
| `bridge/internal/pair/qr.go` | Include tailnet hostname in QR URL |
| `ios/cmux/Connection/PairingStore.swift` | Add `tailscaleHost` to credentials |
| `ios/cmux/Connection/BridgeClient.swift` | LAN-first, tailnet-fallback connection |
| `ios/cmux/Pairing/QRScannerView.swift` | Parse `tailscale_host` param from QR |
| `README.md` | Tailscale setup instructions |
