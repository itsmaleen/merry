import SwiftUI
import UserNotifications

@main
struct merryApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var quickActionStore = QuickActionStore()
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        UserDefaults.standard.register(defaults: [
            "autoSubmitSpeech": true,
            // Hijacking the hardware volume buttons is opt-in: until the user
            // turns it on, the buttons stay ordinary volume controls.
            "volumeButtonControls": false,
        ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(quickActionStore)
                .onOpenURL { url in
                    appState.handlePairingURL(url)
                }
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // Show notifications even when app is in foreground (as banner)
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // Tapping a notification focuses the surface it came from.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let surfaceID = info["surface_id"] as? String else { return }
        let workspaceID = info["workspace_id"] as? String
        await MainActor.run {
            AppState.handleNotificationTap(surfaceID: surfaceID, workspaceID: workspaceID)
        }
    }
}
