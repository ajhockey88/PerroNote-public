import ActivityKit
import Foundation

/// What the lock screen and Dynamic Island show while a recording is running.
/// Shared by the app and the widget extension.
struct RecordingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// A start time shifted by any pauses, so a running timer counts the recorded length.
        var timerStart: Date
        var isPaused: Bool
        /// When paused, the moment it stopped, which freezes the timer.
        var pausedAt: Date?
    }

    var title: String
}
