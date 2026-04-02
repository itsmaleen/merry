import SwiftUI

@main
struct cmuxApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onOpenURL { url in
                    appState.handlePairingURL(url)
                }
        }
    }
}
