# Fullscreen terminal toggle as a quick action

**Goal:** Add a "Fullscreen" option in the Workspace section of quick actions.

## Files to change
- `ios/cmux/Layout/WorkspaceLayoutView.swift` — `QuickActionBuilder.build()` (line 57) + add fullscreen state
- `ios/cmux/Settings/QuickActionSettingsView.swift` — `builtInActions` array (line 9)

## Steps
- [ ] Add `@State var isFullscreen = false` to `WorkspaceLayoutView`
- [ ] Add built-in quick action in `QuickActionBuilder.build()` under Workspace section
- [ ] Wire fullscreen toggle: when active, render only the focused surface card at full width/height, hiding the tile sidebar and workspace bar
- [ ] Add to `QuickActionSettingsView.builtInActions`
- [ ] Pressing the action again (or adding a gesture) should exit fullscreen
