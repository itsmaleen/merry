# Bridge Phase 3 — Tailscale (tsnet)

## Overview

Embed a Tailscale node directly in `cmux-bridge` using `tailscale.com/tsnet`. Users get remote access from anywhere without:
- Port forwarding on their router
- Running the Tailscale desktop app
- Any external relay server

## How tsnet Works

`tsnet` is Tailscale's embeddable library. The bridge becomes its own Tailscale node with a stable hostname (`cmux-bridge.tail-XXXXX.ts.net`). The bridge listens on the Tailscale interface instead of (or in addition to) the LAN interface.

## Changes to Bridge

### New Flag

```
cmux-bridge --tailscale
```

### New Package

`bridge/internal/tailscale/ts.go`

```go
import "tailscale.com/tsnet"

func StartTailscaleListener(hostname string) (net.Listener, string, error) {
    srv := &tsnet.Server{
        Hostname: hostname, // default: "cmux-bridge"
        Dir:      "~/.config/cmux-bridge/tailscale",
    }
    ln, err := srv.Listen("tcp", ":47821")
    // returns listener + stable Tailscale hostname
}
```

### Config Additions

```json
{
  "tailscale": true,
  "tailscale_hostname": "cmux-bridge",
  "tailscale_auth_key": ""   // optional: for headless auth (CI/server). Empty = interactive auth URL printed on first run.
}
```

### QR Code Update

When `--tailscale` is active, the QR code encodes the Tailscale hostname instead of the LAN IP:

```
cmux-bridge://pair?host=cmux-bridge.tail-XXXXX.ts.net&port=47821&token=TOKEN
```

## iOS App Changes

No changes needed to the iOS app — it already supports hostname-based connections (not just IP). The Tailscale hostname resolves when the phone is on the tailnet (Tailscale app installed on iPhone).

## First-Run Auth Flow

On first `--tailscale` run with no auth key:

```
Visit to authenticate:
  https://login.tailscale.com/a/XXXXXXXXXXXX

Waiting for authentication...
```

After auth, the node appears in the Tailscale admin console. Subsequent starts are silent.

## Dual-Mode (LAN + Tailscale)

Both listeners can run simultaneously — the bridge serves on both the LAN WebSocket and the Tailscale interface. Clients connect to whichever is reachable.

## Dependencies Added

```
tailscale.com/tsnet    // ~15MB binary size increase
```
