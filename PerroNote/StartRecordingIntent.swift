import AppIntents
import Foundation

/// Opens PerroNote straight onto the recorder. The Control Center button, Siri and Shortcuts all use it.
struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Record Meeting"
    static var description = IntentDescription("Opens PerroNote and starts recording a meeting.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        RecordRequest.shared.pending = true
        return .result()
    }
}

/// Set when something outside the app asks to start recording; the meetings screen opens the recorder.
@MainActor
final class RecordRequest: ObservableObject {
    static let shared = RecordRequest()
    @Published var pending = false
    /// Set by a widget or a due date alert; the meetings screen slides over to the action items.
    @Published var showActions = false

    /// perronote://record starts recording; perronote://actions opens the action items.
    func open(_ url: URL) {
        guard url.scheme == "perronote" else { return }
        switch url.host {
        case "record": pending = true
        case "actions": showActions = true
        default: break
        }
    }
}
