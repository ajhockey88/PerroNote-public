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

    static let processWalkthrough = NoteTemplate(
        name: "Process walkthrough",
        tag: "Process",
        useTime: false,
        instructions: """
        This is a process walkthrough: someone is explaining, step by step, how they do a process that is not \
        written down yet, so it can be turned into an SOP or work instruction. Capture the whole process in the order \
        the work happens. Completeness and exact detail matter more than keeping the notes short, so keep every step, \
        check, exception and tip that was said, using the exact names of systems, screens, menus, fields, buttons, \
        reports, files, folders and teams.
        Use these topics, in this order, and leave out any that nothing was said about:
        1. "Purpose and scope": what the process achieves, where it starts and ends, and what is in or out of scope.
        2. "Trigger and timing": what starts it, how often it runs, deadlines, cut-off times and how long it takes.
        3. "Roles": who does what, by name and role or team: the owner, the people who do the work, approvers, and \
        who receives handoffs.
        4. "Systems, tools and inputs": every system, application, report, file, form, template, access or permission \
        needed, and the information or documents needed before starting.
        5. The procedure: one or more topics titled "Steps: " plus the phase (for example "Steps: Intake" or \
        "Steps: Review and approval"), in the order the work is done. Each point is one step written as an \
        instruction that starts with a verb, numbered across all phases ("Step 1: Open the vendor record in SAP", \
        "Step 2: ..."). Put the specifics in the step's sub-points, as many as the step needs: where to click or go, \
        fields and the values to enter, what to check, who does it when it is someone else, and what the result \
        should be.
        6. "Decision points and exceptions": each branch as "If ..., then ...", plus exceptions, edge cases, \
        workarounds, what to do when something goes wrong, and who to escalate to.
        7. "Outputs and handoffs": what the process produces, where it is saved or sent, who gets it, and how you \
        know it is finished.
        8. "Controls and records": approvals, reviews, reconciliations, audit or compliance requirements, and the \
        records that must be kept.
        9. "Tips and common mistakes": pitfalls, workarounds and know-how the person shared.
        10. "Pain points and ideas": manual work, delays, single points of failure, and improvement ideas raised.
        Title: the process name followed by "process", for example "Vendor onboarding process". Summary: two to four \
        sentences naming the process, its purpose, who does it, how often, and where it starts and ends. Open \
        questions: every gap an SOP writer would still need filled, such as a step that was skipped over or unclear, \
        an unknown owner, a missing system name, the order of steps being uncertain, or a screenshot or example still \
        needed. Action items: follow-ups promised, such as sending templates, example files, screenshots or access. \
        Risks: risks to the process itself. Only list decisions that were actually made. Never invent steps; if the \
        order was unclear, keep the order described and say so under open questions.
        """)

    static let builtIns: [NoteTemplate] = [.standUp, .processWalkthrough]

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
                  let list = try? JSONDecoder().decode([NoteTemplate].self, from: data) else { return NoteTemplate.builtIns }
            // Templates added in later versions join the ones you already have.
            let missing = NoteTemplate.builtIns.filter { b in !list.contains { $0.name == b.name } }
            return list + missing
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    /// The first template whose rules fit this meeting, or nil for the usual notes.
    static func match(date: Date, tags: [String]?) -> NoteTemplate? {
        all.first { $0.matches(date: date, tags: tags) }
    }

    /// The template saved on a meeting: "" means standard notes were picked, nil means pick by the rules.
    static func chosen(_ name: String?, date: Date, tags: [String]?) -> NoteTemplate? {
        guard let name else { return match(date: date, tags: tags) }
        if name.isEmpty { return nil }
        return all.first { $0.name == name } ?? match(date: date, tags: tags)
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
