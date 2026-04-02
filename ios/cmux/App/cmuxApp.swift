import SwiftUI

@main
struct cmuxApp: App {
    @StateObject private var appState = AppState()

    init() {
        UserDefaults.standard.register(defaults: ["autoSubmitSpeech": true])
    }

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
