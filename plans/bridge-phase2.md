# Bridge Phase 2 — notification.subscribe

**Blocked on:** cmux PR (`plans/cmux-pr-subscribe.md`) being merged.

## Overview

Replace the 1s polling loop in the bridge with a long-lived `notification.subscribe` socket connection that receives pushed events. This reduces notification latency from ~1s to <100ms and eliminates unnecessary socket churn.

## Changes to Bridge

### Remove

- `bridge/internal/poller/poller.go` — entire polling package
- `poll_interval_ms` config field

### Add

`bridge/internal/subscriber/subscriber.go`

The subscriber opens a long-lived socket connection and sends:

```json
{"id":"sub-1","method":"notification.subscribe","params":{}}
```

The socket then pushes events over the same connection:

```json
{"type":"notification.created","data":{...}}
{"type":"notification.cleared","data":{}}
```

The subscriber relays these directly to all connected WebSocket clients (same message format as Phase 1, so iOS app requires no changes).

### Reconnect

If the subscribe connection drops (socket restart, cmux relaunch), the subscriber:
1. Closes with `{"type":"cmux.disconnected"}` push to clients
2. Waits for socket reconnect (exponential backoff)
3. Re-issues `notification.subscribe` on reconnect
4. Pushes `{"type":"cmux.connected"}` to clients

## Config Migration

`poll_interval_ms` is ignored/removed from `config.json`. No migration needed — just remove the field.

## Testing

Once this lands, verify:
- Notification appears on iOS within 100ms of `cmux notify --title "Test"`
- Bridge reconnects cleanly after `cmux` restart
- No duplicate notifications on reconnect
