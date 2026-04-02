import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if case .disconnected = appState.connectionStatus,
           (try? PairingStore().load()) == nil {
            PairingView()
        } else {
            MainTabView()
                .sheet(isPresented: $appState.isPairingPresented) {
                    PairingView()
                }
        }
    }
}
