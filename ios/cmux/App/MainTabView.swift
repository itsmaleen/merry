import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var showSidebar = false
    @State private var sidebarTimer: Timer?

    var body: some View {
        ZStack(alignment: .leading) {
            // Full-screen content
            Group {
                switch appState.selectedTab {
                case .layout:
                    WorkspaceLayoutView()
                case .surfaces:
                    SurfaceListView()
                case .send:
                    SendTextView()
                case .notifications:
                    NotificationsView()
                case .settings:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Menu toggle button (top-left, visible when sidebar hidden)
            if !showSidebar {
                VStack {
                    HStack {
                        Button { revealSidebar() } label: {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white.opacity(0.4))
                                .frame(width: 32, height: 32)
                                .background(
                                    Circle()
                                        .fill(.ultraThinMaterial.opacity(0.5))
                                        .environment(\.colorScheme, .dark)
                                )
                        }
                        .padding(.leading, 12)
                        .padding(.top, 8)
                        Spacer()
                    }
                    Spacer()
                }
                .transition(.opacity)
            }

            // Sidebar overlay
            if showSidebar {
                // Dimmed background
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { dismissSidebar() }
                    .transition(.opacity)

                // Sidebar panel
                sidebarPanel
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showSidebar)
        .onDisappear {
            // Otherwise the auto-dismiss timer fires into a torn-down view.
            sidebarTimer?.invalidate()
            sidebarTimer = nil
        }
        .overlay(alignment: .top) {
            ConnectionStatusBar()
        }
        .sheet(isPresented: $appState.isPairingPresented) {
            PairingView()
        }
        .alert(
            "Add this bridge?",
            isPresented: Binding(
                get: { appState.pendingPairing != nil },
                set: { if !$0 { appState.cancelPendingPairing() } }
            ),
            presenting: appState.pendingPairing
        ) { pending in
            Button("Add \(pending.host):\(pending.port)") {
                appState.confirmPendingPairing()
            }
            Button("Cancel", role: .cancel) {
                appState.cancelPendingPairing()
            }
        } message: { pending in
            Text("This adds a new bridge and switches all input to \(pending.host):\(pending.port). Only continue if you initiated this pairing.")
        }
    }

    // MARK: - Sidebar

    private var sidebarPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SidebarTab.allCases) { tab in
                Button {
                    appState.selectedTab = tab
                    dismissSidebar()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 13))
                            .frame(width: 20)
                        Text(tab.label)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                        Spacer()
                        if tab == .notifications && appState.notifications.count > 0 {
                            Text("\(appState.notifications.count)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.orange))
                        }
                    }
                    .foregroundStyle(appState.selectedTab == tab ? .white : .white.opacity(0.5))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(appState.selectedTab == tab ? Color.white.opacity(0.1) : .clear)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Version / branding
            Text("cmux companion")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.2))
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .padding(.top, 16)
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 16,
                topTrailingRadius: 16
            )
        )
    }

    // MARK: - Actions

    private func revealSidebar() {
        showSidebar = true
        sidebarTimer?.invalidate()
        sidebarTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in
            Task { @MainActor in
                dismissSidebar()
            }
        }
    }

    private func dismissSidebar() {
        showSidebar = false
        sidebarTimer?.invalidate()
        sidebarTimer = nil
    }
}

// MARK: - Tab model

enum SidebarTab: String, CaseIterable, Identifiable {
    case layout
    case surfaces
    case send
    case notifications
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .layout: return "Layout"
        case .surfaces: return "Surfaces"
        case .send: return "Send"
        case .notifications: return "Alerts"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .layout: return "rectangle.3.group.fill"
        case .surfaces: return "square.split.2x1"
        case .send: return "keyboard"
        case .notifications: return "bell"
        case .settings: return "gear"
        }
    }
}
