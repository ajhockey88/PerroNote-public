import SwiftUI
import UIKit
import UserNotifications

/// The look you chose in Settings. System follows the iPhone's Light or Dark setting; Paper is a yellow legal pad.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark, paper
    static let key = "appearance"
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light, .paper: return .light
        case .dark: return .dark
        }
    }
}

@main
struct PerroNoteApp: App {
    @StateObject private var store = MeetingStore()
    @StateObject private var people = PeopleStore()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            MeetingListView()
                .environmentObject(store)
                .environmentObject(people)
                .preferredColorScheme(AppAppearance(rawValue: appearance)?.scheme)
                .onChange(of: scenePhase) { phase in
                    if phase == .background { store.flush(); store.syncInBackground() }
                    else if phase != .active { store.flush() }
                    else { store.applyWidgetTicks(); store.refreshAlerts(); store.scheduleSync(after: 0.5) }
                }
                .onOpenURL { RecordRequest.shared.open($0) }
                .onAppear {
                    store.people = people
                    RecordingActivity.endAll()
                }
        }
    }
}

/// Tapping a due date alert opens the action items page.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.content.userInfo["open"] as? String == "action-items" else { return }
        await MainActor.run { RecordRequest.shared.showActions = true }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
