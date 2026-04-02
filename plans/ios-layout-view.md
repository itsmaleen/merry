# iOS Layout View Plan

## What's working
- `SurfaceListView` (Surfaces tab) shows surfaces correctly
- `appState.surfaces` is populated — the data pipeline works
- Tab UI with both Layout and Surfaces tabs is in place

## Root cause hypothesis

`WorkspaceLayoutView` has never successfully shown surfaces. Three attempts have all failed.
The working `SurfaceListView` uses a `NavigationStack` as its root; `WorkspaceLayoutView`
uses a custom `ZStack + VStack`. The hypothesis is that SwiftUI's environment propagation
or layout sizing behaves differently in this non-standard root structure when inside a `TabView`.

The safest fix: **build `WorkspaceLayoutView` on the same structural foundation as
`SurfaceListView`**, then layer the visual design on top. Don't reinvent the container.

---

## Step 1 — Minimal working skeleton

Replace the entire body of `WorkspaceLayoutView` with this:

```swift
var body: some View {
    NavigationStack {
        Group {
            if appState.surfaces.isEmpty {
                ContentUnavailableView(
                    "No surfaces",
                    systemImage: "square.split.2x1",
                    description: Text("Surfaces in the current workspace appear here.")
                )
            } else {
                surfaceGrid
            }
        }
        .navigationTitle("Layout")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { appState.refreshSurfaces() } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .refreshable { appState.refreshSurfaces() }
    }
    .onAppear { appState.refreshSurfaces() }
}
```

With `surfaceGrid` as:
```swift
private var surfaceGrid: some View {
    let cols: [GridItem] = appState.surfaces.count == 1
        ? [GridItem(.flexible())]
        : [GridItem(.flexible()), GridItem(.flexible())]
    return ScrollView {
        LazyVGrid(columns: cols, spacing: 12) {
            ForEach(appState.surfaces) { surface in
                PaneCardView(
                    title: surface.title,
                    isFocused: surface.id == appState.focusedSurfaceID,
                    hasNotification: appState.hasNotification(for: surface),
                    isTranscribing: false,
                    transcript: ""
                )
                .aspectRatio(1.5, contentMode: .fit)
                .onTapGesture { appState.focusSurface(surface.id) }
            }
        }
        .padding(12)
    }
    .background(Color.black)
}
```

**Goal:** Confirm surfaces show in the Layout tab at all.
No dark background, no workspace pills, no volume controls yet. Just data working.

---

## Step 2 — Add dark background and workspace pills

Once Step 1 works, add styling:

- Set `.toolbarBackground(Color.black, for: .navigationBar)` and
  `.toolbarColorScheme(.dark, for: .navigationBar)` on the NavigationStack
- Add `.background(Color.black.ignoresSafeArea())` to the ScrollView/Group
- Add workspace pills as a `navigationBarItems` leading item or as a pinned
  section header above the grid

---

## Step 3 — Add volume button cycling

Once rendering is confirmed working, add `VolumeButtonHandler` back:

- Add `@StateObject private var volumeHandler = VolumeButtonHandler()`
- Wire up in `.onAppear` / `.onDisappear`
- Single press → `appState.cycleSurface()`
- Double press → no-op for now (pane tabs not available)

The key lesson from previous attempts: **call `volumeHandler.start()` AFTER
`refreshSurfaces()` completes, not before.** `start()` activates `AVAudioSession`
which may interfere with the render cycle on first appearance.

```swift
.onAppear {
    appState.refreshSurfaces()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        setupVolumeHandler()
    }
}
```

---

## Step 4 — Add speech input

Once volume cycling works:

- Add `@StateObject private var speechManager = SpeechInputManager()`
- Call `speechManager.requestPermissions()` in onAppear
- Wire `volumeHandler.onSpeechBegan` / `onSpeechEnded` to speechManager
- Show transcript as an overlay on the focused surface card

---

## Step 5 — Remove NavigationStack chrome (optional polish)

If the NavigationStack title/bar is undesirable visually:

```swift
.navigationBarHidden(true)
// or
.toolbar(.hidden, for: .navigationBar)
```

This hides the nav bar while keeping NavigationStack as the layout root
(which fixes the TabView integration issue).

---

## Files to edit

| File | Change |
|------|--------|
| `ios/cmux/Layout/WorkspaceLayoutView.swift` | Full rewrite per steps above |
| `ios/cmux/App/MainTabView.swift` | No change needed |
| `ios/cmux/Input/VolumeButtonHandler.swift` | No change needed |
| `ios/cmux/Input/SpeechInputManager.swift` | No change needed |
| `ios/cmux/App/AppState.swift` | No change needed |

---

## What NOT to do

- Do not use `ZStack` with `Color.black.ignoresSafeArea()` as the view root inside
  a `TabView` — this breaks SwiftUI's layout sizing and environment propagation
- Do not set up `VolumeButtonHandler` in the same `onAppear` that triggers data
  loading — the audio session activation can disrupt the initial render pass
- Do not use `@ViewBuilder var canvas` as an intermediate computed property —
  put conditions directly in `body` so SwiftUI tracks dependencies correctly
