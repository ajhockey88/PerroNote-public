import ActivityKit
import Foundation

/// Shows the recording on the lock screen and in the Dynamic Island while it runs.
@MainActor
final class RecordingActivity {
    static let shared = RecordingActivity()
    private var activity: Activity<RecordingAttributes>?

    func start(title: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = RecordingAttributes.ContentState(timerStart: Date(), isPaused: false, pausedAt: nil)
        activity = try? Activity<RecordingAttributes>.request(
            attributes: RecordingAttributes(title: title),
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil)
    }

    func setPaused(_ paused: Bool, elapsed: TimeInterval) {
        guard let activity else { return }
        let now = Date()
        let state = RecordingAttributes.ContentState(timerStart: now.addingTimeInterval(-elapsed),
                                                     isPaused: paused,
                                                     pausedAt: paused ? now : nil)
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Clears a recording that was left on the lock screen if the app was closed mid-recording.
    static func endAll() {
        Task {
            for activity in Activity<RecordingAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
