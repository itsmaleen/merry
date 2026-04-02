# Cross-Workspace Notification Indicators

## Problem

Notification indicators don't work reliably — even on the current workspace:

- **Surface-level**: the orange ring on `PaneCardView` checks `panelID` against loaded
  surface IDs, but the `panel_id` from cmux may not match the surface IDs returned by
  `surface.list` (different ID spaces, or the notification references a tab/panel that
  isn't a top-level surface). Need to investigate the exact ID mapping between
  `notification.panel_id` and `surface.id`.
- **Cross-workspace**: other workspace pills have no visual indicator because
  `notification.created` only includes `panel_id`, not `workspace_id`, and the app only
  loads surfaces for the current workspace.

Root cause for both: the bridge forwards raw cmux notification data without resolving
the relationship between notifications, surfaces, and workspaces.

## Solution

### 1. Bridge: add `workspace_id` and `surface_title` to notification events

In the bridge's notification relay, enrich the `notification.created` payload with
workspace context before forwarding to iOS:

```json
{
  "type": "notification.created",
  "data": {
    "id": "uuid",
    "title": "Claude Code",
    "subtitle": "Permission",
    "body": "Approval needed for file write",
    "tab_id": "uuid-or-null",
    "panel_id": "uuid-or-null",
    "workspace_id": "uuid-or-null",
    "surface_title": "zsh — ~/project",
    "created_at": "2026-04-02T10:00:00Z"
  }
}
```

The bridge already has access to cmux's socket and can call `surface.list` / `workspace.list`
to resolve the mapping. Two approaches:

- **Eager**: on `cmux.connected`, fetch all workspaces and surfaces, build a
  `surface_id → workspace_id` lookup table. Refresh on `workspace.created` /
  `surface.created` events if available, or periodically.
- **Lazy**: on each `notification.created`, call `surface.list` (no workspace filter)
  to find which workspace owns the `panel_id`. Cache the result.

Eager is better — avoids per-notification latency and the lookup table is small.

### 2. Protocol: update `shared/protocol.md`

Add `workspace_id` and `surface_title` as optional fields to the `notification.created`
schema. Both are nullable (some notifications may not be tied to a surface/workspace).

### 3. iOS: update `BridgeNotification` model

```swift
struct BridgeNotification: Identifiable, Decodable {
    let id: String
    let title: String
    let subtitle: String?
    let body: String?
    let tabID: String?
    let panelID: String?
    let workspaceID: String?      // new
    let surfaceTitle: String?     // new
    let createdAt: String?
}
```

### 4. Investigate panel_id ↔ surface_id mapping

Before wiring up indicators, confirm how cmux's `notification.panel_id` relates to
`surface.id`. They may be the same, or `panel_id` might reference a sub-panel within
a surface. Debug by logging both values side-by-side when a notification arrives while
surfaces are loaded. If they don't match, the bridge enrichment (step 1) becomes
essential — the bridge can resolve `panel_id` → `surface_id` → `workspace_id` in one
lookup and send all three.

### 5. iOS: workspace pill indicators for any workspace

With `workspaceID` on each notification, the `workspaceHasNotification` check becomes:

```swift
private func workspaceHasNotification(_ ws: Workspace) -> Bool {
    appState.notifications.contains { $0.workspaceID == ws.id }
}
```

No need to have surfaces loaded for that workspace — just match IDs directly.

### 6. iOS: show surface title in notification without loading surfaces

With `surfaceTitle` on the notification, the Notifications tab can display which
surface triggered the notification even if it's in a different workspace, without
needing to fetch that workspace's surface list.

## Debugging steps (do first)

1. When a notification arrives, log `notification.panel_id` and all `surface.id` values
   to confirm whether they share the same ID space
2. If they don't match, check if cmux exposes a mapping (e.g. `tab_id` → `surface_id`)
3. This determines whether the iOS-side `hasNotification(for:)` can ever work without
   bridge enrichment

## Files to change

| Layer | File | Change |
|-------|------|--------|
| Bridge | `bridge/internal/ws/handler.go` | Build surface→workspace lookup, enrich notifications |
| Protocol | `shared/protocol.md` | Add `workspace_id`, `surface_title`, resolved `surface_id` to schema |
| iOS | `ios/cmux/Connection/BridgeClient.swift` | Parse new fields |
| iOS | `ios/cmux/App/AppState.swift` | Update `BridgeNotification` model |
| iOS | `ios/cmux/Layout/WorkspaceLayoutView.swift` | Simplify `workspaceHasNotification` |
