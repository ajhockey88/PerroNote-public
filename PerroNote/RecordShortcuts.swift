import AppIntents

/// Lets Siri, the Shortcuts app and the Action Button start a recording.
struct RecordShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRecordingIntent(),
                    phrases: ["Record a meeting with \(.applicationName)",
                              "Start recording in \(.applicationName)"],
                    shortTitle: "Record Meeting",
                    systemImageName: "mic.fill")
    }
}
