import Foundation
import SwiftUI

/// A different shape for the notes, picked automatically after recording so starting a recording stays one tap.
struct NoteTemplate: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var enabled = true
    /// A meeting with this tag uses the template. Blank means no tag rule.
    var tag = ""
    /// Also use it for meetings that start around this time of day.
    var useTime = true
    /// Minutes after midnight.
    var minutes = 10 * 60 + 30
    /// How many minutes either side of the time still count.
    var window = 15
    var weekdaysOnly = true
    /// Extra instructions for the notes writer.
    var instructions: String

    static let standUp = NoteTemplate(
        name: "Daily stand-up",
        tag: "Stand Up",
        instructions: """
        This is a daily stand-up call where each person gives their update in turn. Write the notes so that \
        every person who gave an update has their own topic. The topic title is just that person's name (use the \
        real name when the speaker label has one). Under each topic, the points are what they did, what they are doing \
        next, and anything blocking them, one short point each, and a point about a blocker starts with "Blocker:". \
        Do not leave out anyone who spoke. Action items go to the person who owns them. The summary is one or two \
        sentences on what the team is working on, who is out, and what is blocked. Only list decisions and open \
        questions that were actually stated.
        """)

    private static func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    func matches(date: Date, tags: [String]?) -> Bool {
        guard enabled else { return false }
        if !tag.trimmingCharacters(in: .whitespaces).isEmpty,
           (tags ?? []).contains(where: { Self.squash($0) == Self.squash(tag) }) { return true }
        guard useTime else { return false }
        let cal = Calendar.current
        if weekdaysOnly, cal.isDateInWeekend(date) { return false }
        let parts = cal.dateComponents([.hour, .minute], from: date)
        let start = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return abs(start - minutes) <= window
    }
}

enum NoteTemplates {
    private static let key = "note-templates"

    static var all: [NoteTemplate] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let list = try? JSONDecoder().decode([NoteTemplate].self, from: data) else { return [.standUp] }
            return list
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    /// The first template whose rules fit this meeting, or nil for the usual notes.
    static func match(date: Date, tags: [String]?) -> NoteTemplate? {
        all.first { $0.matches(date: date, tags: tags) }
    }
}

/// Edit when each template is used. Recording stays one tap; the template is picked after, from these rules.
struct NoteTemplatesView: View {
    @State private var templates = NoteTemplates.all

    private func time(_ t: Binding<NoteTemplate>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: t.wrappedValue.minutes / 60, minute: t.wrappedValue.minutes % 60, second: 0, of: Date()) ?? Date() },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                t.wrappedValue.minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }

    var body: some View {
        Form {
            ForEach($templates) { $t in
                Section {
                    Toggle("Use this template", isOn: $t.enabled)
                    TextField("Tag that picks it", text: $t.tag)
                        .textInputAutocapitalization(.words).autocorrectionDisabled()
                    Toggle("Also pick it by start time", isOn: $t.useTime)
                    if t.useTime {
                        DatePicker("Meeting starts around", selection: time($t), displayedComponents: .hourAndMinute)
                        Stepper("Within \(t.window) minutes", value: $t.window, in: 5...60, step: 5)
                        Toggle("Weekdays only", isOn: $t.weekdaysOnly)
                    }
                    TextEditor(text: $t.instructions)
                        .frame(minHeight: 160)
                        .font(.footnote)
                } header: {
                    Text(t.name)
                } footer: {
                    Text("After a recording is transcribed, the first template whose tag or start time fits is used for the notes. Nothing changes about starting a recording. Open a meeting's \u{22EF} menu and tap Redraft as\u{2026} to use a different one.")
                }
            }
        }
        .navigationTitle("Note templates")
        .onChange(of: templates) { NoteTemplates.all = $0 }
    }
}
