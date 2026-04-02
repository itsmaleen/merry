import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            NotificationsView()
                .tabItem { Label("Notifications", systemImage: "bell") }
                .badge(appState.notifications.count > 0 ? appState.notifications.count : 0)

            WorkspaceListView()
                .tabItem { Label("Workspaces", systemImage: "rectangle.3.group") }

            SurfaceListView()
                .tabItem { Label("Surfaces", systemImage: "square.split.2x1") }

            SendTextView()
                .tabItem { Label("Send", systemImage: "keyboard") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .overlay(alignment: .top) {
            ConnectionStatusBar()
        }
    }
}
