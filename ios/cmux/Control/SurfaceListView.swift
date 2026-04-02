import SwiftUI

struct SurfaceListView: View {
    @EnvironmentObject var appState: AppState

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
                    List(appState.surfaces) { surface in
                        Button {
                            appState.focusSurface(surface.id)
                        } label: {
                            Text(surface.title)
                                .foregroundStyle(.primary)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Surfaces")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        appState.refreshSurfaces()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .refreshable {
                appState.refreshSurfaces()
            }
        }
    }
}
