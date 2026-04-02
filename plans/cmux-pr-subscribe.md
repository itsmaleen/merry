# cmux PR: notification.subscribe

**Target repo:** manaflow-ai/cmux  
**Depends on:** Bridge Phase 1 working (so we have a concrete use case)

## Overview

Add `notification.subscribe` to the cmux v2 socket API. A client sends a subscribe request and the socket connection stays open, receiving pushed notification events as they happen — no polling needed.

This follows the exact pattern of `proxy.stream.subscribe` already implemented in `cmuxd-remote`.

## Socket API Addition

**Request (one-time):**
```json
{"id":"sub-1","method":"notification.subscribe","params":{}}
```

**Response (immediate, confirms subscription):**
```json
{"id":"sub-1","ok":true,"result":{"subscribed":true}}
```

**Pushed events (as they happen, no id):**
```json
{"type":"notification.created","data":{"id":"...","title":"...","body":"...","subtitle":"...","tab_id":"...","panel_id":"..."}}
{"type":"notification.cleared","data":{}}
```

The connection stays open. Client can send other commands on the same connection concurrently.

## Implementation

The subscription is stored in the socket connection's handler. When `TerminalNotificationStore` fires a new notification or a clear, it iterates active subscribers and writes the event.

**Key files to touch:**
- `Sources/TerminalNotificationStore.swift` — add subscriber registration + event dispatch
- The socket command handler (wherever v2 methods are dispatched — grep for `notification.list`) — add `notification.subscribe` case

**Pattern to follow:** `proxy.stream.subscribe` in `daemon/remote/cmd/cmuxd-remote/main.go`

## Acceptance Criteria

- `notification.subscribe` response arrives immediately after request
- `cmux notify --title "Test"` causes a pushed event within 100ms
- `cmux clear-notifications` causes a `notification.cleared` push
- Multiple concurrent subscribers all receive events
- Subscriber connection drop is handled gracefully (no crash, no leak)
- No regression in `notification.list`, `notification.create`, `notification.clear`

## PR Scope

Small, self-contained. No breaking changes. No v1 changes.

Estimated: ~80 lines in Mac app (Swift).

## Testing

Add to `tests_v2/`:
- `test_notification_subscribe.py` — subscribe, send notify via CLI, assert push received within 1s
- Test clear event
- Test multiple concurrent subscribers
