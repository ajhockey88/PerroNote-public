import SwiftUI

/// Every action item from every meeting in one place. Tick one here, and it is ticked in the meeting too.
/// It sits to the left of the meetings list; `onBack` slides back to the meetings.
struct ActionItemsView: View {
    var onBack: () -> Void
    @EnvironmentObject private var store: MeetingStore
    @State private var showDone = false
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue

    private var paper: Bool { appearance == AppAppearance.paper.rawValue }

    /// The person whose items are shown, or nil for everyone.
    @State private var person: String?
    @State private var dateFilter: DateFilter = .all
    @State private var tagFilter: String?
    @State private var pickingDay = false
    @State private var pickedDay = Date()
    @State private var adding = false
    @State private var editing: UUID?

    private var filtering: Bool { person != nil || dateFilter != .all || tagFilter != nil }

    /// Everyone who owns at least one action item, A to Z.
    private var people: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in store.allActionItems where !item.task.isEmpty {
            for name in actionOwners(item) where !isEveryoneOwner(name) && seen.insert(name.lowercased()).inserted { out.append(name) }
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func ownedByPick(_ item: ActionItem) -> Bool {
        person.map { p in actionOwners(item).contains { isEveryoneOwner($0) || $0.caseInsensitiveCompare(p) == .orderedSame } } ?? true
    }

    /// Items you added yourself that fit the filters. They have no meeting or tags, so a tag filter hides them.
    private var loose: [ActionItem] {
        guard tagFilter == nil else { return [] }
        return store.looseItems.filter { item in
            (showDone || !item.done) && ownedByPick(item) && dateFilter.contains(item.created ?? .distantPast)
        }
    }

    private var groups: [(meeting: Meeting, items: [ActionItem])] {
        store.meetings.compactMap { meeting in
            guard dateFilter.contains(meeting.date),
                  tagFilter.map({ t in (meeting.tags ?? []).contains { $0.caseInsensitiveCompare(t) == .orderedSame } }) ?? true
            else { return nil }
            let items = (meeting.notes?.actionItems ?? []).filter { item in
                (showDone || !item.done)
                    && (person.map { p in actionOwners(item).contains { isEveryoneOwner($0) || $0.caseInsensitiveCompare(p) == .orderedSame } } ?? true)
            }
            return items.isEmpty ? nil : (meeting, items)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 0) {
                Picker("Show", selection: $showDone) {
                    Text("Open").tag(false)
                    Text("All").tag(true)
                }
                .pickerStyle(.segmented)
                filters.noPageSwipe(onActions: true)
            }
            .padding(.leading, paper ? Paper.textX - 4 : 16)
            .padding(.trailing, 16)
            .padding(.bottom, 4)
            list
        }
        .background(paper ? Color.clear : Color(.systemGroupedBackground))
        .overlay(alignment: .bottomTrailing) {
            Button { adding = true } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor, in: Circle())
                    .shadow(color: Color.accentColor.opacity(0.4), radius: 8, y: 4)
            }
            .padding(.trailing, 20)
            .padding(.bottom, 12)
            .accessibilityLabel("Add an action item")
        }
        .sheet(isPresented: $adding) { NewActionItemView() }
        .paperScreen()
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Action items")
                .font(.custom(CassetteView.markerFont, size: 28))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.leading, paper ? Paper.textX - 16 : 0)
            Spacer(minLength: 8)
            Button(action: onBack) {
                Image(systemName: "chevron.right").font(.title3)
            }
            .accessibilityLabel("Meetings")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    /// A plain scrolling stack rather than a List: a List laid out off screen re-measures its rows as it
    /// slides in, which made them jump for a moment after the swipe.
    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                FocusCard()
                if groups.isEmpty && loose.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checklist").font(.largeTitle).foregroundStyle(.secondary)
                        Text(filtering ? "Nothing matches" : showDone ? "No action items yet" : "Nothing open")
                            .font(.headline)
                        Text(filtering ? "No action items fit the filters you picked."
                                       : "Action items from your meetings show up here.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }

                if !loose.isEmpty {
                    card("Added by you") {
                        ForEach(Array(loose.enumerated()), id: \.element.id) { i, item in
                            if i > 0 { Divider().padding(.leading, 44) }
                            looseRow(item)
                        }
                    }
                }

                ForEach(groups, id: \.meeting.id) { group in
                    card("\(group.meeting.title) · \(group.meeting.date.formatted(date: .abbreviated, time: .omitted))") {
                        ForEach(Array(group.items.enumerated()), id: \.element.id) { i, item in
                            if i > 0 { Divider().padding(.leading, 44) }
                            row(item, in: group.meeting)
                        }
                    }
                }
            }
            .padding(.leading, paper ? Paper.textX - 4 : 16)
            .padding(.trailing, 16)
            .padding(.top, 8)
            .padding(.bottom, 90)
        }
        .sheet(isPresented: $pickingDay) { dayPicker }
        .sheet(item: Binding(get: { editing.map { EditID(id: $0) } }, set: { editing = $0?.id })) { ActionItemEditor(itemID: $0.id) }
    }

    private func pinButton(_ item: ActionItem) -> some View {
        Button { store.togglePin(item.id) } label: {
            Image(systemName: store.isPinned(item.id) ? "star.fill" : "star")
                .foregroundStyle(store.isPinned(item.id) ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(store.isPinned(item.id) ? "Remove from Today\u{2019}s focus" : "Pin to Today\u{2019}s focus")
    }

    /// A titled group of rows on a rounded card, like a grouped list section.
    private func card<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) { rows() }
                .background(chipFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var chipFill: Color { paper ? Color.white.opacity(0.5) : Color(.secondarySystemGroupedBackground) }

    /// Who and when: a person menu, a date menu, and a way to clear both.
    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) { filterChips }
            .padding(.top, 8)
    }

    private var filterChips: some View {
        HStack(spacing: 6) {
            Menu {
                Button { person = nil } label: {
                    Label { Text("Everyone").bold() } icon: {
                        Image(systemName: person == nil ? "checkmark" : "person.3.fill")
                    }
                }
                if !people.isEmpty { Divider() }
                ForEach(people, id: \.self) { name in
                    Button { person = name } label: { pickLabel(name, on: person == name) }
                }
            } label: {
                chip(person ?? "Everyone", icon: "person", on: person != nil)
            }
            Menu {
                ForEach([DateFilter.all, .today, .yesterday, .thisWeek, .lastWeek, .thisMonth], id: \.title) { option in
                    Button { dateFilter = option } label: { pickLabel(option.title, on: dateFilter == option) }
                }
                Divider()
                Button { pickingDay = true } label: { Label("Pick a day\u{2026}", systemImage: "calendar") }
            } label: {
                chip(dateFilter.title, icon: "calendar", on: dateFilter != .all)
            }
            let tags = store.allTags
            if !tags.isEmpty {
                Menu {
                    Button { tagFilter = nil } label: { pickLabel("All tags", on: tagFilter == nil) }
                    Divider()
                    ForEach(tags, id: \.self) { tag in
                        Button { tagFilter = tag } label: { pickLabel(tag, on: tagFilter == tag) }
                    }
                } label: {
                    chip(tagFilter ?? "Tag", icon: "tag", on: tagFilter != nil)
                }
            }
            if filtering {
                Button("Clear") { person = nil; dateFilter = .all; tagFilter = nil }
                    .font(.footnote.weight(.semibold))
            }
        }
        .menuStyle(.button)
        .menuOrder(.fixed)
        .buttonStyle(.borderless)
    }

    @ViewBuilder private func pickLabel(_ title: String, on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func chip(_ title: String, icon: String, on: Bool) -> some View {
        Label(title, systemImage: icon)
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(on ? Color.accentColor : chipFill, in: Capsule())
    }

    private var dayPicker: some View {
        NavigationStack {
            DatePicker("", selection: $pickedDay, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding()
                .frame(maxHeight: .infinity, alignment: .top)
                .navigationTitle("Action items from")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { pickingDay = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Show") { dateFilter = .day(pickedDay); pickingDay = false }
                    }
                }
        }
        .presentationDetents([.large])
    }

    private func looseRow(_ item: ActionItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button { store.toggleLooseItem(item.id) } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.done ? Color.green : Color.secondary)
            }
            .buttonStyle(.borderless)
            Button { editing = item.id } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.task)
                        .strikethrough(item.done)
                        .foregroundStyle(item.done ? .secondary : .primary)
                        .multilineTextAlignment(.leading)
                    TagPills(item: item)
                    let meta = [item.owner, item.due.map { "due \($0)" }].compactMap { $0 }.joined(separator: " · ")
                    if !meta.isEmpty {
                        Text(meta).font(.caption).foregroundStyle(.secondary)
                    }
                    noteLine(item)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            pinButton(item)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive) { store.deleteLooseItem(item.id) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    /// The note written on the website, if any, under the item.
    @ViewBuilder private func noteLine(_ item: ActionItem) -> some View {
        if let note = item.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            Label(note, systemImage: "note.text")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
    }

    private func row(_ item: ActionItem, in meeting: Meeting) -> some View {
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

            Button { editing = item.id } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.task.isEmpty ? "(empty)" : item.task)
                        .strikethrough(item.done)
                        .foregroundStyle(item.done ? .secondary : .primary)
                        .multilineTextAlignment(.leading)
                    TagPills(item: item)
                    let meta = [item.owner, item.due.map { "due \($0)" }].compactMap { $0 }.joined(separator: " · ")
                    if !meta.isEmpty {
                        Text(meta).font(.caption).foregroundStyle(.secondary)
                    }
                    noteLine(item)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            pinButton(item)
            NavigationLink(value: meeting.id) {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .padding(.vertical, 6).padding(.leading, 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open meeting")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

/// Adds an action item for you by hand: what needs doing and when it's due.
struct NewActionItemView: View {
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(BannerSettings.myNameKey) private var myName = ""
    @State private var task = ""
    @State private var due = Date()
    @FocusState private var focused: Bool

    private var canSave: Bool { !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Action item", text: $task, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($focused)
                } footer: {
                    Text(myName.isEmpty ? "Assigned to you. Add your name under Action items banner in Settings so it matches your items from meetings."
                                        : "Assigned to you (\(myName)).")
                }
                Section("Due") {
                    DatePicker("Due", selection: $due, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                }
            }
            .paperScreen()
            .navigationTitle("New action item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: save).disabled(!canSave)
                }
            }
            .onAppear { focused = true }
        }
    }

    private func save() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, MMM d, yyyy"
        let me = myName.trimmingCharacters(in: .whitespacesAndNewlines)
        store.addLooseItem(ActionItem(task: task.trimmingCharacters(in: .whitespacesAndNewlines),
                                      owner: me.isEmpty ? "Me" : me,
                                      due: f.string(from: due),
                                      created: Date()))
        dismiss()
    }
}
