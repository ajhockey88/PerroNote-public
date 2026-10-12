import SwiftUI

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

    var body: some Scene {
        WindowGroup {
            MeetingListView()
                .environmentObject(store)
                .environmentObject(people)
                .preferredColorScheme(AppAppearance(rawValue: appearance)?.scheme)
                .onChange(of: scenePhase) { phase in
                    if phase != .active { store.flush() }
                }
                .onAppear {
                    store.people = people
                    RecordingActivity.endAll()
                }
        }
    }
}
