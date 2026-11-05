import SwiftUI

/// Every surface in the workspace as a scrollable grid of cards, like the iOS
/// app switcher: scroll to find the one you want, tap it to focus. Workspace
/// chips along the top load another workspace's surfaces in place, and the
/// last cards open a new tab (plain, or straight into claude YOLO).
struct SurfaceSwitcherView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    let workspaceLabel: (Workspace, Int) -> String
    let onSelect: (String) -> Void
    let onNewTab: () -> Void
    let onNewYoloTab: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        GeometryReader { geo in
            // Two columns on a portrait phone, three or more when wider.
            let columns = [GridItem(.adaptive(minimum: geo.size.width > 600 ? 200 : 150), spacing: 10)]
            let cardHeight = max(170, min(260, geo.size.height * 0.27))

            ZStack {
                // Opaque: the cards are glass, so anything behind would show
                // through them.
                Color.black.ignoresSafeArea()

                VStack(spacing: 10) {
                    header
                    workspaceChips

                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVGrid(columns: columns, spacing: 10) {
                                ForEach(appState.surfaces) { surface in
                                    card(for: surface)
                                        .frame(height: cardHeight)
                                        .id(surface.id)
                                }
                                newTabCard(icon: "plus", title: "New tab", action: onNewTab)
                                    .frame(height: cardHeight / 2)
                                newTabCard(icon: "bolt.fill", title: "New YOLO tab", action: onNewYoloTab)
                                    .frame(height: cardHeight / 2)
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 24)
                        }
                        .onAppear {
                            if let id = appState.focusedSurfaceID {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("Surfaces")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
            Text("\(appState.surfaces.count)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
            Spacer()
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Refresh surfaces")
            Button { isPresented = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white.opacity(0.1)))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close")
        }
        .foregroundStyle(.white.opacity(0.7))
        .buttonStyle(.plain)
        .padding(.leading, 16)
        .padding(.trailing, 6)
    }

    private var workspaceChips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(appState.visibleWorkspaces.enumerated()), id: \.element.id) { index, ws in
                        let isActive = ws.id == appState.currentWorkspaceID
                        let hasNotif = appState.notifications.contains { $0.workspaceID == ws.id }
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                appState.selectWorkspace(ws.id)
                            }
                        } label: {
                            Text(workspaceLabel(ws, index))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .lineLimit(1)
                                .foregroundStyle(isActive ? .black : .white.opacity(0.6))
                                .padding(.horizontal, 12)
                                .frame(height: 28)
                                .background(Capsule().fill(isActive ? Color.white : Color.white.opacity(0.08)))
                                .overlay(Capsule().stroke(Color.orange, lineWidth: hasNotif ? 1.5 : 0))
                        }
                        .buttonStyle(.plain)
                        .id(ws.id)
                    }
                }
                .padding(.horizontal, 12)
            }
            .onAppear {
                if let id = appState.currentWorkspaceID { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(height: 30)
    }

    // MARK: - Cards

    private func card(for surface: Surface) -> some View {
        let isCurrent = surface.id == appState.focusedSurfaceID
        return PaneCardView(
            title: surface.title,
            isFocused: false,
            hasNotification: appState.hasNotification(for: surface),
            isTranscribing: false,
            transcript: "",
            terminalText: surface.isBrowser ? "" : appState.cardText(for: surface),
            isBrowser: surface.isBrowser,
            browserURL: appState.browserURLs[surface.id] ?? "",
            isWorking: appState.workingSurfaces.contains(surface.id)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(isCurrent ? 0.85 : 0), lineWidth: 2)
        )
        .overlay(alignment: .bottomTrailing) {
            if isCurrent {
                Text("current")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white))
                    .padding(8)
            }
        }
        // A clear layer on top takes the tap, so the card's text view never
        // starts a selection or scroll inside the grid.
        .overlay(
            Color.clear
                .contentShape(RoundedRectangle(cornerRadius: 12))
                .onTapGesture { onSelect(surface.id) }
        )
        .contextMenu {
            Button { onSelect(surface.id) } label: {
                Label("Open", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            Button(role: .destructive) { appState.closeSurface(surface.id) } label: {
                Label("Close Surface", systemImage: "xmark.rectangle")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(surface.title + (isCurrent ? ", current" : ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect(surface.id) }
    }

    private func newTabCard(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(.white.opacity(0.55))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
