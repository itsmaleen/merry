import SwiftUI

// ControlView is a container used if you want to embed workspace/surface/send
// in a single tab as a NavigationSplitView on iPad. On iPhone the tab bar
// in MainTabView handles navigation directly.
struct ControlView: View {
    var body: some View {
        WorkspaceListView()
    }
}
