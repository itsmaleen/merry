# Remember last focused surface per workspace

**Goal:** When switching back to a workspace, restore the last focused surface instead of defaulting to the first.

## Files to change
- `ios/cmux/App/AppState.swift` — `selectWorkspace()` (line 106), `focusSurface()` (line 115), `refreshSurfaces()` (line ~223)

## Steps
- [ ] Add `private var lastFocusedSurface: [String: String] = [:]` dictionary to `AppState` (maps workspace ID → surface ID)
- [ ] In `focusSurface()`, save the mapping: `lastFocusedSurface[currentWorkspaceID] = id`
- [ ] In `selectWorkspace()` completion, instead of setting `localFocusedSurfaceID = nil`, set it to `lastFocusedSurface[id]` (the remembered surface for the target workspace)
- [ ] In `refreshSurfaces()`, when auto-selecting: check if `localFocusedSurfaceID` is set and exists in the new surface list. If it does, keep it. If it doesn't (surface was closed), fall back to first surface
- [ ] Optional: persist `lastFocusedSurface` to `UserDefaults` so it survives app restarts
