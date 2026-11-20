import SwiftUI

struct WorkspaceListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            Group {
                if appState.visibleWorkspaces.isEmpty {
                    ContentUnavailableView(
                        "No workspaces",
                        systemImage: "rectangle.3.group",
                        description: Text("Connect to a bridge to see your workspaces.")
                    )
                } else {
                    List(appState.visibleWorkspaces) { workspace in
                        Button {
                            appState.selectWorkspace(workspace.id)
                        } label: {
                            HStack {
                                Text(appState.displayTitle(for: workspace))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if workspace.id == appState.currentWorkspaceID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Workspaces")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { appState.refreshWorkspaces() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .refreshable { appState.refreshWorkspaces() }
        }
    }
}
