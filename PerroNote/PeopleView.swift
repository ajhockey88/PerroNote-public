import SwiftUI

/// Opens the people list from the meetings screen.
struct PeopleRoute: Hashable {}

/// Opens one person's page.
struct PersonRoute: Hashable {
    let name: String
}

/// Everyone from your meetings: saved people, attendees and action item owners.
struct PeopleView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var people: PeopleStore

    private var names: [String] {
        var seen = Set<String>()
        var out: [String] = []
        func add(_ name: String) {
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !MeetingNotes.isSpeakerLabel(clean), seen.insert(clean.lowercased()).inserted else { return }
            out.append(clean)
        }
        people.people.forEach { add($0.name) }
        for m in store.meetings {
            (m.attendeeNames ?? []).forEach(add)
            (m.notes?.attendees ?? []).forEach(add)
            (m.voices ?? []).compactMap(\.name).forEach(add)
            (m.notes?.actionItems ?? []).flatMap(actionOwners).forEach(add)
        }
        store.looseItems.flatMap(actionOwners).forEach(add)
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func openCount(_ name: String) -> Int {
        store.allActionItems.filter { item in
            !item.done && !item.task.isEmpty
                && actionOwners(item).contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }.count
    }

    var body: some View {
        List {
            if names.isEmpty {
                Text("People from your meetings show up here once notes name them.")
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            ForEach(names, id: \.self) { name in
                NavigationLink(value: PersonRoute(name: name)) {
                    HStack {
                        Text(name)
                        Spacer()
                        let open = openCount(name)
                        if open > 0 {
                            Text("\(open) open")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.red.opacity(0.14), in: Capsule())
                        }
                    }
                }
            }
        }
        .paperScreen()
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One person: what they owe, what they've finished, and every meeting they were in.
struct PersonView: View {
    let name: String
    @EnvironmentObject private var store: MeetingStore
    @State private var showDone = false

    private func owns(_ item: ActionItem) -> Bool {
        !item.task.isEmpty && actionOwners(item).contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Their items from meetings, then the ones you added yourself (which have no meeting).
    private var items: [(meeting: Meeting?, item: ActionItem)] {
        store.meetings.flatMap { m in (m.notes?.actionItems ?? []).filter(owns).map { (meeting: Optional(m), item: $0) } }
            + store.looseItems.filter(owns).map { (meeting: Meeting?.none, item: $0) }
    }

    private var meetings: [Meeting] {
        store.meetings.filter { m in m.includes(name) || (m.notes?.actionItems ?? []).contains(where: owns) }
            .sorted { $0.date > $1.date }
    }

    private var talkTime: Double {
        store.meetings.reduce(0) { sum, m in
            sum + (m.voices ?? []).filter { $0.name?.caseInsensitiveCompare(name) == .orderedSame }.reduce(0) { $0 + $1.talkTime }
        }
    }

    var body: some View {
        let open = items.filter { !$0.item.done }
        let done = items.filter { $0.item.done }
        List {
            Section {
                HStack(spacing: 0) {
                    stat("\(meetings.count)", meetings.count == 1 ? "meeting" : "meetings")
                    stat("\(open.count)", "open")
                    stat("\(done.count)", "done")
                    if talkTime > 0 { stat(formatDuration(talkTime), "talking") }
                }
            }

            Section("Open action items") {
                if open.isEmpty {
                    Text("Nothing open.").foregroundStyle(.secondary)
                }
                ForEach(open, id: \.item.id) { row($0.item, in: $0.meeting) }
            }

            if !done.isEmpty {
                Section {
                    if showDone {
                        ForEach(done, id: \.item.id) { row($0.item, in: $0.meeting) }
                    }
                } header: {
                    Button(showDone ? "Hide done (\(done.count))" : "Show done (\(done.count))") {
                        withAnimation { showDone.toggle() }
                    }
                    .font(.footnote.weight(.semibold))
                    .textCase(nil)
                }
            }

            Section("Meetings") {
                if meetings.isEmpty {
                    Text("No meetings yet.").foregroundStyle(.secondary)
                }
                ForEach(meetings) { m in
                    NavigationLink(value: m.id) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.title)
                            Text(m.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .paperScreen()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.bold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func row(_ item: ActionItem, in meeting: Meeting?) -> some View {
        if let meeting { meetingRow(item, in: meeting) } else { looseRow(item) }
    }

    private func looseRow(_ item: ActionItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button { store.toggleLooseItem(item.id) } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.done ? Color.green : Color.secondary)
            }
            .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.task)
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? .secondary : .primary)
                Text(["Added by you", item.due.map { "due \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func meetingRow(_ item: ActionItem, in meeting: Meeting) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                store.update(meeting.id) { m in
                    if let i = m.notes?.actionItems.firstIndex(where: { $0.id == item.id }) {
                        m.notes?.actionItems[i].done.toggle()
                    }
                }
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.done ? Color.green : Color.secondary)
            }
            .buttonStyle(.borderless)

            NavigationLink(value: meeting.id) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.task)
                        .strikethrough(item.done)
                        .foregroundStyle(item.done ? .secondary : .primary)
                    let meta = [meeting.title, item.due.map { "due \($0)" }].compactMap { $0 }.joined(separator: " · ")
                    Text(meta).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
