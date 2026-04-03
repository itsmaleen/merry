# Close workspace quick action

**Goal:** Add "Close Workspace" under the Workspace section in quick actions.

## Files to change
- `ios/cmux/Layout/WorkspaceLayoutView.swift` — `QuickActionBuilder.build()` (line 57)
- `ios/cmux/App/AppState.swift` — add `closeWorkspace()` method
- `ios/cmux/Settings/QuickActionSettingsView.swift` — `builtInActions` array

## Steps
- [ ] Add `closeWorkspace(_ id: String)` to `AppState` — sends `workspace.close` RPC (or equivalent cmux method), then refreshes workspaces and selects the next available one
- [ ] Add built-in quick action under Workspace section
- [ ] Add to `QuickActionSettingsView.builtInActions`
- [ ] After closing, auto-select the previous or next workspace in the list
