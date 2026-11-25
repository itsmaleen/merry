import SwiftUI

/// Every surface in the workspace as a scrollable grid of cards, like the iOS
/// app switcher: scroll to find the one you want, tap it to focus. The only
/// place several surfaces show at once, and the home of the workspace pills:
/// they load another workspace's surfaces in place (a small orange dot marks
/// one with a notification). The last cards open a new tab (plain, or straight
/// into claude YOLO).
///
/// With more than one paired device, a row of device chips sits above the
/// workspaces (tap one to show that device here), and the other devices'
/// sessions are listed under the cards: tap one to open it, or start a new
/// tab there. Those lists come from DevicePeeker, connected only while the
/// grid is open.
struct SurfaceSwitcherView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var peeker: DevicePeeker
    @Binding var isPresented: Bool
    let workspaceLabel: (Workspace, Int) -> String
    let onSelect: (String) -> Void
    let onNewTab: () -> Void
    let onNewYoloTab: () -> Void
    let onRefresh: () -> Void
    /// The command a YOLO tab runs, for one started on another device.
    let yoloCommand: () -> String
    /// Other devices whose whole list is shown (more than `previewCount`).
    @State private var expandedDevices: Set<UUID> = []
    private static let previewCount = 4
    /// The "needs you" chip: shows only surfaces waiting on you. Filters,
    /// never re-sorts, so every card keeps its place.
    @State private var needsYouOnly = false
    /// Sunny's deck, opened from the pinned card above the grid.
    @State private var showSunny = false

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
                    if appState.bridges.count > 1 { deviceChips }
                    workspaceChips

                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            SunnySwitcherCard { showSunny = true }
                                .padding(.horizontal, 12)
                                .padding(.bottom, 10)
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

                            if !appState.otherBridges.isEmpty {
                                otherDevices
                                    .padding(.horizontal, 12)
                                    .padding(.bottom, 32)
                                    .id("otherDevices")
                            }
                        }
                        .onAppear {
                            // Screenshot fixture: open on the other devices' list.
                            if appState.isFixtureMode, ProcessInfo.processInfo.arguments.contains("-UITestDevicesList") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { proxy.scrollTo("otherDevices", anchor: .bottom) }
                                return
                            }
                            if let id = appState.focusedSurfaceID {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
        .fullScreenCover(isPresented: $showSunny) {
            SunnyView(onClose: { showSunny = false })
        }
        .onAppear { appState.setDevicePeeking(true) }
        .onDisappear { appState.setDevicePeeking(false) }
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

    // MARK: - Devices

    /// One chip per paired device; the one on screen is filled. Another
    /// device's chip carries its session count, and a dot when one of its
    /// agents is waiting on you.
    private var deviceChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(appState.bridges) { bridge in
                    let isCurrent = bridge.id == appState.selectedBridge?.id
                    let snapshot = peeker.snapshots[bridge.id]
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { appState.selectBridge(bridge.id) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "desktopcomputer")
                                .font(.caption.weight(.semibold))
                            Text(DeviceName.short(bridge.name))
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            if !isCurrent, let snapshot, snapshot.reach != .connecting || !snapshot.sessions.isEmpty {
                                Text(snapshot.reach == .offline ? "offline" : "\(snapshot.sessions.count)")
                                    .font(.footnote.monospacedDigit())
                                    .opacity(0.6)
                            }
                            if !isCurrent, (snapshot?.needsYou ?? 0) > 0 {
                                Circle().fill(Theme.c.attention).frame(width: 6, height: 6)
                            }
                        }
                        .foregroundStyle(isCurrent ? AnyShapeStyle(Color.black) : AnyShapeStyle(.primary))
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Capsule().fill(isCurrent ? Color.white : Color.white.opacity(0.1)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(DialogRowStyle())
                    .accessibilityLabel(deviceChipLabel(bridge, snapshot: snapshot, isCurrent: isCurrent))
                    .accessibilityAddTraits(isCurrent ? .isSelected : [])
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 32)
    }

    private func deviceChipLabel(_ bridge: SavedBridge, snapshot: DeviceSnapshot?, isCurrent: Bool) -> String {
        let name = DeviceName.short(bridge.name)
        if isCurrent { return "\(name), showing" }
        guard let snapshot else { return name }
        if snapshot.reach == .offline { return "\(name), offline" }
        let needs = snapshot.needsYou > 0 ? ", \(snapshot.needsYou) need you" : ""
        return "\(name), \(snapshot.sessions.count) sessions\(needs)"
    }

    /// Under the cards: each other device with its sessions as rows.
    private var otherDevices: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(appState.otherBridges) { bridge in
                deviceSection(bridge, snapshot: peeker.snapshots[bridge.id] ?? DeviceSnapshot())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func deviceSection(_ bridge: SavedBridge, snapshot: DeviceSnapshot) -> some View {
        let name = DeviceName.short(bridge.name)
        let expanded = expandedDevices.contains(bridge.id)
        let shown = expanded ? snapshot.sessions : Array(snapshot.sessions.prefix(Self.previewCount))
        let hidden = snapshot.sessions.count - shown.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("On \(name)")
                    .font(.headline)
                    .foregroundStyle(.primary)
                switch snapshot.reach {
                case .connecting where snapshot.sessions.isEmpty:
                    ProgressView().controlSize(.mini)
                case .offline:
                    Text("Offline")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
                Spacer()
                Menu {
                    Button("New Tab", systemImage: "plus.square") {
                        appState.startSession(on: bridge.id, command: nil)
                        isPresented = false
                    }
                    Button("New YOLO Tab", systemImage: "bolt.fill") {
                        appState.startSession(on: bridge.id, command: yoloCommand())
                        isPresented = false
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                        .frame(width: 44, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("New tab on \(name)")
            }

            VStack(spacing: 0) {
                if shown.isEmpty {
                    Text(emptyText(snapshot.reach, name: name))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                }
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 14) }
                    sessionRow(session, on: bridge)
                }
                if hidden > 0 {
                    Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 14)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { _ = expandedDevices.insert(bridge.id) }
                    } label: {
                        Text("Show \(hidden) more")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(DialogRowStyle())
                }
            }
            .background(Theme.c.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            // The last list of a device that stopped answering, dimmed.
            .opacity(snapshot.reach == .offline ? 0.55 : 1)
        }
    }

    private func emptyText(_ reach: DeviceSnapshot.Reach, name: String) -> String {
        switch reach {
        case .connecting: return "Looking for sessions…"
        case .offline: return "Can't reach \(name) right now."
        case .online: return "No sessions open."
        }
    }

    private func sessionRow(_ session: PeekSession, on bridge: SavedBridge) -> some View {
        Button {
            appState.openSession(on: bridge.id, surfaceID: session.id, workspaceID: session.workspaceID)
            isPresented = false
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(session.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let status = session.statusLabel {
                    HStack(spacing: 5) {
                        if session.needsYou { Circle().fill(Theme.c.attention).frame(width: 6, height: 6) }
                        Text(status)
                    }
                    .font(.footnote.weight(session.needsYou ? .semibold : .regular))
                    .foregroundStyle(session.needsYou ? AnyShapeStyle(Theme.c.attention) : AnyShapeStyle(.secondary))
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(DialogRowStyle())
        .accessibilityLabel("\(session.title), \(session.detail)\(session.statusLabel.map { ", " + $0 } ?? ""), on \(DeviceName.short(bridge.name))")
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
