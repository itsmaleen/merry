import SwiftUI

/// Every surface in the workspace as a scrollable grid of cards, like the iOS
/// app switcher: scroll to find the one you want, tap it to focus. The only
/// place several surfaces show at once, and the home of the workspace pills:
/// they load another workspace's surfaces in place (a small orange dot marks
/// one with a notification). The last cards open a new tab (plain, or straight
/// into claude YOLO).
struct SurfaceSwitcherView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    let workspaceLabel: (Workspace, Int) -> String
    let onSelect: (String) -> Void
    let onNewTab: () -> Void
    let onNewYoloTab: () -> Void
    let onRefresh: () -> Void
    /// The "needs you" chip: shows only surfaces waiting on you. Filters,
    /// never re-sorts, so every card keeps its place.
    @State private var needsYouOnly = false

    private var shownSurfaces: [Surface] {
        guard needsYouOnly else { return appState.surfaces }
        let needs = appState.needsYouSurfaces
        return appState.surfaces.filter { needs.contains($0.id) }
    }

    var body: some View {
        GeometryReader { geo in
            // Two columns on a portrait phone, three or more when wider.
            let columns = [GridItem(.adaptive(minimum: geo.size.width > 600 ? 200 : 150), spacing: 10)]
            let cardHeight = max(170, min(260, geo.size.height * 0.27))

            ZStack {
                // Opaque: the cards are glass, so anything behind would show
                // through them.
                Theme.c.background.ignoresSafeArea()

                VStack(spacing: 10) {
                    header
                    workspaceChips

                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVGrid(columns: columns, spacing: 10) {
                                ForEach(shownSurfaces) { surface in
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
        .onAppear {
            // Screenshot fixture: open with the "needs you" filter on.
            if appState.isFixtureMode, ProcessInfo.processInfo.arguments.contains("-UITestNeedsYou") {
                needsYouOnly = true
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Surfaces")
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                Text("\(appState.surfaces.count)")
                    .font(.title2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
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
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .padding(.leading, 16)
        .padding(.trailing, 6)
    }

    private var workspaceChips: some View {
        HStack(spacing: 0) {
            needsYouChip
            workspaceChipScroller
        }
        .frame(height: 32)
    }

    /// A neutral capsule; selected is filled light with dark text, like a
    /// selected system chip.
    private func chip(_ text: String, selected: Bool, leadingDot: Bool = false, trailingDot: Bool = false) -> some View {
        HStack(spacing: 6) {
            if leadingDot { Circle().fill(Theme.c.attention).frame(width: 6, height: 6) }
            Text(text)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            if trailingDot { Circle().fill(Theme.c.attention).frame(width: 6, height: 6) }
        }
        .foregroundStyle(selected ? AnyShapeStyle(Color.black) : AnyShapeStyle(.primary))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(selected ? Color.white : Color.white.opacity(0.1)))
        .contentShape(Capsule())
    }

    @ViewBuilder
    private var needsYouChip: some View {
        let count = appState.surfaces.filter { appState.needsYouSurfaces.contains($0.id) }.count
        if count > 0 || needsYouOnly {
            Button { needsYouOnly.toggle() } label: {
                chip("Needs you · \(count)", selected: needsYouOnly, leadingDot: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(needsYouOnly ? "Show all surfaces" : "Show only surfaces that need you, \(count)")
            .padding(.leading, 12)
        }
    }

    private var workspaceChipScroller: some View {
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
                            chip(workspaceLabel(ws, index), selected: isActive, trailingDot: hasNotif)
                        }
                        .accessibilityLabel(workspaceLabel(ws, index) + (hasNotif ? ", has notifications" : ""))
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
    }

    // MARK: - Cards

    private func card(for surface: Surface) -> some View {
        let isCurrent = surface.id == appState.focusedSurfaceID
        return PaneCardView(
            title: surface.title,
            isFocused: false,
            hasNotification: appState.hasNotification(for: surface) || appState.needsYouSurfaces.contains(surface.id),
            isTranscribing: false,
            transcript: "",
            terminalText: surface.isBrowser ? "" : appState.cardText(for: surface),
            isBrowser: surface.isBrowser,
            browserURL: appState.browserURLs[surface.id] ?? "",
            isWorking: appState.workingSurfaces.contains(surface.id),
            glanceBody: GlanceBody(surface: surface, appState: appState),
            isCurrent: isCurrent
        )
        // A clear layer on top takes the tap, so the card's text view never
        // starts a selection or scroll inside the grid.
        .overlay(
            Color.clear
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                    .font(.body.weight(.medium))
                Text(title)
                    .font(.footnote.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
